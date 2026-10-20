#!/bin/sh
# Fake package installer: prints a progress bar then exits 0.
echo "Installing dependencies..."
echo ""
printf '  \033[2mfetching\033[0m  \033[36mleft-pad@3.2.1\033[0m\n'
sleep 0.5
printf '  \033[2mfetching\033[0m  \033[36mexpress@4.18.2\033[0m\n'
sleep 0.5
printf '  \033[2mfetching\033[0m  \033[36mlodash@4.17.21\033[0m\n'
sleep 0.5
echo ""
# Progress bar
bar_width=30
for i in 1 2 3 4 5 6 7 8 9 10; do
    filled=$((bar_width * i / 10))
    empty=$((bar_width - filled))
    bar=""
    j=0
    while [ $j -lt $filled ]; do bar="${bar}█"; j=$((j+1)); done
    j=0
    while [ $j -lt $empty ]; do bar="${bar}░"; j=$((j+1)); done
    printf '\r  \033[32m[%s]\033[0m %3d%%' "$bar" $((i * 10))
    sleep 0.3
done
echo ""
echo ""
printf '  \033[32m✓\033[0m Installed \033[1m42 packages\033[0m in 1.2s\n'
printf '  \033[2m  3 are new, 2 are updated\033[0m\n'
exit 0
