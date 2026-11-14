#!/usr/bin/env bash
# Loads an offline bundle (made by bundle.sh) on a host without internet access: checks the checksums, loads the
# images into Docker and unpacks the deploy files. It does not start Castra: run ./install.sh --offline afterwards.
#
#   ./load.sh castra-offline-1.2.3-amd64.tar.gz [target-directory]     (default target: ./castra)
#
# Keep castra-offline-1.2.3-amd64.tar.gz.sha256 next to the archive: it is checked first. An existing
# compose/.env in the target is never touched, so this is also how you carry an upgrade to an offline host.
set -euo pipefail

say() { printf '%s\n' "$*"; }
die() { printf 'load: %s\n' "$*" >&2; exit 1; }

force_arch=0
args=()
for a in "$@"; do
  case "$a" in
    --force-arch) force_arch=1 ;;
    -h | --help) sed -n '2,9p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) args+=("$a") ;;
  esac
done
archive="${args[0]:-}"
target="${args[1]:-$PWD/castra}"
[ -n "$archive" ] && [ -f "$archive" ] || die "usage: ./load.sh ARCHIVE.tar.gz [TARGET_DIR]"
command -v docker > /dev/null 2>&1 || die "docker is not installed"
docker info > /dev/null 2>&1 || die "cannot talk to the Docker daemon"

# 1. The archive as transferred.
if [ -f "$archive.sha256" ]; then
  (cd "$(dirname "$archive")" && sha256sum --check --quiet "$(basename "$archive").sha256") \
    || die "the archive does not match $archive.sha256: it was damaged or changed in transit. Nothing was loaded"
  say "Archive checksum ok"
else
  say "warning: no $archive.sha256 next to the archive: only the checksums inside it will be checked" >&2
fi

# 2. Unpack to a scratch folder and check every file inside, before anything reaches Docker or the target.
if tar -tzf "$archive" | grep -Eq '^/|(^|/)\.\.(/|$)'; then
  die "the archive holds absolute or parent paths: refusing to unpack it"
fi
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
tar -xzf "$archive" -C "$work"
dir="$(find "$work" -mindepth 1 -maxdepth 1 -type d | head -n 1)"
[ -n "$dir" ] && [ -f "$dir/SHA256SUMS" ] || die "this does not look like a Castra offline bundle (no SHA256SUMS)"
(cd "$dir" && sha256sum --check --quiet SHA256SUMS) || die "a file in the bundle does not match SHA256SUMS. Nothing was loaded"
say "Bundle checksums ok"

# 3. The right architecture for this host.
want="$(sed -n 's/^arch=//p' "$dir/images.list")"
case "$(uname -m)" in x86_64 | amd64) have=amd64 ;; aarch64 | arm64) have=arm64 ;; *) have="$(uname -m)" ;; esac
if [ "$want" != "$have" ] && [ "$force_arch" = 0 ]; then
  die "this bundle is for $want and this host is $have. Make a bundle for $have, or pass --force-arch"
fi

# 4. Images.
say "Loading images (this takes a while)"
docker load -i "$dir/images.tar" > /dev/null || die "docker load failed"
while IFS= read -r img; do
  docker image inspect "$img" > /dev/null 2>&1 || die "image $img is missing after loading"
done < <(sed -n 's/^image=//p' "$dir/images.list")

# 5. Deploy files. compose/.env is never in the bundle, and an existing one stays.
mkdir -p "$target"
cp -R "$dir/deploy/." "$target/"
chmod +x "$target/install.sh" "$target/load.sh" "$target/bundle.sh" "$target/compose/castra.sh" "$target/compose/backup.sh" "$target/compose/restore.sh" 2> /dev/null || true

say ""
say "Loaded Castra $(sed -n 's/^version=//p' "$dir/images.list") ($want) into $target"
say "Next: cd $target && ./install.sh --offline"
