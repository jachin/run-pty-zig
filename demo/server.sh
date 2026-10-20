#!/bin/sh
# Fake web server: prints "listening" then fake HTTP requests forever.
printf '\033[32m➜\033[0m Local:    \033[1mhttp://localhost:3000\033[0m\n'
printf '\033[32m➜\033[0m Network:  \033[1mhttp://192.168.1.42:3000\033[0m\n'
echo ""
echo "Ready in 342ms"
echo ""
i=0
while true; do
    i=$((i + 1))
    case $((i % 5)) in
        1) method="GET";    path="/";           status=200 ;;
        2) method="GET";    path="/api/users";  status=200 ;;
        3) method="POST";   path="/api/login";  status=201 ;;
        4) method="GET";    path="/api/orders"; status=500 ;;
        5) method="DELETE"; path="/api/sessions"; status=204 ;;
    esac
    color=32
    [ "$status" = "500" ] && color=31
    [ "$status" = "201" ] && color=36
    printf '\033[%dm%s\033[0m %s \033[%dm%s\033[0m (%dms)\n' \
        "$color" "$method" "$path" "$color" "$status" $((5 + RANDOM % 50))
    sleep 2
done
