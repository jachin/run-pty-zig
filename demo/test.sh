#!/bin/sh
# Fake test runner: prints test results, one fails, exits 1.
echo "Running 8 tests..."
echo ""
printf '  \033[32m✓\033[0m adds two numbers (2ms)\n'
sleep 0.3
printf '  \033[32m✓\033[0m handles negative numbers (1ms)\n'
sleep 0.3
printf '  \033[32m✓\033[0m trims whitespace (3ms)\n'
sleep 0.3
printf '  \033[32m✓\033[0m parses JSON (5ms)\n'
sleep 0.3
printf '  \033[32m✓\033[0m serializes to JSON (4ms)\n'
sleep 0.3
printf '  \033[32m✓\033[0m handles empty arrays (1ms)\n'
sleep 0.3
printf '  \033[31m✗\033[0m handles null values (2ms)\n'
printf '    \033[31m→ expected null, got undefined\033[0m\n'
sleep 0.5
printf '  \033[32m✓\033[0m handles unicode (1ms)\n'
echo ""
printf '\033[31m1 failed\033[0m, \033[32m7 passed\033[0m (8 total, 19ms)\n'
exit 1
