#!/bin/sh

set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PROJECT_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
COMPOSE_FILE="$PROJECT_ROOT/docker-compose.yaml"
LETSENCRYPT_DIR="$PROJECT_ROOT/nginx/letsencrypt"
CERTBOT_IMAGE="${CERTBOT_IMAGE:-certbot/certbot:latest}"

command_name=issue
domains=''
email=''
staging=0
force_renewal=0
dry_run=0

usage() {
    cat <<'EOF'
Usage:
  scripts/issue-letsencrypt.sh [issue options]
  scripts/issue-letsencrypt.sh renew [--dry-run]

Issue options:
  --domain DOMAIN       Domain to include in the certificate. Repeatable.
  --email EMAIL         Let's Encrypt account email address.
  --staging             Use the Let's Encrypt staging environment.
  --force-renewal       Force a new certificate even when the current one is
                        not close to expiry.
  -h, --help            Show this help.

Renew options:
  --dry-run             Test renewal against the staging environment.

Examples:
  scripts/issue-letsencrypt.sh \
    --domain lvyx.cc \
    --domain www.lvyx.cc \
    --email admin@lvyx.cc

  scripts/issue-letsencrypt.sh renew --dry-run
EOF
}

die() {
    printf 'error: %s\n' "$*" >&2
    exit 1
}

compose() {
    docker compose --project-directory "$PROJECT_ROOT" -f "$COMPOSE_FILE" "$@"
}

validate_domain() {
    value=$1
    [ -n "$value" ] || die 'domain cannot be empty'
    case "$value" in
        *[!A-Za-z0-9.-]*|.*|*-|*..*)
            die "invalid domain '$value'"
            ;;
    esac
}

validate_email() {
    value=$1
    [ -n "$value" ] || die '--email is required for issue'
    case "$value" in *'@'*) ;; *) die "invalid email '$value'" ;; esac
    email_local=${value%@*}
    email_domain=${value#*@}
    case "$email_local" in
        ''|*@*|*[!A-Za-z0-9._%+-]*) die "invalid email '$value'" ;;
    esac
    case "$email_domain" in
        ''|*[!A-Za-z0-9.-]*|.*|*-|*..*) die "invalid email '$value'" ;;
    esac
}

append_domain() {
    domain=$1
    validate_domain "$domain"
    if [ -z "$domains" ]; then
        domains=$domain
    else
        domains="$domains $domain"
    fi
}

parse_args() {
    if [ "$#" -gt 0 ]; then
        case "$1" in
            issue)
                command_name=issue
                shift
                ;;
            renew)
                command_name=renew
                shift
                ;;
            help|-h|--help)
                usage
                exit 0
                ;;
        esac
    fi

    while [ "$#" -gt 0 ]; do
        case "$1" in
            --domain)
                [ "$#" -ge 2 ] || die '--domain requires a value'
                append_domain "$2"
                shift 2
                ;;
            --email)
                [ "$#" -ge 2 ] || die '--email requires a value'
                email=$2
                shift 2
                ;;
            --staging)
                staging=1
                shift
                ;;
            --force-renewal)
                force_renewal=1
                shift
                ;;
            --dry-run)
                dry_run=1
                shift
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            *)
                die "unknown option '$1'"
                ;;
        esac
    done

    if [ "$command_name" = issue ]; then
        [ -n "$domains" ] || die 'at least one --domain is required for issue'
        validate_email "$email"
        [ "$dry_run" -eq 0 ] || die '--dry-run is only valid with renew'
    else
        [ "$staging" -eq 0 ] || die '--staging is only valid with issue'
        [ "$force_renewal" -eq 0 ] || die '--force-renewal is only valid with issue'
        [ -z "$domains" ] || die '--domain is only valid with issue'
        [ -z "$email" ] || die '--email is only valid with issue'
    fi
}

prepare_environment() {
    command -v docker >/dev/null 2>&1 || die 'docker is required'
    [ -f "$COMPOSE_FILE" ] || die "compose file not found: $COMPOSE_FILE"
    docker info >/dev/null 2>&1 || die 'Docker daemon is not available'
    compose config --quiet

    mkdir -p "$LETSENCRYPT_DIR/.work" "$LETSENCRYPT_DIR/.log"
    if ! mkdir "$LETSENCRYPT_DIR/.lock" 2>/dev/null; then
        die "another certificate operation is already running: $LETSENCRYPT_DIR/.lock"
    fi
}

gateway_was_running=0
cleanup_done=0

restore_gateway() {
    status=$?
    if [ "$cleanup_done" -eq 1 ]; then
        exit "$status"
    fi
    cleanup_done=1

    if [ "$gateway_was_running" -eq 1 ]; then
        printf 'Restoring gateway...\n' >&2
        if ! compose start gateway >/dev/null; then
            printf 'error: certificate operation finished, but gateway could not be started\n' >&2
            status=1
        fi
    fi

    rmdir "$LETSENCRYPT_DIR/.lock" 2>/dev/null || true
    exit "$status"
}

stop_gateway_if_needed() {
    container_id=$(compose ps -q gateway 2>/dev/null || true)
    if [ -n "$container_id" ]; then
        running=$(docker inspect -f '{{.State.Running}}' "$container_id" 2>/dev/null || printf 'false')
        if [ "$running" = true ]; then
            gateway_was_running=1
            printf 'Stopping gateway temporarily so Certbot can use port 80...\n'
            compose stop gateway >/dev/null
        fi
    fi
}

run_certbot_issue() {
    primary_domain=${domains%% *}
    set -- certonly \
        --standalone \
        --preferred-challenges http \
        --cert-name "$primary_domain" \
        --email "$email" \
        --agree-tos \
        --no-eff-email \
        --non-interactive \
        --keep-until-expiring

    if [ "$staging" -eq 1 ]; then
        set -- "$@" --staging
    fi
    if [ "$force_renewal" -eq 1 ]; then
        set -- "$@" --force-renewal
    fi

    for domain in $domains; do
        set -- "$@" -d "$domain"
    done

    docker run --rm --network host \
        -v "$LETSENCRYPT_DIR:/etc/letsencrypt" \
        -v "$LETSENCRYPT_DIR/.work:/var/lib/letsencrypt" \
        -v "$LETSENCRYPT_DIR/.log:/var/log/letsencrypt" \
        "$CERTBOT_IMAGE" "$@"

    [ -s "$LETSENCRYPT_DIR/live/$primary_domain/fullchain.pem" ] \
        || die "certificate file not found after issuance: $LETSENCRYPT_DIR/live/$primary_domain/fullchain.pem"
    [ -s "$LETSENCRYPT_DIR/live/$primary_domain/privkey.pem" ] \
        || die "private key not found after issuance: $LETSENCRYPT_DIR/live/$primary_domain/privkey.pem"

    printf '\nCertificate ready:\n'
    printf '  fullchain: %s\n' "$LETSENCRYPT_DIR/live/$primary_domain/fullchain.pem"
    printf '  private key: %s\n' "$LETSENCRYPT_DIR/live/$primary_domain/privkey.pem"
    printf '  Nginx path: /etc/letsencrypt/live/%s/\n' "$primary_domain"
}

run_certbot_renew() {
    set -- renew
    if [ "$dry_run" -eq 1 ]; then
        set -- "$@" --dry-run
    fi

    docker run --rm --network host \
        -v "$LETSENCRYPT_DIR:/etc/letsencrypt" \
        -v "$LETSENCRYPT_DIR/.work:/var/lib/letsencrypt" \
        -v "$LETSENCRYPT_DIR/.log:/var/log/letsencrypt" \
        "$CERTBOT_IMAGE" "$@"
}

main() {
    parse_args "$@"
    prepare_environment
    trap restore_gateway 0 1 2 15

    stop_gateway_if_needed
    if [ "$command_name" = issue ]; then
        run_certbot_issue
    else
        run_certbot_renew
    fi

    printf '\nCertificate operation completed.\n'
    printf 'Run `docker compose exec gateway nginx -t` after adding or changing HTTPS server blocks.\n'
}

main "$@"
