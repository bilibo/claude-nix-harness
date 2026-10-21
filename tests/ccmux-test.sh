#!/usr/bin/env bash
#   ccmux-test.sh <path-to-ccmux-or-ccode>
#
# `ccmux -n` prints the resolution instead of touching tmux, so this runs
# anywhere. flake.nix runs it once per entry point (ccmux and the ccode alias).
set -uo pipefail
ccmux="${1:?usage: ccmux-test.sh <ccmux>}"
pass=0; fail=0
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
root="$tmp/code/git"
mkdir -p "$root/acme/infra/modules/net" "$root/acme/infra/.claude/worktrees/wt1" "$root/acme/app" "$tmp/elsewhere"
export HARNESS_CODE_ROOT="$root"
unset HARNESS_PROJECT

# check <want-exit> <want-output-regex> <cwd> <args...>
check() {
  local want="$1" re="$2" dir="$3"; shift 3
  local out got
  out=$(cd "$dir" && "$ccmux" -n "$@" 2>&1); got=$?
  if [ "$got" = "$want" ] && [[ "$out" =~ $re ]]; then pass=$((pass+1)); else
    fail=$((fail+1)); echo "FAIL (want $want /$re/, got $got): cd $dir && ccmux -n $*"; echo "  $out"; fi
}
ok() { check 0 "$@"; }

# Explicit <customer>/<repo>, from anywhere.
ok "session=acme-infra repo=$root/acme/infra" "$tmp/elsewhere" acme/infra
ok "session=acme-infra repo=$root/acme/infra args=--worktree" "$tmp/elsewhere" acme/infra --worktree
ok "session=acme-app repo=$root/acme/app" "$root/acme/infra" acme/app
# No argument: the repo containing the current directory.
ok "session=acme-infra repo=$root/acme/infra" "$root/acme/infra"
ok "session=acme-infra repo=$root/acme/infra" "$root/acme/infra/modules/net"
ok "session=acme-infra repo=$root/acme/infra" "$root/acme/infra/.claude/worktrees/wt1"
# Only claude args: project from the current directory.
ok "session=acme-infra repo=$root/acme/infra args=-p hi" "$root/acme/infra" -p hi
ok "session=acme-infra repo=$root/acme/infra args=--worktree" "$root/acme/infra/modules" --worktree
# A path instead of a name.
ok "session=acme-infra repo=$root/acme/infra" "$tmp/elsewhere" "$root/acme/infra"
ok "session=acme-infra repo=$root/acme/infra" "$root/acme" infra
ok "session=acme-infra repo=$root/acme/infra" "$root/acme/infra" .
ok "session=acme-app repo=$root/acme/app" "$root/acme/infra" ../app
# A name with more than two segments is the repo containing it, like a path.
ok "session=acme-infra repo=$root/acme/infra" "$tmp/elsewhere" acme/infra/modules/net
# The code root may be a symlink.
ln -s "$root" "$tmp/link"
HARNESS_CODE_ROOT="$tmp/link" ok "session=acme-infra repo=$root/acme/infra" "$tmp/elsewhere" acme/infra
HARNESS_CODE_ROOT="$tmp/link" ok "session=acme-infra repo=$root/acme/infra" "$root/acme/infra/modules"
# HARNESS_PROJECT (exported by the devenv shell) wins over cwd.
HARNESS_PROJECT=acme/app ok "session=acme-app repo=$root/acme/app" "$root/acme/infra"
# A clone outside the root: the devenv shell exports the project and its dir.
mkdir -p "$tmp/elsewhere/harness"
HARNESS_PROJECT=local/harness HARNESS_PROJECT_DIR="$tmp/elsewhere/harness" ok "session=local-harness repo=$tmp/elsewhere/harness" "$tmp/elsewhere/harness"
HARNESS_PROJECT=local/harness HARNESS_PROJECT_DIR="$tmp/elsewhere/harness" ok "session=local-harness repo=$tmp/elsewhere/harness args=-p hi" "$tmp" -p hi
# An explicit project still wins over the exported one.
HARNESS_PROJECT=local/harness HARNESS_PROJECT_DIR="$tmp/elsewhere/harness" ok "session=acme-app repo=$root/acme/app" "$tmp" acme/app
# Failures: outside the root, missing repo, customer only.
check 64 "usage" "$tmp/elsewhere"
# No HARNESS_CODE_ROOT at all (install.sh route): the default root under $HOME, and usage still prints.
out=$(cd "$tmp/elsewhere" && env -u HARNESS_CODE_ROOT HOME="$tmp" "$ccmux" -n 2>&1); got=$?
if [ "$got" = 64 ] && [[ "$out" =~ usage ]]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: without HARNESS_CODE_ROOT: got $got: $out"; fi
check 66 "no such repo" "$tmp/elsewhere" acme/missing
check 66 "no such repo" "$tmp/elsewhere" infra
check 66 "not under" "$tmp" elsewhere
check 66 "not under" "$root" acme

echo "ccmux-test ($(basename "$ccmux")): $pass passed, $fail failed"
[ "$fail" = 0 ]
