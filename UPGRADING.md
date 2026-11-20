# Upgrading Castra

This page covers upgrading a Docker Compose install (the `compose` folder next to this file). Commands are run from this folder. Read the backup and restore section of the [README](README.md) first.

## Before you start

1. **Read the release notes.** They are in `CHANGELOG.md`, published with each release alongside this guide, newest first, under the version heading (changes not yet in a release are under "Unreleased"). Look for anything that changes settings, adds an environment variable or changes how something behaves.
2. **Take a backup.** Database and objects, with the same version you are about to replace:

   ```sh
   BACKUP_DIR=/srv/castra-backups BACKUP_KEEP=14 compose/backup.sh
   ```

   Check the run finished and that the new folder holds `database.dump`, the objects copy, `backup.info` and `SHA256SUMS`. Keep a copy of your `compose/.env` somewhere else; the scripts never copy it.

3. **Note the current version.** `backup.info` records the Castra version and the last migration applied. `GET /api/v1/meta` also reports the running version.

## How migrations run

The database schema changes through numbered SQL files in `apps/server/drizzle`, applied in order and recorded in the database, so each runs once. In Compose, the `migrate` service runs them as the schema owner (`castra_owner`) every time the stack starts, and every other service waits for it to finish (`service_completed_successfully`). If `migrate` fails, nothing else starts, and its logs say which file failed.

Migrations only move forward. There are no "down" files. A migration can add tables and columns or change a constraint; some also change a database function. Once it has run, older server code may not work against the database, which is why the way back is a restore (below).

The `migrate` role also creates the first organisation from the `CASTRA_BOOTSTRAP_*` settings if it is missing. It does nothing if the organisation exists.

## Choosing and pinning a version

Images are published to `ghcr.io/castracloud/castra-server` and `ghcr.io/castracloud/castra-web`. The tags are:

| Tag (examples) | Meaning                                      |
| -------------- | -------------------------------------------- |
| `1.4.2`        | exactly that release                         |
| `1.4`          | the newest patch release of 1.4              |
| `latest`       | the newest release that is not a pre-release |
| `integrate`    | the newest build of the integration branch   |

For production, pin an exact version, or better a digest, and change it on purpose. In `compose/.env`:

```sh
CASTRA_IMAGE_SERVER=ghcr.io/castracloud/castra-server:1.4.2
CASTRA_IMAGE_WEB=ghcr.io/castracloud/castra-web:1.4.2
```

Use the same version for both images. Do not run `latest` or `integrate` unattended. CI scans each published image for critical vulnerabilities that have a fix.

## Upgrading

```sh
cd /opt/castra
git pull                     # only if you keep deploy/compose in a checkout
# edit compose/.env: set the new image tags, add any new settings the release notes mention
compose/castra.sh pull
compose/castra.sh up -d
```

`compose/castra.sh` runs `docker compose` with the files and profiles chosen in `compose/.env` (`./install.sh` sets them), so you do not repeat them. If you started Castra with a hand-written `docker compose -f ... --profile ...` command, keep using that command instead, with the same files and profiles. Compose recreates the services whose image changed; `migrate` runs first. Expect a short interruption while the API restarts. Sessions are kept in Valkey, so people stay signed in as long as Valkey is not restarted empty.

Changes to know about when you move from an earlier set of Compose files:

- NATS now starts only with the `nats` profile. If you set `CASTRA_EVENT_TRANSPORT=nats`, add `--profile nats` (or `nats` to `COMPOSE_PROFILES` for `castra.sh`). With the default `outbox` transport nothing used NATS.
- A Draw.io service (`drawio`) now runs by default, published on `CASTRA_DRAWIO_PORT` (8081). Set `DRAWIO_URL` and `CASTRA_FRAME_SRC` to use it (see "Diagrams" in the README), or add `compose.external-drawio.yml` to turn it off.

- The portal can now have a host name of its own (`CASTRA_PORTAL_DOMAIN`, `portal.host` in Helm). Nothing changes on upgrade: the portal stays at `/portal/` and the setting is empty. To use it, add a DNS record for the name that points where Castra's points, make your proxy (if you run one) serve the name over https and send it to the same Castra port with `Host` passed on, with `files` TLS use a certificate that covers both names or set `CASTRA_TLS_PORTAL_CERT` and `CASTRA_TLS_PORTAL_KEY`, set `CASTRA_PORTAL_DOMAIN=<the name>` in `compose/.env` and run `compose/castra.sh up -d`. Sessions are now tied to the host name they were made on. Everyone keeps their current sign-in. Accounts made from inbound mail become portal-only customers: if you had given one a staff role by hand it keeps it and stays staff; otherwise convert it under Administration, Portal access if you want it to become staff.
- Draw.io can now have a host name of its own (`CASTRA_DRAWIO_DOMAIN`) instead of a second port. Existing installs keep the port form (`CASTRA_DRAWIO_PORT`) until you set it, so nothing changes on upgrade. To switch:
  1. Choose a name, for example `castra-diagrams.example.com` for `castra.example.com` (a one-level wildcard certificate such as Cloudflare's free one covers it; `diagrams.castra.example.com` needs a certificate for `*.castra.example.com`). Add a DNS record for it that points where Castra's points. Behind your own proxy, make the proxy serve the name over https and send it to the same Castra port with `Host` passed on ([guide](docs/behind-a-proxy.md)). With `files` TLS, use a certificate that covers both names or set `CASTRA_TLS_DRAWIO_CERT` and `CASTRA_TLS_DRAWIO_KEY`.
  2. In `compose/.env` set `CASTRA_DRAWIO_DOMAIN=<the name>` and `CASTRA_DRAWIO_BIND=127.0.0.1`, and delete or update `DRAWIO_URL` and `CASTRA_FRAME_SRC` (they follow the name when unset; keep any other sources you listed in `CASTRA_FRAME_SRC`).
  3. `compose/castra.sh up -d`. Open a page with a diagram to check it.
  4. Close the old port (8081) in your firewall and in your proxy.

Compare `compose/.env.example` with your `.env` and add any new variables you want. New variables have defaults in `compose.yml`, so nothing breaks if you add none.

## Checks after an upgrade

1. `compose/castra.sh ps` shows every service running and `migrate` exited with code 0. `compose/castra.sh logs migrate` ends with "migrations applied".
2. Readiness. `GET /readyz` on the API answers 200 with a JSON body that lists the database, the cache and object storage:

   ```json
   { "status": "ready", "checks": { "database": { "status": "ok", "ms": 2 }, "cache": { "status": "ok", "ms": 1 }, "storage": { "status": "ok", "ms": 4 } } }
   ```

   It answers 503 when the database or cache check fails. A storage failure shows "degraded" with 200, since only files are affected. A check for something you have not configured shows "skipped". The body never says why a check failed; the API log does.

3. The version: `GET /api/v1/meta` reports the version you expect.
4. The audit chain of every organisation:

   ```sh
   compose/castra.sh run --rm -e CASTRA_ROLE=audit-verify api
   ```

   It exits non-zero if a chain is broken. If an organisation uses audit retention, the check starts from its signed checkpoint and needs the same `SESSION_SECRET` (or `WEBHOOK_ENCRYPTION_KEY`) that was used when the checkpoint was written.

5. Sign in, open an item, a page with an attachment and a ticket, and open Administration, Audit log, Verify chain.
6. If you scrape metrics (`METRICS_ENABLED=true`), check the queue gauges are falling back to zero after the restart.

## Rolling back

There is no downgrade of the database. To go back to the previous version:

1. Stop the stack.
2. Restore the backup you took before upgrading with `compose/restore.sh /srv/castra-backups/castra-<timestamp>`. This restores the database and the objects. Everything written after the backup is lost.
3. Set the image tags in `.env` back to the previous version.
4. Start the stack. The `migrate` service finds the database already at the old level and has nothing to do.
5. Run the checks above.

Do not point an older image at a database that has been migrated by a newer one without restoring. The restore steps in "Restoring after a disaster, in order" in the README apply here too.

If you only need to undo a setting change, change it back and restart; that is not a rollback.

## What was not verified here

The Compose commands above follow the files in `compose/`. The repository's tests cover the backup and restore scripts against a stand-in `docker` command and the migrations against a real Postgres, but they do not run an upgrade between two published releases. Rehearse an upgrade and a restore on a spare copy before you do it in production. `compose/restore-drill.sh` rehearses the restore on a throwaway stack (see "Restore drill" in the README).
