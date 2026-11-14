#!/usr/bin/env bash
# Whole-instance backup for the compose stack: a Postgres dump plus a copy of the object store.
# See "Backup and restore" in the README for what this does and does not cover.
#
#   deploy/compose/backup.sh
#
# Settings (environment):
#   COMPOSE_FILE        compose file, default: compose.yml next to this script
#   ENV_FILE            env file, default: .env next to this script
#   BACKUP_DIR          where backups go, default: ./backups
#   BACKUP_KEEP         keep only the newest N backups in BACKUP_DIR (default: keep all)
#   BACKUP_OBJECTS      volume (default): copy the SeaweedFS data volume
#                       rclone: copy the bucket with rclone, from BACKUP_RCLONE_SRC (for example castra:castra)
#                       none: database only
#   BACKUP_STOP_STORE   true (default): stop SeaweedFS while its volume is copied, so the copy is consistent
#
# The .env file and every secret in it are NOT copied. Keep them somewhere else.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMPOSE_FILE="${COMPOSE_FILE:-$here/compose.yml}"
ENV_FILE="${ENV_FILE:-$here/.env}"
BACKUP_DIR="${BACKUP_DIR:-$PWD/backups}"
BACKUP_KEEP="${BACKUP_KEEP:-}"
BACKUP_OBJECTS="${BACKUP_OBJECTS:-volume}"
BACKUP_STOP_STORE="${BACKUP_STOP_STORE:-true}"
BACKUP_RCLONE_SRC="${BACKUP_RCLONE_SRC:-}"

dc() { docker compose -f "$COMPOSE_FILE" --env-file "$ENV_FILE" "$@"; }
say() { printf '%s\n' "$*"; }
die() { printf 'backup: %s\n' "$*" >&2; exit 1; }

[ -f "$ENV_FILE" ] || die "no env file at $ENV_FILE (set ENV_FILE)"
case "$BACKUP_OBJECTS" in volume | rclone | none) ;; *) die "BACKUP_OBJECTS must be volume, rclone or none" ;; esac
if [ "$BACKUP_OBJECTS" = rclone ]; then
  [ -n "$BACKUP_RCLONE_SRC" ] || die "set BACKUP_RCLONE_SRC, for example castra:castra"
  command -v rclone > /dev/null || die "rclone is not installed"
fi
[ -n "$(dc ps -q postgres)" ] || die "the postgres service is not running"

stamp="$(date -u +%Y%m%dT%H%M%SZ)"
out="$BACKUP_DIR/castra-$stamp"
mkdir -p "$BACKUP_DIR"
mkdir -m 700 "$out"
cleanup_failed=1
store_stopped=0
finish() {
  if [ "$store_stopped" = 1 ]; then dc start seaweedfs > /dev/null || say "backup: could not restart seaweedfs, start it by hand" >&2; fi
  if [ "$cleanup_failed" = 1 ]; then rm -rf "$out"; say "backup: failed, the partial backup was removed" >&2; fi
}
trap finish EXIT

# The dump runs as the Postgres superuser, not castra_owner: every tenant table forces row-level
# security even on its owner, so as castra_owner pg_dump stops with an error and, forced past it,
# would write empty tables.
say "Dumping the database (custom format)"
dc exec -T postgres sh -c 'pg_dump --format=custom --username "$POSTGRES_USER" --dbname "$POSTGRES_DB"' > "$out/database.dump.part"
mv "$out/database.dump.part" "$out/database.dump"
[ -s "$out/database.dump" ] || die "the database dump is empty"
migrations="$(dc exec -T postgres sh -c 'psql --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" -Atc "select count(*) from drizzle.__drizzle_migrations"' | tr -d '[:space:]')"

case "$BACKUP_OBJECTS" in
  volume)
    cid="$(dc ps -aq seaweedfs)"
    [ -n "$cid" ] || die "the seaweedfs service has no container"
    image="$(docker inspect --format '{{.Config.Image}}' "$cid")"
    if [ "$BACKUP_STOP_STORE" = true ] && [ -n "$(dc ps -q seaweedfs)" ]; then
      say "Stopping seaweedfs while its volume is copied (attachments are unavailable for a moment)"
      dc stop seaweedfs > /dev/null
      store_stopped=1
    fi
    say "Copying the object store volume"
    docker run --rm --entrypoint tar --volumes-from "$cid:ro" -v "$out:/backup" "$image" \
      -czf /backup/objects.tar.gz -C /data .
    ;;
  rclone)
    say "Copying the bucket with rclone"
    rclone copy "$BACKUP_RCLONE_SRC" "$out/objects" --checksum
    ;;
  none) say "Skipping the object store (BACKUP_OBJECTS=none)" ;;
esac

version="$(sed -n 's/^CASTRA_VERSION=//p' "$ENV_FILE" | tail -n 1)"
{
  echo "created_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "castra_version=${version:-dev}"
  echo "migrations_applied=$migrations"
  echo "objects=$BACKUP_OBJECTS"
} > "$out/backup.info"

(
  cd "$out"
  files=(database.dump backup.info)
  [ -f objects.tar.gz ] && files+=(objects.tar.gz)
  { sha256sum "${files[@]}"; if [ -d objects ]; then find objects -type f -print0 | sort -z | xargs -0 -r sha256sum; fi; } > SHA256SUMS
)

cleanup_failed=0
say "Backup written to $out"
say "Not included: $(basename "$ENV_FILE") and its secrets. Keep a copy of them somewhere separate."

if [ -n "$BACKUP_KEEP" ]; then
  case "$BACKUP_KEEP" in *[!0-9]* | "") die "BACKUP_KEEP must be a whole number" ;; esac
  # Only directories this script made (castra-YYYYMMDDTHHMMSSZ) are ever removed.
  find "$BACKUP_DIR" -mindepth 1 -maxdepth 1 -type d -name 'castra-????????T??????Z' | sort -r \
    | tail -n +$((BACKUP_KEEP + 1)) | while IFS= read -r old; do
      say "Removing old backup $old"
      rm -rf "$old"
    done
fi
