#!/bin/sh
# Fake DB migration: prints migration steps with timing, exits 0.
echo "Running database migrations..."
echo ""
printf '  \033[2m→\033[0m 20240101_create_users_table \033[32m✓\033[0m (12ms)\n'
sleep 0.5
printf '  \033[2m→\033[0m 20240115_add_email_index \033[32m✓\033[0m (8ms)\n'
sleep 0.5
printf '  \033[2m→\033[0m 20240201_create_posts_table \033[32m✓\033[0m (15ms)\n'
sleep 0.5
printf '  \033[2m→\033[0m 20240301_add_fulltext_search \033[32m✓\033[0m (45ms)\n'
sleep 0.5
printf '  \033[2m→\033[0m 20240415_create_comments_table \033[32m✓\033[0m (11ms)\n'
sleep 0.5
echo ""
printf '\033[1m5 migrations applied in 91ms\033[0m\n'
exit 0
