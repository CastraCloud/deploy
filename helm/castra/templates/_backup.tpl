{{/* The Postgres dump step of a backup. (dict "root" $ "name" "dump" "dest" "/backups" "mount" "backups" "keep" 14)
     The same checks as compose/backup.sh: a non-empty custom-format dump, the number of migrations applied, a
     backup.info file and SHA256SUMS, and a check of the dump and the sums before it counts as made. */}}
{{- define "castra.backupDump" -}}
{{- $root := .root -}}
{{- $v := $root.Values -}}
{{- $bundled := eq $v.database.mode "bundled" -}}
- name: {{ .name }}
  image: {{ $v.database.bundled.image | quote }}
  command:
    - sh
    - -c
    - |
      set -eu
      stamp=$(date -u +%Y%m%dT%H%M%SZ)
      out="$DEST/castra-$stamp"
      mkdir -p "$out"
      chmod 700 "$out"
      trap 'rc=$?; if [ "$rc" -ne 0 ]; then rm -rf "$out"; echo "backup: failed, the partial backup was removed" >&2; fi' EXIT
      echo "Dumping the database (custom format)"
      pg_dump --format=custom > "$out/database.dump.part"
      mv "$out/database.dump.part" "$out/database.dump"
      [ -s "$out/database.dump" ] || { echo "backup: the database dump is empty" >&2; exit 1; }
      pg_restore --list "$out/database.dump" > /dev/null
      migrations=$(psql -Atc 'select count(*) from drizzle.__drizzle_migrations' | tr -d '[:space:]')
      {
        echo "created_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
        echo "castra_version=$CASTRA_VERSION"
        echo "migrations_applied=$migrations"
        echo "objects=none"
      } > "$out/backup.info"
      (cd "$out" && sha256sum database.dump backup.info > SHA256SUMS && sha256sum -c SHA256SUMS)
      echo "Backup written to $out"
      if [ -n "${KEEP:-}" ]; then
        # Only directories this job made (castra-YYYYMMDDTHHMMSSZ) are ever removed.
        find "$DEST" -mindepth 1 -maxdepth 1 -type d -name 'castra-????????T??????Z' | sort -r \
          | tail -n +$((KEEP + 1)) | while IFS= read -r old; do
            echo "Removing old backup $old"
            rm -rf "$old"
          done
      fi
  env:
    - name: DEST
      value: {{ .dest | quote }}
    {{- with .keep }}
    - name: KEEP
      value: {{ include "castra.str" . | quote }}
    {{- end }}
    - name: CASTRA_VERSION
      value: {{ default $root.Chart.AppVersion $v.image.server.tag | quote }}
    - name: PGHOST
      value: {{ include "castra.dbHost" $root | quote }}
    - name: PGPORT
      value: {{ include "castra.dbPort" $root | quote }}
    - name: PGDATABASE
      value: {{ $v.database.name | quote }}
    - name: PGUSER
      value: {{ ternary $v.database.bundled.user $v.backup.database.user $bundled | quote }}
    - name: PGPASSWORD
      {{- if $bundled }}
      {{- include "castra.sref" (dict "root" $root "cfg" $v.database.bundled.superuserPassword "k" "db-superuser-password" "hook" false) | nindent 6 }}
      {{- else }}
      {{- include "castra.sref" (dict "root" $root "cfg" $v.backup.database.password "k" "backup-db-password" "hook" false) | nindent 6 }}
      {{- end }}
    {{- with $v.backup.extraEnv }}
    {{- toYaml . | nindent 4 }}
    {{- end }}
  resources:
    {{- toYaml (default (dict "requests" (dict "cpu" "50m" "memory" "128Mi")) $v.backup.resources) | nindent 4 }}
  securityContext:
    allowPrivilegeEscalation: false
    readOnlyRootFilesystem: true
    capabilities:
      drop: [ALL]
  volumeMounts:
    - name: {{ .mount }}
      mountPath: {{ .dest }}
    - name: tmp
      mountPath: /tmp
{{- end -}}
