#!/bin/sh
# Fake crash: prints a stack trace and exits 1.
echo "Starting worker process..."
sleep 1
printf '\033[32m✓\033[0m Connected to message queue\n'
sleep 1
printf '\033[32m✓\033[0m Processing batch #42\n'
sleep 1
printf '\033[31m✗\033[0m Unhandled exception in worker #3:\n'
echo ""
echo "  TypeError: Cannot read properties of undefined (reading 'map')"
echo "      at transform (pipeline.js:142:8)"
echo "      at processBatch (worker.js:67:22)"
echo "      at async run (main.js:12:5)"
echo ""
printf '\033[31mProcess exited with code 1\033[0m\n'
exit 1
