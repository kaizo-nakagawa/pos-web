# Config fish untuk siapa pun yang membuka shell di container, lewat SSH atau
# `docker exec`.

alias pa="php artisan"
alias prd="bun run dev"
alias prb="bun run build"

if status is-interactive
    abbr -a -- bri 'bun install'
    abbr -a -- brb 'bun run build'

    function fish_greeting
        echo "== POS Web ("(hostname)") =="
        echo "  php "(php -r 'echo PHP_VERSION;')"  |  bun "(bun --version)"  |  cwd /var/www/html"
    end
end
