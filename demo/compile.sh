#!/bin/sh
# Fake compiler: prints warnings (yellow) and errors (red), exits 0.
echo "Compiling 12 files..."
echo ""
printf '  src/main.c\n'
sleep 0.5
printf '  src/parser.c\n'
sleep 0.5
printf '  src/lexer.c:42: \033[33mwarning:\033[0m unused variable %s\n' "'tmp_buf'"
sleep 0.5
printf '  src/lexer.c:87: \033[33mwarning:\033[0m implicit int return in %s\n' "'parse_token()'"
sleep 0.5
printf '  src/optimizer.c\n'
sleep 0.5
printf '  src/codegen.c:15: \033[31merror:\033[0m expected %s, got %s\n' "'{'" "';'"
sleep 0.5
printf '  src/codegen.c:15: \033[31m  →\033[0m did you mean %s?\n' "'{'"
sleep 0.5
echo ""
printf '\033[31m1 error\033[0m, \033[33m2 warnings\033[0m in 6 files (0.8s)\n'
exit 1
