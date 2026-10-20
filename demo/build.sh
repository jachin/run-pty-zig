#!/bin/sh
# Fake one-off build: prints progress steps then exits 0.
echo "Building project..."
echo ""
printf '  \033[32m✓\033[0m Resolving dependencies\n'
sleep 1
printf '  \033[32m✓\033[0m Compiling 42 modules\n'
sleep 1
printf '  \033[32m✓\033[0m Tree-shaking (removed 12%%)\n'
sleep 1
printf '  \033[32m✓\033[0m Bundling → dist/main.js (348 KB)\n'
sleep 1
printf '  \033[32m✓\033[0m Minifying\n'
sleep 1
echo ""
printf '\033[1mBuild complete in 5.2s\033[0m\n'
exit 0
