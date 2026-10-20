#!/bin/sh
# Fake TUI: uses the alternate screen, shows a spinner, then exits.
# Enters alternate screen, shows a progress display, leaves alternate screen.
printf '\033[?1049h'
printf '\033[2J\033[H'
echo ""
echo "  ┌─────────────────────────────────────┐"
echo "  │         Deploying to production     │"
echo "  │                                     │"
i=0
while [ $i -lt 8 ]; do
    i=$((i + 1))
    case $i in
        1) step="Building image..."       ;;
        2) step="Pushing to registry..."  ;;
        3) step="Waiting for rollout..."  ;;
        4) step="Running health checks..." ;;
        5) step="Updating DNS..."         ;;
        6) step="Flipping traffic..."     ;;
        7) step="Verifying endpoints..."  ;;
        8) step="Done!"                   ;;
    esac
    dots=""
    j=0
    while [ $j -lt $((i % 4 + 1)) ]; do dots="${dots}."; j=$((j+1)); done
    printf '\033[4A  │  \033[32m●\033[0m %s%s              │\n' "$step" "$dots"
    sleep 1
done
echo "  │                                     │"
echo "  │  \033[32m✓ Deploy complete in 8.2s\033[0m        │"
echo "  └─────────────────────────────────────┘"
echo ""
sleep 2
printf '\033[?1049l'
exit 0
