#!/usr/bin/env bash
# Restore drill: proves that backup.sh and restore.sh bring a Castra stack back with its data intact.
#
#   scripts/restore-drill.sh [--plan] [--force] [--keep] [--project NAME] [IMAGE_TAG]
#
# It starts a throwaway stack under its own Compose project, loads the demo data (which includes
# attachments), records fingerprints, runs backup.sh, destroys that project's containers and volumes,
# restores into a fresh stack with restore.sh, starts it, runs migrations and compares everything.
# It prints PASS or FAIL with what differed, and removes what it made even when it fails.
#
# IMAGE_TAG picks ghcr.io/castracloud/castra-server:TAG and castra-web:TAG. Or set CASTRA_IMAGE_SERVER and
# CASTRA_IMAGE_WEB yourself (they win over the tag). Nothing is built: the images are pulled if missing.
#
#   --plan           print the steps and commands without running Docker
#   --force          go on even if the project name already has containers or volumes (they are destroyed)
#   --keep           leave the stack, backup and temp files in place afterwards, for debugging
#   --project NAME   Compose project name, must start with castra-drill (default: castra-drill-<random>)
#
# Settings (environment): SEAWEEDFS_VOLUME_SIZE_MB (default 32), DRILL_COMPOSE_DIR (folder holding
# compose.yml, backup.sh and restore.sh; default: deploy/compose in this repository, or this folder
# when the script sits in the deploy kit's compose/ folder).
# Needs Docker with Compose v2.20 or later, and the local Docker daemon (volumes are copied with bind mounts).
# It publishes no ports, never touches other projects, and never runs a host-wide prune.
set -Eeuo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -n "${DRILL_COMPOSE_DIR:-}" ]; then
  compose_dir="$DRILL_COMPOSE_DIR"
elif [ -f "$here/../deploy/compose/compose.yml" ]; then
  compose_dir="$here/../deploy/compose"
else
  compose_dir="$here"
fi

compose_dir="$(cd "$compose_dir" 2> /dev/null && pwd || echo "$compose_dir")"
plan=0
force=0
keep=0
project=""
tag=""

say() { printf '%s\n' "$*"; }
die() { printf 'restore-drill: %s\n' "$*" >&2; exit 1; }
usage() { sed -n '2,/^set -euo/p' "${BASH_SOURCE[0]}" | sed -e '$d' -e 's/^# \{0,1\}//' -e '1d'; }

while [ $# -gt 0 ]; do
  case "$1" in
    --plan) plan=1 ;;
    --force) force=1 ;;
    --keep) keep=1 ;;
    --project) shift; [ $# -gt 0 ] || { usage >&2; exit 2; }; project="$1" ;;
    -h | --help) usage; exit 0 ;;
    -*) usage >&2; exit 2 ;;
    *) [ -z "$tag" ] || { usage >&2; exit 2; }; tag="$1" ;;
  esac
  shift
done

if [ -z "$project" ]; then
  suffix="$(od -An -N4 -tx1 /dev/urandom | tr -d ' \n')"
  project="castra-drill-$suffix"
fi
# The prefix means a typo can never point the clean-up at a real stack.
case "$project" in
  castra-drill | castra-drill-*) ;;
  *) die "the project name must start with castra-drill (got $project)" ;;
esac
case "$project" in *[!a-z0-9_-]*) die "the project name may only hold a-z, 0-9, - and _" ;; esac

if [ -n "$tag" ]; then
  case "$tag" in *[!A-Za-z0-9_.-]* | "") die "the image tag may only hold letters, digits, . _ and -" ;; esac
  export CASTRA_IMAGE_SERVER="${CASTRA_IMAGE_SERVER:-ghcr.io/castracloud/castra-server:$tag}"
  export CASTRA_IMAGE_WEB="${CASTRA_IMAGE_WEB:-ghcr.io/castracloud/castra-web:$tag}"
fi
if [ -z "${CASTRA_IMAGE_SERVER:-}" ]; then
  if [ "$plan" = 1 ]; then
    CASTRA_IMAGE_SERVER="ghcr.io/castracloud/castra-server:<tag>"
    CASTRA_IMAGE_WEB="ghcr.io/castracloud/castra-web:<tag>"
  else
    die "give an image tag (for example sha-1a2b3c4) or set CASTRA_IMAGE_SERVER and CASTRA_IMAGE_WEB; nothing is built"
  fi
fi
CASTRA_IMAGE_WEB="${CASTRA_IMAGE_WEB:-${CASTRA_IMAGE_SERVER%-server*}-web:${CASTRA_IMAGE_SERVER##*:}}"
server_image="$CASTRA_IMAGE_SERVER"
web_image="$CASTRA_IMAGE_WEB"
store_mb="${SEAWEEDFS_VOLUME_SIZE_MB:-32}"
case "$store_mb" in *[!0-9]* | "") die "SEAWEEDFS_VOLUME_SIZE_MB must be a whole number" ;; esac

if [ "$plan" = 1 ]; then work="<temp dir>"; else work=""; fi
compose_file="$compose_dir/compose.yml"
env_file="$work/drill.env"
backups="$work/backups"
fp="$work/fingerprints"
label="com.docker.compose.project=$project"

# In plan mode a command is only printed.
x() {
  if [ "$plan" != 1 ]; then "$@"; return; fi
  if [ "$1" = dc ]; then shift; set -- docker compose -p "$project" -f "$compose_file" --env-file "$env_file" "$@"; fi
  printf '  $ %s\n' "$*"
}
dc() { docker compose -p "$project" -f "$compose_file" --env-file "$env_file" "$@"; }
all_profiles=(--profile minimal --profile full --profile dev --profile identity --profile nats --profile seed-demo)
step() { say ""; say "== $*"; }

fail_count=0
note_fail() { fail_count=$((fail_count + 1)); say "FAIL: $*"; }

existing() { # lines naming what the project already owns
  docker ps -aq --filter "label=$label"
  docker volume ls -q --filter "label=$label"
  docker network ls -q --filter "label=$label"
}

# Only what carries this project's label, so other stacks on the host are never touched.
destroy_stack() {
  local ids
  dc "${all_profiles[@]}" down --volumes --remove-orphans --timeout 10 > /dev/null 2>&1 || true
  ids="$(docker ps -aq --filter "label=$label")"
  # shellcheck disable=SC2086
  [ -z "$ids" ] || docker rm -f $ids > /dev/null 2>&1 || true
  ids="$(docker volume ls -q --filter "label=$label")"
  # shellcheck disable=SC2086
  [ -z "$ids" ] || docker volume rm $ids > /dev/null 2>&1 || true
  ids="$(docker network ls -q --filter "label=$label")"
  # shellcheck disable=SC2086
  [ -z "$ids" ] || docker network rm $ids > /dev/null 2>&1 || true
}

stack_made=0
cleaned=0
cleanup() {
  local code=$?
  [ "$plan" = 1 ] && return
  [ "$cleaned" = 0 ] || return
  cleaned=1
  if [ "$code" != 0 ] && [ "$stack_made" = 1 ] && [ -n "$(docker ps -aq --filter "label=$label")" ]; then
    say "--- last log lines of the stack, for diagnosis" >&2
    dc "${all_profiles[@]}" logs --no-color --tail 25 2>&1 | sed 's/^/    /' >&2 || true
  fi
  if [ "$keep" = 1 ]; then
    say "Kept: project $project, files in $work. Remove with: docker compose -p $project ${all_profiles[*]} -f $compose_file --env-file $env_file down --volumes; rm -rf $work"
    return
  fi
  if [ "$stack_made" = 1 ]; then destroy_stack; fi
  [ -z "$work" ] || rm -rf "$work"
}
trap cleanup EXIT
trap 'printf "restore-drill: FAIL: a command failed at line %s: %s\n" "$LINENO" "$BASH_COMMAND" >&2' ERR
trap 'exit 130' INT TERM

# ---- SQL, run as the Postgres superuser (row-level security does not apply to it)
sql() { printf '%s\n' "$1" | dc exec -T postgres sh -c 'psql --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" -Atq -v ON_ERROR_STOP=1'; }

SQL_ROWS="$(cat << 'SQL'
select 'rows.' || table_name || '=' || (xpath('/row/c/text()', query_to_xml(format('select count(*) as c from %I.%I', table_schema, table_name), false, true, '')))[1]::text
from information_schema.tables where table_schema = 'public' and table_type = 'BASE TABLE' order by table_name;
select 'migrations=' || count(*) from drizzle.__drizzle_migrations;
SQL
)"
SQL_AUDIT="$(cat << 'SQL'
select 'audit.' || o.slug || '=' || a.seq || ':' || a.hash
from audit_event a join organisation o on o.id = a.org_id
where a.seq = (select max(b.seq) from audit_event b where b.org_id = a.org_id) order by o.slug;
SQL
)"
SQL_CAELUS="$(cat << 'SQL'
with top as (select page_id, count(*) n from page_version group by page_id order by n desc, page_id limit 1)
select 'caelus.page=' || p.slug || ':' || t.n || ' versions:' || md5(string_agg(v.markdown || chr(30) || v.title, chr(31) order by v.number))
from top t join page p on p.id = t.page_id join page_version v on v.page_id = t.page_id group by p.slug, t.n;
SQL
)"
SQL_TICKET="$(cat << 'SQL'
with top as (select ticket_id, count(*) n from ticket_comment group by ticket_id order by n desc, ticket_id limit 1)
select 'ticket.comments=' || t.ticket_id || ':' || t.n || ' comments:' || md5(string_agg(c.visibility || chr(30) || c.body, chr(31) order by c.created_at, c.id))
from top t join ticket_comment c on c.ticket_id = t.ticket_id group by t.ticket_id, t.n;
select 'ticket.row=' || md5(k::text) from ticket k where k.work_item_id = (select ticket_id from ticket_comment group by ticket_id order by count(*) desc, ticket_id limit 1);
SQL
)"
SQL_ATTACH="$(cat << 'SQL'
select 'attachment.' || storage_key || '.recorded=' || sha256 from (
  select storage_key, sha256 from attachment where blob_deleted_at is null
  union all select storage_key, sha256 from attachment_version where blob_deleted_at is null) x order by 1;
SQL
)"
SQL_KEYS="$(cat << 'SQL'
select storage_key from attachment where blob_deleted_at is null
union all select storage_key from attachment_version where blob_deleted_at is null order by 1;
SQL
)"

# Reads each key from the object store through the server image's own client and prints its SHA-256.
NODE_HASH="$(cat << 'JS'
import { createHash } from "node:crypto";
import { loadConfig } from "/app/dist/config.js";
import { createBlobStore } from "/app/dist/storage/index.js";
const store = createBlobStore(loadConfig());
if (!store) { console.error("no object store is configured"); process.exit(2); }
let input = "";
for await (const chunk of process.stdin) input += chunk;
for (const key of input.split("\n").filter(Boolean)) {
  const got = await store.get(key);
  if (!got) { console.log(`attachment.${key}.actual=MISSING`); continue; }
  const h = createHash("sha256");
  for await (const chunk of got.body) h.update(chunk);
  console.log(`attachment.${key}.actual=${h.digest("hex")}`);
}
store.close?.();
JS
)"

# capture FILE full|key. "full" adds row counts and audit heads, which only hold until the app has run.
capture() {
  local out="$1" mode="$2" keys
  : > "$out"
  if [ "$mode" = full ]; then
    sql "$SQL_ROWS" >> "$out"
    sql "$SQL_AUDIT" >> "$out"
  fi
  sql "$SQL_CAELUS" >> "$out"
  sql "$SQL_TICKET" >> "$out"
  sql "$SQL_ATTACH" >> "$out"
  keys="$(sql "$SQL_KEYS")"
  printf '%s\n' "$keys" | dc --profile minimal run --rm --no-deps -T --entrypoint node app --input-type=module -e "$NODE_HASH" | grep '^attachment\.' >> "$out" || true
  sort -o "$out" "$out"
}

# Fails if the data this drill depends on is missing, or an attachment's bytes do not match its recorded hash.
check_loaded() {
  local f="$1" what
  for what in 'rows\.' 'audit\.' 'caelus\.page=' 'ticket\.comments=' 'ticket\.row=' 'attachment\..*\.recorded='; do
    grep -q "^$what" "$f" || die "no $what data was loaded, so the drill proves nothing (did the demo seed finish?)"
  done
  grep -q '^attachment\..*\.actual=' "$f" || die "no attachment could be read back from the object store"
}
check_attachments() { # check_attachments FILE LABEL
  local f="$1" lbl="$2" missing
  missing="$(grep '\.recorded=' "$f" | sed 's/\.recorded=/.actual=/' | grep -vxF -f <(grep '\.actual=' "$f") || true)"
  if [ -n "$missing" ]; then
    note_fail "$lbl: attachment bytes are missing or do not match the recorded SHA-256:"
    printf '%s\n' "$missing" | sed 's/^/    expected /'
  fi
}

audit_verify() { # audit_verify OUTFILE; prints nothing, returns the exit code of the role
  dc --profile minimal run --rm --no-deps -T -e CASTRA_ROLE=audit-verify app > "$1" 2>&1
}
chain_summary() { grep -o '"org":"[^"]*","events":[0-9]*,"headSeq":[0-9]*,"headHash":"[^"]*"' "$1" | sort || true; }

step "0. Preflight"
if [ "$plan" = 1 ]; then
  say "  project:       $project"
  say "  compose dir:   $compose_dir"
  say "  server image:  $server_image"
  say "  web image:     $web_image (never started: no ports are published)"
  say "  object store:  SeaweedFS volumes limited to ${store_mb} MB"
  x docker info
  x docker compose version
  say "  refuse if anything carries label $label, unless --force"
  [ -f "$compose_file" ] || say "  note: $compose_file does not exist here"
else
  [ -f "$compose_file" ] || die "no compose.yml at $compose_file (set DRILL_COMPOSE_DIR)"
  [ -x "$compose_dir/backup.sh" ] || [ -f "$compose_dir/backup.sh" ] || die "no backup.sh in $compose_dir"
  [ -f "$compose_dir/restore.sh" ] || die "no restore.sh in $compose_dir"
  docker info > /dev/null 2>&1 || die "cannot talk to the Docker daemon"
  docker compose version > /dev/null 2>&1 || die "docker compose (v2) is not available"
  found="$(existing | grep -c . || true)"
  if [ "$found" != 0 ]; then
    if [ "$force" = 1 ]; then
      say "Project $project already owns $found Docker objects; --force given, destroying them."
      stack_made=1
      destroy_stack
    else
      die "project $project already owns $found Docker objects (containers, volumes or networks). Choose another --project, or use --force to destroy them."
    fi
  fi
  docker image inspect "$server_image" > /dev/null 2>&1 || docker pull --quiet "$server_image" > /dev/null || die "cannot find or pull $server_image"
  work="$(mktemp -d "${TMPDIR:-/tmp}/castra-drill.XXXXXX")"
  chmod 700 "$work"
  env_file="$work/drill.env"
  backups="$work/backups"
  fp="$work/fingerprints"
  mkdir -p "$backups" "$fp"
fi

step "1. Throwaway settings (random secrets, a file only this run reads)"
if [ "$plan" = 1 ]; then
  say "  write drill.env: CASTRA_DEMO=true, bootstrap organisation, placeholder OIDC settings, random passwords,"
  say "  CASTRA_IMAGE_SERVER/CASTRA_IMAGE_WEB, SEAWEEDFS_VOLUME_SIZE_MB=$store_mb, COMPOSE_PROJECT_NAME=$project"
else
  rnd() { od -An -N24 -tx1 /dev/urandom | tr -d ' \n'; }
  {
    echo "COMPOSE_PROJECT_NAME=$project"
    echo "CASTRA_VERSION=${tag:-drill}"
    echo "CASTRA_IMAGE_SERVER=$server_image"
    echo "CASTRA_IMAGE_WEB=$web_image"
    echo "POSTGRES_USER=castra"
    echo "POSTGRES_DB=castra"
    echo "POSTGRES_PASSWORD=$(rnd)"
    echo "CASTRA_DB_OWNER_PASSWORD=$(rnd)"
    echo "CASTRA_DB_APP_PASSWORD=$(rnd)"
    echo "S3_ACCESS_KEY=drill$(rnd | cut -c1-16)"
    echo "S3_SECRET_KEY=$(rnd)"
    echo "S3_BUCKET=castra"
    echo "SEAWEEDFS_VOLUME_SIZE_MB=$store_mb"
    echo "CASTRA_DEMO=true"
    echo "CASTRA_LICENCE_ACCEPTANCE=off"
    echo "CASTRA_BOOTSTRAP_ORG_NAME=Restore drill"
    echo "CASTRA_BOOTSTRAP_ORG_SLUG=drill"
    echo "CASTRA_BOOTSTRAP_ADMINS=drill-admin"
    # Never contacted: the server only looks the issuer up when someone signs in.
    echo "OIDC_ISSUER=http://127.0.0.1:9/realms/drill"
    echo "OIDC_CLIENT_ID=castra"
    echo "OIDC_CLIENT_SECRET=$(rnd)"
    echo "OIDC_REDIRECT_URI=http://127.0.0.1:9/api/auth/callback"
    echo "SESSION_SECRET=$(rnd)"
    echo "CASTRA_PUBLIC_URL=http://127.0.0.1:9"
    echo "KEYCLOAK_ADMIN_PASSWORD=$(rnd)"
    echo "KEYCLOAK_DEV_CLIENT_SECRET=$(rnd)"
    echo "KEYCLOAK_DB_PASSWORD=$(rnd)"
  } > "$env_file"
  chmod 600 "$env_file"
  export COMPOSE_PROJECT_NAME="$project"
fi

step "2. Start the source stack: Postgres, SeaweedFS, Valkey"
stack_made=1
x dc up -d --wait --wait-timeout 240 postgres seaweedfs valkey

step "3. Load known data with the demo seed (migrations run first, attachments go to the object store)"
x dc --profile seed-demo run --rm -T seed-demo

step "4. Record fingerprints before the backup"
if [ "$plan" = 1 ]; then
  say "  row count of every table in the public schema, and the migration count"
  say "  audit chain head (sequence and hash) of each organisation"
  say "  the Caelus page with the most versions: slug, version count, hash of every version's text"
  say "  the ticket with the most comments: comment count, hash of the comments, hash of the ticket row"
  say "  every attachment: the SHA-256 recorded in the database, and the SHA-256 of the bytes read from the object store"
  say "  the audit-verify role's per-organisation event count and chain head"
else
  capture "$fp/before" full
  check_loaded "$fp/before"
  check_attachments "$fp/before" "before the backup"
  audit_verify "$fp/chain-before.log" || die "the audit chain was already broken before the backup; see $fp/chain-before.log"
  chain_summary "$fp/chain-before.log" > "$fp/chain-before"
  [ -s "$fp/chain-before" ] || die "audit-verify printed no chain summary (output format changed?)"
  say "  $(wc -l < "$fp/before" | tr -d ' ') fingerprints recorded"
fi

step "5. Back up with backup.sh"
if [ "$plan" = 1 ]; then
  x env "COMPOSE_FILE=$compose_file" "ENV_FILE=$env_file" "BACKUP_DIR=<temp dir>/backups" "$compose_dir/backup.sh"
else
  COMPOSE_FILE="$compose_file" ENV_FILE="$env_file" BACKUP_DIR="$backups" "$compose_dir/backup.sh" || die "backup.sh failed"
  backup="$(find "$backups" -mindepth 1 -maxdepth 1 -type d -name 'castra-????????T??????Z' | sort | tail -n 1)"
  [ -n "$backup" ] || die "backup.sh made no backup directory"
  [ -s "$backup/objects.tar.gz" ] || die "the backup has no object store copy"
  say "  backup: $(du -sk "$backup" | cut -f1) KiB in $backup"
fi

step "6. Destroy the source stack and its volumes (this project only, found by its label)"
if [ "$plan" = 1 ]; then
  x docker compose -p "$project" "${all_profiles[@]}" down --volumes --remove-orphans
  say "  then remove anything still labelled $label, and fail if any container, volume or network is left"
else
  destroy_stack
  left="$(existing | grep -c . || true)"
  [ "$left" = 0 ] || die "$left Docker objects of project $project are still there after the clean-up"
  say "  gone; the backup directory is kept"
fi

step "7. Restore into a fresh stack with restore.sh"
if [ "$plan" = 1 ]; then
  x env "COMPOSE_FILE=$compose_file" "ENV_FILE=$env_file" "$compose_dir/restore.sh" --yes "<temp dir>/backups/castra-<timestamp>"
else
  COMPOSE_FILE="$compose_file" ENV_FILE="$env_file" "$compose_dir/restore.sh" --yes "$backup" || die "restore.sh failed"
fi
x dc up -d --wait --wait-timeout 240 postgres seaweedfs valkey

step "8. Compare with the restored data, before anything has run against it"
if [ "$plan" = 1 ]; then
  say "  every fingerprint from step 4 must match exactly, including every table's row count and each audit head"
else
  capture "$fp/restored" full
  check_attachments "$fp/restored" "after the restore"
  if ! diff -u "$fp/before" "$fp/restored" > "$fp/diff-restored"; then
    note_fail "the restored data differs from what was backed up (- before, + after the restore):"
    grep '^[+-][^+-]' "$fp/diff-restored" | sed 's/^/    /'
  fi
fi

step "9. Start the restored stack: migrations, then the application"
x dc --profile minimal run --rm -T migrate
x dc --profile minimal up -d --wait --wait-timeout 240 app
if [ "$plan" = 1 ]; then
  x dc --profile minimal exec -T app node -e "fetch('http://127.0.0.1:8080/readyz')..."
else
  if ! dc --profile minimal exec -T app node -e "fetch('http://127.0.0.1:8080/readyz').then(async (r) => { console.log(r.status, await r.text()); process.exit(r.ok ? 0 : 1); }, (e) => { console.log(String(e)); process.exit(1); })" > "$fp/readyz" 2>&1; then
    note_fail "the application is not ready after the restore: $(cat "$fp/readyz")"
  else
    say "  /readyz: $(cat "$fp/readyz")"
  fi
fi

step "10. Verify the audit chains and compare again"
if [ "$plan" = 1 ]; then
  say "  CASTRA_ROLE=audit-verify must exit 0, and each organisation's chain head from step 4 must still be in the chain"
  say "  (the application writes new events once it runs, such as SLA checks, so the chain may only grow)"
  say "  Caelus and attachment fingerprints must still match (tickets and row counts may change once it runs)"
else
  if audit_verify "$fp/chain-after.log"; then
    # The running application appends events (SLA checks and the like); the old head must still be there, unchanged.
    while IFS='=' read -r key value; do
      slug="${key#audit.}"
      seq="${value%%:*}"
      hash="${value#*:}"
      now="$(sql "select a.hash from audit_event a join organisation o on o.id = a.org_id where o.slug = '${slug//\'/\'\'}' and a.seq = ${seq}")"
      if [ "$now" != "$hash" ]; then
        note_fail "the audit chain of $slug no longer holds event $seq as it was before the backup (expected $hash, found ${now:-nothing})"
      fi
    done < <(grep '^audit\.' "$fp/before")
  else
    note_fail "audit chain verification failed after the restore:"
    grep -i 'broken\|error' "$fp/chain-after.log" | sed 's/^/    /' | head -n 10
  fi
  capture "$fp/after" key
  check_attachments "$fp/after" "after the restart"
  # Tickets were compared exactly in step 8; once running, the SLA worker may comment on them and stamp them.
  grep -v '^rows\.\|^audit\.\|^migrations=\|^ticket\.' "$fp/before" > "$fp/before-key"
  grep -v '^ticket\.' "$fp/after" > "$fp/after-key"
  if ! diff -u "$fp/before-key" "$fp/after-key" > "$fp/diff-after"; then
    note_fail "data differs once the application is running (- before, + after):"
    grep '^[+-][^+-]' "$fp/diff-after" | sed 's/^/    /'
  fi
fi

step "Result"
if [ "$plan" = 1 ]; then
  say "Plan only: no Docker command was run. Run again without --plan to do the drill."
  exit 0
fi
if [ "$fail_count" = 0 ]; then
  say "PASS: the backup was restored into a fresh stack and everything compared equal"
  say "      ($(grep -c '^rows\.' "$fp/before") tables, $(grep -c '\.recorded=' "$fp/before") attachment files, $(wc -l < "$fp/chain-before" | tr -d ' ') audit chain(s), image $server_image)."
  exit 0
fi
say "FAIL: $fail_count check(s) failed, see above (image $server_image)"
exit 1
