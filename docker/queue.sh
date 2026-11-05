#!/bin/bash
# The queue worker, as a supervised long-lived process.
set -euo pipefail

cd /var/www/html

# shellcheck source=docker/env.sh
source /usr/local/lib/app-env.sh
load_env QUEUE_TIMEOUT DB_QUEUE_RETRY_AFTER

# Same reasoning as the scheduler: this image ships without `vendor/`, and
# exiting here would burn supervisor's start attempts before the dependencies
# are ever installed.
while [ ! -f vendor/autoload.php ]; do
    echo "[queue] vendor/ is not installed yet -- waiting"
    sleep 15
done

# How long a single job may run before the worker kills it, and how long the
# queue waits before deciding a reserved job died and handing it to another
# worker. Laravel's defaults (60s / 90s); raise both in .env if a job ever
# needs longer. `retry_after` must stay above the timeout, or a slow job is
# picked up a second time while the first worker is still running it.
timeout=${QUEUE_TIMEOUT:-60}
retry_after=${DB_QUEUE_RETRY_AFTER:-90}

if [ "$retry_after" -le "$timeout" ]; then
    echo "[queue] WARNING: DB_QUEUE_RETRY_AFTER ($retry_after) is not greater"
    echo "[queue]          than the job timeout ($timeout). A job running longer"
    echo "[queue]          than ${retry_after}s will be handed to a second worker"
    echo "[queue]          while the first is still on it. Raise it above ${timeout}."
fi

echo "[queue] starting queue:work (timeout=${timeout}s, retry_after=${retry_after}s)"

# No `--queue`: the connection and queue name come from QUEUE_CONNECTION and
# DB_QUEUE, so switching the app to Redis needs no change here.
#
# `--max-time` recycles the process every hour. A worker holds a booted
# framework in memory for its whole life, and a slow leak in any dependency
# accumulates in a way a short-lived request never shows.
#
# `--tries` is a floor for jobs that declare none; a job's own `$tries` wins.

# Restarted in a loop here rather than by supervisor. Supervisor treats an exit
# inside `startsecs` as a failed start and gives up permanently after a few
# tries -- which is exactly what happened in production: the database
# configuration was briefly absent, Laravel fell back to the `sqlite` default
# from config/database.php, and "Database file ... does not exist" killed the
# process five times in nine seconds. It then sat in FATAL long after the
# database came back. A loop rides out anything transient underneath us.
while true; do
    if php artisan queue:work \
        --no-interaction \
        --timeout="$timeout" \
        --tries=3 \
        --max-time=3600
    then
        echo "[queue] worker reached --max-time; starting a fresh one"
    else
        echo "[queue] worker exited with an error; retrying in 15s"
        sleep 15
    fi
done
