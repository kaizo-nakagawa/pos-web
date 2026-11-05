# syntax=docker/dockerfile:1

# Image runtime untuk Coolify.
#
# Image ini TIDAK membawa kode aplikasi, dan tidak menjalankan
# `composer install` maupun `bun install && bun run build`. Isinya hanya
# toolchain dan layanan -- PHP, nginx, SSH, scheduler dan queue worker;
# deploy.bash mengirim kode lewat SSH, memasang dependensi PHP, dan
# mengirim build front-end yang dibuat di build server.
#
# Dikonfigurasi oleh file `.env` yang di-mount di /var/www/html/.env saat
# container berjalan -- bukan oleh environment variable Coolify, dan tidak
# pernah ikut ke dalam image (.dockerignore hanya meloloskan docker/). Laravel
# membaca file itu sendiri; docker/env.sh membaca beberapa nilai yang
# dibutuhkan skrip shell sebelum PHP berjalan. Lihat catatan di bagian bawah.

# Dipin ke rilis patch; naikkan dengan sengaja, dan build dengan --pull supaya
# layer dasar beserta perbaikan keamanannya selalu segar.
FROM php:8.4.27-fpm-bookworm

# Satu process manager untuk nginx, php-fpm, sshd, scheduler dan queue worker,
# karena container menjalankan satu perintah dan image ini butuh lima layanan.
#
# Hanya setelan toolchain di sini. Setelan aplikasi tempatnya di .env:
# variabel ENV adalah environment variable sungguhan, dan Laravel membiarkannya
# menimpa .env, jadi nilai di sini akan diam-diam mengalahkan isi .env.
ENV DEBIAN_FRONTEND=noninteractive \
    SHELL=/usr/bin/fish \
    COMPOSER_ALLOW_SUPERUSER=1 \
    COMPOSER_HOME=/composer

# ---------------------------------------------------------------------------
# Ekstensi PHP
# ---------------------------------------------------------------------------
# zip untuk openspout (impor/ekspor xlsx) -- sisanya yang diminta
# `composer check-platform-reqs --no-dev` sudah ada di image dasar.
# pdo_mysql bila produksi memakai MySQL/MariaDB (pdo_sqlite sudah bawaan),
# pcntl agar queue worker berhenti dengan rapi, opcache untuk performa.
COPY --from=mlocati/php-extension-installer:2 /usr/bin/install-php-extensions /usr/local/bin/
RUN install-php-extensions \
        opcache \
        pcntl \
        pdo_mysql \
        zip

# ---------------------------------------------------------------------------
# Paket sistem
# ---------------------------------------------------------------------------
# rsync agar deploy.bash bisa mengirim kode, build front-end dan file storage
# langsung ke container. sqlite3 untuk memeriksa database SQLite lewat SSH.
RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates \
        curl \
        fish \
        git \
        gnupg \
        less \
        nano \
        openssh-server \
        procps \
        rsync \
        sqlite3 \
        supervisor \
        unzip \
    && rm -rf /var/lib/apt/lists/*

# nginx dari repository stable nginx.org: bookworm sendiri hanya punya 1.22.
# Untuk upgrade, ganti NGINX_VERSION ke versi yang ada di repository itu.
#
# Kunci penandatangan dicocokkan dengan fingerprint yang dipublikasikan
# nginx.org sebelum apt mempercayainya. Paket ini tidak punya
# sites-available; server block ada di conf.d/default.conf (ditulis oleh
# entrypoint), dan worker diganti dari `nginx` ke www-data, pemilik file Laravel.
ARG NGINX_VERSION=1.30.6
RUN set -eux; \
    curl -fsSL https://nginx.org/keys/nginx_signing.key \
        | gpg --dearmor -o /usr/share/keyrings/nginx-archive-keyring.gpg; \
    fingerprints="$(gpg --show-keys --with-colons /usr/share/keyrings/nginx-archive-keyring.gpg | awk -F: '/^fpr:/ { print $10 }')"; \
    for fingerprint in \
        573BFD6B3D8FBC641079A6ABABF5BD827BD9BF62 \
        8540A6F18833A80E9C1653A42FD21310B49F6B46 \
        9E9BE90EACBCDE69FE9B204CBCDCD8A38D88A2B3; do \
        echo "$fingerprints" | grep -qx "$fingerprint"; \
    done; \
    echo "deb [signed-by=/usr/share/keyrings/nginx-archive-keyring.gpg] https://nginx.org/packages/debian bookworm nginx" \
        > /etc/apt/sources.list.d/nginx.list; \
    apt-get update; \
    apt-get install -y --no-install-recommends "nginx=${NGINX_VERSION}-1~bookworm"; \
    sed -i 's/^user .*;/user www-data;/' /etc/nginx/nginx.conf; \
    grep -qx 'user www-data;' /etc/nginx/nginx.conf; \
    rm -rf /var/lib/apt/lists/*

# Bun, untuk membangun front-end di dalam container bila perlu (biasanya build
# dibuat di build server oleh deploy.bash).
COPY --from=oven/bun:1.3.14 /usr/local/bin/bun /usr/local/bin/bun
RUN ln -s /usr/local/bin/bun /usr/local/bin/bunx

# Binary Composer saja; deploy.bash yang menjalankan `composer install`.
COPY --from=composer:2 /usr/bin/composer /usr/local/bin/composer

# Fish untuk siapa pun yang membuka shell, lewat SSH maupun `docker exec`.
RUN chsh -s /usr/bin/fish root
COPY docker/fish/config.fish /root/.config/fish/config.fish

# ---------------------------------------------------------------------------
# Konfigurasi layanan
# ---------------------------------------------------------------------------
COPY docker/nginx/default.conf /etc/nginx/app.conf.template
COPY docker/php/php.ini /usr/local/etc/php/conf.d/zz-app.ini
COPY docker/php/www.conf /usr/local/etc/php-fpm.d/zz-app.conf
COPY docker/supervisor/supervisord.conf /etc/supervisor/conf.d/app.conf
COPY docker/sshd/sshd_config.conf /etc/ssh/sshd_config.d/app.conf
COPY docker/env.sh /usr/local/lib/app-env.sh
COPY docker/entrypoint.sh /usr/local/bin/entrypoint
COPY docker/scheduler.sh /usr/local/bin/scheduler
COPY docker/queue.sh /usr/local/bin/queue

# /var/run/sshd tidak ada di image dan sshd menolak start tanpanya.
RUN chmod +x /usr/local/bin/entrypoint /usr/local/bin/scheduler /usr/local/bin/queue \
    && mkdir -p /var/run/sshd /var/log/supervisor

# ---------------------------------------------------------------------------
# Direktori aplikasi
# ---------------------------------------------------------------------------
# Kosong kecuali path yang bisa ditulis: kode datang lewat deploy.bash, ke
# volume yang di-mount di sini (lihat catatan di bawah), yang diisi Docker
# dari direktori ini saat pertama kali di-mount.
WORKDIR /var/www/html

# `storage` dan `bootstrap/cache` adalah satu-satunya path yang ditulis Laravel
# saat runtime. Sisanya milik root, supaya worker php-fpm yang dibobol tidak
# bisa menulis ulang kode. storage/database untuk file SQLite (lihat bawah).
# Path ditulis satu per satu, bukan brace expansion: `RUN` memakai /bin/sh
# (dash), yang tidak mengenal {a,b}.
RUN mkdir -p \
        storage/app/public \
        storage/database \
        storage/framework/cache/data \
        storage/framework/sessions \
        storage/framework/views \
        storage/logs \
        bootstrap/cache \
    && chown -R www-data:www-data storage bootstrap/cache \
    && chmod -R u+rwX,g+rwX storage bootstrap/cache

# 80 untuk aplikasi secara default (PORT di .env mengubahnya). 22 untuk SSH --
# petakan ke port host yang kosong di Coolify, dan hanya bila memang perlu
# dijangkau dari luar jaringan.
EXPOSE 80 22

# Menjawab tanpa menyentuh PHP, supaya Coolify melihat container sehat sebelum
# aplikasi di-deploy, alih-alih me-restartnya terus-menerus. Port dibaca dari
# file yang ditulis entrypoint: healthcheck tidak lewat entrypoint, jadi tidak
# akan melihat PORT dari .env.
HEALTHCHECK --interval=30s --timeout=5s --start-period=20s --retries=3 \
    CMD curl -fsS "http://127.0.0.1:$(cat /run/app-port 2>/dev/null || echo 80)/healthz" || exit 1

ENTRYPOINT ["/usr/local/bin/entrypoint"]
CMD ["/usr/bin/supervisord", "-c", "/etc/supervisor/supervisord.conf", "-n"]

# ---------------------------------------------------------------------------
# Sebelum deploy pertama, di Coolify:
#
#   Build pack Dockerfile, dari repository ini.
#
#   Tambahkan file mount (Storages -> Add -> File mount) di
#   /var/www/html/.env dan tempel .env produksi ke dalamnya -- mulai dari
#   .env.example, dengan APP_ENV=production, APP_DEBUG=false, dan
#   SSH_PUBLIC_KEY berisi public key build server. File mount berada di luar
#   writable layer container, jadi bertahan saat redeploy. Biarkan tab
#   Environment Variables di Coolify kosong: apa pun yang diset di sana
#   menimpa key yang sama di .env.
#
#   Tambahkan persistent volume untuk /var/www/html -- kode yang dikirim
#   deploy.bash, beserta vendor/ dan public/build -- dan satu lagi untuk
#   /var/www/html/storage (upload, log, dan database SQLite), dipisah supaya
#   data tidak pernah bernasib sama dengan kode. Mount bertingkat tidak
#   masalah: file mount .env dan volume storage berada di dalam volume
#   /var/www/html.
#
#   Bila memakai SQLite, set di .env:
#     DB_CONNECTION=sqlite
#     DB_DATABASE=/var/www/html/storage/database/database.sqlite
#   -- di dalam storage/, yang dimiliki www-data (SQLite butuh direktori yang
#   bisa ditulis untuk file journal-nya), dan ikut volume storage. Entrypoint
#   membuat file kosongnya bila belum ada.
#
# Setelah container hidup -- ia start tanpa aplikasi, hanya menjawab /healthz
# dan SSH -- deploy dari build server:
#
#   DEPLOY_REMOTE=root@<container> ./deploy.bash --dry-run   # pratinjau
#   DEPLOY_REMOTE=root@<container> ./deploy.bash
#
# Bila APP_KEY di .env yang di-mount masih kosong, jalankan sekali lewat SSH:
#
#   php artisan key:generate --show   # lalu salin nilainya ke .env di Coolify
#
# Tanpa volume /var/www/html, kode, vendor/ dan public/build berada di
# writable layer container dan HILANG pada redeploy Coolify berikutnya --
# situs mati sampai deploy.bash dijalankan lagi. Tanpa volume storage, upload
# dan database SQLite ikut hilang.
# ---------------------------------------------------------------------------
