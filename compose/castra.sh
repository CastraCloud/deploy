#!/usr/bin/env bash
# Runs `docker compose` for this install with the files and profiles chosen in .env (install.sh sets them),
# so you do not have to repeat them.
#
#   compose/castra.sh ps
#   compose/castra.sh pull
#   compose/castra.sh up -d
#   compose/castra.sh logs -f app
#   compose/castra.sh root-cert [file]   copy the internal CA's root certificate (self-signed TLS mode)
#
# .env settings read here (neither is passed to the containers):
#   CASTRA_COMPOSE_FILES  files in this folder to add after compose.yml, space separated
#                         (compose.tls.yml, compose.external-db.yml, compose.external-s3.yml, compose.external-valkey.yml, compose.external-drawio.yml, compose.external-previews.yml)
#   COMPOSE_PROFILES      profiles to start, comma separated (minimal or full, identity, nats, previews)
# Environment: ENV_FILE overrides the path of .env.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${ENV_FILE:-$here/.env}"
[ -f "$ENV_FILE" ] || { echo "castra.sh: no env file at $ENV_FILE (run install.sh, or copy .env.example to .env)" >&2; exit 1; }

# The last uncommented NAME=value line, without surrounding quotes. .env is not sourced: it is not shell syntax.
envval() { sed -n "s/^$1=//p" "$ENV_FILE" | tail -n 1 | sed -e 's/^"\(.*\)"$/\1/' -e "s/^'\(.*\)'$/\1/"; }

args=(-f "$here/compose.yml")
for f in $(envval CASTRA_COMPOSE_FILES); do
  case "$f" in
    */* | *..*) echo "castra.sh: CASTRA_COMPOSE_FILES holds file names in this folder, not paths: $f" >&2; exit 1 ;;
  esac
  [ -f "$here/$f" ] || { echo "castra.sh: $here/$f does not exist" >&2; exit 1; }
  args+=(-f "$here/$f")
done
args+=(--env-file "$ENV_FILE")
profiles="$(envval COMPOSE_PROFILES)"
IFS=',' read -r -a plist <<< "$profiles"
for p in "${plist[@]}"; do
  [ -z "$p" ] || args+=(--profile "$p")
done

if [ "${1:-}" = root-cert ]; then
  # Copies the root certificate of the internal CA (CASTRA_TLS_MODE=self-signed) out of the web container.
  out="${2:-$here/castra-root-ca.crt}"
  docker compose "${args[@]}" cp web:/data/caddy/pki/authorities/local/root.crt "$out"
  echo "Wrote $out. Install it as a trusted root certificate on the machines that open Castra."
  exit 0
fi

exec docker compose "${args[@]}" "$@"
