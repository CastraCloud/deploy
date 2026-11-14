#!/usr/bin/env bash
# Restores a backup made by backup.sh onto this compose stack. It REPLACES the database and the
# object store contents. See "Backup and restore" in the README for the full order of steps.
#
#   deploy/compose/restore.sh [--yes] BACKUP_DIR
#
# Settings (environment): COMPOSE_FILE, ENV_FILE, BACKUP_RCLONE_SRC as for backup.sh.
# Run it with the same .env values (database passwords, S3 keys) the backup was taken with.
# It leaves the application stopped. Start it again afterwards with the profile you use.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMPOSE_FILE="${COMPOSE_FILE:-$here/compose.yml}"
ENV_FILE="${ENV_FILE:-$here/.env}"
BACKUP_RCLONE_SRC="${BACKUP_RCLONE_SRC:-}"

dc() { docker compose -f "$COMPOSE_FILE" --env-file "$ENV_FILE" "$@"; }
say() { printf '%s\n' "$*"; }
die() { printf 'restore: %s\n' "$*" >&2; exit 1; }

assume_yes=0
if [ "${1:-}" = "--yes" ]; then assume_yes=1; shift; fi
src="${1:-}"
[ -n "$src" ] || die "usage: restore.sh [--yes] BACKUP_DIR"
[ -d "$src" ] || die "$src is not a directory"
src="$(cd "$src" && pwd)"
[ -f "$ENV_FILE" ] || die "no env file at $ENV_FILE (set ENV_FILE)"
[ -f "$src/database.dump" ] || die "$src has no database.dump"
[ -f "$src/SHA256SUMS" ] || die "$src has no SHA256SUMS"

say "Checking the backup against its checksums"
(cd "$src" && sha256sum --check --quiet SHA256SUMS) || die "the backup does not match its checksums; nothing was changed"

if [ -f "$src/objects.tar.gz" ] && [ -d "$src/objects" ]; then die "the backup holds both a volume copy and an rclone copy"; fi
if [ -d "$src/objects" ]; then
  [ -n "$BACKUP_RCLONE_SRC" ] || die "this backup used rclone: set BACKUP_RCLONE_SRC to the bucket to restore into"
  command -v rclone > /dev/null || die "rclone is not installed"
fi

if [ "$assume_yes" != 1 ]; then
  say "This replaces the Castra database and object store on this host with the backup in $src."
  printf 'Type "restore" to go on: '
  read -r answer
  [ "$answer" = restore ] || die "cancelled; nothing was changed"
fi

say "Stopping the application"
dc --profile minimal --profile full --profile dev stop > /dev/null

say "Starting Postgres on its own"
dc up -d --wait postgres > /dev/null

# As in backup.sh, this is the superuser: loading with COPY is refused for castra_owner because
# row-level security is forced on its tables. --create recreates the database with its grants.
say "Restoring the database"
dc exec -T postgres sh -c 'pg_restore --clean --if-exists --create --exit-on-error --username "$POSTGRES_USER" --dbname postgres' < "$src/database.dump"

if [ -f "$src/objects.tar.gz" ]; then
  say "Restoring the object store volume"
  dc up --no-start seaweedfs > /dev/null
  cid="$(dc ps -aq seaweedfs)"
  [ -n "$cid" ] || die "the seaweedfs service has no container"
  image="$(docker inspect --format '{{.Config.Image}}' "$cid")"
  docker run --rm --entrypoint sh --volumes-from "$cid" -v "$src:/backup:ro" "$image" \
    -c 'find /data -mindepth 1 -delete && tar -xzf /backup/objects.tar.gz -C /data'
elif [ -d "$src/objects" ]; then
  say "Copying the bucket back with rclone (existing objects are kept, nothing is deleted)"
  rclone copy "$src/objects" "$BACKUP_RCLONE_SRC" --checksum
else
  say "This backup has no object store copy; attachments are not restored"
fi

say "Restored. The application is stopped. Start it with your profile, for example:"
say "  docker compose -f $COMPOSE_FILE --env-file $ENV_FILE --profile minimal up -d"
say "Then check the audit chains:"
say "  docker compose -f $COMPOSE_FILE --env-file $ENV_FILE --profile minimal run --rm -e CASTRA_ROLE=audit-verify app"
