#!/bin/bash

# === Load config ===
set -a
source .env
set +a

BASE_URL="https://api.bitget.com/api/mix/v1"
PROGRESS_FILE="progress.csv"
START_BALANCE=10
TARGET_BALANCE=100
SLEEP_SECONDS=300  # 5 minutes

# === Function: Generate signature ===
generate_signature() {
    local prehash="$1"
    echo -n "$prehash" | openssl dgst -sha256 -hmac "$BITGET_API_SECRET" -binary | base64
}

# === Function: Call Bitget API (GET) ===
api_get() {
    local endpoint=$1
    local query=$2

    local timestamp=$(($(date +%s%N)/1000000))
    local sign=$(generate_signature "$timestampGET$endpoint$query")

    curl -s -G "$BASE_URL$endpoint" \
        --data "$query" \
        -H "ACCESS-KEY: $BITGET_API_KEY" \
        -H "ACCESS-SIGN: $sign" \
        -H "ACCESS-TIMESTAMP: $timestamp" \
        -H "ACCESS-PASSPHRASE: $BITGET_API_PASSPHRASE"
}

# === Function: Check USDT balance ===
check_balance() {
    response=$(api_get "/account/accounts" "productType=USDT")
    balance=$(echo "$response" | jq -r '.data[] | select(.symbol=="USDT") | .available')
    echo "$balance"
}

# === Function: Update progress CSV ===
update_progress_file() {
    local date=$(date '+%Y-%m-%d %H:%M:%S')
    local balance=$1
    local percent=$(echo "scale=2; ($balance / $TARGET_BALANCE) * 100" | bc)

    if [ ! -f "$PROGRESS_FILE" ]; then
        echo "Date,Balance,Progress%" > "$PROGRESS_FILE"
    fi

    echo "$date,$balance,$percent" >> "$PROGRESS_FILE"
    echo "✅ [$date] Balance: $balance USDT ($percent% to $TARGET_BALANCE USDT target)"
}

# === Function: Notify Telegram ===
notify_telegram() {
    local message=$1
    curl -s -X POST "https://api.telegram.org/bot$TELEGRAM_BOT_TOKEN/sendMessage" \
        -d chat_id="$TELEGRAM_PERSONAL_CHAT_ID" \
        -d text="$message" >/dev/null
}

# === Main Loop ===
main_loop() {
    while true; do
        balance=$(check_balance)

        if [ -z "$balance" ] || [ "$balance" == "null" ]; then
            echo "❌ Failed to get balance. Retrying in $SLEEP_SECONDS seconds..."
            sleep $SLEEP_SECONDS
            continue
        fi

        update_progress_file "$balance"

        percent=$(echo "scale=2; ($balance / $TARGET_BALANCE) * 100" | bc)
        message="📈 Challenge Progress Update:\nBalance: $balance USDT\nProgress: $percent% towards $TARGET_BALANCE USDT target"
        notify_telegram "$message"

        if (( $(echo "$balance >= $TARGET_BALANCE" | bc -l) )); then
            notify_telegram "🎉 Challenge COMPLETE! Final balance: $balance USDT 🎉"
            break
        elif (( $(echo "$balance <= 1" | bc -l) )); then
            notify_telegram "⚠ Challenge FAILED! Balance dropped to $balance USDT ⚠"
            break
        fi

        echo "Sleeping for $SLEEP_SECONDS seconds before next check..."
        sleep $SLEEP_SECONDS
    done
}

main_loop
