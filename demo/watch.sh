#!/bin/sh
# Fake file watcher: prints "watching" then periodic change events forever.
printf '\033[32m●\033[0m Watching \033[1m./src\033[0m for changes...\n'
i=0
while true; do
    i=$((i + 1))
    case $((i % 4)) in
        1) f="main.js" ;;
        2) f="utils.ts" ;;
        3) f="components/Button.tsx" ;;
        4) f="styles.css" ;;
    esac
    sleep 2
    printf '\033[33m↻\033[0m change detected in \033[36m%s\033[0m\n' "$f"
    sleep 1
    printf '  \033[2mrecompiled in %dms\033[0m\n' $((100 + RANDOM % 400))
done
