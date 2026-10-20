#!/bin/sh
# Fake log tailer: prints timestamped log lines forever.
echo "Tailing application.log..."
echo ""
i=0
while true; do
    i=$((i + 1))
    ts=$(date "+%H:%M:%S")
    case $((i % 6)) in
        1) printf '\033[90m%s\033[0m \033[32mINFO\033[0m  Request handled in %dms\n' "$ts" $((10 + RANDOM % 100)) ;;
        2) printf '\033[90m%s\033[0m \033[32mINFO\033[0m  User session created (id=%d)\n' "$ts" $((1000 + RANDOM % 9000)) ;;
        3) printf '\033[90m%s\033[0m \033[33mWARN\033[0m  Slow query: %dms (threshold: 200ms)\n' "$ts" $((200 + RANDOM % 800)) ;;
        4) printf '\033[90m%s\033[0m \033[32mINFO\033[0m  Cache hit ratio: %d%%\n' "$ts" $((80 + RANDOM % 20)) ;;
        5) printf '\033[90m%s\033[0m \033[31mERROR\033[0m Connection timeout to db-replica-2\n' "$ts" ;;
        6) printf '\033[90m%s\033[0m \033[32mINFO\033[0m  GC pause: %dms\n' "$ts" $((1 + RANDOM % 20)) ;;
    esac
    sleep 1
done
