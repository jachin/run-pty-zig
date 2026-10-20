#!/bin/sh
# Interactive REPL: reads lines and echoes them back with a prompt.
printf '\033[1mmylang\033[0m v2.1.0 — type \033[33m:quit\033[0m to exit\n'
printf '\033[2m  :help for commands, :run to execute\033[0m\n'
echo ""
while true; do
    printf '\033[36m❯\033[0m '
    read -r line
    [ -z "$line" ] && continue
    case "$line" in
        :quit|:q|exit)
            echo "Goodbye!"
            exit 0
            ;;
        :help)
            echo "  :run    execute the current buffer"
            echo "  :ls     list files"
            echo "  :quit   exit the REPL"
            ;;
        :run)
            printf '\033[32m  → executing...\033[0m\n'
            sleep 1
            printf '\033[32m  ✓ done (42ms)\033[0m\n'
            ;;
        :ls)
            printf '  main.js  utils.ts  config.json\n'
            ;;
        *)
            printf '  \033[2mevaluated: %s\033[0m\n' "$line"
            ;;
    esac
done
