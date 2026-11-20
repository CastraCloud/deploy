{{/* Names */}}
{{- define "castra.fullname" -}}
{{- if .Values.fullnameOverride -}}
{{- .Values.fullnameOverride | trunc 40 | trimSuffix "-" -}}
{{- else -}}
{{- $n := default .Chart.Name .Values.nameOverride -}}
{{- if contains $n .Release.Name -}}
{{- .Release.Name | trunc 40 | trimSuffix "-" -}}
{{- else -}}
{{- printf "%s-%s" .Release.Name $n | trunc 40 | trimSuffix "-" -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{- define "castra.secretName" -}}{{ include "castra.fullname" . }}-secrets{{- end -}}
{{- define "castra.hookSecretName" -}}{{ include "castra.fullname" . }}-hook-secrets{{- end -}}
{{- define "castra.serviceAccountName" -}}
{{- if .Values.serviceAccount.create -}}{{ default (include "castra.fullname" .) .Values.serviceAccount.name }}{{- else -}}{{ default "default" .Values.serviceAccount.name }}{{- end -}}
{{- end -}}

{{/* Labels. Call with the root context. */}}
{{- define "castra.labels" -}}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
app.kubernetes.io/name: castra
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/part-of: castra
{{- with .Values.commonLabels }}
{{ toYaml . }}
{{- end }}
{{- end -}}

{{/* Selector labels. Call with (dict "root" $ "component" "api"). */}}
{{- define "castra.selector" -}}
app.kubernetes.io/name: castra
app.kubernetes.io/instance: {{ .root.Release.Name }}
app.kubernetes.io/component: {{ .component }}
{{- end -}}

{{/* Image reference. Call with (dict "img" .Values.image.server "root" $). */}}
{{- define "castra.image" -}}
{{- if .img.digest -}}
{{- printf "%s@%s" .img.repository .img.digest -}}
{{- else -}}
{{- printf "%s:%s" .img.repository (default .root.Chart.AppVersion .img.tag) -}}
{{- end -}}
{{- end -}}

{{/* A value as a string. Whole numbers survive YAML parsing as floats, so write them without an exponent. */}}
{{- define "castra.str" -}}
{{- if kindIs "float64" . -}}{{ . | int64 }}{{- else -}}{{ . }}{{- end -}}
{{- end -}}

{{/* Adds a plain environment variable to a dict unless the value is unset or empty. (dict "e" $e "k" "NAME" "v" value) */}}
{{- define "castra.put" -}}
{{- if not (or (kindIs "invalid" .v) (and (kindIs "string" .v) (eq .v ""))) -}}
{{- $_ := set .e .k (include "castra.str" .v) -}}
{{- end -}}
{{- end -}}

{{/* A secret key reference. (dict "root" $ "cfg" .Values.x.password "k" "internal-key" "hook" false) */}}
{{- define "castra.sref" -}}
valueFrom:
  secretKeyRef:
{{- if .cfg.existingSecret }}
    name: {{ .cfg.existingSecret }}
    key: {{ default .k .cfg.key }}
{{- else }}
    name: {{ ternary (include "castra.hookSecretName" .root) (include "castra.secretName" .root) .hook }}
    key: {{ .k }}
{{- end }}
{{- end -}}

{{/* True (prints "true") when a secret item is available: an existing Secret or a value. */}}
{{- define "castra.has" -}}
{{- if or .existingSecret .value -}}true{{- end -}}
{{- end -}}

{{/* Whether sign-in is on: an issuer, or the bundled Keycloak. */}}
{{- define "castra.signIn" -}}
{{- if or .Values.signIn.oidc.issuer .Values.keycloak.enabled .Values.signIn.saml.idpEntityId -}}true{{- end -}}
{{- end -}}

{{/* "true" when staff sign in with OIDC (your provider or the bundled Keycloak). */}}
{{- define "castra.oidcOn" -}}
{{- if or .Values.signIn.oidc.issuer .Values.keycloak.enabled -}}true{{- end -}}
{{- end -}}

{{/* "true" when staff sign in with SAML 2.0. */}}
{{- define "castra.samlOn" -}}
{{- if .Values.signIn.saml.idpEntityId -}}true{{- end -}}
{{- end -}}

{{/* Public URL, with no trailing slash. */}}
{{- define "castra.publicUrl" -}}
{{- if .Values.publicUrl -}}
{{- trimSuffix "/" .Values.publicUrl -}}
{{- else if and .Values.ingress.enabled .Values.ingress.host -}}
{{- printf "%s://%s" (ternary "http" "https" (eq .Values.ingress.tls.mode "none")) .Values.ingress.host -}}
{{- else -}}
{{- fail "Set publicUrl (for example https://castra.example.com), or enable the ingress and set ingress.host." -}}
{{- end -}}
{{- end -}}

{{/* Where the browser reaches Draw.io. Empty when there is no diagram editing. */}}
{{- define "castra.drawioUrl" -}}
{{- if eq .Values.drawio.mode "external" -}}
{{- required "drawio.external.url is required when drawio.mode is external" .Values.drawio.external.url -}}
{{- else if eq .Values.drawio.mode "bundled" -}}
{{- if .Values.drawio.publicUrl -}}
{{- trimSuffix "/" .Values.drawio.publicUrl -}}
{{- else if and .Values.ingress.enabled .Values.drawio.host -}}
{{- printf "%s://%s" (ternary "http" "https" (eq .Values.ingress.tls.mode "none")) .Values.drawio.host -}}
{{- else -}}
{{- fail "The bundled Draw.io needs its own address. Set drawio.host (with the ingress) or drawio.publicUrl, or set drawio.mode to external or none." -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{/* Database host and port. */}}
{{- define "castra.dbHost" -}}
{{- if eq .Values.database.mode "bundled" -}}{{ include "castra.fullname" . }}-postgres{{- else -}}{{ required "database.external.host is required when database.mode is external" .Values.database.external.host }}{{- end -}}
{{- end -}}
{{- define "castra.dbPort" -}}
{{- if eq .Values.database.mode "bundled" -}}5432{{- else -}}{{ include "castra.str" .Values.database.external.port }}{{- end -}}
{{- end -}}

{{/* Hook annotations of the migrate Job and its Secret. With a bundled Postgres the first install has to run after the
     Postgres exists; with your own, it runs before. */}}
{{- define "castra.migrateHook" -}}
{{- if eq .Values.database.mode "bundled" -}}post-install,pre-upgrade{{- else -}}pre-install,pre-upgrade{{- end -}}
{{- end -}}

{{/* Server environment. (dict "root" $ "role" "api" "hook" false). The migrate Job passes hook=true and gets the owner
     password and the hook Secret. */}}
{{- define "castra.serverEnv" -}}
{{- $root := .root -}}
{{- $v := $root.Values -}}
{{- $hook := .hook -}}
{{- $full := include "castra.fullname" $root -}}
{{- $url := include "castra.publicUrl" $root -}}
{{- $signIn := include "castra.oidcOn" $root -}}
{{- $saml := $v.signIn.saml -}}
{{- $e := dict -}}
{{- $put := dict "e" $e -}}
{{- include "castra.put" (merge (dict "k" "LOG_LEVEL" "v" $v.logLevel) $put) -}}
{{- include "castra.put" (merge (dict "k" "CASTRA_PUBLIC_URL" "v" $url) $put) -}}
{{- include "castra.put" (merge (dict "k" "CASTRA_HSTS" "v" $v.signIn.hsts) $put) -}}
{{- include "castra.put" (merge (dict "k" "CASTRA_DEMO" "v" (ternary "true" "" $v.demo.enabled)) $put) -}}
{{- include "castra.put" (merge (dict "k" "CASTRA_EVENT_TRANSPORT" "v" $v.events.transport) $put) -}}
{{- /* The web proxy is one hop; when it believes the ingress's X-Forwarded-For, the ingress is a second. */ -}}
{{- include "castra.put" (merge (dict "k" "TRUST_PROXY" "v" (ternary "2" "1" (ne (toString $v.web.trustedProxies) ""))) $put) -}}
{{- if eq $v.events.transport "nats" -}}
{{- $natsUrl := printf "nats://%s-nats:4222" $full -}}
{{- if ne $v.nats.mode "bundled" -}}{{- $natsUrl = required "nats.url is required when nats.mode is external" $v.nats.url -}}{{- end -}}
{{- include "castra.put" (merge (dict "k" "NATS_URL" "v" $natsUrl) $put) -}}
{{- end -}}
{{- /* sign-in */ -}}
{{- if $v.keycloak.enabled -}}
{{- include "castra.put" (merge (dict "k" "OIDC_ISSUER" "v" (default (printf "%s/idp/realms/castra" $url) $v.signIn.oidc.issuer)) $put) -}}
{{- include "castra.put" (merge (dict "k" "OIDC_CLIENT_ID" "v" (default "castra" $v.signIn.oidc.clientId)) $put) -}}
{{- else -}}
{{- include "castra.put" (merge (dict "k" "OIDC_ISSUER" "v" $v.signIn.oidc.issuer) $put) -}}
{{- include "castra.put" (merge (dict "k" "OIDC_CLIENT_ID" "v" $v.signIn.oidc.clientId) $put) -}}
{{- end -}}
{{- if $signIn -}}
{{- include "castra.put" (merge (dict "k" "OIDC_REDIRECT_URI" "v" (default (printf "%s/auth/callback" $url) $v.signIn.oidc.redirectUri)) $put) -}}
{{- end -}}
{{- include "castra.put" (merge (dict "k" "OIDC_USERNAME_CLAIM" "v" $v.signIn.oidc.usernameClaim) $put) -}}
{{- include "castra.put" (merge (dict "k" "OIDC_GROUPS_CLAIM" "v" $v.signIn.oidc.groupsClaim) $put) -}}
{{- include "castra.put" (merge (dict "k" "OIDC_GROUP_PREFIX_FILTER" "v" $v.signIn.oidc.groupPrefixFilter) $put) -}}
{{- include "castra.put" (merge (dict "k" "OIDC_REQUIRED_GROUPS" "v" $v.signIn.oidc.requiredGroups) $put) -}}
{{- if include "castra.samlOn" $root -}}
{{- if $signIn -}}{{- fail "SAML and OIDC are both set. An installation signs staff in with one or the other: clear signIn.saml.idpEntityId, or signIn.oidc.issuer and keycloak.enabled." -}}{{- end -}}
{{- if not (or $saml.idpMetadataUrl $saml.idpMetadataFile) -}}{{- fail "signIn.saml needs idpMetadataUrl or idpMetadataFile." -}}{{- end -}}
{{- if and $saml.idpMetadataUrl $saml.idpMetadataFile -}}{{- fail "Set signIn.saml.idpMetadataUrl or idpMetadataFile, not both." -}}{{- end -}}
{{- if ne (not (include "castra.has" $saml.signingKey)) (not $saml.signingCert) -}}{{- fail "signIn.saml.signingKey and signingCert go together." -}}{{- end -}}
{{- end -}}
{{- include "castra.put" (merge (dict "k" "SAML_IDP_ENTITY_ID" "v" $saml.idpEntityId) $put) -}}
{{- include "castra.put" (merge (dict "k" "SAML_IDP_METADATA_URL" "v" $saml.idpMetadataUrl) $put) -}}
{{- include "castra.put" (merge (dict "k" "SAML_IDP_METADATA_FILE" "v" $saml.idpMetadataFile) $put) -}}
{{- include "castra.put" (merge (dict "k" "SAML_SP_ENTITY_ID" "v" $saml.spEntityId) $put) -}}
{{- include "castra.put" (merge (dict "k" "SAML_SP_SIGNING_CERT" "v" $saml.signingCert) $put) -}}
{{- include "castra.put" (merge (dict "k" "SAML_ATTR_USERNAME" "v" $saml.attributes.username) $put) -}}
{{- include "castra.put" (merge (dict "k" "SAML_ATTR_EMAIL" "v" $saml.attributes.email) $put) -}}
{{- include "castra.put" (merge (dict "k" "SAML_ATTR_DISPLAY_NAME" "v" $saml.attributes.displayName) $put) -}}
{{- include "castra.put" (merge (dict "k" "SAML_ATTR_GROUPS" "v" $saml.attributes.groups) $put) -}}
{{- include "castra.put" (merge (dict "k" "SAML_ATTR_SUBJECT" "v" $saml.attributes.subject) $put) -}}
{{- include "castra.put" (merge (dict "k" "SAML_EMAIL_VERIFIED" "v" $saml.emailVerified) $put) -}}
{{- include "castra.put" (merge (dict "k" "CASTRA_BOOTSTRAP_ORG_NAME" "v" $v.signIn.bootstrap.orgName) $put) -}}
{{- include "castra.put" (merge (dict "k" "CASTRA_BOOTSTRAP_ORG_SLUG" "v" $v.signIn.bootstrap.orgSlug) $put) -}}
{{- include "castra.put" (merge (dict "k" "CASTRA_BOOTSTRAP_ADMINS" "v" $v.signIn.bootstrap.admins) $put) -}}
{{- include "castra.put" (merge (dict "k" "CASTRA_BOOTSTRAP_JOIN_POLICY" "v" $v.signIn.bootstrap.joinPolicy) $put) -}}
{{- include "castra.put" (merge (dict "k" "CASTRA_OPERATORS" "v" $v.signIn.operators) $put) -}}
{{- include "castra.put" (merge (dict "k" "CASTRA_LICENCE_ACCEPTANCE" "v" $v.licence.acceptance) $put) -}}
{{- include "castra.put" (merge (dict "k" "SESSION_COOKIE_SECURE" "v" $v.signIn.session.cookieSecure) $put) -}}
{{- include "castra.put" (merge (dict "k" "SESSION_COOKIE_NAME" "v" $v.signIn.session.cookieName) $put) -}}
{{- include "castra.put" (merge (dict "k" "SESSION_IDLE_TIMEOUT_SECONDS" "v" $v.signIn.session.idleTimeoutSeconds) $put) -}}
{{- include "castra.put" (merge (dict "k" "SESSION_ABSOLUTE_TIMEOUT_SECONDS" "v" $v.signIn.session.absoluteTimeoutSeconds) $put) -}}
{{- /* email */ -}}
{{- include "castra.put" (merge (dict "k" "SMTP_HOST" "v" $v.email.smtp.host) $put) -}}
{{- include "castra.put" (merge (dict "k" "SMTP_PORT" "v" $v.email.smtp.port) $put) -}}
{{- include "castra.put" (merge (dict "k" "SMTP_USER" "v" $v.email.smtp.user) $put) -}}
{{- include "castra.put" (merge (dict "k" "SMTP_FROM" "v" $v.email.smtp.from) $put) -}}
{{- include "castra.put" (merge (dict "k" "SMTP_TLS" "v" $v.email.smtp.tls) $put) -}}
{{- include "castra.put" (merge (dict "k" "MAIL_DIGEST_WINDOW_SECONDS" "v" $v.email.digestWindowSeconds) $put) -}}
{{- include "castra.put" (merge (dict "k" "MAIL_MAX_ATTEMPTS" "v" $v.email.maxAttempts) $put) -}}
{{- include "castra.put" (merge (dict "k" "MAIL_REPLY_DOMAIN" "v" $v.email.replyDomain) $put) -}}
{{- include "castra.put" (merge (dict "k" "MAIL_OAUTH_MICROSOFT_CLIENT_ID" "v" $v.email.oauth.microsoft.clientId) $put) -}}
{{- include "castra.put" (merge (dict "k" "MAIL_OAUTH_MICROSOFT_TENANT" "v" $v.email.oauth.microsoft.tenant) $put) -}}
{{- include "castra.put" (merge (dict "k" "MAIL_OAUTH_GOOGLE_CLIENT_ID" "v" $v.email.oauth.google.clientId) $put) -}}
{{- include "castra.put" (merge (dict "k" "MAIL_REPLY_TOKEN_DAYS" "v" $v.email.replyTokenDays) $put) -}}
{{- /* web push */ -}}
{{- include "castra.put" (merge (dict "k" "WEB_PUSH_PUBLIC_KEY" "v" $v.push.publicKey) $put) -}}
{{- include "castra.put" (merge (dict "k" "WEB_PUSH_CONTACT" "v" $v.push.contact) $put) -}}
{{- /* inbound email */ -}}
{{- include "castra.put" (merge (dict "k" "MAIL_IN_IMAP_URL" "v" $v.inboundEmail.imap.url) $put) -}}
{{- include "castra.put" (merge (dict "k" "MAIL_IN_IMAP_USER" "v" $v.inboundEmail.imap.user) $put) -}}
{{- include "castra.put" (merge (dict "k" "MAIL_IN_IMAP_FOLDER" "v" $v.inboundEmail.imap.folder) $put) -}}
{{- include "castra.put" (merge (dict "k" "MAIL_IN_POLL_SECONDS" "v" $v.inboundEmail.imap.pollSeconds) $put) -}}
{{- include "castra.put" (merge (dict "k" "MAIL_IN_MAX_BYTES" "v" $v.inboundEmail.maxBytes) $put) -}}
{{- include "castra.put" (merge (dict "k" "MAIL_IN_RATE_PER_SENDER" "v" $v.inboundEmail.ratePerSender) $put) -}}
{{- include "castra.put" (merge (dict "k" "MAIL_IN_RATE_PER_PROJECT" "v" $v.inboundEmail.ratePerProject) $put) -}}
{{- include "castra.put" (merge (dict "k" "MAIL_IN_TRUSTED_AUTHSERV" "v" $v.inboundEmail.trustedAuthserv) $put) -}}
{{- include "castra.put" (merge (dict "k" "MAIL_IN_REQUIRE_DMARC_PASS" "v" $v.inboundEmail.requireDmarcPass) $put) -}}
{{- /* limits, webhooks, imports */ -}}
{{- include "castra.put" (merge (dict "k" "RATE_LIMIT_ENABLED" "v" $v.limits.rateLimitEnabled) $put) -}}
{{- include "castra.put" (merge (dict "k" "RATE_LIMIT_MAX" "v" $v.limits.rateLimitMax) $put) -}}
{{- include "castra.put" (merge (dict "k" "RATE_LIMIT_AUTH_MAX" "v" $v.limits.rateLimitAuthMax) $put) -}}
{{- include "castra.put" (merge (dict "k" "RATE_LIMIT_WINDOW_SECONDS" "v" $v.limits.rateLimitWindowSeconds) $put) -}}
{{- include "castra.put" (merge (dict "k" "RATE_LIMIT_TOKEN_MAX" "v" $v.limits.rateLimitTokenMax) $put) -}}
{{- include "castra.put" (merge (dict "k" "STATUS_RATE_LIMIT_PER_MINUTE" "v" $v.limits.statusRateLimitPerMinute) $put) -}}
{{- include "castra.put" (merge (dict "k" "STATUS_SUBSCRIBE_PER_HOUR" "v" $v.limits.statusSubscribePerHour) $put) -}}
{{- include "castra.put" (merge (dict "k" "STATUS_CACHE_SECONDS" "v" $v.limits.statusCacheSeconds) $put) -}}
{{- include "castra.put" (merge (dict "k" "API_TOKEN_MAX_DAYS" "v" $v.limits.apiTokenMaxDays) $put) -}}
{{- include "castra.put" (merge (dict "k" "AUTOMATION_MAX_RUNS_PER_HOUR" "v" $v.limits.automationMaxRunsPerHour) $put) -}}
{{- include "castra.put" (merge (dict "k" "SEARCH_EXPORT_MAX_ROWS" "v" $v.limits.searchExportMaxRows) $put) -}}
{{- include "castra.put" (merge (dict "k" "DB_STATEMENT_TIMEOUT_MS" "v" $v.limits.dbStatementTimeoutMs) $put) -}}
{{- include "castra.put" (merge (dict "k" "WEBHOOK_ALLOW_PRIVATE_CIDRS" "v" $v.webhooks.allowPrivateCidrs) $put) -}}
{{- include "castra.put" (merge (dict "k" "WEBHOOK_DISABLE_AFTER" "v" $v.webhooks.disableAfter) $put) -}}
{{- include "castra.put" (merge (dict "k" "IMPORT_ALLOW_PRIVATE_CIDRS" "v" $v.imports.allowPrivateCidrs) $put) -}}
{{- include "castra.put" (merge (dict "k" "LINK_PREVIEW_ALLOW_PRIVATE_CIDRS" "v" $v.linkPreviews.allowPrivateCidrs) $put) -}}
{{- include "castra.put" (merge (dict "k" "CASTRA_EXPORT_TTL_HOURS" "v" $v.advanced.exportTtlHours) $put) -}}
{{- include "castra.put" (merge (dict "k" "CASTRA_IMPORT_MAX_BYTES" "v" $v.advanced.importMaxBytes) $put) -}}
{{- include "castra.put" (merge (dict "k" "CASTRA_IMPORT_MAX_UNPACKED_BYTES" "v" $v.advanced.importMaxUnpackedBytes) $put) -}}
{{- include "castra.put" (merge (dict "k" "CASTRA_IMPORT_MAX_FILES" "v" $v.advanced.importMaxFiles) $put) -}}
{{- include "castra.put" (merge (dict "k" "CASTRA_IMPORT_MAX_PAGES" "v" $v.advanced.importMaxPages) $put) -}}
{{- include "castra.put" (merge (dict "k" "CASTRA_LIBRARY_EXPORT_MAX_PAGES" "v" $v.advanced.libraryExportMaxPages) $put) -}}
{{- /* metrics */ -}}
{{- if $v.metrics.enabled -}}
{{- include "castra.put" (merge (dict "k" "METRICS_ENABLED" "v" "true") $put) -}}
{{- end -}}
{{- /* storage, cache, diagrams */ -}}
{{- $creds := $v.storage.s3.credentials | default "keys" -}}
{{- if not (has $creds (list "keys" "aws-default")) -}}{{- fail "storage.s3.credentials must be one of: keys, aws-default" -}}{{- end -}}
{{- if eq $creds "aws-default" -}}
{{- if eq $v.storage.mode "bundled" -}}{{- fail "storage.s3.credentials=aws-default needs storage.mode=external: the bundled SeaweedFS uses fixed keys" -}}{{- end -}}
{{- if or (include "castra.has" $v.storage.accessKey) (include "castra.has" $v.storage.secretKey) -}}{{- fail "storage.accessKey and storage.secretKey must be unset with storage.s3.credentials=aws-default" -}}{{- end -}}
{{- end -}}
{{- include "castra.put" (merge (dict "k" "S3_CREDENTIALS" "v" $creds) $put) -}}
{{- $s3 := printf "http://%s-seaweedfs:8333" $full -}}
{{- if ne $v.storage.mode "bundled" -}}{{- $s3 = required "storage.external.endpoint is required when storage.mode is external" $v.storage.external.endpoint -}}{{- end -}}
{{- include "castra.put" (merge (dict "k" "S3_ENDPOINT" "v" $s3) $put) -}}
{{- include "castra.put" (merge (dict "k" "S3_REGION" "v" $v.storage.region) $put) -}}
{{- include "castra.put" (merge (dict "k" "S3_BUCKET" "v" $v.storage.bucket) $put) -}}
{{- include "castra.put" (merge (dict "k" "S3_FORCE_PATH_STYLE" "v" $v.storage.forcePathStyle) $put) -}}
{{- include "castra.put" (merge (dict "k" "ATTACHMENT_MAX_BYTES" "v" $v.storage.attachmentMaxBytes) $put) -}}
{{- if ne $v.previews.mode "none" -}}
{{- if not (has $v.previews.mode (list "bundled" "external")) -}}{{- fail "previews.mode must be one of: none, bundled, external" -}}{{- end -}}
{{- if and (eq $v.mode "full") (not $v.roles.preview.enabled) -}}{{- fail "previews need the preview role: set roles.preview.enabled=true, or previews.mode=none" -}}{{- end -}}
{{- $conv := printf "http://%s-previews:3000" $full -}}
{{- if eq $v.previews.mode "external" -}}{{- $conv = required "previews.external.url is required when previews.mode is external" $v.previews.external.url -}}{{- end -}}
{{- include "castra.put" (merge (dict "k" "PREVIEW_URL" "v" $conv) $put) -}}
{{- include "castra.put" (merge (dict "k" "PREVIEW_MAX_BYTES" "v" $v.previews.maxBytes) $put) -}}
{{- include "castra.put" (merge (dict "k" "PREVIEW_TIMEOUT_SECONDS" "v" $v.previews.timeoutSeconds) $put) -}}
{{- include "castra.put" (merge (dict "k" "PREVIEW_CONCURRENCY" "v" $v.previews.concurrency) $put) -}}
{{- end -}}
{{- if eq $v.valkey.mode "bundled" -}}
{{- include "castra.put" (merge (dict "k" "VALKEY_URL" "v" (printf "redis://%s-valkey:6379" $full)) $put) -}}
{{- end -}}
{{- include "castra.put" (merge (dict "k" "DRAWIO_URL" "v" (include "castra.drawioUrl" $root)) $put) -}}
{{- if $v.portal.host -}}
{{- include "castra.put" (merge (dict "k" "CASTRA_PORTAL_DOMAIN" "v" $v.portal.host) $put) -}}
{{- end -}}
{{- /* output */ -}}
- name: CASTRA_ROLE
  value: {{ .role | quote }}
- name: CASTRA_DB_PASSWORD
  {{- include "castra.sref" (dict "root" $root "cfg" (ternary $v.database.ownerPassword $v.database.appPassword $hook) "k" (ternary "db-owner-password" "db-app-password" $hook) "hook" $hook) | nindent 2 }}
- name: DATABASE_URL
  value: {{ printf "postgres://%s:$(CASTRA_DB_PASSWORD)@%s:%s/%s%s" (ternary "castra_owner" "castra_app" $hook) (include "castra.dbHost" $root) (include "castra.dbPort" $root) $v.database.name ($v.database.external.params | default "") | quote }}
{{- if $signIn }}
- name: OIDC_CLIENT_SECRET
  {{- include "castra.sref" (dict "root" $root "cfg" $v.signIn.oidc.clientSecret "k" "oidc-client-secret" "hook" $hook) | nindent 2 }}
{{- end }}
{{- if and (include "castra.samlOn" $root) (include "castra.has" $saml.signingKey) }}
- name: SAML_SP_SIGNING_KEY
  {{- include "castra.sref" (dict "root" $root "cfg" $saml.signingKey "k" "saml-signing-key" "hook" $hook) | nindent 2 }}
{{- end }}
{{- if or (include "castra.signIn" $root) (include "castra.has" $v.signIn.session.secret) }}
- name: SESSION_SECRET
  {{- include "castra.sref" (dict "root" $root "cfg" $v.signIn.session.secret "k" "session-secret" "hook" $hook) | nindent 2 }}
{{- end }}
{{- if or (include "castra.has" $v.webhooks.encryptionKey) $v.secrets.generate }}
- name: WEBHOOK_ENCRYPTION_KEY
  {{- include "castra.sref" (dict "root" $root "cfg" $v.webhooks.encryptionKey "k" "webhook-encryption-key" "hook" $hook) | nindent 2 }}
{{- end }}
{{- if include "castra.has" $v.email.smtp.password }}
- name: SMTP_PASSWORD
  {{- include "castra.sref" (dict "root" $root "cfg" $v.email.smtp.password "k" "smtp-password" "hook" $hook) | nindent 2 }}
{{- end }}
{{- if include "castra.has" $v.email.oauth.microsoft.clientSecret }}
- name: MAIL_OAUTH_MICROSOFT_CLIENT_SECRET
  {{- include "castra.sref" (dict "root" $root "cfg" $v.email.oauth.microsoft.clientSecret "k" "mail-oauth-microsoft-client-secret" "hook" $hook) | nindent 2 }}
{{- end }}
{{- if include "castra.has" $v.email.oauth.google.clientSecret }}
- name: MAIL_OAUTH_GOOGLE_CLIENT_SECRET
  {{- include "castra.sref" (dict "root" $root "cfg" $v.email.oauth.google.clientSecret "k" "mail-oauth-google-client-secret" "hook" $hook) | nindent 2 }}
{{- end }}
{{- if include "castra.has" $v.email.tokenSecret }}
- name: MAIL_TOKEN_SECRET
  {{- include "castra.sref" (dict "root" $root "cfg" $v.email.tokenSecret "k" "mail-token-secret" "hook" $hook) | nindent 2 }}
{{- end }}
{{- if include "castra.has" $v.push.privateKey }}
- name: WEB_PUSH_PRIVATE_KEY
  {{- include "castra.sref" (dict "root" $root "cfg" $v.push.privateKey "k" "push-private-key" "hook" $hook) | nindent 2 }}
{{- end }}
{{- if include "castra.has" $v.inboundEmail.imap.password }}
- name: MAIL_IN_IMAP_PASSWORD
  {{- include "castra.sref" (dict "root" $root "cfg" $v.inboundEmail.imap.password "k" "imap-password" "hook" $hook) | nindent 2 }}
{{- end }}
{{- if or $v.inboundEmail.webhook.enabled (include "castra.has" $v.inboundEmail.webhook.secret) }}
- name: MAIL_IN_WEBHOOK_SECRET
  {{- include "castra.sref" (dict "root" $root "cfg" $v.inboundEmail.webhook.secret "k" "mail-in-webhook-secret" "hook" $hook) | nindent 2 }}
{{- end }}
{{- if or $v.identity.file.configMap $v.identity.file.secret }}
- name: CASTRA_IDENTITY_CONFIG
  value: /etc/castra/identity.yaml
{{- end }}
{{- if $hook }}
{{- range $i, $n := list "IDENTITY_SECRET_1" "IDENTITY_SECRET_2" "IDENTITY_SECRET_3" }}
{{- $s := index $v.identity (printf "secret%d" (add1 $i)) }}
{{- if $s.existingSecret }}
- name: {{ $n }}
  valueFrom:
    secretKeyRef:
      name: {{ $s.existingSecret }}
      key: {{ required (printf "identity.secret%d.key is required with its existingSecret" (add1 $i)) $s.key }}
{{- end }}
{{- end }}
{{- end }}
{{- if $v.metrics.enabled }}
- name: METRICS_TOKEN
  {{- include "castra.sref" (dict "root" $root "cfg" $v.metrics.token "k" "metrics-token" "hook" $hook) | nindent 2 }}
{{- end }}
{{- if ne ($v.storage.s3.credentials | default "keys") "aws-default" }}
- name: S3_ACCESS_KEY
  {{- include "castra.sref" (dict "root" $root "cfg" $v.storage.accessKey "k" "s3-access-key" "hook" $hook) | nindent 2 }}
- name: S3_SECRET_KEY
  {{- include "castra.sref" (dict "root" $root "cfg" $v.storage.secretKey "k" "s3-secret-key" "hook" $hook) | nindent 2 }}
{{- end }}
{{- if eq $v.valkey.mode "external" }}
- name: VALKEY_URL
  {{- include "castra.sref" (dict "root" $root "cfg" $v.valkey.external.url "k" "valkey-url" "hook" $hook) | nindent 2 }}
{{- end }}
{{- range $k := keys $e | sortAlpha }}
- name: {{ $k }}
  value: {{ get $e $k | quote }}
{{- end }}
{{- with $v.extraEnv }}
{{ toYaml . }}
{{- end }}
{{- end -}}

{{/* A Castra server container. (dict "root" $ "role" "api" "hook" false "resources" {...}) */}}
{{- define "castra.serverContainer" -}}
- name: castra
  image: {{ include "castra.image" (dict "img" .root.Values.image.server "root" .root) | quote }}
  imagePullPolicy: {{ .root.Values.image.server.pullPolicy }}
  env:
    {{- include "castra.serverEnv" (dict "root" .root "role" .role "hook" .hook) | nindent 4 }}
  {{- with .root.Values.extraEnvFrom }}
  envFrom:
    {{- toYaml . | nindent 4 }}
  {{- end }}
  ports:
    - name: http
      containerPort: 8080
      protocol: TCP
  {{- if not .noProbes }}
  startupProbe:
    httpGet:
      path: /healthz
      port: http
    periodSeconds: 5
    failureThreshold: 36
  livenessProbe:
    httpGet:
      path: /healthz
      port: http
    periodSeconds: 15
    timeoutSeconds: 3
    failureThreshold: 3
  readinessProbe:
    httpGet:
      path: /readyz
      port: http
    periodSeconds: 10
    timeoutSeconds: 3
    failureThreshold: 3
  {{- end }}
  resources:
    {{- toYaml (default .root.Values.resources .resources) | nindent 4 }}
  securityContext:
    {{- toYaml .root.Values.securityContext | nindent 4 }}
  volumeMounts:
    - name: tmp
      mountPath: /tmp
    {{- if and (eq .role "migrate") (or .root.Values.identity.file.configMap .root.Values.identity.file.secret) }}
    - name: identity-file
      mountPath: /etc/castra/identity.yaml
      subPath: {{ .root.Values.identity.file.key }}
      readOnly: true
    {{- end }}
    {{- with .root.Values.extraVolumeMounts }}
    {{- toYaml . | nindent 4 }}
    {{- end }}
{{- end -}}

{{/* Scheduling settings shared by every pod. */}}
{{- define "castra.scheduling" -}}
{{- with .Values.nodeSelector }}
nodeSelector:
  {{- toYaml . | nindent 2 }}
{{- end }}
{{- with .Values.affinity }}
affinity:
  {{- toYaml . | nindent 2 }}
{{- end }}
{{- with .Values.tolerations }}
tolerations:
  {{- toYaml . | nindent 2 }}
{{- end }}
{{- end -}}

{{- define "castra.pullSecrets" -}}
{{- with .Values.imagePullSecrets }}
imagePullSecrets:
  {{- toYaml . | nindent 2 }}
{{- end }}
{{- end -}}

{{/* The list of Castra workloads for the chosen mode, as a list of dicts. */}}
{{- define "castra.workloads" -}}
{{- $items := list -}}
{{- if eq .Values.mode "minimal" -}}
{{- $items = append $items (dict "name" "app" "role" "all-in-one" "cfg" .Values.app) -}}
{{- else -}}
{{- range $name := list "api" "collab" "realtime" "worker-jobs" "worker-sla" "mail-in" "mail-out" "idp-sync" "indexer" "preview" -}}
{{- $cfg := get $.Values.roles $name -}}
{{- if $cfg.enabled -}}
{{- $items = append $items (dict "name" $name "role" $name "cfg" $cfg) -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- toJson $items -}}
{{- end -}}

{{/* Wait for Postgres. (dict "root" $) */}}
{{- define "castra.waitForDb" -}}
- name: wait-for-postgres
  image: {{ .root.Values.database.bundled.image | quote }}
  command:
    - sh
    - -c
    - |
      i=0
      until pg_isready -h "$DB_HOST" -p "$DB_PORT" -t 3; do
        i=$((i + 1))
        [ "$i" -lt 120 ] || { echo "Postgres did not answer in time" >&2; exit 1; }
        sleep 3
      done
  env:
    - name: DB_HOST
      value: {{ include "castra.dbHost" .root | quote }}
    - name: DB_PORT
      value: {{ include "castra.dbPort" .root | quote }}
  resources:
    requests:
      cpu: 10m
      memory: 16Mi
  securityContext:
    runAsNonRoot: true
    runAsUser: 999
    runAsGroup: 999
    allowPrivilegeEscalation: false
    readOnlyRootFilesystem: true
    capabilities:
      drop: [ALL]
    seccompProfile:
      type: RuntimeDefault
{{- end -}}
