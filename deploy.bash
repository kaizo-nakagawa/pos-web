#!/bin/bash

set -euo pipefail

# Deploy lewat rsync dari mesin ini: kode, lalu build front-end, lalu
# (opsional) file storage. Container tidak butuh checkout git -- cukup SSH,
# rsync, php dan composer.

cd "$(dirname "$0")"

# Container-nya adalah image dari Dockerfile repo ini: tanpa kode, hanya
# toolchain dan layanan (lihat catatan di akhir Dockerfile).

# Alamat SSH container (user@host, atau alias Host dari ~/.ssh/config):
# DEPLOY_REMOTE dari environment -- mis. `DEPLOY_REMOTE=... ./deploy.bash`
# untuk container staging -- atau dari .env mesin ini. Dibaca dengan parser
# yang dipakai container untuk .env-nya (docker/env.sh), bukan dengan
# `source`, yang akan menjalankan .env sebagai kode shell.
# Periksa baik-baik: alamat yang salah akan menyinkronkan kode ini
# ke container aplikasi lain dan menghapus apa pun yang berbeda.
APP_ENV_FILE=.env
# shellcheck source=docker/env.sh
source docker/env.sh
load_env DEPLOY_REMOTE

if [ -z "${DEPLOY_REMOTE:-}" ]; then
    echo 'DEPLOY_REMOTE belum diset -- tambahkan ke .env (lihat .env.example), atau berikan lewat environment.' >&2
    exit 1
fi

REMOTE=$DEPLOY_REMOTE
REMOTE_PATH=${DEPLOY_PATH:-/var/www/html}

usage() {
    echo "Usage: $(basename "$0") [--no-assets | --assets-only] [--storage] [--dry-run]" >&2
    echo "       $(basename "$0") --ssh" >&2
}

# --storage: ikut kirim storage/app/public (upload, media). Opt-in, karena
#   isinya berubah dengan jadwalnya sendiri dan kebanyakan deploy hanya kode.
# --dry-run: tampilkan apa yang akan di-upload dan dihapus, tanpa mengubah apa pun.
# --ssh: hanya buka shell di direktori aplikasi pada container; tidak deploy.
# --no-assets: kode saja (PHP, routes, config, migrations): lewati build Vite
#   dan biarkan public/build yang live. Untuk perubahan back-end; apa pun di
#   resources/js atau resources/css butuh deploy penuh.
# --assets-only: build Vite saja: tanpa sync kode, composer atau migrasi.
#   Untuk perubahan front-end yang sudah dilayani PHP yang ter-deploy (tanpa
#   props, route atau endpoint baru).
SYNC_STORAGE=false
DRY_RUN=false
OPEN_SHELL=false
NO_ASSETS=false
ASSETS_ONLY=false

for arg in "$@"; do
    case "$arg" in
        --storage) SYNC_STORAGE=true ;;
        --dry-run) DRY_RUN=true ;;
        --ssh) OPEN_SHELL=true ;;
        --no-assets) NO_ASSETS=true ;;
        --assets-only) ASSETS_ONLY=true ;;
        -h|--help) usage; exit 0 ;;
        *)
            echo "Argumen tidak dikenal: $arg" >&2
            usage
            exit 1
            ;;
    esac
done

if [ "$OPEN_SHELL" = true ]; then
    # Sendirian, supaya membuka shell tidak pernah memicu deploy tanpa sengaja.
    if [ "$SYNC_STORAGE" = true ] || [ "$DRY_RUN" = true ] || [ "$NO_ASSETS" = true ] || [ "$ASSETS_ONLY" = true ]; then
        echo '--ssh hanya membuka shell; tidak bisa digabung dengan opsi lain.' >&2
        usage
        exit 1
    fi

    # \$SHELL di-escape supaya di-expand di remote, bukan di mesin ini.
    exec ssh -t "$REMOTE" "cd '$REMOTE_PATH' && exec \"\$SHELL\" -l"
fi

if [ "$NO_ASSETS" = true ] && [ "$ASSETS_ONLY" = true ]; then
    echo '--no-assets dan --assets-only saling meniadakan; kosongkan keduanya untuk deploy penuh.' >&2
    usage
    exit 1
fi

# Yang dikirim adalah working tree, jadi harus persis sebuah commit: tanpa
# edit yang belum di-commit dan tanpa file untracked.
if [ -n "$(git status --porcelain)" ]; then
    echo 'Working tree tidak bersih -- commit atau stash (termasuk file untracked) sebelum deploy.' >&2
    git status --short >&2
    exit 1
fi

command -v rsync >/dev/null || {
    echo 'rsync belum terpasang di mesin ini.' >&2
    exit 1
}

# Apa yang dikirim sync kode: hanya yang dibutuhkan aplikasi saat runtime,
# sebagai whitelist. Aturan dicocokkan berurutan, yang pertama cocok menang.
#
# Pertama, state milik server, tidak disentuh di kedua sisi: path yang
# di-exclude tidak di-upload dan tidak dihapus oleh --delete.
# - .gitignore top-level: .env, vendor/, node_modules/, public/build,
#   public/storage, folder editor.
# - storage/ dan bootstrap/cache/: ditulis aplikasi saat runtime (upload,
#   session, log, cache). storage/app/public dikirim terpisah lewat --storage.
# - database lokal (sqlite), agar database server tidak tertimpa.
# - deploy.log, catatan server tentang apa yang di-deploy kapan.
#
# Lalu yang dibutuhkan PHP saat runtime. Bukan resources/js atau resources/css:
# @vite hanya mencari entry di manifest public/build, dan Inertia tidak
# memeriksa file page di production (inertia.pages.ensure_pages_exist).
# Bukan tests/, tooling front-end, atau docs.
#
# Sisanya hanya disembunyikan dari sisi pengirim (`H`), tidak di-exclude, jadi
# --delete menghapusnya dari server bila ada (sisa deploy lama).
CODE_FILTERS=(
    --exclude-from=.gitignore
    --exclude=/storage/
    --exclude=/bootstrap/cache/
    --exclude='*.sqlite'
    --exclude='*.sqlite-journal'
    --exclude='*.sqlite-wal'
    --exclude='*.sqlite-shm'
    --exclude=/deploy.log
    --include=/artisan
    --include=/composer.json
    --include=/composer.lock
    --include=/app/***
    --include=/bootstrap/
    --include=/bootstrap/app.php
    --include=/bootstrap/providers.php
    --include=/config/***
    --include=/database/
    --include=/database/migrations/***
    --include=/database/seeders/***
    --include=/database/factories/***
    --include=/lang/***
    --include=/public/***
    --include=/resources/
    --include=/resources/views/***
    --include=/routes/***
    --filter='H *'
)

remote() {
    # Heredoc ber-kutip di semua tempat, supaya tidak ada yang ter-expand di
    # lokal; satu-satunya nilai yang dibutuhkan remote dikirim eksplisit.
    # shellcheck disable=SC2029
    ssh "$REMOTE" "REMOTE_PATH='$REMOTE_PATH' bash -se"
}

if [ "$DRY_RUN" = true ]; then
    # shellcheck disable=SC2029
    echo "Live di $REMOTE: $(ssh "$REMOTE" "tail -n 1 '$REMOTE_PATH/deploy.log' 2>/dev/null" || true)"
    echo "Deploying:  $(git rev-parse --short=12 HEAD) $(git log -1 --format=%s)"

    if [ "$ASSETS_ONLY" = true ]; then
        test -f public/build/manifest.json || {
            echo 'Tidak ada build lokal untuk dibandingkan -- jalankan `bun run build` dulu.' >&2
            exit 1
        }
        echo "Dry run: perubahan build di $REMOTE (tidak ada yang diubah)"
        rsync -azn --delete --itemize-changes public/build/ "$REMOTE:$REMOTE_PATH/public/build/"
    else
        echo "Dry run: perubahan sync kode di $REMOTE (tidak ada yang diubah)"
        rsync -azn --delete --itemize-changes "${CODE_FILTERS[@]}" \
            ./ "$REMOTE:$REMOTE_PATH/"
    fi

    if [ "$SYNC_STORAGE" = true ]; then
        echo "Dry run: file storage yang akan ditambah/diperbarui di $REMOTE"
        rsync -azn --itemize-changes storage/app/public/ "$REMOTE:$REMOTE_PATH/storage/app/public/"
    fi
    exit 0
fi

# Dicek sebelum apa pun di server berubah: tool yang hilang di sisi sana
# kalau tidak akan ketahuan di tengah jalan, dengan kode baru tanpa dependensi.
# Yang membuktikan ini container yang benar adalah file yang hanya dimiliki
# image ini, bukan public/index.php aplikasi -- yang belum ada pada deploy
# pertama ke container kosong.
if ! remote <<'EOF'
set -euo pipefail
command -v rsync >/dev/null
command -v composer >/dev/null
command -v php >/dev/null
test -f /usr/local/lib/app-env.sh
test -d "$REMOTE_PATH"
EOF
then
    echo "Bukan container aplikasi ini, atau rsync/composer/php tidak ada di sana -- periksa DEPLOY_REMOTE, atau build ulang image." >&2
    exit 1
fi

if [ "$NO_ASSETS" = false ]; then
    # Build di sini, bukan di server: build Vite butuh memori dan CPU jauh
    # lebih besar daripada yang dibutuhkan aplikasi untuk melayani.
    bun install --frozen-lockfile
    bun run build
fi

if [ "$ASSETS_ONLY" = false ]; then
    # Kode, termasuk penghapusan: file yang dihapus di sini ikut dihapus di sana.
    # Dimiliki root, supaya worker php-fpm yang dibobol tidak bisa menulis
    # ulang kode; storage/ dan bootstrap/cache/ tetap milik www-data karena
    # sync tidak pernah menyentuhnya.
    rsync -az --delete --chown=root:root "${CODE_FILTERS[@]}" \
        ./ "$REMOTE:$REMOTE_PATH/"

    echo 'kode tersinkron'

    remote <<'EOF'
set -euo pipefail
cd "$REMOTE_PATH"
composer install --no-dev --optimize-autoloader --no-interaction
EOF
fi

if [ "$NO_ASSETS" = false ]; then
    # Di-stage di samping build live lalu ditukar, mengosongkan yang lama dulu:
    # nama file di-hash per konten, jadi tanpa itu setiap deploy meninggalkan
    # satu generasi chunk basi. Dikosongkan dan diisi ulang, bukan di-rename,
    # supaya tetap jalan bila public/build adalah volume ter-mount.
    rsync -az --delete public/build/ "$REMOTE:$REMOTE_PATH/public/build.new/"

    remote <<'EOF'
set -euo pipefail
cd "$REMOTE_PATH"
test -f public/build.new/manifest.json
mkdir -p public/build
find public/build -mindepth 1 -delete
cp -a public/build.new/. public/build/
rm -rf public/build.new
EOF

    echo 'build terkirim'
fi

# Tidak pernah --delete: storage/app/public di server berisi apa yang ditulis
# aplikasi sejak deploy terakhir (upload), yang tidak ada salinannya di sini.
# Aditif. Dimiliki web server saat tiba, kalau tidak PHP tidak bisa menimpanya.
if [ "$SYNC_STORAGE" = true ]; then
    rsync -az --info=stats1 --chown=www-data:www-data \
        storage/app/public/ "$REMOTE:$REMOTE_PATH/storage/app/public/"
    echo 'storage tersinkron'
fi

# Hanya perubahan kode yang memengaruhi langkah ini; build baru tidak butuh.
# Queue worker adalah proses panjang yang memegang framework saat ia boot,
# jadi tanpa queue:restart ia menjalankan job dengan kode lama.
if [ "$ASSETS_ONLY" = false ]; then
    remote <<'EOF'
set -euo pipefail
cd "$REMOTE_PATH"
php artisan migrate --force
php artisan optimize
php artisan queue:restart
EOF
fi

# Satu baris per deploy yang selesai, di-append di server, supaya selalu jelas
# commit mana yang live -- dan ke mana harus kembali: checkout lalu deploy
# lagi. Ditulis paling akhir, supaya deploy yang gagal di tengah tidak pernah
# tercatat. Dikirim lewat stdin, supaya subjek commit berisi kutip aman.
if [ "$ASSETS_ONLY" = true ]; then
    part=assets-only
elif [ "$NO_ASSETS" = true ]; then
    part=no-assets
else
    part=full
fi
[ "$SYNC_STORAGE" = true ] && part="$part+storage"

printf '%s %s %s %s %s\n' \
    "$(date -Iseconds)" \
    "$(git rev-parse --short=12 HEAD)" \
    "$part" \
    "$(git config user.name || whoami)" \
    "$(git log -1 --format=%s)" |
    ssh "$REMOTE" "cat >> '$REMOTE_PATH/deploy.log'"

echo 'deployed'
