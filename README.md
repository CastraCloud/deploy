<p align="center">
  <img src="assets/castra-logo.svg" alt="Castra" height="48">
</p>

# Castra deploy

Everything you need to run Castra on your own infrastructure: an installer, Docker Compose files,
an offline bundle for hosts without internet, backup and restore scripts, and the upgrade guide.

## About Castra

Castra is a self-hosted suite of three tools that share one sign-in, one search and one set of
people and permissions:

- **Minerva** for agile delivery: backlogs, boards, sprints, releases, timelines, reports and
  automation.
- **Caelus**, a wiki and knowledge base: libraries of pages edited together in real time, with
  reviews, templates, macros, and export to PDF and Word.
- **Mercury**, a service desk with a requester portal: queues, SLAs, approvals, incidents,
  problems, changes and an asset inventory.

Each organisation's data is kept apart by the database itself (Postgres row-level security), every
change goes into a tamper-evident audit log, and people sign in through an OpenID Connect identity
provider: your own, or the Keycloak that comes with this kit.

Castra is free to self-host. Find out more at [castracloud.com](https://castracloud.com).

## What is here

| Path                                      | What it is                                                                                          |
| ----------------------------------------- | --------------------------------------------------------------------------------------------------- |
| `install.sh`                              | The installer: checks the host, asks what it needs, makes the secrets, starts Castra.               |
| `install.answers.example`                 | Every answer `install.sh` understands, for installs with no questions.                              |
| `bundle.sh`, `load.sh`                    | Make an offline bundle on a machine with internet; load it on a host without.                       |
| `compose/compose.yml`                     | The Docker Compose stack: Castra plus Postgres, Valkey, SeaweedFS (S3 storage) and Draw.io.         |
| `compose/castra.sh`                       | Runs `docker compose` with the files and profiles chosen in `compose/.env`.                         |
| `compose/compose.tls.yml`                 | Optional: HTTPS served by Castra's own web proxy.                                                   |
| `compose/compose.external-*.yml`          | Optional: use your own Postgres, S3 bucket, Valkey or Redis, or Draw.io instead of the bundled one. |
| `compose/.env.example`                    | Every setting, with comments. `install.sh` writes `compose/.env` from it.                           |
| `compose/backup.sh`, `compose/restore.sh` | Instance backup and restore.                                                                        |
| `compose/postgres/`                       | Database roles and the first-start scripts.                                                         |
| `compose/identity/`                       | The realm for the bundled sign-in (`identity` profile), with no users.                              |
| `helm/castra/`                            | The Helm chart for Kubernetes. See [Kubernetes](#kubernetes).                                       |
| `UPGRADING.md`                            | How to upgrade, pin versions and roll back.                                                         |

## What you need

Castra runs as a handful of containers. This table shows what you must bring, what the kit runs for
you (and how to swap it for your own), and what is optional.

### Required

| What                                  | Notes                                                                                                                                                                  |
| ------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| A Linux host with Docker              | Docker Engine and Docker Compose v2 (2.24 or newer if you use your own Postgres), on amd64 or arm64. A normal user in the `docker` group is enough; no root otherwise. |
| A DNS name, and TLS for anything real | Passwords and sessions cross the network. Castra can get its own certificate (see [HTTPS](#https)), or sit behind your own TLS proxy. Plain http is for a trial only.  |
| An OpenID Connect identity provider   | Bring your own (Keycloak, Microsoft Entra ID, Okta, Authentik, Google Workspace, any other) or run the bundled Keycloak. See [Sign-in](#sign-in).                      |

### Bundled, and replaceable

These start with Castra and need nothing from you. Each can be replaced with a service you already run.

| What                         | Bundled as             | Use your own instead                                                                                                           |
| ---------------------------- | ---------------------- | ------------------------------------------------------------------------------------------------------------------------------ |
| Postgres 17 or newer         | `postgres` service     | `compose/compose.external-db.yml`, `CASTRA_DB_*`. You create two roles with `postgres/roles.sql`; `install.sh` can do it.      |
| Valkey (or Redis)            | `valkey` service       | `compose/compose.external-valkey.yml` and `VALKEY_URL`. Sessions and caches live there.                                        |
| S3-compatible object storage | SeaweedFS, `seaweedfs` | `compose/compose.external-s3.yml` and `S3_*`. Create the bucket first. Attachments live there.                                 |
| Draw.io, for diagram editing | `drawio` service       | `compose/compose.external-drawio.yml` and `DRAWIO_URL`. The bundled one needs no internet access from the browser.             |
| NATS, an event transport     | only if you choose it  | Starts with `--profile nats`, and only matters with `CASTRA_EVENT_TRANSPORT=nats`. The default (`outbox`) uses Postgres alone. |
| Keycloak, as the sign-in     | only if you choose it  | The `identity` profile. See [Sign-in](#sign-in).                                                                               |

### Optional external pieces

| What                                        | What it gives you                                                                                                                         |
| ------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------- |
| An SMTP relay                               | Email notifications and replies. Without one, notifications appear in the app only.                                                       |
| An IMAP mailbox                             | Email to tickets: Castra reads the mailbox and turns mail into requests. (A provider that posts raw messages to a webhook works too.)     |
| Chat services                               | Connect Slack, Mattermost or Rocket.Chat for posts to channels.                                                                           |
| Git and CI services                         | The development panel shows branches, pull requests and builds from GitHub, GitLab, Gitea, Forgejo, Bitbucket Cloud or a CI webhook.      |
| A Jitsi server                              | Rooms for major-incident calls. Leave the address empty to use `meet.jit.si`, or name your own. Pasted links (Zoom and others) also work. |
| Prometheus                                  | Metrics at `/metrics` (`METRICS_ENABLED=true`).                                                                                           |
| An OpenTelemetry collector or syslog server | Audit events streamed as they happen. Set up in the app under Administration.                                                             |
| Somewhere off the host for backups          | A copy of what `compose/backup.sh` makes, and of `compose/.env`. A backup on the same disk is not a backup.                               |

### How big a host

These are starting points to size from, not promises: they depend on how many people use Castra, how
big your attachments and pages are, and how much you automate. Watch memory and disk for the first
weeks and adjust.

| Use                                  | Starting point                                                      |
| ------------------------------------ | ------------------------------------------------------------------- |
| A trial, one team, `minimal` profile | 2 vCPU, 4 GB of memory, 20 GB of disk                               |
| A department, a few hundred people   | 4 vCPU, 8 GB of memory, 100 GB of disk (SSD), `minimal` or `full`   |
| Larger or busier                     | `full` profile, Postgres and storage on their own hosts or services |

Disk is mostly attachments, plus the database and its backups. `install.sh` refuses to run with less
than 5 GB free or 2 GB of memory, and warns below 20 GB and 3 GB.

## Install

On the host:

```sh
./install.sh
```

It asks for the Castra version, your address and HTTPS choice, how people sign in, email, storage and
database. It makes every password and key itself (with `openssl rand`, or `/dev/urandom` without it),
writes them to `compose/.env` with mode 600 and never prints them, pulls the images, checks their
signatures if [cosign](https://github.com/sigstore/cosign) is installed, starts Castra, and waits for
`/readyz`. Then it prints the address and what to do next. It can be run again: it keeps an existing
`compose/.env` unless you say to replace it, and it needs no root.

For an install with no questions, copy `install.answers.example`, fill it in, and run:

```sh
./install.sh --answers install.answers.env
```

Day to day, use `compose/castra.sh` in place of a long `docker compose -f ... --profile ...` command:
`compose/castra.sh ps`, `logs -f app`, `pull`, `up -d`.

Keep a copy of `compose/.env` somewhere safe and separate from your backups: it holds every secret,
and the backup scripts never copy it.

### Doing it by hand

```sh
cp compose/.env.example compose/.env
# Edit compose/.env:
#  - set CASTRA_VERSION to the release you want, for example 1.0.0
#  - replace every other CHANGE_ME value with a long random secret
#  - set OIDC_ISSUER and the client ID and secret from your identity provider
docker compose -f compose/compose.yml --env-file compose/.env --profile minimal pull
docker compose -f compose/compose.yml --env-file compose/.env --profile minimal up -d
```

Open `http://<host>:8080` for the agent app and `http://<host>:8080/portal/` for the requester
portal. Change the port with `CASTRA_HTTP_PORT`.

The `migrate` service runs database migrations on every start, then exits. The first organisation
and its admins are created from the `CASTRA_BOOTSTRAP_*` settings in `.env`.

## Profiles

Choose `minimal` or `full`. Postgres, Valkey, SeaweedFS, Draw.io, `migrate` and `web` start in both.

| Profile    | Adds                                                                                                              | Use for                                         |
| ---------- | ----------------------------------------------------------------------------------------------------------------- | ----------------------------------------------- |
| `minimal`  | `app`: every role in one process                                                                                  | small installs and trials                       |
| `full`     | one service per role (`api`, `collab`, `realtime`, `worker-jobs`, `worker-sla`, `mail-in`, `mail-out` and others) | scaling each role on its own                    |
| `identity` | Keycloak in production mode, with its own database in the bundled Postgres                                        | installs with no identity provider of their own |
| `nats`     | NATS (JetStream)                                                                                                  | only with `CASTRA_EVENT_TRANSPORT=nats`         |

`identity` and `nats` are added to `minimal` or `full`. Only `web` publishes ports: the app on
`CASTRA_HTTP_PORT` (and 443 with [HTTPS](#https)), and, in the port form only, Draw.io on `CASTRA_DRAWIO_PORT`
(see [Diagrams](#diagrams)). It serves the agent
app at `/`, the portal at `/portal/`, and passes `/api/*` to the API.

## HTTPS

`CASTRA_TLS_MODE` in `compose/.env` chooses how Castra is served. `install.sh` asks for it. Every mode
except `off` needs `compose/compose.tls.yml` (listed in `CASTRA_COMPOSE_FILES`, which `install.sh`
sets), `CASTRA_DOMAIN` (the name people use, no scheme), `CASTRA_HTTP_PORT=80`, and ports 80 and 443
reachable. Set `CASTRA_PUBLIC_URL` to `https://<the domain>`. In those modes http on port 80 redirects
to https.

| Mode          | What happens                                                                                        | Set                                           |
| ------------- | --------------------------------------------------------------------------------------------------- | --------------------------------------------- |
| `off`         | Default. Plain http on `CASTRA_HTTP_PORT`, for use behind your own TLS proxy.                       | `CASTRA_HSTS=true` if your proxy serves https |
| `self-signed` | The web proxy runs its own certificate authority and signs a certificate for your domain.           | `CASTRA_DOMAIN`                               |
| `files`       | Your certificate chain and key are mounted into the web container.                                  | `CASTRA_TLS_CERT_FILE`, `CASTRA_TLS_KEY_FILE` |
| `acme`        | Certificates are fetched and renewed automatically, from Let's Encrypt or any ACME server you name. | `CASTRA_ACME_*` below, all optional           |

**`off`, behind your own proxy.** Point the proxy at `CASTRA_HTTP_PORT`, pass the `Host` header and
WebSocket upgrades (live editing uses `/collab`), and set `CASTRA_PUBLIC_URL` to the https address,
`CASTRA_HSTS=true`, and leave `SESSION_COOKIE_SECURE` unset. The proxy must also serve Draw.io over https,
because a page served over https cannot frame an http editor: with `CASTRA_DRAWIO_DOMAIN` set, as a second
host name sent to the same `CASTRA_HTTP_PORT` (the web proxy tells the two apart by `Host`); otherwise port
8081 on this host, at the address you give in `DRAWIO_URL`.

**`self-signed`.** Browsers distrust the certificate until the root certificate is installed on each
machine. Run `compose/castra.sh root-cert` to copy it to `compose/castra-root-ca.crt` (it is also served
at `https://<domain>/castra-root-ca.crt`, and never the private key). Only the root is public. Keep
`CASTRA_HSTS` off with this mode, or people cannot click through a warning. The Castra server does not
trust this CA, so the bundled sign-in cannot use it: use `files` or `acme` with the bundled sign-in.

**`files`.** Give absolute paths on the host. The web container runs as user 10001 and must be able to
read the key. The certificate is read when the proxy starts: after renewing, run
`compose/castra.sh restart web`. If you use a Draw.io host name (see [Diagrams](#diagrams)), either the one
certificate covers both names, or set `CASTRA_TLS_DRAWIO_CERT` and `CASTRA_TLS_DRAWIO_KEY` for a second pair.

**`acme`.** With only `CASTRA_DOMAIN` set, Castra asks Let's Encrypt. Settings, in `.env`:

| Setting                                              | Meaning                                                                                                      |
| ---------------------------------------------------- | ------------------------------------------------------------------------------------------------------------ |
| `CASTRA_ACME_EMAIL`                                  | Contact address for the certificate authority (expiry notices).                                              |
| `CASTRA_ACME_DIRECTORY`                              | The ACME directory URL of another server. Empty means Let's Encrypt.                                         |
| `CASTRA_ACME_CA_ROOT`                                | Path of a PEM file: the root certificate that signs that server's own certificate, if it is not a public CA. |
| `CASTRA_ACME_EAB_KEY_ID`, `CASTRA_ACME_EAB_HMAC_KEY` | External account binding, for servers that require it.                                                       |

With a Draw.io host name, Caddy asks for a separate certificate for it. The ACME server must be able to reach this host on port 80 or 443 to check each name (HTTP and
TLS-ALPN challenges). DNS challenges are not supported by the web image. Certificates and the account
are kept in a volume, so restarts do not use up Let's Encrypt limits.

Worked examples with a private certificate authority follow. They are settings only: they were **not**
tested against a live server.

_HashiCorp Vault PKI._ Enable the ACME API on a PKI mount and allow the host's name. Then:

```sh
CASTRA_TLS_MODE=acme
CASTRA_DOMAIN=castra.corp.example
CASTRA_ACME_DIRECTORY=https://vault.corp.example:8200/v1/pki/acme/directory
CASTRA_ACME_CA_ROOT=/etc/ssl/castra/vault-root.pem   # the root that signs Vault's own listener certificate
CASTRA_ACME_EMAIL=ops@corp.example
```

Vault's ACME needs the host to be able to reach Vault, Vault to reach the host to validate the name,
and the mount's `cluster_path` and `allowed_roles` set as Vault's ACME documentation describes. External
account binding is not used by Vault's ACME.

_Smallstep `step-ca`._ Add an ACME provisioner (`step ca provisioner add acme --type ACME`). Then:

```sh
CASTRA_TLS_MODE=acme
CASTRA_DOMAIN=castra.corp.example
CASTRA_ACME_DIRECTORY=https://ca.corp.example:9000/acme/acme/directory
CASTRA_ACME_CA_ROOT=/etc/ssl/castra/step-root-ca.pem   # step-ca's root_ca.crt
CASTRA_ACME_EMAIL=ops@corp.example
```

Add `CASTRA_ACME_EAB_KEY_ID` and `CASTRA_ACME_EAB_HMAC_KEY` if you made the provisioner with
`--require-eab` (`step ca acme eab add <provisioner> <reference>` prints them).

Machines that open Castra must trust your private root separately; that is up to you to distribute.

### Behind your own proxy

With `CASTRA_TLS_MODE=off` and another proxy in front, every request reaches Castra from that proxy, so
all people would share one per-address rate limit and audit entries would record the proxy's address.
Set `CASTRA_TRUSTED_PROXIES` in `compose/.env` to the proxy's address as space-separated CIDRs (for example
`10.0.0.0/8 172.16.0.0/12`). Castra's web proxy then keeps the `X-Forwarded-For` header your proxy sends.
Leave it empty when people reach Castra directly: the header is then set from the connecting address and
cannot be forged. Only the web proxy publishes a port; the API is reachable only inside the compose network.
Make sure your own proxy overwrites, not appends to, any `X-Forwarded-For` a client sends.

When the proxy runs on the same host, also set `CASTRA_HTTP_BIND=127.0.0.1` so the web ports listen on this host
only and nothing can reach Castra around the proxy. [docs/behind-a-proxy.md](docs/behind-a-proxy.md) walks through
a full example with nginx ending TLS and Cloudflare in front, including the nginx config and the Cloudflare settings.

## Diagrams

Caelus pages can hold Draw.io diagrams. The kit runs the official Draw.io image
(`jgraph/drawio`, pinned to an exact version) so editing works without the browser reaching the
internet. The editor must run on a different origin from Castra so it cannot act as Castra. There are two ways.

**A host name of its own (preferred).** Pick a name, point its DNS record where Castra's points, and set it in
`compose/.env`:

```sh
CASTRA_DRAWIO_DOMAIN=castra-diagrams.example.com
CASTRA_DRAWIO_BIND=127.0.0.1   # nothing listens on the old Draw.io port
```

The web proxy serves it on the same ports as Castra, told apart by the `Host` header, so no extra port is
published. `DRAWIO_URL` and the frame source follow (`https://castra-diagrams.example.com`); set them yourself
only to override, for example `DRAWIO_URL=http://...` on a plain-http trial. How each `CASTRA_TLS_MODE` handles the second name:

| Mode          | Draw.io name                                                                                                      |
| ------------- | ----------------------------------------------------------------------------------------------------------------- |
| `off`         | Served on `CASTRA_HTTP_PORT`, matched by `Host`. Your proxy must send both names there and serve both over https. |
| `self-signed` | Served on 443 with a certificate from the same internal CA (the root you installed already covers it).            |
| `acme`        | Served on 443; Caddy obtains a certificate for the name too (port 80 or 443 must reach this host for both names). |
| `files`       | Served on 443. One certificate can cover both names, or set `CASTRA_TLS_DRAWIO_CERT` and `CASTRA_TLS_DRAWIO_KEY`. |

`install.sh` suggests the name for you: `castra.example.com` becomes `castra-diagrams.example.com`, and a domain
with fewer labels gets `diagrams.<domain>`. The first form is covered by a one-level wildcard certificate
(`*.example.com`, such as Cloudflare's free one); `diagrams.castra.example.com` needs a certificate for
`*.castra.example.com`.

**A port of its own (fallback).** For an install with no DNS name (an IP address) and for development, leave
`CASTRA_DRAWIO_DOMAIN` empty. The web proxy then serves Draw.io on `CASTRA_DRAWIO_PORT` (default 8081), which
gives it a separate origin. Set the two settings that make it work, and open the port in your firewall:

```sh
DRAWIO_URL=https://castra.example.com:8081        # the address the browser uses
CASTRA_FRAME_SRC=https://castra.example.com:8081  # lets the page frame Castra and exactly that
```

Behind your own TLS proxy, publish the Draw.io port over https and use that address. To use a Draw.io you
already run, add `compose/compose.external-drawio.yml` and set both settings to its address.

## Sign-in

Castra signs people in through OpenID Connect only. Users are matched on issuer and subject, not on
email. Castra asks for the scopes `openid profile email`, sends a PKCE challenge, and needs these
from the provider:

| Castra setting             | What to give it                                                                              |
| -------------------------- | -------------------------------------------------------------------------------------------- |
| `OIDC_ISSUER`              | The issuer URL. Castra reads `/.well-known/openid-configuration` below it.                   |
| `OIDC_CLIENT_ID`           | The client ID of a confidential client (it has a secret).                                    |
| `OIDC_CLIENT_SECRET`       | That client's secret.                                                                        |
| `OIDC_REDIRECT_URI`        | `<CASTRA_PUBLIC_URL>/auth/callback`. Register exactly this redirect URL with the provider.   |
| `OIDC_USERNAME_CLAIM`      | The claim that holds the username (default `preferred_username`).                            |
| `OIDC_GROUPS_CLAIM`        | The claim that holds group names (default `groups`). Groups are optional.                    |
| `OIDC_GROUP_PREFIX_FILTER` | Comma-separated prefixes: import only matching groups.                                       |
| `OIDC_REQUIRED_GROUPS`     | Comma-separated group names: sign-in needs at least one in the token. Empty allows everyone. |
| `CASTRA_BOOTSTRAP_ADMINS`  | Usernames (the username claim) who become administrators of the first organisation.          |

The Castra server itself (not only the browser) must be able to reach the issuer URL.

### Bundled sign-in

Without an identity provider, add the `identity` profile (`install.sh` does this when you choose
"bundled"). It runs Keycloak in production mode:

- It is served by the same web entry point under **`/idp`** on your address (`https://castra.example.com/idp`).
  A path was chosen over a subdomain because it needs no extra DNS name or certificate, and
  Keycloak supports a relative path cleanly (`KC_HTTP_RELATIVE_PATH`). Sign-in itself is at `/auth` on
  Castra, so the two do not clash.
- It keeps its data in its own `keycloak` database in the bundled Postgres, created by a one-shot
  `idp-db-init` service. It cannot be combined with your own Postgres.
- Its realm `castra` (`compose/identity/castra-realm.json`) has one confidential client, `castra`,
  with PKCE and a `groups` claim, and no users. The client secret is `OIDC_CLIENT_SECRET`.
- The admin console and the master realm are **not** served on the public address. The Keycloak admin
  name and password are `KEYCLOAK_ADMIN` and `KEYCLOAK_ADMIN_PASSWORD` in `compose/.env`. To use the
  console, tunnel to the loopback port from your own machine and browse to it:

  ```sh
  ssh -L 8180:localhost:8180 you@castra-host
  # then open http://localhost:8180/idp/admin/ and choose the castra realm
  ```

- The installer creates the first administrator (name, email and password you give, or a generated
  password saved to `compose/first-admin.txt`, mode 600, to be changed at first sign-in) and puts
  its username in `CASTRA_BOOTSTRAP_ADMINS`. To make one by hand, add a user in the `castra` realm
  with a password, then add that username to `CASTRA_BOOTSTRAP_ADMINS` and run `compose/castra.sh up -d`.
- It needs an https address the Castra server can reach (`acme`, `files`, or your own https proxy).
  Email is not set up in Keycloak, so there is no password reset by email: an administrator sets
  passwords in the console. Back up its database with the rest (`compose/backup.sh` dumps the whole
  Postgres, Keycloak's database included).

### Your own provider

Register Castra as a web application with the redirect URL above, and fill in the settings. Examples,
with what to look for. **Only Keycloak has been tested with Castra.** The others are settings that
follow each product's documentation and are not confirmed here, so try them on a spare install first.

| Provider              | `OIDC_ISSUER`                                         | Username claim                    | Groups claim                                                                                      |
| --------------------- | ----------------------------------------------------- | --------------------------------- | ------------------------------------------------------------------------------------------------- |
| **Keycloak** (tested) | `https://kc.example.com/realms/<realm>`               | `preferred_username`              | Add a "Group Membership" mapper to the client: claim name `groups`, full group path off.          |
| Microsoft Entra ID    | `https://login.microsoftonline.com/<tenant-id>/v2.0`  | `preferred_username`              | In Token configuration add a groups claim. It sends group object IDs by default, not names.       |
| Okta                  | `https://<org>.okta.com` or `.../oauth2/default`      | `preferred_username`              | Add a `groups` claim to the authorization server (a regex filter picks the groups) for ID tokens. |
| Authentik             | `https://authentik.example.com/application/o/<slug>/` | `preferred_username`              | Its default profile scope mapping includes `groups`. Use the application's slug in the issuer.    |
| Google Workspace      | `https://accounts.google.com`                         | `email` (no `preferred_username`) | Google does not send groups, so group-based access is not available with it.                      |

Each provider's steps, in short:

- **Keycloak.** Create a client with "Client authentication" on, the standard flow on, the redirect
  URL above, and PKCE method `S256`. Copy the secret from the Credentials tab. Add the groups mapper.
- **Microsoft Entra ID.** App registrations, New registration, platform Web, redirect URL above. Under
  Certificates and secrets make a client secret. The client ID is the Application (client) ID. If a
  user is in many groups, Entra sends a link instead of the list; filter groups to those assigned to
  the app.
- **Okta.** Applications, Create App Integration, OIDC, Web application, with the redirect URL above.
  To get groups, add the claim under Security, API, your authorization server, Claims.
- **Authentik.** Create an OAuth2/OpenID provider (confidential), strict redirect URI as above, add
  the `openid`, `profile` and `email` scope mappings, and attach it to an application.
- **Google Workspace.** In Google Cloud Console, Credentials, create an OAuth client ID of type Web
  application with the redirect URL above, and set `OIDC_USERNAME_CLAIM=email`. Restrict who may use it
  with the consent screen's internal user type.

## Kubernetes

`helm/castra` is a Helm chart that runs the same stack on Kubernetes: Castra in `minimal` or `full`
mode, with Postgres, Valkey, SeaweedFS, Draw.io, NATS and Keycloak each bundled or replaced by your
own, an Ingress or Gateway route with TLS options (including cert-manager with Let's Encrypt or an
internal ACME CA), a Postgres backup CronJob and an optional ServiceMonitor. It has no chart
dependencies, so it works from this one folder, offline too once the images are in your registry.

```sh
helm install castra ./helm/castra --namespace castra --create-namespace -f my-values.yaml
```

Read [helm/castra/README.md](helm/castra/README.md) first: it covers secrets (use `existingSecret`),
the database roles, live editing through the ingress, backups and upgrades. The chart is linted and
rendered in CI but has **not been run on a live cluster** here, so try it on a spare namespace first.
`bundle.sh` and `install.sh` are for Docker Compose and do not apply to it: mirror the images listed in
the chart's `values.yaml` to your own registry for an offline cluster.

## Offline install

For a host with no internet access, make a bundle on a machine that has it, carry it across, and load
it. The bundle holds every image the stack runs (Castra, Postgres, Valkey, SeaweedFS, Draw.io,
Keycloak and NATS for the profiles you choose), these deploy files and a `SHA256SUMS` file.

On a machine with internet and Docker, in this folder:

```sh
./bundle.sh --version 1.0.0 --arch amd64        # or --arch arm64
```

It reads the image list from `compose/compose.yml`, pulls the images for that architecture, checks
Castra's signatures if cosign is installed (and stops if one fails), saves everything into
`castra-offline-1.0.0-amd64.tar.gz` and writes `castra-offline-1.0.0-amd64.tar.gz.sha256`. By default it
includes every profile; `--profiles minimal,identity` leaves out what you will not run. Build on a machine of
the same architecture as the target, or one using Docker's containerd image store.

Copy the archive, its `.sha256` file and `load.sh` to the offline host, then:

```sh
./load.sh castra-offline-1.0.0-amd64.tar.gz     # unpacks to ./castra
cd castra
./install.sh --offline
```

`load.sh` checks the archive against its `.sha256`, then every file inside against `SHA256SUMS`, and
refuses on any mismatch or a wrong architecture, before it loads anything. It then runs `docker load`
and unpacks the deploy files, never touching an existing `compose/.env`. `install.sh --offline` skips
pulling and signature checks (do the signature check on the machine that made the bundle) and starts
Castra from the loaded images. Your identity provider, SMTP relay and other services must be reachable
from the offline host; the bundled ones are. To upgrade, make a new bundle for the new version and load it
the same way.

## Images

Castra is two images, published for linux/amd64 and linux/arm64:

- `ghcr.io/castracloud/castra-server`: every backend role, chosen by `CASTRA_ROLE`.
- `ghcr.io/castracloud/castra-web`: the web front end and reverse proxy.

| Tag            | Meaning                                                                       |
| -------------- | ----------------------------------------------------------------------------- |
| `1.2.3`        | An exact release. Use this (or a digest) in production.                       |
| `1.2`          | The newest patch release of 1.2.                                              |
| `latest`       | The newest stable release. Fine for a trial; pin a version for anything else. |
| `sha-<commit>` | One build, for testing a specific fix.                                        |

Pin an exact version (or a digest) in production and change it on purpose. Each image is signed
with [cosign](https://github.com/sigstore/cosign) keyless signing from the release workflow,
carries an SPDX SBOM and build provenance, and is scanned for known vulnerabilities as part of the
build, which fails on any critical vulnerability that already has a fix. `install.sh` and
`bundle.sh` check the signatures for you when cosign is installed. To check one by hand:

```sh
cosign verify ghcr.io/castracloud/castra-server:1.2.3 \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com \
  --certificate-identity-regexp '^https://github\.com/CastraCloud/castra/\.github/workflows/ci\.yml@refs/tags/v.*$'
```

Use the same command for `castra-web`. Read the SBOM with:

```sh
docker buildx imagetools inspect ghcr.io/castracloud/castra-server:1.2.3 --format '{{ json .SBOM.SPDX }}'
```

Problems with installing, upgrading or the images themselves: open an issue in this repository.

## Backups

Two things hold your data: Postgres and the object store. `compose/backup.sh` copies both, database
first, into a dated folder with checksums:

```sh
BACKUP_DIR=/srv/castra-backups BACKUP_KEEP=14 compose/backup.sh
```

`compose/restore.sh /srv/castra-backups/castra-<timestamp>` checks the checksums, asks you to
confirm, and restores both. Keep `compose/.env` separately (a password manager or secret store):
the scripts never copy it, so a stolen backup holds no secrets.

These scripts work with the bundled Postgres and SeaweedFS. With your own Postgres or bucket, back
them up with their own tools (`BACKUP_OBJECTS=none` skips the object copy).

Back up at least daily and before every upgrade, keep several, keep a copy off the host, and do a
restore drill on a spare machine every few months.

## Upgrading

See [UPGRADING.md](UPGRADING.md): back up first, set the new image tags, pull, start. Migrations run
by themselves. To go back, restore the backup taken before the upgrade.

## Monitoring

- `/healthz` answers when the process is up; `/readyz` lists the database, cache and storage
  checks.
- Set `METRICS_ENABLED=true` and `METRICS_TOKEN` to serve `/metrics` in the Prometheus text format.
- Audit events can be streamed as they happen to an OpenTelemetry collector (OTLP over HTTPS), any
  HTTPS endpoint (JSON lines) or a syslog server. Set this up in the app under Administration.

## What has and has not been tested

The scripts here are tested against a stand-in `docker` command, which checks their logic: the
answers, the secrets, the order of steps and the checksums. They have not been run here against a
live Docker daemon, a real Caddy, Keycloak or ACME server, so do a trial install and a restore on a
spare host before you rely on them.

## Getting help

Open an issue in this repository for problems with installing or upgrading.

## Licence

The files in this repository (the installer, scripts, Compose files, Helm chart and documentation)
are licensed under the [Apache License 2.0](LICENSE): copy and change them for your own installs.

Castra itself, the software in the `castra-server` and `castra-web` images, is not open source. It
is free to install and use for your own organisation under the [Castra Licence](LICENSE-castra.md),
which among other things does not allow offering Castra to others as a hosted service. The open
source components inside the images keep their own licences, listed in each image's SBOM.
