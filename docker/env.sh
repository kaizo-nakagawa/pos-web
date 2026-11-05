#!/bin/bash
# Sourced by the entrypoint and the queue script, never executed on its own --
# and by deploy.bash on the build server, pointed at that machine's .env, to
# read DEPLOY_REMOTE.
#
# The app is configured by /var/www/html/.env, mounted into the container at
# runtime -- not by variables injected into the container's environment. PHP
# needs no help with that: Laravel reads .env itself, in php-fpm, in the
# scheduler and worker, and in `php artisan` over SSH alike. The shell scripts
# around it do not, and a few of them need a value before PHP ever runs --
# nginx's port, the SSH key, the worker timeouts. This reads those few.

APP_ENV_FILE=${APP_ENV_FILE:-/var/www/html/.env}

# Print one key's value from the .env file; fail if the file or key is absent.
#
# Covers the forms these keys are written in -- KEY=value, KEY="value",
# KEY='value', an optional `export`, a trailing ` # comment` after an unquoted
# value. It is not a full dotenv parser (no ${VAR} interpolation, no multiline
# values), and does not need to be: only the keys named in `load_env` calls go
# through it, and everything else is left to Laravel.
env_value() {
    local key=$1 line value

    [ -r "$APP_ENV_FILE" ] || return 1
    line=$(grep -E "^[[:space:]]*(export[[:space:]]+)?${key}[[:space:]]*=" "$APP_ENV_FILE" | tail -n 1) || return 1
    [ -n "$line" ] || return 1

    value=${line#*=}
    value=${value#"${value%%[![:space:]]*}"}

    case $value in
        \"*) value=${value#\"}; value=${value%%\"*} ;;
        \'*) value=${value#\'}; value=${value%%\'*} ;;
        *)
            value=${value%%[[:space:]]#*}
            value=${value%"${value##*[![:space:]]}"}
            ;;
    esac

    printf '%s' "$value"
}

# Export each named key from .env. A variable already set in the real
# environment wins, which is the same precedence Laravel applies -- so a
# one-off `docker run -e PORT=8080` still works.
load_env() {
    local key value

    for key in "$@"; do
        if [ -z "${!key:-}" ] && value=$(env_value "$key"); then
            export "$key=$value"
        fi
    done
}
