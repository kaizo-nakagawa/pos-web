#!/bin/bash
# bash, bukan sh: docker/env.sh yang di-source di bawah memakai ekspansi khusus
# bash, dan /bin/sh di Debian adalah dash.
set -euo pipefail

# Berjalan sebelum supervisord mengambil alih. Semua di sini harus berhasil di
# container yang dependensinya belum terpasang -- tanpa `php artisan`, tanpa
# `composer`, tanpa apa pun yang butuh `vendor/`. Inti image ini adalah kita
# bisa mendapat shell sebelum semua itu ada.

log() {
    echo "[entrypoint] $*"
}

cd /var/www/html

# Kode tidak datang dari image: deploy.bash yang mengirimnya, ke volume di
# /var/www/html. Container baru belum punya kode, tapi tetap harus start --
# SSH adalah jalan masuk kodenya -- jadi di sini hanya diberi tahu.
if [ ! -f public/index.php ]; then
    log "NOTE: aplikasi belum di-deploy -- jalankan deploy.bash dari build"
    log "      server. Sampai saat itu semua halaman kecuali /healthz adalah 404."
fi

# ---------------------------------------------------------------------------
# Environment
# ---------------------------------------------------------------------------
# Konfigurasi datang dari .env yang di-mount, yang dibaca Laravel sendiri --
# di php-fpm, di scheduler dan worker, dan di `php artisan` lewat SSH. Di sini
# hanya nilai yang dibutuhkan skrip ini sebelum PHP berjalan.
# shellcheck source=docker/env.sh
source /usr/local/lib/app-env.sh

if [ -f "$APP_ENV_FILE" ]; then
    # Hanya bisa dibaca www-data (php-fpm) dan root: isinya APP_KEY dan semua
    # kredensial aplikasi.
    if ! { chown root:www-data "$APP_ENV_FILE" && chmod 640 "$APP_ENV_FILE"; } 2>/dev/null; then
        log "WARNING: tidak bisa mengatur kepemilikan $APP_ENV_FILE -- mount read-only?"
    fi
else
    log "WARNING: $APP_ENV_FILE tidak ada. Aplikasi tanpa konfigurasi dan akan"
    log "         memakai default (sqlite, tanpa APP_KEY). Mount .env produksi"
    log "         di sana -- lihat catatan di akhir Dockerfile."
fi

load_env PORT SSH_PUBLIC_KEY DB_CONNECTION DB_DATABASE

# ---------------------------------------------------------------------------
# SSH
# ---------------------------------------------------------------------------
# Host key dibuat saat boot pertama, bukan di-bake ke image: key yang ada di
# registry adalah key yang dimiliki bersama oleh setiap pull image itu.
if ! ls /etc/ssh/ssh_host_*_key >/dev/null 2>&1; then
    log "membuat SSH host key"
    ssh-keygen -A >/dev/null
fi

mkdir -p /root/.ssh
chmod 700 /root/.ssh

if [ -n "${SSH_PUBLIC_KEY:-}" ]; then
    # Ditulis ulang setiap boot, bukan di-append, supaya menghapus key dari
    # .env benar-benar mencabut aksesnya.
    printf '%s\n' "$SSH_PUBLIC_KEY" > /root/.ssh/authorized_keys
    chmod 600 /root/.ssh/authorized_keys
    log "SSH key untuk root terpasang"
else
    log "WARNING: SSH_PUBLIC_KEY belum diset -- sshd tidak menerima login."
    log "         Isi dengan public key Anda di .env, atau pakai terminal"
    log "         Coolify. Login password sengaja dimatikan."
fi

# ---------------------------------------------------------------------------
# nginx
# ---------------------------------------------------------------------------
# PORT dari .env, 80 bila kosong. Harus sama dengan port yang dituju proxy
# Coolify ("Ports Exposes"): container yang listen di port salah adalah 502
# tanpa ada yang salah di dalamnya.
#
# `sed` pada ${PORT} literal, bukan `envsubst`: envsubst juga akan
# mengosongkan $uri, $query_string dan $realpath_root milik nginx.
port=${PORT:-80}
sed "s|\${PORT}|${port}|g" /etc/nginx/app.conf.template > /etc/nginx/conf.d/default.conf
# Untuk HEALTHCHECK, yang berjalan di luar skrip ini dan tidak melihat .env.
printf '%s' "$port" > /run/app-port
log "nginx akan listen di ${port}"

# ---------------------------------------------------------------------------
# Path yang bisa ditulis
# ---------------------------------------------------------------------------
# Dibuat ulang setiap boot: volume Coolify yang baru datang kosong dan milik
# root, dan tulisan pertama Laravel akan gagal.
mkdir -p \
    storage/app/public \
    storage/database \
    storage/framework/cache/data \
    storage/framework/sessions \
    storage/framework/views \
    storage/logs \
    bootstrap/cache

# SQLite: file kosong dibuat bila belum ada, supaya `migrate` pertama dari
# deploy.bash tidak gagal dengan "Database file ... does not exist". Hanya
# bila letaknya di dalam storage/ -- di tempat lain direktorinya milik root
# dan www-data tidak bisa menulis journal-nya.
if [ "${DB_CONNECTION:-sqlite}" = sqlite ] && [ -n "${DB_DATABASE:-}" ]; then
    case $DB_DATABASE in
        /var/www/html/storage/*)
            if [ ! -e "$DB_DATABASE" ]; then
                mkdir -p "$(dirname "$DB_DATABASE")"
                touch "$DB_DATABASE"
                log "membuat database SQLite kosong di $DB_DATABASE"
            fi
            ;;
        *)
            log "WARNING: DB_DATABASE ($DB_DATABASE) di luar storage/ -- SQLite butuh"
            log "         direktori yang bisa ditulis www-data. Pindahkan ke"
            log "         /var/www/html/storage/database/database.sqlite."
            ;;
    esac
fi

chown -R www-data:www-data storage bootstrap/cache 2>/dev/null ||
    log "WARNING: tidak bisa chown storage/ -- mount read-only?"

# public/storage -> storage/app/public, link yang dibuat `php artisan
# storage:link`. Dibuat di sini karena tidak butuh PHP, dan link-nya tidak
# ikut sync (public/storage di-ignore git).
if [ ! -e public/storage ]; then
    # public/ sendiri belum ada sebelum deploy pertama.
    mkdir -p public
    # -f -n mengganti link yang menggantung, mis. yang dibuat dengan path host absolut.
    ln -sfn ../storage/app/public public/storage
    log "public/storage ter-link"
fi

if [ -f public/index.php ] && [ ! -f vendor/autoload.php ]; then
    log "NOTE: vendor/ tidak ada, jadi aplikasi menjawab 500 sampai deploy.bash"
    log "      (atau 'composer install' lewat SSH) memasangnya. /healthz tetap menjawab."
fi

log "menjalankan layanan"
exec "$@"
