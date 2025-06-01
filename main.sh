#!/bin/bash

# Load config
set -a
source .env
set +a

BASE_URL="https://api.bitget.com/api/mix/v1"
SYMBOLS=("BTCUSDT" "ETHUSDT")
LAST_UPDATE_FILE="last_update_id.txt"

init_db() {
    sqlite3 $DB_FILE <<EOF
    CREATE TABLE IF NOT EXISTS trades (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        time TEXT,
        symbol TEXT,
        side TEXT,
        size REAL,
        status TEXT
    );
EOF
}

log_info() {
    local msg="$1"
    echo "$(date '+%Y-%m-%d %H:%M:%S') | INFO | $msg" | tee -a $LOG_FILE
    export_to_sheets "$msg"
}

log_error() {
    local msg="$1"
    echo "$(date '+%Y-%m-%d %H:%M:%S') | ERROR | $msg" | tee -a $LOG_FILE
    export_to_sheets "$msg"
}

export_to_sheets() {
    local log_line="$1"
    local json="{\"values\":[[\"$(date '+%Y-%m-%d %H:%M:%S')\",\"$log_line\"]]}"
    curl -s -X POST \
        -H "Authorization: Bearer $GOOGLE_SHEETS_TOKEN" \
        -H "Content-Type: application/json" \
        -d "$json" \
        "https://sheets.googleapis.com/v4/spreadsheets/$SHEET_ID/values/$SHEET_RANGE:append?valueInputOption=RAW" >/dev/null
}

notify_telegram() {
    local message=$1
    curl -s -X POST "https://api.telegram.org/bot$TELEGRAM_BOT_TOKEN/sendMessage" \
        -d chat_id="$TELEGRAM_PERSONAL_CHAT_ID" \
        -d text="$message" >/dev/null
}

get_latest_message() {
    local last_update_id=0
    if [ -f "$LAST_UPDATE_FILE" ]; then
        last_update_id=$(cat $LAST_UPDATE_FILE)
    fi

    response=$(curl -s "https://api.telegram.org/bot$TELEGRAM_BOT_TOKEN/getUpdates?offset=$((last_update_id + 1))")
    if [ $? -ne 0 ] || [ -z "$response" ]; then
        log_error "Failed to get Telegram updates"
        return 1
    fi

    update_id=$(echo "$response" | jq '.result[-1].update_id')
    message=$(echo "$response" | jq -r '.result[-1].message.text')

    if [ "$update_id" != "null" ]; then
        echo "$update_id" > $LAST_UPDATE_FILE
    fi

    echo "$message"
}

generate_signature() {
    local prehash="$1"
    echo -n "$prehash" | openssl dgst -sha256 -hmac "$BITGET_API_SECRET" -binary | base64
}

api_get() {
    local endpoint=$1
    local query=$2

    local timestamp=$(($(date +%s%N)/1000000))
    local sign=$(generate_signature "$timestampGET$endpoint$query")

    response=$(curl -s -G "$BASE_URL$endpoint" \
        --data "$query" \
        -H "ACCESS-KEY: $BITGET_API_KEY" \
        -H "ACCESS-SIGN: $sign" \
        -H "ACCESS-TIMESTAMP: $timestamp" \
        -H "ACCESS-PASSPHRASE: $BITGET_API_PASSPHRASE")

    echo "$response"
}

check_open_position_api() {
    local symbol=$1
    response=$(api_get "/position/singlePosition" "symbol=$symbol&marginCoin=USDT")
    if [ $? -ne 0 ] || [ -z "$response" ]; then
        log_error "Failed to check open position"
        return 1
    fi

    side=$(echo "$response" | jq -r '.data.holdSide')
    if [ "$side" == "long" ] || [ "$side" == "short" ]; then
        echo "$side"
        return 0
    else
        echo "none"
        return 1
    fi
}

api_post() {
    local endpoint=$1
    local body=$2

    local timestamp=$(($(date +%s%N)/1000000))
    local sign=$(generate_signature "$timestampPOST$endpoint$body")

    response=$(curl -s -X POST "$BASE_URL$endpoint" \
        -H "ACCESS-KEY: $BITGET_API_KEY" \
        -H "ACCESS-SIGN: $sign" \
        -H "ACCESS-TIMESTAMP: $timestamp" \
        -H "ACCESS-PASSPHRASE: $BITGET_API_PASSPHRASE" \
        -H "Content-Type: application/json" \
        -d "$body")

    code=$(echo "$response" | jq -r '.code')
    if [ "$code" != "00000" ]; then
        log_error "API error on $endpoint: $(echo "$response" | jq -r '.msg')"
        return 1
    fi

    log_info "API $endpoint success"
    return 0
}

close_position() {
    local symbol=$1
    api_post "/order/close" "{\"symbol\":\"$symbol\",\"marginCoin\":\"USDT\"}" || return 1
    log_info "Closed position on $symbol"
}

open_position() {
    local symbol=$1
    local side=$2
    local body="{\"symbol\":\"$symbol\",\"marginCoin\":\"USDT\",\"side\":\"$side\",\"size\":\"$SIZE\"}"

    api_post "/order" "$body" || return 1
    log_info "Opened $side on $symbol"
}

set_tp_sl() {
    local symbol=$1
    local body="{\"symbol\":\"$symbol\",\"marginCoin\":\"USDT\",\"tpTriggerPrice\":\"$TP_PRICE\",\"slTriggerPrice\":\"$SL_PRICE\"}"

    api_post "/order/tpsl" "$body" || return 1
}

process_signal() {
    local symbol=$1
    local signal=$2
    current_side=$(check_open_position_api "$symbol")

    if [[ "$signal" == "LONG" && "$current_side" == "short" ]]; then
        close_position "$symbol"
        open_position "$symbol" "open_long" && set_tp_sl "$symbol" && notify_telegram "🔄 Switched to LONG $symbol"
    elif [[ "$signal" == "SHORT" && "$current_side" == "long" ]]; then
        close_position "$symbol"
        open_position "$symbol" "open_short" && set_tp_sl "$symbol" && notify_telegram "🔄 Switched to SHORT $symbol"
    elif [[ "$signal" == "LONG" && "$current_side" == "none" ]]; then
        open_position "$symbol" "open_long" && set_tp_sl "$symbol" && notify_telegram "✅ Opened LONG $symbol"
    elif [[ "$signal" == "SHORT" && "$current_side" == "none" ]]; then
        open_position "$symbol" "open_short" && set_tp_sl "$symbol" && notify_telegram "✅ Opened SHORT $symbol"
    else
        log_info "No action needed for $symbol"
    fi
}

main_loop() {
    init_db
    while true; do
        message=$(get_latest_message)
        if [ $? -ne 0 ] || [ -z "$message" ]; then
            sleep 10
            continue
        fi

        for symbol in "${SYMBOLS[@]}"; do
            if [[ "$message" == *"${symbol} LONG"* ]]; then
                process_signal "$symbol" "LONG"
            elif [[ "$message" == *"${symbol} SHORT"* ]]; then
                process_signal "$symbol" "SHORT"
            else
                log_info "No valid signal for $symbol"
            fi
        done

        sleep 30
    done
}

main_loop
