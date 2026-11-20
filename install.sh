#!/usr/bin/env bash
# Installs Castra on this host with Docker Compose.
#
#   ./install.sh                         asks what it needs
#   ./install.sh --answers answers.env   no questions: read the answers from a file (see install.answers.example)
#   ./install.sh --help
#
# It checks the host, asks about your domain, sign-in, email, storage and database, generates every secret
# (they go into compose/.env, mode 600, and are never printed), pulls the images, starts Castra and waits
# for it to be ready. Run it again at any time: it keeps an existing compose/.env unless you say otherwise.
# It does not need root, only a user who can run `docker`.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
compose_dir="$here/compose"
env_file="$compose_dir/.env"

declare -A ans=()
interactive=1
[ -t 0 ] || interactive=0
skip_pull=0
skip_start=0
skip_checks=0
skip_verify=0
offline=0

say() { printf '%s\n' "$*"; }
warn() { printf 'warning: %s\n' "$*" >&2; }
die() { printf 'install: %s\n' "$*" >&2; exit 1; }

usage() {
  cat << 'EOF'
Usage: ./install.sh [options]

  --answers FILE      read answers from FILE (KEY=value lines; see install.answers.example) and ask nothing
  --set KEY=VALUE     give one answer on the command line (repeatable)
  --version VERSION   the Castra release to install, for example 1.0.0 (same as --set VERSION=...)
  --domain NAME       the public address people use, for example castra.example.com (same as --set DOMAIN=...)
  --accept-licence    accept the Castra Licence without being asked (same as --set ACCEPT_LICENCE=yes)
  --yes               never ask: use answers and defaults, stop if something required is missing
  --offline           the images are already loaded (see load.sh): do not pull and do not verify signatures
  --skip-pull         do not pull images
  --skip-verify       do not check image signatures, even if cosign is installed
  --skip-start        write compose/.env and stop before starting Castra
  --skip-checks       do not check docker, disk, memory and ports
  -h, --help          this text

Answers are written to compose/.env, which holds your secrets: keep it private and keep a copy somewhere safe.
EOF
}

# ---------------------------------------------------------------- arguments

load_answers() {
  [ -f "$1" ] || die "answers file not found: $1"
  local line key val
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in '' | '#'*) continue ;; esac
    case "$line" in *=*) ;; *) die "answers file: not KEY=value: $line" ;; esac
    key="${line%%=*}"
    val="${line#*=}"
    [[ "$key" =~ ^[A-Z][A-Z0-9_]*$ ]] || die "answers file: bad key: $key"
    case "$val" in \"*\") val="${val#\"}"; val="${val%\"}" ;; \'*\') val="${val#\'}"; val="${val%\'}" ;; esac
    ans["$key"]="$val"
  done < "$1"
}

while [ $# -gt 0 ]; do
  case "$1" in
    --answers) [ $# -ge 2 ] || die "--answers needs a file"; load_answers "$2"; interactive=0; shift 2 ;;
    --set)
      [ $# -ge 2 ] || die "--set needs KEY=VALUE"
      case "$2" in *=*) ans["${2%%=*}"]="${2#*=}" ;; *) die "--set needs KEY=VALUE" ;; esac
      shift 2 ;;
    --version) [ $# -ge 2 ] || die "--version needs a value"; ans[VERSION]="$2"; shift 2 ;;
    --domain) [ $# -ge 2 ] || die "--domain needs a value"; ans[DOMAIN]="$2"; shift 2 ;;
    --accept-licence) ans[ACCEPT_LICENCE]=yes; shift ;;
    --yes | -y) interactive=0; shift ;;
    --offline) offline=1; skip_pull=1; skip_verify=1; shift ;;
    --skip-pull) skip_pull=1; shift ;;
    --skip-verify) skip_verify=1; shift ;;
    --skip-start) skip_start=1; shift ;;
    --skip-checks) skip_checks=1; shift ;;
    -h | --help) usage; exit 0 ;;
    *) usage >&2; die "unknown option: $1" ;;
  esac
done

# ---------------------------------------------------------------- helpers

dc() { "$compose_dir/castra.sh" "$@"; }

# ask VAR "question" [default]: the answer is ans[VAR] if given, else typed, else the default.
ask() {
  local var="$1" q="$2" def="${3:-}" reply
  if [ -n "${ans[$var]+x}" ]; then printf -v "$var" '%s' "${ans[$var]}"; return; fi
  if [ "$interactive" = 1 ]; then
    if [ -n "$def" ]; then read -r -p "$q [$def]: " reply; else read -r -p "$q: " reply; fi
    printf -v "$var" '%s' "${reply:-$def}"
  else
    printf -v "$var" '%s' "$def"
  fi
}

# ask_choice VAR "question" default option...: as ask, but the answer must be one of the options.
ask_choice() {
  local var="$1" q="$2" def="$3"; shift 3
  local opts=("$@") ok=0 o
  while true; do
    ask "$var" "$q ($(IFS=/; echo "${opts[*]}"))" "$def"
    for o in "${opts[@]}"; do [ "${!var}" = "$o" ] && ok=1; done
    [ "$ok" = 1 ] && return
    [ "$interactive" = 1 ] || die "$var must be one of: ${opts[*]} (got '${!var}')"
    unset "ans[$var]"
    say "Please answer one of: ${opts[*]}"
  done
}

# ask_secret VAR "question": hidden input; from the answers file when given. May be left empty.
ask_secret() {
  local var="$1" q="$2" reply=""
  if [ -n "${ans[$var]+x}" ]; then printf -v "$var" '%s' "${ans[$var]}"; return; fi
  if [ "$interactive" = 1 ]; then
    read -r -s -p "$q: " reply
    printf '\n'
  fi
  printf -v "$var" '%s' "$reply"
}

# require VAR "what": stop (non-interactive) or keep asking (interactive) until VAR is not empty.
require() {
  local var="$1" what="$2"
  [ -n "${!var}" ] && return
  [ "$interactive" = 1 ] || die "$what is required: set $var in the answers"
  while [ -z "${!var}" ]; do
    read -r -p "$what: " reply
    printf -v "$var" '%s' "$reply"
  done
}

rand_hex() { # rand_hex BYTES
  if command -v openssl > /dev/null 2>&1; then
    openssl rand -hex "$1"
  else
    head -c "$1" /dev/urandom | od -An -tx1 | tr -d ' \n'
  fi
}

# Prints a Web Push key pair as two lines, WEB_PUSH_PUBLIC_KEY=... and WEB_PUSH_PRIVATE_KEY=... (base64url, no padding).
# An EC key in DER is 7 bytes of header, the 32-byte private value, 17 bytes of curve data, then the 65-byte public point.
vapid_keys() {
  local der priv pub
  command -v openssl > /dev/null 2>&1 || die "openssl is needed to make push keys"
  der="$(mktemp)"
  openssl ecparam -genkey -name prime256v1 -noout | openssl ec -outform DER > "$der" 2> /dev/null
  priv="$(dd if="$der" bs=1 skip=7 count=32 2> /dev/null | openssl base64 -A | tr '+/' '-_' | tr -d '=')"
  pub="$(tail -c 65 "$der" | openssl base64 -A | tr '+/' '-_' | tr -d '=')"
  rm -f "$der"
  [ "${#priv}" = 43 ] && [ "${#pub}" = 87 ] || die "could not make push keys"
  printf 'WEB_PUSH_PUBLIC_KEY=%s\nWEB_PUSH_PRIVATE_KEY=%s\n' "$pub" "$priv"
}

# Writes NAME=value into the new env file, replacing the example's line (commented or not), or appending.
set_env() {
  local name="$1" value="$2" quoted
  case "$value" in *\'* | *$'\n'*) die "$name: values cannot contain a quote or a newline" ;; esac
  if [[ "$value" =~ ^[A-Za-z0-9_./:@%+=,?\&~-]*$ ]]; then quoted="$value"; else quoted="'$value'"; fi
  NAME="$name" VALUE="$quoted" awk '
    BEGIN { n = ENVIRON["NAME"]; v = ENVIRON["VALUE"]; done = 0; set = n "=" ; cmt = "# " n "=" }
    {
      if (!done && (index($0, set) == 1 || index($0, cmt) == 1)) { print n "=" v; done = 1; next }
      print
    }
    END { if (!done) print n "=" v }
  ' "$new_env" > "$new_env.tmp" && mv "$new_env.tmp" "$new_env"
}

url_encode() { # percent-encode everything outside A-Za-z0-9._~-
  local s="$1" out="" i c
  for ((i = 0; i < ${#s}; i++)); do
    c="${s:i:1}"
    case "$c" in [A-Za-z0-9._~-]) out+="$c" ;; *) out+="$(printf '%%%02X' "'$c")" ;; esac
  done
  printf '%s' "$out"
}

port_in_use() {
  if command -v ss > /dev/null 2>&1; then
    ss -ltn 2> /dev/null | awk -v p=":$1" '$4 ~ p"$" { f = 1 } END { exit !f }'
  else
    (exec 3<> "/dev/tcp/127.0.0.1/$1") 2> /dev/null
  fi
}

# ---------------------------------------------------------------- checks

check_host() {
  say "Checking this host"
  [ "$(uname -s)" = Linux ] || warn "this is not Linux; Castra's install is only tested on Linux"
  case "$(uname -m)" in
    x86_64 | amd64 | aarch64 | arm64) ;;
    *) die "unsupported architecture $(uname -m): the images are for amd64 and arm64" ;;
  esac
  command -v docker > /dev/null 2>&1 || die "docker is not installed. Install Docker Engine: https://docs.docker.com/engine/install/"
  docker compose version > /dev/null 2>&1 || die "Docker Compose v2 is missing (the 'docker compose' command). Install the compose plugin: https://docs.docker.com/compose/install/linux/"
  docker info > /dev/null 2>&1 || die "cannot talk to the Docker daemon. Is it running, and is your user in the docker group?"

  local free_kb mem_kb
  free_kb="$(df -Pk "$here" | awk 'NR == 2 { print $4 }')"
  if [ -n "$free_kb" ] && [ "$free_kb" -lt $((5 * 1024 * 1024)) ]; then
    die "less than 5 GB free in $here. Castra's images and data need more; free some space or use another disk"
  elif [ -n "$free_kb" ] && [ "$free_kb" -lt $((20 * 1024 * 1024)) ]; then
    warn "less than 20 GB free in $here. That is enough to start, not to grow"
  fi
  mem_kb="$(awk '/^MemAvailable:/ { print $2 }' /proc/meminfo 2> /dev/null || true)"
  if [ -n "$mem_kb" ] && [ "$mem_kb" -lt $((2 * 1024 * 1024)) ]; then
    die "less than 2 GB of memory available. Castra needs at least 4 GB of RAM for the minimal profile"
  elif [ -n "$mem_kb" ] && [ "$mem_kb" -lt $((3 * 1024 * 1024)) ]; then
    warn "less than 3 GB of memory available; 4 GB is the starting point for the minimal profile"
  fi
}

check_ports() { # check_ports PORT...
  local p running=0
  [ -f "$env_file" ] && [ -n "$(dc ps -q 2> /dev/null || true)" ] && running=1
  for p in "$@"; do
    if port_in_use "$p"; then
      if [ "$running" = 1 ]; then warn "port $p is in use (probably Castra itself)"; else die "port $p is already in use on this host. Stop what uses it or choose another port"; fi
    fi
  done
}

# ---------------------------------------------------------------- cosign

verify_images() {
  command -v cosign > /dev/null 2>&1 || { say "cosign is not installed: skipping signature checks (see README, \"Images\")"; return 0; }
  local img
  while IFS= read -r img; do
    case "$img" in ghcr.io/castracloud/castra-*) ;; *) continue ;; esac
    say "Verifying the signature of $img"
    cosign verify "$img" \
      --certificate-oidc-issuer https://token.actions.githubusercontent.com \
      --certificate-identity-regexp '^https://github\.com/CastraCloud/castra/\.github/workflows/ci\.yml@refs/tags/v.*$' > /dev/null 2>&1 \
      || die "the signature of $img could not be verified. Do not run it; check the version and your network, or use --skip-verify if you accept the risk"
  done < <(dc config --images 2> /dev/null)
}

# ---------------------------------------------------------------- bundled identity provider

create_first_admin() {
  local user="$1" email="$2" fullname="$3" pw="$4" temp="$5"
  local first="${fullname%% *}" last="${fullname#* }"
  [ "$last" != "$fullname" ] || last="Admin"
  say "Creating the first administrator '$user' in the bundled identity provider"
  # The password goes in on stdin and the admin credentials stay inside the container: nothing secret is in a process list.
  printf '%s\n' "$pw" | dc exec -T -e FA_USER="$user" -e FA_EMAIL="$email" -e FA_FIRST="$first" -e FA_LAST="$last" -e FA_TEMP="$temp" idp sh -c '
    set -eu
    read -r FA_PASS
    kc=/opt/keycloak/bin/kcadm.sh
    $kc config credentials --server http://localhost:8080/idp --realm master \
      --user "$KC_BOOTSTRAP_ADMIN_USERNAME" --password "$KC_BOOTSTRAP_ADMIN_PASSWORD" > /dev/null
    if $kc get users -r castra -q username="$FA_USER" --fields username | grep -q "\"$FA_USER\""; then
      echo "user exists, leaving it as it is"; exit 0
    fi
    $kc create users -r castra -s username="$FA_USER" -s email="$FA_EMAIL" -s emailVerified=true \
      -s firstName="$FA_FIRST" -s lastName="$FA_LAST" -s enabled=true
    if [ "$FA_TEMP" = true ]; then
      $kc set-password -r castra --username "$FA_USER" --new-password "$FA_PASS" --temporary
    else
      $kc set-password -r castra --username "$FA_USER" --new-password "$FA_PASS"
    fi
  ' || return 1
}

# ---------------------------------------------------------------- licence

licence_notice() {
  say "Castra is free to install and use for your own organisation, under the Castra Licence."
  say "It is not open source, and it may not be offered to others as a hosted service."
  say "The full text is in LICENSE-castra.md in this folder, and at"
  say "https://github.com/CastraCloud/deploy/blob/main/LICENSE-castra.md"
}

# Nothing is written before this passes. An administrator is also asked to accept the licence in the app on first sign-in.
accept_licence() {
  licence_notice
  say ""
  if [ -n "${ans[ACCEPT_LICENCE]+x}" ]; then
    [ "${ans[ACCEPT_LICENCE]}" = yes ] || die "ACCEPT_LICENCE must be 'yes' to install Castra. Read LICENSE-castra.md first"
    say "Licence accepted (ACCEPT_LICENCE=yes)."
  elif [ "$interactive" = 1 ]; then
    local reply
    read -r -p "Type yes to accept the Castra Licence and continue: " reply
    [ "$reply" = yes ] || die "the licence was not accepted, so nothing was installed"
  else
    die "the Castra Licence needs accepting: read LICENSE-castra.md, then set ACCEPT_LICENCE=yes in the answers or pass --accept-licence"
  fi
  say ""
}

# ---------------------------------------------------------------- start

[ -f "$compose_dir/compose.yml" ] || die "compose/compose.yml not found next to install.sh"
[ -x "$compose_dir/castra.sh" ] || chmod +x "$compose_dir/castra.sh" 2> /dev/null || true

say "Castra installer"
say ""

accept_licence

[ "$skip_checks" = 1 ] || check_host

# ---- an existing install
keep_env=0
if [ -f "$env_file" ]; then
  say "compose/.env already exists."
  if [ "$interactive" = 1 ] && [ -z "${ans[EXISTING_ENV]+x}" ]; then
    say "  keep:    use it as it is and just pull and start (the safe choice)"
    say "  replace: save it as compose/.env.old-<time>, generate new secrets and ask everything again."
    say "           Do this only on a fresh host: the database and storage on an existing install keep their old passwords."
    ask_choice EXISTING_ENV "Keep or replace it?" keep keep replace abort
  else
    EXISTING_ENV="${ans[EXISTING_ENV]:-keep}"
  fi
  case "$EXISTING_ENV" in
    keep) keep_env=1 ;;
    replace) cp -p "$env_file" "$env_file.old-$(date -u +%Y%m%dT%H%M%SZ)" ;;
    *) die "stopped: nothing was changed" ;;
  esac
fi

if [ "$keep_env" = 0 ]; then
  [ -f "$compose_dir/.env.example" ] || die "compose/.env.example not found"
  new_env="$(umask 077; mktemp "$compose_dir/.env.new.XXXXXX")"
  trap 'rm -f "$new_env" "$new_env.tmp"' EXIT
  cp "$compose_dir/.env.example" "$new_env"
  chmod 600 "$new_env"

  say ""
  say "A few questions. Press Enter to accept the answer in [brackets]."
  say ""

  # ---- version and address
  ask VERSION "Castra version to install, for example 1.0.0 (see the releases at https://github.com/CastraCloud/deploy/releases)" ""
  require VERSION "Castra version"
  [[ "$VERSION" =~ ^[0-9A-Za-z][0-9A-Za-z._-]*$ ]] || die "VERSION does not look like a version tag: $VERSION"
  [ "$VERSION" != latest ] || warn "'latest' moves when a release is made. Pin an exact version for production"
  set_env CASTRA_VERSION "$VERSION"

  say "HTTPS. off = plain http, for use behind your own TLS proxy (or a trial); self-signed = Castra makes a certificate"
  say "with its own certificate authority; files = your certificate and key; acme = automatic certificates from"
  say "Let's Encrypt or from your own ACME server."
  ask_choice TLS_MODE "TLS mode" off off self-signed files acme
  files=()
  profiles=()
  proxy_https=no
  case "$TLS_MODE" in
    off)
      ask DOMAIN "Address people will use (a host name or IP, or localhost)" "localhost"
      ask_choice PROXY_HTTPS "Does your own proxy serve Castra over https?" no yes no
      proxy_https="$PROXY_HTTPS"
      ask HTTP_PORT "Port Castra listens on for it" 8080
      ;;
    *)
      ask DOMAIN "Public address (domain name, for example castra.example.com)" ""
      require DOMAIN "Public address"
      HTTP_PORT=80
      files+=(compose.tls.yml)
      ;;
  esac
  [[ "$DOMAIN" =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$ ]] || die "DOMAIN must be a host name or IP address, with no scheme or port: $DOMAIN"
  [[ "$HTTP_PORT" =~ ^[0-9]{1,5}$ ]] || die "port must be a number: $HTTP_PORT"
  set_env CASTRA_HTTP_PORT "$HTTP_PORT"
  set_env CASTRA_TLS_MODE "$TLS_MODE"
  scheme=https
  case "$TLS_MODE" in
    off)
      if [ "$proxy_https" = yes ]; then
        set_env CASTRA_HSTS true
      else
        scheme=http
        set_env SESSION_COOKIE_SECURE false
        warn "plain http is for trying Castra out: passwords and sessions cross the network unprotected"
      fi
      ports=("$HTTP_PORT")
      ;;
    self-signed)
      set_env CASTRA_DOMAIN "$DOMAIN"
      # HSTS on a certificate the browser does not trust would stop people clicking through the warning.
      ports=(80 443)
      ;;
    files)
      set_env CASTRA_DOMAIN "$DOMAIN"
      ask TLS_CERT_FILE "Path of the certificate chain (PEM, server certificate first)" ""; require TLS_CERT_FILE "Certificate file"
      ask TLS_KEY_FILE "Path of the private key (PEM)" ""; require TLS_KEY_FILE "Key file"
      [[ "$TLS_CERT_FILE" = /* && "$TLS_KEY_FILE" = /* ]] || die "give absolute paths for the certificate and key"
      [ -r "$TLS_CERT_FILE" ] || die "cannot read $TLS_CERT_FILE"
      [ -r "$TLS_KEY_FILE" ] || die "cannot read $TLS_KEY_FILE"
      warn "the web container runs as uid 10001 and must be able to read the key file (for example chgrp or chmod it)"
      set_env CASTRA_TLS_CERT_FILE "$TLS_CERT_FILE"
      set_env CASTRA_TLS_KEY_FILE "$TLS_KEY_FILE"
      set_env CASTRA_HSTS true
      ports=(80 443)
      ;;
    acme)
      set_env CASTRA_DOMAIN "$DOMAIN"
      ask ACME_EMAIL "Contact email for the certificate authority (optional)" ""
      ask ACME_DIRECTORY "ACME directory URL (empty: Let's Encrypt)" ""
      [ -z "$ACME_EMAIL" ] || set_env CASTRA_ACME_EMAIL "$ACME_EMAIL"
      if [ -n "$ACME_DIRECTORY" ]; then
        [[ "$ACME_DIRECTORY" =~ ^https:// ]] || die "ACME_DIRECTORY must be an https address"
        set_env CASTRA_ACME_DIRECTORY "$ACME_DIRECTORY"
        ask ACME_CA_ROOT "Root certificate (PEM file) that signs that server's certificate, if it is not a public one" ""
        if [ -n "$ACME_CA_ROOT" ]; then
          [[ "$ACME_CA_ROOT" = /* ]] && [ -r "$ACME_CA_ROOT" ] || die "ACME_CA_ROOT must be an absolute path of a readable file"
          set_env CASTRA_ACME_CA_ROOT "$ACME_CA_ROOT"
        fi
        ask ACME_EAB_KEY_ID "External account binding key id (empty if not needed)" ""
        if [ -n "$ACME_EAB_KEY_ID" ]; then
          ask_secret ACME_EAB_HMAC_KEY "External account binding HMAC key"; require ACME_EAB_HMAC_KEY "HMAC key"
          set_env CASTRA_ACME_EAB_KEY_ID "$ACME_EAB_KEY_ID"
          set_env CASTRA_ACME_EAB_HMAC_KEY "$ACME_EAB_HMAC_KEY"
        fi
      fi
      set_env CASTRA_HSTS true
      ports=(80 443)
      ;;
  esac
  if [ "$TLS_MODE" = off ] && [ "$scheme" = http ] && [ "$HTTP_PORT" != 80 ]; then public_url="http://$DOMAIN:$HTTP_PORT"; else public_url="$scheme://$DOMAIN"; fi
  set_env CASTRA_PUBLIC_URL "$public_url"

  # ---- diagrams
  ask_choice DRAWIO "Diagram editing (Draw.io): the bundled one, your own server, or none?" bundled bundled external none
  drawio_url=""
  case "$DRAWIO" in
    bundled)
      # A host name for Draw.io is a different origin from Castra, on the normal ports. Without one (an IP or no DNS) it gets its own port.
      drawio_mode=port
      if [[ "$DOMAIN" == *.* && ! "$DOMAIN" =~ ^[0-9.]+$ && "$DOMAIN" != localhost ]]; then
        drawio_mode=host
        # An answers file from before host names existed names a port: keep that behaviour.
        [ -z "${ans[DRAWIO_PORT]+x}" ] || [ -n "${ans[DRAWIO_MODE]+x}" ] || drawio_mode=port
        say "Draw.io runs on its own origin so it cannot act as Castra: on a host name of its own (needs a DNS record for it), or on its own port."
        ask_choice DRAWIO_MODE "Serve Draw.io on a host name or a port?" "$drawio_mode" host port
        drawio_mode="$DRAWIO_MODE"
      fi
      if [ "$drawio_mode" = host ]; then
        if [ "$(printf '%s' "$DOMAIN" | tr -cd . | wc -c)" -ge 2 ]; then
          drawio_suggest="${DOMAIN%%.*}-diagrams.${DOMAIN#*.}"
        else
          drawio_suggest="diagrams.$DOMAIN"
        fi
        say "A name like castra-diagrams.example.com is covered by a one-level wildcard certificate (*.example.com, such as Cloudflare's free one)."
        say "A name like diagrams.castra.example.com needs a certificate for *.castra.example.com."
        ask DRAWIO_DOMAIN "Host name for Draw.io (point its DNS record where $DOMAIN points)" "$drawio_suggest"
        [[ "$DRAWIO_DOMAIN" =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$ && "$DRAWIO_DOMAIN" == *.* ]] || die "DRAWIO_DOMAIN must be a host name, with no scheme or port: $DRAWIO_DOMAIN"
        [ "$DRAWIO_DOMAIN" != "$DOMAIN" ] || die "DRAWIO_DOMAIN must differ from DOMAIN: Draw.io needs an origin of its own"
        set_env CASTRA_DRAWIO_DOMAIN "$DRAWIO_DOMAIN"
        # Nothing listens on the old Draw.io port in this form.
        set_env CASTRA_DRAWIO_BIND 127.0.0.1
        if [ "$TLS_MODE" = files ]; then
          ask DRAWIO_TLS_CERT_FILE "Certificate chain for $DRAWIO_DOMAIN, if the one above does not cover it (empty: use the same)" ""
          if [ -n "$DRAWIO_TLS_CERT_FILE" ]; then
            ask DRAWIO_TLS_KEY_FILE "Private key for $DRAWIO_DOMAIN" ""; require DRAWIO_TLS_KEY_FILE "Draw.io key file"
            [[ "$DRAWIO_TLS_CERT_FILE" = /* && "$DRAWIO_TLS_KEY_FILE" = /* ]] || die "give absolute paths for the Draw.io certificate and key"
            [ -r "$DRAWIO_TLS_CERT_FILE" ] || die "cannot read $DRAWIO_TLS_CERT_FILE"
            [ -r "$DRAWIO_TLS_KEY_FILE" ] || die "cannot read $DRAWIO_TLS_KEY_FILE"
            set_env CASTRA_TLS_DRAWIO_CERT "$DRAWIO_TLS_CERT_FILE"
            set_env CASTRA_TLS_DRAWIO_KEY "$DRAWIO_TLS_KEY_FILE"
          fi
        fi
        if [ "$TLS_MODE" = off ] && [ "$scheme" = http ] && [ "$HTTP_PORT" != 80 ]; then drawio_url="http://$DRAWIO_DOMAIN:$HTTP_PORT"; else drawio_url="$scheme://$DRAWIO_DOMAIN"; fi
        [ "$TLS_MODE" != off ] || [ "$proxy_https" != yes ] || say "Your proxy must also serve $DRAWIO_DOMAIN over https and pass it to port $HTTP_PORT here (see docs/behind-a-proxy.md)."
      else
        ask DRAWIO_PORT "Port the bundled Draw.io listens on" 8081
        set_env CASTRA_DRAWIO_PORT "$DRAWIO_PORT"
        ports+=("$DRAWIO_PORT")
        if [ "$TLS_MODE" = off ] && [ "$proxy_https" = yes ]; then
          say "Your proxy serves Castra over https, so it must also serve Draw.io (this host, port $DRAWIO_PORT) over https."
          ask DRAWIO_PUBLIC_URL "The https address your proxy gives Draw.io (empty: set DRAWIO_URL in compose/.env later)" ""
          drawio_url="$DRAWIO_PUBLIC_URL"
        else
          drawio_url="$scheme://$DOMAIN:$DRAWIO_PORT"
        fi
      fi
      ;;
    external)
      files+=(compose.external-drawio.yml)
      ask DRAWIO_PUBLIC_URL "Address of your Draw.io server (https)" ""; require DRAWIO_PUBLIC_URL "Draw.io address"
      drawio_url="$DRAWIO_PUBLIC_URL"
      ;;
    none) files+=(compose.external-drawio.yml) ;;
  esac
  if [ -n "$drawio_url" ]; then
    [[ "$drawio_url" =~ ^https?://[^[:space:]]+$ ]] || die "the Draw.io address must start with http:// or https://: $drawio_url"
    set_env DRAWIO_URL "$drawio_url"
    set_env CASTRA_FRAME_SRC "$(printf '%s' "$drawio_url" | sed -E 's#^(https?://[^/]+).*#\1#')"
  fi

  # ---- the portal on its own host name (optional)
  # People who raise requests then reach the portal at the root of that name, and can sign in with an emailed link.
  if [[ "$DOMAIN" == *.* && ! "$DOMAIN" =~ ^[0-9.]+$ && "$DOMAIN" != localhost ]]; then
    ask PORTAL_DOMAIN "Host name for the portal, such as help.${DOMAIN#*.} (empty: the portal stays at $public_url/portal/)" ""
    if [ -n "$PORTAL_DOMAIN" ]; then
      [[ "$PORTAL_DOMAIN" =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$ && "$PORTAL_DOMAIN" == *.* ]] || die "PORTAL_DOMAIN must be a host name, with no scheme or port: $PORTAL_DOMAIN"
      PORTAL_DOMAIN="$(printf '%s' "$PORTAL_DOMAIN" | tr '[:upper:]' '[:lower:]')"
      [ "$PORTAL_DOMAIN" != "$DOMAIN" ] || die "PORTAL_DOMAIN must differ from DOMAIN"
      [ "$PORTAL_DOMAIN" != "${DRAWIO_DOMAIN:-}" ] || die "PORTAL_DOMAIN must differ from DRAWIO_DOMAIN"
      set_env CASTRA_PORTAL_DOMAIN "$PORTAL_DOMAIN"
      if [ "$TLS_MODE" = files ]; then
        ask PORTAL_TLS_CERT_FILE "Certificate chain for $PORTAL_DOMAIN, if the one above does not cover it (empty: use the same)" ""
        if [ -n "$PORTAL_TLS_CERT_FILE" ]; then
          ask PORTAL_TLS_KEY_FILE "Private key for $PORTAL_DOMAIN" ""; require PORTAL_TLS_KEY_FILE "Portal key file"
          [[ "$PORTAL_TLS_CERT_FILE" = /* && "$PORTAL_TLS_KEY_FILE" = /* ]] || die "give absolute paths for the portal certificate and key"
          [ -r "$PORTAL_TLS_CERT_FILE" ] || die "cannot read $PORTAL_TLS_CERT_FILE"
          [ -r "$PORTAL_TLS_KEY_FILE" ] || die "cannot read $PORTAL_TLS_KEY_FILE"
          set_env CASTRA_TLS_PORTAL_CERT "$PORTAL_TLS_CERT_FILE"
          set_env CASTRA_TLS_PORTAL_KEY "$PORTAL_TLS_KEY_FILE"
        fi
      fi
      [ "$TLS_MODE" != off ] || [ "$proxy_https" != yes ] || say "Your proxy must also serve $PORTAL_DOMAIN over https and pass it to port $HTTP_PORT here (see docs/behind-a-proxy.md)."
      say "Point a DNS record for $PORTAL_DOMAIN where $DOMAIN points. Then add the portal's sign-up policy under Administration, Portal."
    fi
  fi
  [ "$skip_checks" = 1 ] || check_ports "${ports[@]}"

  ask_choice PROFILE "Run every part in one process (minimal) or each on its own (full)?" minimal minimal full
  profiles+=("$PROFILE")

  # ---- database
  ask_choice DATABASE "Database: the bundled Postgres, or your own existing Postgres 17 or newer?" bundled bundled external
  if [ "$DATABASE" = bundled ]; then
    set_env POSTGRES_PASSWORD "$(rand_hex 24)"
    set_env CASTRA_DB_OWNER_PASSWORD "$(rand_hex 24)"
    set_env CASTRA_DB_APP_PASSWORD "$(rand_hex 24)"
  else
    files+=(compose.external-db.yml)
    ask DB_HOST "Database host" ""; require DB_HOST "Database host"
    ask DB_PORT "Database port" 5432
    ask DB_NAME "Database name (it must exist and be empty or already Castra's)" castra
    ask_choice DB_SSLMODE "SSL mode for the connection" require require verify-full prefer disable
    set_env CASTRA_DB_HOST "$DB_HOST"
    set_env CASTRA_DB_PORT "$DB_PORT"
    set_env POSTGRES_DB "$DB_NAME"
    set_env CASTRA_DB_PARAMS "?sslmode=$DB_SSLMODE"
    set_env POSTGRES_PASSWORD "$(rand_hex 24)" # unused with your own database, but the Compose file asks for it
    ask_secret DB_OWNER_PASSWORD "Password of the castra_owner role (leave empty to generate one)"
    ask_secret DB_APP_PASSWORD "Password of the castra_app role (leave empty to generate one)"
    [ -n "$DB_OWNER_PASSWORD" ] || DB_OWNER_PASSWORD="$(rand_hex 24)"
    [ -n "$DB_APP_PASSWORD" ] || DB_APP_PASSWORD="$(rand_hex 24)"
    set_env CASTRA_DB_OWNER_PASSWORD "$(url_encode "$DB_OWNER_PASSWORD")"
    set_env CASTRA_DB_APP_PASSWORD "$(url_encode "$DB_APP_PASSWORD")"
    ask DB_ADMIN_USER "A database user that may create roles, so this script can create castra_owner and castra_app (empty: you do it, see README)" ""
    if [ -n "$DB_ADMIN_USER" ]; then
      ask_secret DB_ADMIN_PASSWORD "Password of $DB_ADMIN_USER"
      db_admin_pending=1
    else
      db_admin_pending=0
    fi
  fi

  # ---- object storage
  ask_choice STORAGE "File storage: the bundled SeaweedFS, or an existing S3-compatible bucket?" bundled bundled s3
  if [ "$STORAGE" = bundled ]; then
    set_env S3_ACCESS_KEY "$(rand_hex 10)"
    set_env S3_SECRET_KEY "$(rand_hex 24)"
  else
    files+=(compose.external-s3.yml)
    ask S3_ENDPOINT_ANS "S3 endpoint URL, for example https://s3.eu-west-1.amazonaws.com" ""; require S3_ENDPOINT_ANS "S3 endpoint"
    ask S3_REGION_ANS "Region" us-east-1
    ask S3_BUCKET_ANS "Bucket name (it must already exist)" castra
    ask S3_ACCESS_KEY_ANS "Access key" ""; require S3_ACCESS_KEY_ANS "Access key"
    ask_secret S3_SECRET_KEY_ANS "Secret key"; require S3_SECRET_KEY_ANS "Secret key"
    ask_choice S3_PATH_STYLE "Path-style addressing (true for most non-AWS stores)" false true false
    set_env S3_ENDPOINT "$S3_ENDPOINT_ANS"
    set_env S3_REGION "$S3_REGION_ANS"
    set_env S3_BUCKET "$S3_BUCKET_ANS"
    set_env S3_ACCESS_KEY "$S3_ACCESS_KEY_ANS"
    set_env S3_SECRET_KEY "$S3_SECRET_KEY_ANS"
    [ "$S3_PATH_STYLE" != true ] || set_env S3_FORCE_PATH_STYLE true
  fi

  # ---- sign-in
  ask_choice IDP "Sign-in: your own identity provider (external), or run the bundled Keycloak (bundled)?" external external bundled
  IDP_PROTOCOL=oidc
  [ "$IDP" != external ] || ask_choice IDP_PROTOCOL "Your identity provider speaks OpenID Connect (oidc) or SAML 2.0, for ADFS and others (saml)?" oidc oidc saml
  set_env SESSION_SECRET "$(rand_hex 48)"
  set_env KEYCLOAK_ADMIN_PASSWORD "$(rand_hex 18)"
  ask ORG_NAME "Name of your organisation" "My organisation"
  org_slug="$(printf '%s' "$ORG_NAME" | tr '[:upper:]' '[:lower:]' | sed -e 's/[^a-z0-9]\{1,\}/-/g' -e 's/^-//' -e 's/-$//')"
  ask ORG_SLUG "Short name for it (letters, numbers, dashes)" "${org_slug:-main}"
  set_env CASTRA_BOOTSTRAP_ORG_NAME "$ORG_NAME"
  set_env CASTRA_BOOTSTRAP_ORG_SLUG "$ORG_SLUG"
  if [ "$IDP" = bundled ]; then
    [ "$scheme" = https ] || die "the bundled sign-in needs a real address with HTTPS (TLS_MODE self-signed, files or acme, or off behind your own https proxy): the server must be able to reach the address people use. Use an external provider for a plain-http trial"
    [ "$TLS_MODE" != self-signed ] || die "with a self-signed certificate the Castra server cannot reach the sign-in address (it does not trust the internal CA). Use TLS_MODE files or acme with the bundled sign-in"
    [ "$DATABASE" = bundled ] || die "the bundled sign-in keeps its data in the bundled Postgres. Choose DATABASE=bundled, or use your own provider"
    profiles+=(identity)
    oidc_secret="$(rand_hex 24)"
    set_env OIDC_REDIRECT_URI "$public_url/auth/callback"
    set_env OIDC_ISSUER "$public_url/idp/realms/castra"
    set_env OIDC_CLIENT_ID castra
    set_env OIDC_CLIENT_SECRET "$oidc_secret"
    set_env KEYCLOAK_DB_PASSWORD "$(rand_hex 24)"
    ask FIRST_ADMIN_USER "Username of the first administrator" admin
    ask FIRST_ADMIN_NAME "Their full name" "Castra Admin"
    ask FIRST_ADMIN_EMAIL "Their email address" ""; require FIRST_ADMIN_EMAIL "Their email address"
    ask_secret FIRST_ADMIN_PASSWORD "Their password, at least 12 characters (empty: generate one, saved to compose/first-admin.txt)"
    set_env CASTRA_BOOTSTRAP_ADMINS "$FIRST_ADMIN_USER"
  elif [ "$IDP_PROTOCOL" = saml ]; then
    ask SAML_IDP_METADATA_URL_ANS "Metadata URL of your identity provider, for example https://adfs.example.com/FederationMetadata/2007-06/FederationMetadata.xml" ""; require SAML_IDP_METADATA_URL_ANS "Metadata URL"
    case "$SAML_IDP_METADATA_URL_ANS" in http://* | https://*) ;; *) die "the metadata address must start with https:// (or http://)" ;; esac
    saml_entity_default=""
    if [ -z "${ans[SAML_IDP_ENTITY_ID_ANS]+x}" ] && command -v curl > /dev/null 2>&1; then
      saml_entity_default="$(curl -fsS --max-time 10 "$SAML_IDP_METADATA_URL_ANS" 2> /dev/null | tr '\n' ' ' | sed -n 's/.*<[A-Za-z:]*EntityDescriptor[^>]* entityID="\([^"]*\)".*/\1/p' | head -n 1 || true)"
    fi
    ask SAML_IDP_ENTITY_ID_ANS "Entity ID of your identity provider (the entityID in its metadata)" "$saml_entity_default"; require SAML_IDP_ENTITY_ID_ANS "Entity ID"
    ask SAML_ATTR_USERNAME_ANS "SAML attribute that holds the username (empty: the ADFS and Entra ID defaults)" ""
    ask SAML_ATTR_GROUPS_ANS "SAML attribute that holds group names (empty: the defaults)" ""
    ask OIDC_REQUIRED_GROUPS_ANS "Only allow members of these groups, comma separated (empty: everyone)" ""
    ask BOOTSTRAP_ADMINS "Username(s) of the first administrators, comma separated (as your provider sends them, for ADFS usually user@domain)" ""; require BOOTSTRAP_ADMINS "First administrator"
    set_env SAML_IDP_METADATA_URL "$SAML_IDP_METADATA_URL_ANS"
    set_env SAML_IDP_ENTITY_ID "$SAML_IDP_ENTITY_ID_ANS"
    [ -z "$SAML_ATTR_USERNAME_ANS" ] || set_env SAML_ATTR_USERNAME "$SAML_ATTR_USERNAME_ANS"
    [ -z "$SAML_ATTR_GROUPS_ANS" ] || set_env SAML_ATTR_GROUPS "$SAML_ATTR_GROUPS_ANS"
    set_env OIDC_REQUIRED_GROUPS "$OIDC_REQUIRED_GROUPS_ANS"
    set_env CASTRA_BOOTSTRAP_ADMINS "$BOOTSTRAP_ADMINS"
  else
    set_env OIDC_REDIRECT_URI "$public_url/auth/callback"
    ask OIDC_ISSUER_ANS "Issuer URL of your provider (see README, \"Your own identity provider\")" ""; require OIDC_ISSUER_ANS "Issuer URL"
    ask OIDC_CLIENT_ID_ANS "Client ID" castra
    ask_secret OIDC_CLIENT_SECRET_ANS "Client secret"; require OIDC_CLIENT_SECRET_ANS "Client secret"
    ask OIDC_USERNAME_CLAIM_ANS "Claim that holds the username" preferred_username
    ask OIDC_GROUPS_CLAIM_ANS "Claim that holds group names" groups
    ask OIDC_REQUIRED_GROUPS_ANS "Only allow members of these groups, comma separated (empty: everyone)" ""
    ask BOOTSTRAP_ADMINS "Username(s) of the first administrators, comma separated (as your provider reports them)" ""; require BOOTSTRAP_ADMINS "First administrator"
    set_env OIDC_ISSUER "$OIDC_ISSUER_ANS"
    set_env OIDC_CLIENT_ID "$OIDC_CLIENT_ID_ANS"
    set_env OIDC_CLIENT_SECRET "$OIDC_CLIENT_SECRET_ANS"
    set_env OIDC_USERNAME_CLAIM "$OIDC_USERNAME_CLAIM_ANS"
    set_env OIDC_GROUPS_CLAIM "$OIDC_GROUPS_CLAIM_ANS"
    set_env OIDC_REQUIRED_GROUPS "$OIDC_REQUIRED_GROUPS_ANS"
    set_env CASTRA_BOOTSTRAP_ADMINS "$BOOTSTRAP_ADMINS"
  fi

  # ---- email
  ask_choice EMAIL "Outgoing email: through an SMTP relay, or none (notifications then show in the app only)?" none none smtp
  if [ "$EMAIL" = smtp ]; then
    ask SMTP_HOST_ANS "SMTP host" ""; require SMTP_HOST_ANS "SMTP host"
    ask SMTP_PORT_ANS "SMTP port" 587
    ask_choice SMTP_TLS_ANS "Connection security" starttls starttls tls none
    ask SMTP_USER_ANS "SMTP user (empty if none)" ""
    [ -z "$SMTP_USER_ANS" ] || ask_secret SMTP_PASSWORD_ANS "SMTP password"
    ask SMTP_FROM_ANS "From address, for example Castra <castra@example.com>" "Castra <castra@$DOMAIN>"
    set_env SMTP_HOST "$SMTP_HOST_ANS"
    set_env SMTP_PORT "$SMTP_PORT_ANS"
    set_env SMTP_TLS "$SMTP_TLS_ANS"
    [ -z "$SMTP_USER_ANS" ] || set_env SMTP_USER "$SMTP_USER_ANS"
    [ -z "${SMTP_PASSWORD_ANS:-}" ] || set_env SMTP_PASSWORD "$SMTP_PASSWORD_ANS"
    set_env SMTP_FROM "$SMTP_FROM_ANS"
  fi

  # ---- push notifications
  ask_choice PUSH "Push notifications to phones and desktops that install the app? Keys are made for you" no no yes
  if [ "$PUSH" = yes ]; then
    ask PUSH_CONTACT_ANS "Contact the push services can reach you at (mailto: address or https: URL)" "mailto:${FIRST_ADMIN_EMAIL:-admin@$DOMAIN}"
    keys="$(vapid_keys)"
    set_env WEB_PUSH_PUBLIC_KEY "$(printf '%s\n' "$keys" | sed -n 's/^WEB_PUSH_PUBLIC_KEY=//p')"
    set_env WEB_PUSH_PRIVATE_KEY "$(printf '%s\n' "$keys" | sed -n 's/^WEB_PUSH_PRIVATE_KEY=//p')"
    set_env WEB_PUSH_CONTACT "$PUSH_CONTACT_ANS"
  fi

  # ---- inbound email
  ask_choice INBOUND "Email to tickets: read a mailbox over IMAP, or none?" none none imap
  if [ "$INBOUND" = imap ]; then
    ask IMAP_URL_ANS "IMAP address, for example imaps://imap.example.com" ""; require IMAP_URL_ANS "IMAP address"
    ask IMAP_USER_ANS "Mailbox user" ""; require IMAP_USER_ANS "Mailbox user"
    ask_secret IMAP_PASSWORD_ANS "Mailbox password"; require IMAP_PASSWORD_ANS "Mailbox password"
    ask IMAP_FOLDER_ANS "Folder" INBOX
    set_env MAIL_IN_IMAP_URL "$IMAP_URL_ANS"
    set_env MAIL_IN_IMAP_USER "$IMAP_USER_ANS"
    set_env MAIL_IN_IMAP_PASSWORD "$IMAP_PASSWORD_ANS"
    set_env MAIL_IN_IMAP_FOLDER "$IMAP_FOLDER_ANS"
  fi

  # ---- events
  ask_choice EVENT_TRANSPORT "How events reach the workers: outbox (Postgres only, simplest) or nats (starts the NATS service)?" outbox outbox nats
  if [ "$EVENT_TRANSPORT" = nats ]; then
    profiles+=(nats)
    set_env CASTRA_EVENT_TRANSPORT nats
  fi

  # ---- Office previews
  ask_choice PREVIEWS "Office previews (Word, Excel, PowerPoint and OpenDocument files shown in the browser as PDF; the bundled converter needs about 2 GB of memory and a large image): the bundled converter, your own Gotenberg, or none?" none bundled external none
  case "$PREVIEWS" in
    bundled)
      profiles+=(previews)
      set_env PREVIEW_URL http://converter:3000
      ;;
    external)
      files+=(compose.external-previews.yml)
      ask PREVIEWS_URL "Address of your Gotenberg, reachable from the server only (for example http://gotenberg.internal:3000)" ""; require PREVIEWS_URL "Gotenberg address"
      [[ "$PREVIEWS_URL" =~ ^https?://[^[:space:]]+$ ]] || die "the Gotenberg address must start with http:// or https://: $PREVIEWS_URL"
      set_env PREVIEW_URL "$PREVIEWS_URL"
      ;;
  esac

  # What castra.sh starts.
  [ "${#files[@]}" = 0 ] || set_env CASTRA_COMPOSE_FILES "${files[*]}"
  profile_list="$(IFS=,; echo "${profiles[*]}")"
  set_env COMPOSE_PROFILES "$profile_list"

  # ---- write it
  mv "$new_env" "$env_file"
  chmod 600 "$env_file"
  trap - EXIT
  say ""
  say "Wrote compose/.env (mode 600). It holds every secret: keep a copy somewhere safe, apart from your backups."
  say "To change a setting later, edit it and run: compose/castra.sh up -d"
fi

# From here on the settings come from .env, whether it was just written or kept.
[ "$keep_env" = 0 ] || say "Keeping compose/.env as it is."
env_get() { sed -n "s/^$1=//p" "$env_file" | tail -n 1 | sed -e "s/^'\(.*\)'$/\1/"; }
version="$(env_get CASTRA_VERSION)"
case "$version" in '' | CHANGE_ME*) die "CASTRA_VERSION is not set in compose/.env" ;; esac
public_url="$(env_get CASTRA_PUBLIC_URL)"
profile_list="$(env_get COMPOSE_PROFILES)"
case ",$profile_list," in *,identity,*) has_identity=1 ;; *) has_identity=0 ;; esac
case ",$profile_list," in *,full,*) api_service=api ;; *) api_service=app ;; esac
case " $(env_get CASTRA_COMPOSE_FILES) " in *" compose.external-db.yml "*) external_db=1 ;; *) external_db=0 ;; esac

if [ "$external_db" = 1 ] && [ "$keep_env" = 0 ]; then
  compose_version="$(docker compose version --short 2> /dev/null | sed 's/^v//')"
  if [ -n "$compose_version" ] && [ "$(printf '%s\n2.24.0\n' "$compose_version" | sort -V | head -n 1)" != "2.24.0" ]; then
    die "your own database needs Docker Compose 2.24 or newer (this is $compose_version)"
  fi
  pg_image="$(dc config --images 2> /dev/null | grep '^postgres:' | head -n 1 || true)"
  pg_image="${pg_image:-postgres:17.6-bookworm}"
  if [ "${db_admin_pending:-0}" = 1 ]; then
    say "Creating the database roles on $DB_HOST"
    [ "$offline" = 1 ] || [ "$skip_pull" = 1 ] || docker pull -q "$pg_image" > /dev/null
    # Passwords are passed through the environment of the container, not as arguments.
    ver="$(PGPASSWORD="$DB_ADMIN_PASSWORD" docker run --rm -e PGPASSWORD "$pg_image" psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_ADMIN_USER" -d "$DB_NAME" -Atc 'show server_version_num' 2> /dev/null || true)"
    [ -n "$ver" ] || die "could not connect to $DB_HOST:$DB_PORT as $DB_ADMIN_USER. Nothing was started"
    [ "$ver" -ge 170000 ] || die "the database is older than Postgres 17 (server_version_num $ver)"
    PGPASSWORD="$DB_ADMIN_PASSWORD" OWNER_PW="$DB_OWNER_PASSWORD" APP_PW="$DB_APP_PASSWORD" \
      docker run --rm -i -e PGPASSWORD -e OWNER_PW -e APP_PW -v "$compose_dir/postgres/roles.sql:/castra/roles.sql:ro" "$pg_image" \
      sh -c 'psql -v ON_ERROR_STOP=1 -h "$0" -p "$1" -U "$2" -d "$3" -v owner_password="$OWNER_PW" -v app_password="$APP_PW" -f /castra/roles.sql' \
      "$DB_HOST" "$DB_PORT" "$DB_ADMIN_USER" "$DB_NAME" > /dev/null || die "creating the roles failed"
  else
    say ""
    say "Before Castra can start, your database needs the two roles. As a user that may create roles, run"
    say "postgres/roles.sql in the Castra database with the passwords now in compose/.env"
    say "(CASTRA_DB_OWNER_PASSWORD and CASTRA_DB_APP_PASSWORD, percent-decoded if you gave unusual characters):"
    say "  psql -h $DB_HOST -U <admin> -d $DB_NAME -v owner_password=... -v app_password=... -f compose/postgres/roles.sql"
    say "Then run ./install.sh again to start Castra."
    exit 0
  fi
fi

[ "$skip_checks" = 1 ] || [ "$keep_env" = 0 ] || check_ports "$(env_get CASTRA_HTTP_PORT)"

# ---- images
if [ "$offline" = 1 ]; then
  say "Offline install: using images already loaded (load.sh)"
  while IFS= read -r img; do
    docker image inspect "$img" > /dev/null 2>&1 || die "image $img is not loaded. Run load.sh with the offline bundle first"
  done < <(dc config --images)
elif [ "$skip_pull" = 0 ]; then
  say "Pulling images for Castra $version"
  dc pull
fi
[ "$skip_verify" = 1 ] || verify_images

if [ "$skip_start" = 1 ]; then
  say "Not starting (--skip-start). Start Castra with: compose/castra.sh up -d"
  exit 0
fi

# ---- start
say "Starting Castra"
if [ "$offline" = 1 ]; then dc up -d --pull never; else dc up -d; fi

if [ "$has_identity" = 1 ]; then
  say "Waiting for the bundled identity provider"
  tries=0
  until [ "$(dc ps --format '{{.Health}}' idp 2> /dev/null | head -n 1)" = healthy ]; do
    tries=$((tries + 1))
    [ "$tries" -lt 60 ] || die "the identity provider did not become healthy. See: compose/castra.sh logs idp"
    sleep 5
  done
  if [ "$keep_env" = 0 ]; then
    temp=false
    if [ -z "${FIRST_ADMIN_PASSWORD:-}" ]; then
      FIRST_ADMIN_PASSWORD="$(rand_hex 12)"
      temp=true
      (umask 077; printf 'Castra first administrator\nusername: %s\ntemporary password: %s\n(Keycloak asks for a new password at first sign-in. Delete this file once you have signed in.)\n' "$FIRST_ADMIN_USER" "$FIRST_ADMIN_PASSWORD" > "$compose_dir/first-admin.txt")
    else
      [ "${#FIRST_ADMIN_PASSWORD}" -ge 12 ] || die "the first administrator's password must be at least 12 characters"
    fi
    create_first_admin "$FIRST_ADMIN_USER" "$FIRST_ADMIN_EMAIL" "$FIRST_ADMIN_NAME" "$FIRST_ADMIN_PASSWORD" "$temp" \
      || die "could not create the first administrator. Create one by hand (README, \"Bundled sign-in\"), then sign in"
  fi
fi

say "Waiting for Castra to be ready (the first start runs the database migrations)"
tries=0
until dc exec -T "$api_service" node -e "fetch('http://127.0.0.1:'+(process.env.PORT||8080)+'/readyz').then(r=>process.exit(r.ok?0:1),()=>process.exit(1))" > /dev/null 2>&1; do
  tries=$((tries + 1))
  if [ "$tries" -ge 60 ]; then
    die "Castra did not become ready in 5 minutes. See: compose/castra.sh logs $api_service migrate"
  fi
  sleep 5
done

tls_mode="$(env_get CASTRA_TLS_MODE)"
root_cert_note=""
if [ "$tls_mode" = self-signed ]; then
  if dc root-cert "$compose_dir/castra-root-ca.crt" > /dev/null 2>&1; then
    root_cert_note="Install compose/castra-root-ca.crt as a trusted root certificate on every machine that opens Castra (it is also at $public_url/castra-root-ca.crt)."
  else
    root_cert_note="Copy the root certificate with: compose/castra.sh root-cert (it is also at $public_url/castra-root-ca.crt) and install it on every machine that opens Castra."
  fi
fi

say ""
say "Castra is running."
say ""
say "  Agent app:        $public_url/"
say "  Requester portal: $public_url/portal/"
say ""
say "Next steps"
if [ "$has_identity" = 1 ] && [ "$keep_env" = 0 ]; then
  if [ "${temp:-false}" = true ]; then
    say "  1. Sign in at $public_url/ as '$FIRST_ADMIN_USER'. The temporary password is in compose/first-admin.txt; you will be asked to change it. Then delete that file."
  else
    say "  1. Sign in at $public_url/ as '$FIRST_ADMIN_USER' with the password you chose."
  fi
  say "  2. Add more people in the identity provider's admin console: open an SSH tunnel to this host's port $(env_get KEYCLOAK_HTTP_PORT), then browse to http://localhost:8180/idp/admin/ (realm castra). Admin name and password: KEYCLOAK_ADMIN and KEYCLOAK_ADMIN_PASSWORD in compose/.env."
else
  say "  1. Sign in at $public_url/ with an account your identity provider knows. Accounts listed in CASTRA_BOOTSTRAP_ADMINS become administrators of the first organisation."
  if [ -n "$(env_get SAML_IDP_ENTITY_ID)" ]; then
    say "     Add Castra to your identity provider as a relying party or enterprise application: give it $public_url/auth/saml/metadata (README, \"Sign in with SAML\")"
  else
    say "     Your provider must have this redirect URL registered: $public_url/auth/callback"
  fi
fi
say "  - The first administrator to sign in is asked to accept the Castra Licence in the app. Until then nobody can use Castra."
[ -z "$root_cert_note" ] || say "  - $root_cert_note"
say "  - Set up backups before you rely on this (README, \"Backups\"): compose/backup.sh"
say "  - Day to day: compose/castra.sh ps | logs -f | pull | up -d. Upgrading: UPGRADING.md"
