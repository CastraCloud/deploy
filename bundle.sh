#!/usr/bin/env bash
# Makes an offline bundle: every image Castra runs plus these deploy files, in one archive you can carry to a
# host with no internet access. Run it on a machine that has internet and Docker. On the other host, run load.sh.
#
#   ./bundle.sh --version 1.2.3 [--arch amd64|arm64] [--out DIR] [--profiles a,b] [--no-verify]
#
# The image list is read from compose/compose.yml (and compose/.env, if there is one, for CASTRA_VERSION and
# any CASTRA_IMAGE_* you set). By default it covers every profile; --profiles narrows it, for example
# --profiles minimal,identity to leave out the images the full profile and the dev tools use.
#
# Output (in --out, default the current directory):
#   castra-offline-<version>-<arch>.tar.gz          images, deploy files and SHA256SUMS
#   castra-offline-<version>-<arch>.tar.gz.sha256   the checksum of the archive, for the transfer
# Copy both and load.sh to the other host. The archive holds no secrets.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
compose_dir="$here/compose"
version=""
arch=""
out="$PWD"
profiles="*"
verify=1

say() { printf '%s\n' "$*"; }
die() { printf 'bundle: %s\n' "$*" >&2; exit 1; }

while [ $# -gt 0 ]; do
  case "$1" in
    --version) [ $# -ge 2 ] || die "--version needs a value"; version="$2"; shift 2 ;;
    --arch) [ $# -ge 2 ] || die "--arch needs amd64 or arm64"; arch="$2"; shift 2 ;;
    --out) [ $# -ge 2 ] || die "--out needs a directory"; out="$2"; shift 2 ;;
    --profiles) [ $# -ge 2 ] || die "--profiles needs a comma-separated list"; profiles="$2"; shift 2 ;;
    --no-verify) verify=0; shift ;;
    -h | --help) sed -n '2,16p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "unknown option: $1" ;;
  esac
done

if [ -z "$arch" ]; then
  case "$(uname -m)" in x86_64 | amd64) arch=amd64 ;; aarch64 | arm64) arch=arm64 ;; *) die "unknown architecture $(uname -m): use --arch" ;; esac
fi
case "$arch" in amd64 | arm64) ;; *) die "--arch must be amd64 or arm64" ;; esac
[[ "$version" =~ ^[0-9A-Za-z][0-9A-Za-z._-]*$ ]] || die "give the Castra version with --version, for example 1.2.3"
command -v docker > /dev/null 2>&1 || die "docker is not installed"
docker compose version > /dev/null 2>&1 || die "Docker Compose v2 is missing"
docker info > /dev/null 2>&1 || die "cannot talk to the Docker daemon"
[ -f "$compose_dir/compose.yml" ] || die "compose/compose.yml not found next to bundle.sh"
mkdir -p "$out"

# The same notice install.sh shows. Accepting happens in install.sh.
say "Castra is free to install and use for your own organisation, under the Castra Licence."
say "It is not open source, and it may not be offered to others as a hosted service."
say "The full text is in LICENSE-castra.md in this folder, and at"
say "https://github.com/CastraCloud/deploy/blob/main/LICENSE-castra.md"
say ""

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# ---- the image list
# A real .env supplies CASTRA_VERSION and any image overrides; --version wins. Without one, a throwaway file stands
# in, because the Compose file asks for values (never used here) before it will list anything.
{
  if [ -f "$compose_dir/.env" ]; then
    grep -E '^(CASTRA_IMAGE_SERVER|CASTRA_IMAGE_WEB)=' "$compose_dir/.env" || true
  fi
  for v in POSTGRES_PASSWORD CASTRA_DB_OWNER_PASSWORD CASTRA_DB_APP_PASSWORD S3_ACCESS_KEY S3_SECRET_KEY \
    KEYCLOAK_ADMIN_PASSWORD; do echo "$v=unused"; done
  echo "CASTRA_VERSION=$version"
} > "$work/list.env"
env_args=(--env-file "$work/list.env")
profile_args=()
IFS=',' read -r -a plist <<< "$profiles"
for p in "${plist[@]}"; do profile_args+=(--profile "$p"); done

docker compose -f "$compose_dir/compose.yml" "${env_args[@]}" "${profile_args[@]}" config --images | sort -u > "$work/images.list"
[ -s "$work/images.list" ] || die "no images found in the Compose file"
say "Images for Castra $version on $arch:"
sed 's/^/  /' "$work/images.list"

# ---- pull and verify
for img in $(cat "$work/images.list"); do
  say "Pulling $img"
  docker pull --platform "linux/$arch" "$img" > /dev/null || die "could not pull $img"
  got="$(docker image inspect --format '{{.Architecture}}' "$img" 2> /dev/null || true)"
  [ "$got" = "$arch" ] || die "$img is $got, not $arch. Cross-architecture bundles need Docker's containerd image store; run this on a $arch machine instead"
done

if [ "$verify" = 1 ]; then
  if command -v cosign > /dev/null 2>&1; then
    for img in $(grep '^ghcr.io/castracloud/castra-' "$work/images.list" || true); do
      say "Verifying the signature of $img"
      cosign verify "$img" \
        --certificate-oidc-issuer https://token.actions.githubusercontent.com \
        --certificate-identity-regexp '^https://github\.com/CastraCloud/castra/\.github/workflows/ci\.yml@refs/tags/v.*$' > /dev/null 2>&1 \
        || die "the signature of $img could not be verified. No bundle was made"
    done
  else
    say "cosign is not installed: Castra's signatures were not checked (see README, \"Images\")"
  fi
fi

# ---- assemble
name="castra-offline-$version-$arch"
stage="$work/$name"
mkdir -p "$stage/deploy"
say "Saving images (this takes a while)"
# shellcheck disable=SC2046
docker save -o "$stage/images.tar" $(cat "$work/images.list") || die "docker save failed"
{ echo "# castra offline bundle"; echo "version=$version"; echo "arch=$arch"; sed 's/^/image=/' "$work/images.list"; } > "$stage/images.list"

(
  cd "$here"
  files=(compose install.sh load.sh bundle.sh README.md UPGRADING.md)
  for f in CHANGELOG.md install.answers.example; do [ -e "$f" ] && files+=("$f"); done
  # Never carry a real .env, a first-admin note or a certificate that happens to be in the folder.
  tar -cf - --exclude='compose/.env' --exclude='compose/.env.*' --exclude='compose/first-admin.txt' \
    --exclude='compose/castra-root-ca.crt' --exclude='compose/backups' "${files[@]}"
) | tar -C "$stage/deploy" -xf -

(cd "$stage" && find . -type f ! -name SHA256SUMS -print0 | sort -z | xargs -0 sha256sum > SHA256SUMS)

say "Compressing"
tar -C "$work" -czf "$out/$name.tar.gz" "$name"
(cd "$out" && sha256sum "$name.tar.gz" > "$name.tar.gz.sha256")

say ""
say "Made $out/$name.tar.gz ($(du -h "$out/$name.tar.gz" | cut -f1))"
say "Copy it, $name.tar.gz.sha256 and load.sh to the offline host, then run:"
say "  ./load.sh $name.tar.gz"
