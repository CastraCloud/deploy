# Castra Helm chart

Runs Castra (Minerva, Caelus and Mercury) on Kubernetes from one directory, with no chart
dependencies, so it also works offline. It is the Kubernetes counterpart of the Docker Compose kit
in the parent repository: the same images, roles, settings and defaults.

**Status.** The chart is linted and rendered in CI for every layout below, but it has **not been run
on a live cluster** yet. Install it on a spare namespace first, and do a backup and restore drill
before you rely on it.

## What it installs

| Piece                          | Kind                  | Notes                                                                                       |
| ------------------------------ | --------------------- | ------------------------------------------------------------------------------------------- |
| `migrate`                      | Job (Helm hook)       | Runs migrations as `castra_owner`, and creates the first organisation.                      |
| `app` or one Deployment a role | Deployments, Services | `mode: minimal` (one all-in-one process) or `mode: full` (api, collab, realtime and so on). |
| `web`                          | Deployment, Service   | Caddy: the web apps, `/api`, `/auth`, `/collab`, the mail-in webhook and `/idp`.            |
| Ingress or HTTPRoute           | Ingress, HTTPRoute    | Optional. TLS is ended here, not in the web pod.                                            |
| Postgres 17                    | StatefulSet           | Bundled or your own. The chart applies `roles.sql` on first start.                          |
| Valkey                         | StatefulSet           | Bundled or your own Valkey or Redis.                                                        |
| SeaweedFS                      | StatefulSet           | Bundled S3 storage, or your own bucket.                                                     |
| Draw.io                        | Deployment            | Bundled by default: diagram editing needs it.                                               |
| NATS                           | StatefulSet           | Only with `events.transport: nats`.                                                         |
| Keycloak (production mode)     | Deployment            | Optional, for people with no identity provider. Served at `/idp`.                           |
| Postgres backup                | CronJob               | Optional.                                                                                   |
| ServiceMonitor                 | ServiceMonitor        | Optional, for the Prometheus operator.                                                      |

Images are pinned to the same exact versions as `compose/compose.yml`. Castra's own images default
to the chart's `appVersion`; set `image.server.tag` and `image.web.tag` (or a `digest`) to pin them.

## Install

You need Kubernetes 1.27 or newer, Helm 3.14 or newer, a default StorageClass (or set one), an
identity provider (or `keycloak.enabled`), and an Ingress controller or Gateway. Checking image
signatures is done by you, with cosign: see the main README.

A first install for a trial, with random secrets made by the chart:

```sh
helm install castra ./helm/castra --namespace castra --create-namespace \
  --set secrets.generate=true \
  --set ingress.enabled=true --set ingress.className=nginx --set ingress.preset=nginx \
  --set ingress.host=castra.example.com \
  --set drawio.host=drawio.example.com \
  --set ingress.tls.mode=certManager --set ingress.tls.issuer.name=letsencrypt \
  --set keycloak.enabled=true \
  --set signIn.bootstrap.orgName="Example Org" --set signIn.bootstrap.orgSlug=example \
  --set signIn.bootstrap.admins=admin1
```

For anything real, put your settings in a values file and keep it in version control (without
secrets), and use `existingSecret` for every secret:

```sh
helm install castra ./helm/castra --namespace castra --create-namespace -f my-values.yaml
```

Two names need DNS records pointing at your ingress: the Castra address and the Draw.io address
(`drawio.host`). Draw.io has its own name so the editor runs on a different origin from Castra and
cannot act as it. With a Gateway or your own load balancer, set `publicUrl` and `drawio.publicUrl`
yourself. To use a Draw.io you already run, set `drawio.mode: external` and `drawio.external.url`;
to have no diagram editing, `drawio.mode: none`.

The web proxy lets a page frame only Castra itself and the Draw.io address. If pages embed other sites (Administration, Embedded sites), put the sources that page shows in `web.frameSrc`, space separated.

`helm install --wait` works with an external Postgres. With the bundled one, the migration runs after
the first install (the database has to exist first), so the web and API pods may restart once or
twice while it starts. `kubectl logs job/castra-castra-migrate` shows it (the name starts with your
release name; the Job is removed when it succeeds, so watch for it during the install). Every later
upgrade runs the migration before the new pods start.

### Settings

Every setting is in [`values.yaml`](values.yaml), commented, and checked by `values.schema.json`.
They follow `compose/.env.example` name for name, with the same defaults:

| Group in values.yaml                                   | What it sets                                                                 |
| ------------------------------------------------------ | ---------------------------------------------------------------------------- |
| `mode`, `publicUrl`, `logLevel`                        | minimal or full, the address people use, log level                           |
| `signIn`                                               | OIDC issuer and client, session secret, first organisation and admins, HSTS  |
| `email`                                                | SMTP, digests, reply domain and tokens                                       |
| `inboundEmail`                                         | IMAP mailbox, the mail webhook secret, size and rate limits, SPF/DKIM/DMARC  |
| `limits`, `webhooks`, `imports`                        | rate limits, API token lifetime, webhook and importer private ranges (CIDRs) |
| `metrics`                                              | `/metrics` and the ServiceMonitor                                            |
| `events`, `nats`                                       | `outbox` (Postgres) or `nats` event transport                                |
| `database`, `valkey`, `storage`, `drawio`              | bundled or external for each                                                 |
| `keycloak`                                             | the bundled identity provider                                                |
| `ingress`, `gateway`                                   | exposing Castra                                                              |
| `backup`                                               | the Postgres dump CronJob                                                    |
| `extraEnv`, `extraEnvFrom`, `extraVolumes`, `advanced` | anything else Castra reads, and extra mounts                                 |

Retention of closed tickets, old page versions, notifications and audit events is set in the app
under Administration, Retention, not here.

## Secrets

No secret has a default. Each one is a small block:

```yaml
signIn:
  session:
    secret:
      existingSecret: castra-session # a Secret you made
      key: session-secret # the key inside it
      value: "" # or the value itself (kept in a chart-made Secret; trials only)
```

The secrets are: `database.ownerPassword`, `database.appPassword`, `database.bundled.superuserPassword`,
`signIn.session.secret`, `signIn.oidc.clientSecret`, `webhooks.encryptionKey`, `storage.accessKey` and
`secretKey`, `email.smtp.password`, `email.tokenSecret`, `push.privateKey`, `inboundEmail.imap.password`,
`inboundEmail.webhook.secret`, `metrics.token`, `valkey.external.url` (it holds a password),
`keycloak.adminPassword` and `keycloak.databasePassword`, and the backup ones.

Make them yourself, for example:

```sh
kubectl -n castra create secret generic castra-db \
  --from-literal=owner-password="$(openssl rand -base64 36 | tr -d '/+=')" \
  --from-literal=app-password="$(openssl rand -base64 36 | tr -d '/+=')"
```

and point at them (`database.ownerPassword.existingSecret: castra-db`, `key: owner-password`, and so on).
Database passwords go into a connection string, so use letters and digits, or percent-encode them.

**`secrets.generate: true`** makes a random value for every secret that has no `existingSecret` and
no value, on first install. The chart looks its own Secret up, so upgrades keep what was made. It
will **not** work when the manifests are produced with `helm template` and applied (Argo CD, Flux
with plain manifests, `kubectl apply`): there is no lookup, so the secrets would change on every sync
and stop matching the database. Use `existingSecret` there. The Secret the chart makes is kept when
you uninstall, so its passwords still match the volumes that are left behind. After changing a secret
in an existing Secret, restart the pods (`kubectl rollout restart deployment -l app.kubernetes.io/instance=castra`).

Back up your secrets separately from your backups. The backup job never copies them.

## Sign-in

Set `signIn.oidc.issuer`, `clientId`, the client secret, and register `<publicUrl>/auth/callback`
with your provider. The Castra pods themselves must be able to reach the issuer URL. See "Sign-in" in
the main README for the settings each provider needs.

**Bundled Keycloak** (`keycloak.enabled: true`). Keycloak runs in production mode and is served by
the web pod at `<publicUrl>/idp`. Its realm `castra` has one confidential client and no users.
It uses a database `keycloak` in the bundled Postgres (so it cannot be combined with an external
Postgres), made by an init container. The chart sets the issuer, client ID and redirect address for
you and makes the client secret. The public address must be https and reachable from inside the
cluster: pods have to resolve your Castra host name to the ingress. If your cluster DNS cannot do
that, add a CoreDNS rewrite or a `hostAliases` entry to your own overlay.

The admin console and master realm are not served on the public address. Reach them with:

```sh
kubectl -n castra port-forward svc/castra-castra-keycloak 8180:8080
# open http://localhost:8180/idp/admin/ and choose the castra realm
kubectl -n castra get secret castra-castra-secrets -o jsonpath='{.data.keycloak-admin-password}' | base64 -d
```

Add a user with a password in the `castra` realm, and put their username in `signIn.bootstrap.admins`.
There is no email in Keycloak, so no password reset by email.

## Identity sources from a file

Keycloak and other directories can be set in Administration, Identity sources, or from a file. With a file, that screen is read-only. The migrate Job reads the file on each install and upgrade. Put it in a ConfigMap (or a Secret) and name it under `identity.file`. In the file a secret is written as `${env:IDENTITY_SECRET_1}` to `${env:IDENTITY_SECRET_3}`; give each one from an existing Secret, and only the migrate Job sees them.

```yaml
identity:
  file:
    configMap: castra-identity # key identity.yaml
  secret1:
    existingSecret: castra-identity-secrets
    key: keycloak-client-secret
```

## HTTPS

`ingress.tls.mode` is one of:

| Mode             | What it does                                                                                              |
| ---------------- | --------------------------------------------------------------------------------------------------------- |
| `none`           | Plain http. Use it behind a load balancer that ends TLS (set `publicUrl` to the https address).           |
| `existingSecret` | Uses a `kubernetes.io/tls` Secret you made, named in `ingress.tls.secretName`. It covers both host names. |
| `certManager`    | Adds the cert-manager annotation for `ingress.tls.issuer` and a TLS block. cert-manager makes the Secret. |

The certificate must cover the Castra host and the Draw.io host.

### cert-manager with Let's Encrypt

With cert-manager installed, make a ClusterIssuer (HTTP-01 through your ingress class):

```yaml
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt
spec:
  acme:
    server: https://acme-v02.api.letsencrypt.org/directory
    email: ops@example.com
    privateKeySecretRef:
      name: letsencrypt-account
    solvers:
      - http01:
          ingress:
            ingressClassName: nginx
```

then `ingress.tls.mode=certManager`, `ingress.tls.issuer.name=letsencrypt`.

### cert-manager with an internal ACME CA

Any ACME server works as a cert-manager issuer. These are settings only and were **not** tested
against a live server.

HashiCorp Vault PKI (with its ACME API enabled on the PKI mount):

```yaml
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: vault-acme
spec:
  acme:
    server: https://vault.corp.example:8200/v1/pki/acme/directory
    caBundle: <base64 of the root certificate that signs Vault's own listener certificate>
    privateKeySecretRef:
      name: vault-acme-account
    solvers:
      - http01:
          ingress:
            ingressClassName: nginx
```

Smallstep `step-ca` (with an ACME provisioner; add `externalAccountBinding` if you made it with
`--require-eab`):

```yaml
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: step-acme
spec:
  acme:
    server: https://ca.corp.example:9000/acme/acme/directory
    caBundle: <base64 of step-ca's root_ca.crt>
    privateKeySecretRef:
      name: step-acme-account
    solvers:
      - http01:
          ingress:
            ingressClassName: nginx
```

Then set `ingress.tls.issuer.name` to `vault-acme` or `step-acme`. Use `kind: Issuer` for a
namespaced issuer. Machines that open Castra must trust your private root; that is up to you.
Because the Castra pods call the public address (sign-in), they must trust it too: for a private CA,
make the pods trust the root: mount it with `extraVolumes` and `extraVolumeMounts`, and set
`NODE_EXTRA_CA_CERTS` to its path in `extraEnv`.

## Live editing and the ingress

Live editing (`/collab`) is a long-lived WebSocket, and so is the connection a page keeps for updates.
Ingress controllers close idle connections, which would cut editing off. The chart's `ingress.preset`
sets what it can:

- **`nginx`**: `proxy-read-timeout` and `proxy-send-timeout` of 3600 seconds, and `proxy-body-size`
  (`ingress.maxBodySize`, default 100m, keep it above `storage.attachmentMaxBytes`). The nginx
  ingress controller upgrades WebSockets by itself.
- **`traefik`**: selects the `websecure` entry point (`ingress.traefikEntryPoints`) when TLS is on.
  Traefik upgrades WebSockets by itself, but its idle and read timeouts belong to the entry point,
  not the Ingress: in Traefik's static configuration, set
  `entryPoints.websecure.transport.respondingTimeouts.idleTimeout` to `3600s` and leave
  `readTimeout` at `0` (the default).
- **`none`**: nothing is added. Set what your controller needs under `ingress.annotations`.

A Gateway needs the same: set `gateway.timeouts.request` (Gateway API 1.1), and for Envoy Gateway or
others use their own policy object for idle and stream timeouts.

## Gateway API

Instead of an Ingress, set `gateway.enabled: true`, `gateway.parentRefs`, `gateway.hostnames` and
(for the bundled Draw.io) `gateway.drawioHostnames`, and set `publicUrl` and `drawio.publicUrl`.
TLS is then the Gateway's business.

## Using your own Postgres, Valkey, storage and Draw.io

Each of `database`, `valkey`, `storage` and `drawio` has a `mode`. For your own:

- **Postgres 17 or newer.** Set `database.mode: external` and `database.external.host`, `port` and
  `params` (for example `?sslmode=require`). Create the database and the two roles before the first
  install, as the Postgres superuser, connected to the Castra database:

  ```sh
  psql -v ON_ERROR_STOP=1 -v owner_password='...' -v app_password='...' -f files/roles.sql
  ```

  `castra_owner` owns the schema and runs migrations only. `castra_app` runs everything else and
  cannot bypass row-level security. Give the same two passwords to the chart. The script is safe to
  run again, and re-applies the passwords.
- **Valkey or Redis.** `valkey.mode: external` and `valkey.external.url` (a Secret).
- **S3.** `storage.mode: external`, `storage.external.endpoint`, the keys, `storage.forcePathStyle: "true"`
  if your store needs it. Create the bucket first.
- **S3 on AWS with an IAM role.** Instead of fixed keys, set `storage.s3.credentials: aws-default` and leave
  `storage.accessKey` and `storage.secretKey` empty. Castra then uses the AWS default credential chain, with
  credentials refreshed automatically. It needs `storage.mode: external`, and `storage.external.endpoint` set to
  your region's S3 endpoint (for example `https://s3.eu-west-1.amazonaws.com`) with `storage.forcePathStyle: "false"`.
  The chart refuses to render if keys are also set. The role needs `s3:GetObject`, `s3:PutObject`,
  `s3:DeleteObject` and `s3:ListBucket` on the bucket. On EKS with IRSA, annotate the chart's service account:

  ```yaml
  storage:
    mode: external
    external:
      endpoint: https://s3.eu-west-1.amazonaws.com
    region: eu-west-1
    forcePathStyle: "false"
    s3:
      credentials: aws-default
  serviceAccount:
    annotations:
      eks.amazonaws.com/role-arn: arn:aws:iam::123456789012:role/castra-attachments
  ```

  With EKS pod identity, create the pod identity association for the same service account (named after the
  release unless you set `serviceAccount.name`) and leave the annotation out. Without either, the pods fall back
  to the node's instance role; set the node's IMDSv2 hop limit to 2 so pods can reach it.

The bundled Postgres makes the two roles on the first start of an empty volume. Changing a database
password later in the chart does not change it inside Postgres: run `roles.sql` again with the new
passwords.

## Backups

Two things hold your data: Postgres and the object store. Your secrets are a third thing to keep.

**Postgres.** `backup.enabled: true` adds a CronJob (`backup.schedule`) that runs `pg_dump` in
custom format with the same checks as `compose/backup.sh`: the dump must be non-empty and readable
by `pg_restore --list`, the number of migrations applied is recorded in `backup.info`, and
`SHA256SUMS` is written and checked before the backup counts as made. A failed run removes its
partial output. The dump runs as the Postgres superuser (castra_owner cannot read the tables, because
row-level security is forced on them). With an external Postgres, name a role that can read every table in
`backup.database.user`.

- `backup.target: pvc` writes dated folders (`castra-<timestamp>`) to a volume (`backup.pvc`) and keeps
  the newest `backup.keep`. Copy that volume off the cluster too.
- `backup.target: s3` uploads each folder to `backup.s3.bucket`. Use the bucket's lifecycle rules for
  retention. Use a different bucket and account from Castra's own attachments.

**Attachments.** The job does not copy the object store. With the bundled SeaweedFS, take volume
snapshots (VolumeSnapshot, or your storage provider's snapshots) of its PVC, taken right after the
database dump so they agree, or run `rclone copy` between your bucket and a backup bucket. With an
external bucket, use its own versioning and replication. A restore needs both to match.

**Secrets.** Keep the Secrets (or your values file and secret store) separate from the backups.

**Restore.** Stop Castra's pods (`kubectl scale deployment -l app.kubernetes.io/instance=castra --replicas=0`),
then restore as the Postgres superuser, as `compose/restore.sh` does:

```sh
kubectl -n castra cp <backup>/database.dump castra-castra-postgres-0:/tmp/database.dump
kubectl -n castra exec castra-castra-postgres-0 -- sh -c \
  'pg_restore --clean --if-exists --create --exit-on-error --username "$POSTGRES_USER" --dbname postgres /tmp/database.dump'
```

Restore the object store from its own backup, then scale the pods back up. Check `SHA256SUMS`
before you start, and do a restore drill on a spare namespace every few months.

Volume snapshots of the Postgres PVC are a fine extra, but they are only crash-consistent: keep the
dumps too.

## Monitoring

`/healthz` and `/readyz` are the liveness and readiness probes of every Castra pod. Set
`metrics.enabled: true` (and a token) to serve `/metrics` on every role; the web proxy does not route
it, so it is reachable only inside the cluster. `metrics.serviceMonitor.enabled: true` adds a
ServiceMonitor for the Prometheus operator that scrapes each role with the bearer token. The token's
Secret must be in the ServiceMonitor's namespace: if that is not the release namespace, copy it
there.

## Scaling and availability

Only the API is known to be safe to run more than once (`roles.api.replicas`). The workers and the
live-editing role hold state or do scheduled work, so they stay at one replica and use the
`Recreate` strategy where two copies at once would be wrong. Do not raise their replicas unless
Castra's release notes say it is supported. A PodDisruptionBudget is made for any workload that has
more than one replica. The bundled Postgres, Valkey, SeaweedFS and NATS are single instances with a
volume: use your own managed services where you need high availability.

Pod security: Castra's pods run as a non-root user with a read-only root file system (a small
`/tmp` volume), no added capabilities, no privilege escalation, and the runtime default seccomp
profile. Keycloak, SeaweedFS and Draw.io write outside their data folders, so their root file
systems are left writable; their security contexts can be changed in values.

## Upgrading

Back up first. Then set the new image tags (or `appVersion`) and run:

```sh
helm upgrade castra ./helm/castra --namespace castra -f my-values.yaml
```

The migration Job runs before the new pods roll out. Migrations only move forward: the way back is a
restore of the backup you took. See `UPGRADING.md` in the parent folder. Read the release notes for
new settings first.

## Uninstalling

`helm uninstall castra` removes the workloads. It keeps the volumes (StatefulSet claims), the backup
volume and the Secret the chart made, so nothing is lost by accident. Delete them by hand when you
mean to.

## What has and has not been tested

CI lints the chart and renders it for each layout in `ci/` (minimal, full, all external services,
bundled Keycloak with NATS, and each TLS mode), and checks that every server setting in the compose
file is mapped. Nothing here has been run against a live cluster, a real ingress controller,
cert-manager, an ACME server, Keycloak or the Prometheus operator. Known gaps:

- the migration ordering on a first install with the bundled Postgres is by hook, not tested;
- the bundled images run with the security settings above unchanged, which has not been tried on every
  Kubernetes distribution (Draw.io's image in particular);
- behind the web proxy the API may see the proxy's address for the per-IP rate limit; check before relying on it.
