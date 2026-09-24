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
cert_name=''
requested_domain=''
operation_selected=0
staging=0
force_renewal=0
dry_run=0

usage() {
    cat <<'EOF'
Usage:
  scripts/issue-letsencrypt.sh [issue options]
  scripts/issue-letsencrypt.sh renew [--dry-run]
  scripts/issue-letsencrypt.sh --add DOMAIN [--cert-name NAME] [--email EMAIL]
  scripts/issue-letsencrypt.sh --del DOMAIN [--cert-name NAME] [--email EMAIL]
  scripts/issue-letsencrypt.sh --list [--cert-name NAME]

Issue options:
  --domain DOMAIN       Domain to include in the certificate. Repeatable.
  --email EMAIL         Let's Encrypt account email address.
  --staging             Use the Let's Encrypt staging environment.
  --force-renewal       Force a new certificate even when the current one is
                        not close to expiry.
  -h, --help            Show this help.

Certificate management:
  --add DOMAIN          Add a domain to an existing certificate and reissue it.
  --del DOMAIN          Remove a domain from an existing certificate and reissue it.
  --list                List domains on Certbot-managed certificates.
  --cert-name NAME      Select a certificate when more than one exists.
  --email EMAIL         Optional account email for --add and --del.

Renew options:
  --dry-run             Test renewal against the staging environment.

Examples:
  scripts/issue-letsencrypt.sh \
    --domain lvyx.cc \
    --domain www.lvyx.cc \
    --email admin@lvyx.cc

  scripts/issue-letsencrypt.sh --list
  scripts/issue-letsencrypt.sh --add api.lvyx.cc
  scripts/issue-letsencrypt.sh --del www.lvyx.cc --cert-name lvyx.cc

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

select_operation() {
    [ "$operation_selected" -eq 0 ] || die 'choose only one command'
    command_name=$1
    operation_selected=1
}

parse_args() {
    if [ "$#" -gt 0 ]; then
        case "$1" in
            issue)
                command_name=issue
                operation_selected=1
                shift
                ;;
            renew)
                command_name=renew
                operation_selected=1
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
            --add)
                [ "$#" -ge 2 ] || die '--add requires a domain'
                select_operation add
                requested_domain=$2
                validate_domain "$requested_domain"
                shift 2
                ;;
            --del)
                [ "$#" -ge 2 ] || die '--del requires a domain'
                select_operation del
                requested_domain=$2
                validate_domain "$requested_domain"
                shift 2
                ;;
            --list)
                select_operation list
                shift
                ;;
            --cert-name)
                [ "$#" -ge 2 ] || die '--cert-name requires a value'
                [ -z "$cert_name" ] || die '--cert-name may only be specified once'
                cert_name=$2
                validate_domain "$cert_name"
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

    case "$command_name" in
        issue)
            [ -n "$domains" ] || die 'at least one --domain is required for issue'
            [ -z "$cert_name" ] || die '--cert-name is only valid with --add, --del, or --list'
            validate_email "$email"
            [ "$dry_run" -eq 0 ] || die '--dry-run is only valid with renew'
            ;;
        renew)
            [ "$staging" -eq 0 ] || die '--staging is only valid with issue'
            [ "$force_renewal" -eq 0 ] || die '--force-renewal is only valid with issue'
            [ -z "$domains" ] || die '--domain is only valid with issue'
            [ -z "$email" ] || die '--email is only valid with issue'
            [ -z "$cert_name" ] || die '--cert-name is only valid with --add, --del, or --list'
            ;;
        add|del)
            [ -n "$requested_domain" ] || die "--$command_name requires a domain"
            [ -z "$domains" ] || die '--domain is only valid with issue'
            [ "$staging" -eq 0 ] || die '--staging cannot be used while changing an existing certificate'
            [ "$dry_run" -eq 0 ] || die '--dry-run is only valid with renew'
            [ -z "$email" ] || validate_email "$email"
            force_renewal=1
            ;;
        list)
            [ -z "$domains" ] || die '--domain is only valid with issue'
            [ -z "$requested_domain" ] || die '--add and --del cannot be used with --list'
            [ -z "$email" ] || die '--email is not valid with --list'
            [ "$staging" -eq 0 ] || die '--staging is only valid with issue'
            [ "$force_renewal" -eq 0 ] || die '--force-renewal is only valid with issue'
            [ "$dry_run" -eq 0 ] || die '--dry-run is only valid with renew'
            ;;
        *)
            die "unknown command '$command_name'"
            ;;
    esac
}

require_docker() {
    command -v docker >/dev/null 2>&1 || die 'docker is required'
    docker info >/dev/null 2>&1 || die 'Docker daemon is not available'
}

prepare_environment() {
    require_docker
    [ -f "$COMPOSE_FILE" ] || die "compose file not found: $COMPOSE_FILE"
    compose config --quiet

    mkdir -p "$LETSENCRYPT_DIR/.work" "$LETSENCRYPT_DIR/.log"
    if ! mkdir "$LETSENCRYPT_DIR/.lock" 2>/dev/null; then
        die "another certificate operation is already running: $LETSENCRYPT_DIR/.lock"
    fi
}

certbot_certificates() {
    docker run --rm \
        -v "$LETSENCRYPT_DIR:/etc/letsencrypt:ro" \
        "$CERTBOT_IMAGE" certificates
}

parse_certificate_entries() {
    printf '%s\n' "$1" | awk '
        /^[[:space:]]*Certificate Name:/ {
            name = $0
            sub(/^.*Certificate Name:[[:space:]]*/, "", name)
            next
        }
        /^[[:space:]]*Domains:/ && name != "" {
            domains = $0
            sub(/^.*Domains:[[:space:]]*/, "", domains)
            gsub(/,[[:space:]]*/, " ", domains)
            print name "|" domains
            name = ""
        }
    '
}

list_certificates() {
    if [ ! -d "$LETSENCRYPT_DIR" ]; then
        if [ -n "$cert_name" ]; then
            die "certificate '$cert_name' was not found"
        fi
        printf 'No Certbot certificates found.\n'
        return 0
    fi

    require_docker
    certificate_output=$(certbot_certificates) || die 'could not read Certbot certificates'
    certificate_entries=$(parse_certificate_entries "$certificate_output")

    if [ -n "$cert_name" ]; then
        certificate_entries=$(printf '%s\n' "$certificate_entries" | awk -F '|' -v wanted="$cert_name" '$1 == wanted')
        [ -n "$certificate_entries" ] || die "certificate '$cert_name' was not found"
    fi

    if [ -z "$certificate_entries" ]; then
        printf 'No Certbot certificates found.\n'
        return 0
    fi

    printf '%s\n' "$certificate_entries" | while IFS='|' read -r entry_name entry_domains; do
        [ -n "$entry_name" ] || continue
        printf '%s\n' "$entry_name:"
        for domain in $entry_domains; do
            printf '  %s\n' "$domain"
        done
    done
}

prepare_managed_domains() {
    certificate_output=$(certbot_certificates) || die 'could not read Certbot certificates'
    certificate_entries=$(parse_certificate_entries "$certificate_output")
    [ -n "$certificate_entries" ] || die 'no Certbot certificates found; issue a certificate first'

    certificate_count=$(printf '%s\n' "$certificate_entries" | awk 'NF { count++ } END { print count + 0 }')
    if [ -z "$cert_name" ]; then
        [ "$certificate_count" -eq 1 ] || {
            printf 'Available certificate names:\n' >&2
            printf '%s\n' "$certificate_entries" | awk -F '|' 'NF { print "  " $1 }' >&2
            die 'multiple certificates found; select one with --cert-name'
        }
        cert_name=${certificate_entries%%|*}
    fi

    matching_certificate=$(printf '%s\n' "$certificate_entries" | awk -F '|' -v wanted="$cert_name" '$1 == wanted { print; found = 1 } END { if (!found) exit 1 }') \
        || die "certificate '$cert_name' was not found"
    domains=${matching_certificate#*|}
    [ -n "$domains" ] || die "certificate '$cert_name' has no domain names"

    case "$command_name" in
        add)
            case " $domains " in
                *" $requested_domain "*) die "domain '$requested_domain' is already on certificate '$cert_name'" ;;
            esac
            append_domain "$requested_domain"
            ;;
        del)
            updated_domains=''
            domain_was_found=0
            for existing_domain in $domains; do
                if [ "$existing_domain" = "$requested_domain" ]; then
                    domain_was_found=1
                    continue
                fi
                if [ -z "$updated_domains" ]; then
                    updated_domains=$existing_domain
                else
                    updated_domains="$updated_domains $existing_domain"
                fi
            done
            [ "$domain_was_found" -eq 1 ] || die "domain '$requested_domain' is not on certificate '$cert_name'"
            [ -n "$updated_domains" ] || die 'cannot remove the last domain from a certificate'
            domains=$updated_domains
            ;;
    esac
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
    [ -n "$cert_name" ] || cert_name=${domains%% *}
    set -- certonly \
        --standalone \
        --preferred-challenges http \
        --cert-name "$cert_name" \
        --agree-tos \
        --no-eff-email \
        --non-interactive \
        --keep-until-expiring

    if [ -n "$email" ]; then
        set -- "$@" --email "$email"
    fi

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

    [ -s "$LETSENCRYPT_DIR/live/$cert_name/fullchain.pem" ] \
        || die "certificate file not found after issuance: $LETSENCRYPT_DIR/live/$cert_name/fullchain.pem"
    [ -s "$LETSENCRYPT_DIR/live/$cert_name/privkey.pem" ] \
        || die "private key not found after issuance: $LETSENCRYPT_DIR/live/$cert_name/privkey.pem"

    printf '\nCertificate ready:\n'
    printf '  fullchain: %s\n' "$LETSENCRYPT_DIR/live/$cert_name/fullchain.pem"
    printf '  private key: %s\n' "$LETSENCRYPT_DIR/live/$cert_name/privkey.pem"
    printf '  Nginx path: /etc/letsencrypt/live/%s/\n' "$cert_name"
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
    if [ "$command_name" = list ]; then
        list_certificates
        return
    fi

    prepare_environment
    trap restore_gateway 0 1 2 15

    if [ "$command_name" = add ] || [ "$command_name" = del ]; then
        prepare_managed_domains
    fi

    stop_gateway_if_needed
    if [ "$command_name" = issue ] || [ "$command_name" = add ] || [ "$command_name" = del ]; then
        run_certbot_issue
    else
        run_certbot_renew
    fi

    printf '\nCertificate operation completed.\n'
    printf 'Run `docker compose exec gateway nginx -t` after adding or changing HTTPS server blocks.\n'
}

main "$@"
