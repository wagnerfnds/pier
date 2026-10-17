#!/bin/sh
# Installs pierd, the Pier box server, and sets it up:
#
#   curl -fsSL https://docktopier.com/install.sh | sh
#
# It downloads the latest pierd release for this OS and CPU from GitHub (github.com/wagnerfnds/pier), checks it
# against the release's checksums, puts it in ~/.local/bin and runs `pierd setup`: Claude Code, Codex and the GitHub
# CLI in ~/.local/bin where they are missing (no sudo), pierd as a user service, the agents' hooks, your git
# repositories as projects, and a pairing link (on a Mac, the Pier app pairs by itself).
# Arguments go to `pierd setup` (`sh -s -- --no-projects`); PIERD_VERSION=1.2.3 picks a release; PIERD_NO_SETUP=1
# only installs; PIERD_NO_TOOLS=1 leaves Claude Code, Codex and the GitHub CLI alone (setup reads it);
# PIERD_DOWNLOAD=<url> downloads the release's files from a mirror.
set -eu

repo=wagnerfnds/pier
bindir=$HOME/.local/bin

say() { printf '%s\n' "$*"; }
fail() { say "pierd install: $*" >&2; exit 1; }

case $(uname -s) in
  Linux) os=linux ;;
  Darwin) os=darwin ;;
  *) fail "pierd runs on Linux and macOS, not $(uname -s)" ;;
esac
case $(uname -m) in
  x86_64 | amd64) arch=amd64 ;;
  arm64 | aarch64) arch=arm64 ;;
  *) fail "no pierd build for $(uname -m) (x86-64 and arm64 only)" ;;
esac
command -v curl >/dev/null 2>&1 || fail "curl is needed"
command -v tar >/dev/null 2>&1 || fail "tar is needed"

version=${PIERD_VERSION:-}
if [ -z "$version" ]; then
  # The newest pierd-v* release of the repository (the app is not released there).
  version=$(curl -fsSL "https://api.github.com/repos/$repo/releases?per_page=30" |
    sed -n 's/.*"tag_name": *"pierd-v\([^"]*\)".*/\1/p' | head -n 1)
  [ -n "$version" ] || fail "could not find a pierd release on github.com/$repo/releases"
fi
version=${version#v}

name=pierd-v$version-$os-$arch
base=${PIERD_DOWNLOAD:-https://github.com/$repo/releases/download/pierd-v$version}
tmp=$(mktemp -d)
trap 'rc=$?; rm -rf "$tmp"; exit $rc' EXIT
trap 'exit 130' INT TERM

say "Downloading pierd v${version} for ${os}/${arch}..."
curl -fsSL "$base/$name.tar.gz" -o "$tmp/$name.tar.gz" || fail "could not download $base/$name.tar.gz"
curl -fsSL "$base/checksums.txt" -o "$tmp/checksums.txt" || fail "could not download the release's checksums"
want=$(sed -n "s/^\([0-9a-f]\{64\}\)  $name\.tar\.gz\$/\1/p" "$tmp/checksums.txt")
if command -v sha256sum >/dev/null 2>&1; then
  got=$(sha256sum "$tmp/$name.tar.gz" | cut -d' ' -f1)
else
  got=$(shasum -a 256 "$tmp/$name.tar.gz" | cut -d' ' -f1)
fi
[ -n "$want" ] && [ "$want" = "$got" ] || fail "checksum mismatch for $name.tar.gz"

tar -xzf "$tmp/$name.tar.gz" -C "$tmp"
mkdir -p "$bindir"
cp "$tmp/$name/pierd" "$bindir/pierd.new" && chmod 755 "$bindir/pierd.new" && mv "$bindir/pierd.new" "$bindir/pierd"
say "Installed $bindir/pierd ($("$bindir/pierd" version))"
case ":$PATH:" in
  *":$bindir:"*) ;;
  *) say "Note: $bindir is not on your PATH; add it to run pierd by name (export PATH=\"\$HOME/.local/bin:\$PATH\")." ;;
esac

[ "${PIERD_NO_SETUP:-}" = 1 ] && exit 0
say ""
exec "$bindir/pierd" setup "$@"
