# Castra behind nginx and Cloudflare

This guide covers a common setup: Castra runs on a host that already has nginx in front of other sites, nginx
ends TLS, and Cloudflare sits in front of nginx.

```
visitor ── https ──> Cloudflare ── https ──> nginx (this host) ── http ──> Castra web (127.0.0.1:8080)
                                                                              (castra.example.org and
                                                                               castra-diagrams.example.org)
```

Castra runs with `CASTRA_TLS_MODE=off` and never sees TLS. Cloudflare and nginx handle certificates.

## 1. Castra settings

In `compose/.env`:

```sh
CASTRA_TLS_MODE=off
# Listen on this host only, so nothing reaches Castra around nginx.
CASTRA_HTTP_BIND=127.0.0.1
CASTRA_HTTP_PORT=8080
# The address people use.
CASTRA_PUBLIC_URL=https://castra.example.org
# Draw.io gets its own host name so the editor runs on a different origin from Castra. The web proxy serves it on the
# same port as Castra and tells the two apart by Host, so nothing listens on a second port. DRAWIO_URL follows.
CASTRA_DRAWIO_DOMAIN=castra-diagrams.example.org
CASTRA_DRAWIO_BIND=127.0.0.1
# Optional: the portal on its own host name (help.example.org), served the same way as Draw.io's name above.
# CASTRA_PORTAL_DOMAIN=help.example.org
# Believe X-Forwarded-For from nginx. nginx reaches the container through Docker's bridge network, so it shows up
# with a private address; private_ranges covers that.
CASTRA_TRUSTED_PROXIES=private_ranges
```

Leave `CASTRA_HSTS` unset and turn HSTS on in Cloudflare instead, so it is set in one place.

Keep `ATTACHMENT_MAX_BYTES` below your Cloudflare plan's upload limit (see section 3). The default, 25 MB, is
below every plan's limit.

## 2. nginx

nginx needs to:

- take the real visitor address from Cloudflare (`CF-Connecting-IP`), trusting it only from Cloudflare's own
  addresses;
- pass that address on to Castra as `X-Forwarded-For`, replacing any value the visitor sent;
- pass WebSocket upgrades through and keep them open, because live editing uses one long-lived connection;
- allow uploads up to Castra's attachment limit.

```nginx
# Cloudflare's addresses. Refresh this list from https://www.cloudflare.com/ips/ when Cloudflare changes it.
set_real_ip_from 173.245.48.0/20;
set_real_ip_from 103.21.244.0/22;
set_real_ip_from 103.22.200.0/22;
set_real_ip_from 103.31.4.0/22;
set_real_ip_from 141.101.64.0/18;
set_real_ip_from 108.162.192.0/18;
set_real_ip_from 190.93.240.0/20;
set_real_ip_from 188.114.96.0/20;
set_real_ip_from 197.234.240.0/22;
set_real_ip_from 198.41.128.0/17;
set_real_ip_from 162.158.0.0/15;
set_real_ip_from 104.16.0.0/13;
set_real_ip_from 104.24.0.0/14;
set_real_ip_from 172.64.0.0/13;
set_real_ip_from 131.0.72.0/22;
set_real_ip_from 2400:cb00::/32;
set_real_ip_from 2606:4700::/32;
set_real_ip_from 2803:f800::/32;
set_real_ip_from 2405:b500::/32;
set_real_ip_from 2405:8100::/32;
set_real_ip_from 2a06:98c0::/29;
set_real_ip_from 2c0f:f248::/32;
real_ip_header CF-Connecting-IP;

map $http_upgrade $connection_upgrade {
    default upgrade;
    ''      close;
}

server {
    listen 443 ssl;
    listen [::]:443 ssl;
    http2 on;
    server_name castra.example.org;

    # A Cloudflare Origin CA certificate (SSL/TLS, Origin Server in the Cloudflare dashboard) is the simplest choice.
    ssl_certificate     /etc/nginx/certs/castra.example.org.pem;
    ssl_certificate_key /etc/nginx/certs/castra.example.org.key;

    # At least ATTACHMENT_MAX_BYTES, and no more than your Cloudflare plan allows.
    client_max_body_size 100m;

    location / {
        proxy_pass http://127.0.0.1:8080;
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        # $remote_addr is the visitor's address here, thanks to real_ip above. Replace, do not append.
        proxy_set_header X-Forwarded-For $remote_addr;
        proxy_set_header X-Forwarded-Proto https;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection $connection_upgrade;
        # Live editing keeps a WebSocket open; uploads and downloads stream.
        proxy_read_timeout 3600s;
        proxy_send_timeout 3600s;
        proxy_request_buffering off;
        proxy_buffering off;
    }
}

# Draw.io: the same Castra port. Castra's web proxy picks Draw.io by the Host header, so Host must be passed on.
server {
    listen 443 ssl;
    listen [::]:443 ssl;
    http2 on;
    server_name castra-diagrams.example.org;

    # A certificate that covers this name: its own, or one that lists both names.
    ssl_certificate     /etc/nginx/certs/castra-diagrams.example.org.pem;
    ssl_certificate_key /etc/nginx/certs/castra-diagrams.example.org.key;

    location / {
        proxy_pass http://127.0.0.1:8080;
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header X-Forwarded-For $remote_addr;
        proxy_set_header X-Forwarded-Proto https;
    }
}
```

Without a second DNS name, leave `CASTRA_DRAWIO_DOMAIN` unset: Draw.io then listens on `CASTRA_DRAWIO_PORT` (8081),
you set `DRAWIO_URL` to the https address nginx gives that port, and nginx proxies a second server block to
`http://127.0.0.1:8081`.

To make sure only Cloudflare can reach these sites, either allow only Cloudflare's addresses on port 443 in the
host firewall, or turn on Authenticated Origin Pulls in Cloudflare and require the client certificate in nginx.

## 3. Cloudflare

- **DNS**: `castra.example.org` and `castra-diagrams.example.org` as proxied (orange cloud) records pointing at the
  host.
- **Name and certificate**: the free Universal certificate at the edge covers the apex and one level of
  subdomain (`*.example.org`), so `castra-diagrams.example.org` is covered and `diagrams.castra.example.org` is
  not (that needs Advanced Certificate Manager). Pick the first form.
- **SSL/TLS**: Full (strict), with an Origin CA certificate on nginx that lists both names (for example
  `castra.example.org` and `castra-diagrams.example.org`, or `*.example.org`). Turn on Always Use HTTPS and HSTS.
- **Network**: WebSockets on (live editing needs them).
- **Caching**: by default Cloudflare caches only static files by extension, which suits Castra: the app's scripts
  and styles have hashed names. Add a Cache Rule that bypasses the cache for `/api/*`, `/auth/*` and `/collab*`,
  so nothing personal is ever cached. Set Browser Cache TTL (under Caching, Configuration) to "Respect Existing
  Headers": otherwise Cloudflare replaces the `no-cache` that Castra sends for `/sw.js` and `/portal/sw.js` with
  4 hours, and the installed app is slower to notice a new version.
- **Speed**: turn off Rocket Loader and Email Address Obfuscation. Both rewrite pages and inject scripts, which
  Castra's Content-Security-Policy blocks.
- **Security**: Bot Fight Mode, Super Bot Fight Mode and Browser Integrity Check can block the services that call
  Castra on their own. Add a WAF custom rule that skips them for these paths:
  - `/api/v1/incoming/` (incoming webhooks)
  - `/api/v1/chat/` (chat commands and events)
  - `/api/v1/dev/inbound/` (Git and CI deliveries)
  - `/api/v1/mail/inbound` (inbound email webhook, if you use one)
  - `/api/v1/public/status` and the status page's feeds and sign-up (if the status page is on)
  - `/api/v1/change-feed/` and `/api/v1/blog-feed/` (calendar and blog feeds read by other apps)
- **Upload limit**: Cloudflare refuses request bodies over 100 MB on the Free and Pro plans, 200 MB on Business
  and 500 MB on Enterprise. Keep `ATTACHMENT_MAX_BYTES` and nginx's `client_max_body_size` below it.
- **Long requests**: Cloudflare ends a request that gets no response for 100 seconds (error 524). Castra runs long
  work (exports, imports, retention) as background jobs, so normal use stays well inside that.

## 4. Check it

```sh
# From the host: Castra answers locally and nowhere else.
curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:8080/readyz
# From outside: the public address works through Cloudflare.
curl -s -o /dev/null -w '%{http_code}\n' https://castra.example.org/readyz
```

Then sign in, open a page and edit it in two browser windows at once (this checks WebSockets), and look at
Administration, Audit log: new entries should show your own address, not Cloudflare's or nginx's.

## What has and has not been tested

The Castra settings and the Compose binding are covered by the repository's checks. The nginx and Cloudflare
settings above follow nginx's and Cloudflare's documentation but have not been run against a live Cloudflare
zone by us. Cloudflare's address list and plan limits change: check them against Cloudflare's current pages.
