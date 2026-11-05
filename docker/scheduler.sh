#!/bin/bash
# Laravel's scheduler, as a supervised long-lived process.
set -euo pipefail

cd /var/www/html

# This image ships without the app or `vendor/` -- deploy.bash sends the one
# and installs the other. Wait for it rather than exiting: supervisor's default is
# three start attempts, which a missing autoloader burns through in under a
# second, and the scheduler would then sit in FATAL even after the dependencies
# arrive. Waiting means it starts working on its own the moment they do.
while [ ! -f vendor/autoload.php ]; do
    echo "[scheduler] vendor/ is not installed yet -- waiting"
    sleep 15
done

echo "[scheduler] starting schedule:work"

# `schedule:work` rather than a crontab calling `schedule:run` every minute:
# it is the same dispatcher, running as one process that wakes each minute.
# That is what a supervised container wants -- no crond to run alongside
# supervisor, and one log stream instead of two.

# Restarted in a loop here rather than by supervisor. Supervisor treats an exit
# inside `startsecs` as a failed start and gives up permanently after a few
# tries -- which is exactly what happened in production: the database
# configuration was briefly absent, Laravel fell back to the `sqlite` default
# from config/database.php, and "Database file ... does not exist" killed the
# process five times in nine seconds. It then sat in FATAL long after the
# database came back. A loop rides out anything transient underneath us.
while true; do
    php artisan schedule:work --no-interaction ||
        echo "[scheduler] schedule:work exited with an error; retrying in 15s"
    sleep 15
done
