#!/bin/sh
#
# Build the release archives for one version, from the current checkout.
#
# Usage: scripts/release.sh VERSION
#
# VERSION must equal .version in build.zig.zon. Output in zig-out/release/:
#
#   accord-VERSION-<target>.tar.gz   one per target in TARGETS below
#   SHA256SUMS                       checksums of the archives
#   SHA256SUMS.minisig               only if MINISIGN_SECRET_KEY is set
#
# MINISIGN_SECRET_KEY is the path to a minisign secret key made with
# `minisign -G -W` (no password, as CI cannot type one). The signature is
# checked against minisign.pub in the repository (MINISIGN_PUBLIC_KEY to use
# another, for testing) before the script succeeds.
#
# Each archive holds bin/accord (ReleaseSafe, stripped), share/man/man{1,5,7},
# LICENSE, README.md and examples/. Archives are reproducible with GNU tar:
# file order, owners and mtimes are fixed, mtimes to the commit's date.

set -eu

# <archive name>=<zig target>. glibc builds need glibc 2.34 or newer
# (RHEL 9, Debian 12, Ubuntu 22.04); musl builds are static and run anywhere.
TARGETS="
aarch64-linux-gnu=aarch64-linux-gnu.2.34
x86_64-linux-gnu=x86_64-linux-gnu.2.34
aarch64-linux-musl=aarch64-linux-musl
x86_64-linux-musl=x86_64-linux-musl
aarch64-freebsd=aarch64-freebsd
x86_64-freebsd=x86_64-freebsd
"

REPO="$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)"
OUT="$REPO/zig-out/release"

fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
info() { printf '==> %s\n' "$*"; }

[ "$#" -eq 1 ] || fail "usage: $0 VERSION"
version="${1#v}"
zon_version="$(sed -n 's/^ *\.version = "\(.*\)",$/\1/p' "$REPO/build.zig.zon")"
[ "$version" = "$zon_version" ] || fail "version $version does not match build.zig.zon ($zon_version)"

cd "$REPO"
# The man page date and archive mtimes come from the commit, not the clock
epoch="$(git log -1 --format=%ct)"
date="$(git log -1 --format=%cs)"

rm -rf "$OUT"
mkdir -p "$OUT/stage"

if tar --version 2> /dev/null | grep -q 'GNU tar'; then
	tar_flags="--sort=name --mtime=@$epoch --owner=0 --group=0 --numeric-owner"
else
	# bsdtar (macOS): no mtime or sort control, so not reproducible
	tar_flags="--uid 0 --gid 0 --uname root --gname root --no-xattrs"
fi

for entry in $TARGETS; do
	name="${entry%%=*}"
	target="${entry#*=}"
	dir="accord-$version-$name"
	info "building $dir ($target)"
	zig build install -Doptimize=ReleaseSafe -Dstrip=true -Dtarget="$target" \
		-Ddate="$date" --prefix "$OUT/stage/$dir"
	cp LICENSE README.md "$OUT/stage/$dir/"
	cp -R examples "$OUT/stage/$dir/"
	# shellcheck disable=SC2086 # tar_flags is a list of flags
	(cd "$OUT/stage" && COPYFILE_DISABLE=1 tar $tar_flags -cf - "$dir") |
		gzip -9n > "$OUT/$dir.tar.gz"
done
rm -rf "$OUT/stage"

cd "$OUT"
if command -v sha256sum > /dev/null; then
	sha256sum accord-*.tar.gz > SHA256SUMS
else
	shasum -a 256 accord-*.tar.gz > SHA256SUMS
fi
info "checksums in $OUT/SHA256SUMS"

if [ -n "${MINISIGN_SECRET_KEY:-}" ]; then
	pubkey="${MINISIGN_PUBLIC_KEY:-$REPO/minisign.pub}"
	[ -f "$pubkey" ] || fail "no public key at $pubkey"
	minisign -S -s "$MINISIGN_SECRET_KEY" -m SHA256SUMS -t "accord $version SHA256SUMS" < /dev/null
	minisign -V -p "$pubkey" -m SHA256SUMS
	info "signed: $OUT/SHA256SUMS.minisig"
fi

ls -l "$OUT"
