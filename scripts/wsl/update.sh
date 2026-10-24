#!/bin/sh
# Pull-only update of a NixOS-WSL host, run as root by install-wsl.ps1
# or by hand:
#   sudo sh wsl/update.sh <output> [--switch|--no-switch]
#
# /etc/nixos is the checkout wsl/bootstrap.sh made. Changes are committed
# elsewhere, pulled here with --ff-only and switched to; this box never
# commits, and a dirty tree stops the update.
set -eu

OUT="${1:?nixosConfigurations attribute}"
SWITCH=1
[ "${2:-}" = "--no-switch" ] && SWITCH=0

REPO=/etc/nixos
OWNER="$(stat -c %U "$REPO")"
export NIX_CONFIG="experimental-features = nix-command flakes"
as_owner() { runuser -u "$OWNER" -- env NIX_CONFIG="$NIX_CONFIG" "$@"; }
og() { as_owner git -C "$REPO" "$@"; }

[ -d "$REPO/.git" ] || { echo "$REPO is not a git checkout; run wsl/bootstrap.sh first" >&2; exit 2; }
command -v git >/dev/null 2>&1 || { echo "git is not on PATH; add pkgs.git to the host configuration" >&2; exit 2; }
echo "== $REPO (owner $OWNER) -> #$OUT"

if [ -n "$(og status --porcelain)" ]; then
  echo "working tree is dirty and this box is pull-only:" >&2
  og status --short >&2
  echo "discard with:  git -C $REPO checkout -- . && git -C $REPO clean -fd" >&2
  exit 3
fi

if og remote get-url origin >/dev/null 2>&1; then
  echo "== git pull --ff-only"
  og pull --ff-only
else
  echo "== no remote 'origin'; building what is committed locally"
  echo "   add one with:  git -C $REPO remote add origin <url> && git -C $REPO branch -u origin/main"
fi
og log --oneline -n 3

echo "== build #$OUT as $OWNER"
LOG=/tmp/nixos-build.log
if ! T=$(as_owner nix build "$REPO#nixosConfigurations.$OUT.config.system.build.toplevel" \
          --no-link --print-out-paths --no-write-lock-file 2> "$LOG"); then
  grep -v '^copying path' "$LOG" | tail -n 60
  echo "== build FAILED (full log: $LOG)" >&2
  exit 1
fi
echo "$T"

if [ "$T" = "$(readlink /run/current-system)" ]; then
  echo "== already running this system; nothing to activate"
  exit 0
fi
if [ "$SWITCH" -eq 1 ]; then
  echo "== activate"
  nix-env -p /nix/var/nix/profiles/system --set "$T"
  "$T/bin/switch-to-configuration" switch 2>&1 | tail -n 40
else
  echo "== built, not activated. To switch:"
  echo "   sudo nix-env -p /nix/var/nix/profiles/system --set $T"
  echo "   sudo $T/bin/switch-to-configuration switch"
  echo "   then from Windows: wsl -t <distro>"
fi
echo "== current system"
readlink /run/current-system
