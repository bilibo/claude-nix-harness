#!/usr/bin/env bash
#   ccmux-test.sh <path-to-ccmux>
#
# `ccmux -n` prints the resolution instead of touching tmux, so most of this
# runs anywhere; the live cases at the end start a private tmux server (the
# tmux ccmux runs) and never touch the user's. The claude ccmux puts in the
# window: from PATH (a stub first on it, for every case that is not about
# where claude comes from), else from the repo's devenv shell through a
# stub direnv, else an error naming harness.claudeCode.enable.
set -uo pipefail
ccmux="${1:?usage: ccmux-test.sh <ccmux>}"
pass=0; fail=0
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
root="$tmp/code/git"
mkdir -p "$root/acme/infra/modules/net" "$root/acme/infra/.claude/worktrees/wt1" "$root/acme/app" "$tmp/elsewhere" "$tmp/hostbin"
export HARNESS_CODE_ROOT="$root"
unset HARNESS_PROJECT HARNESS_PROJECT_DIR HARNESS_ROLE
nl=$'\n'
printf '#!/bin/sh\nexit 0\n' >"$tmp/hostbin/claude"; chmod +x "$tmp/hostbin/claude"
export PATH="$tmp/hostbin:$PATH"
cl="${nl}claude=$tmp/hostbin/claude \\(PATH\\)$" # the last line of -n, with claude from PATH

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
# HARNESS_ROLE (exported with HARNESS_PROJECT) names the window and goes into
# it when the window opens the shell's own project, named or not.
ok "session=acme-infra repo=$root/acme/infra${nl}role=unset window=claude${cl}" "$root/acme/infra"
HARNESS_PROJECT=acme/infra HARNESS_ROLE=work ok "session=acme-infra repo=$root/acme/infra${nl}role=work window=work${cl}" "$root/acme/infra/modules"
HARNESS_PROJECT=acme/infra HARNESS_ROLE=work ok "args=--worktree${nl}role=work window=work${cl}" "$tmp/elsewhere" acme/infra --worktree
HARNESS_PROJECT=local/harness HARNESS_PROJECT_DIR="$tmp/elsewhere/harness" HARNESS_ROLE=center ok "session=local-harness repo=$tmp/elsewhere/harness${nl}role=center window=center${cl}" "$tmp/elsewhere/harness"
# The center launching a work repo: the window does not get `center`.
HARNESS_PROJECT=local/harness HARNESS_PROJECT_DIR="$tmp/elsewhere/harness" HARNESS_ROLE=center ok "session=acme-app repo=$root/acme/app args=--worktree${nl}role=unset window=claude \(HARNESS_ROLE=center is for local/harness\)${cl}" "$tmp/elsewhere/harness" acme/app --worktree
HARNESS_PROJECT=acme/infra HARNESS_ROLE=center ok "session=acme-app .*${nl}role=unset window=claude " "$root/acme/infra" ../app
# A role that is not a word never reaches tmux.
HARNESS_PROJECT=acme/infra HARNESS_ROLE='x; y' check 66 "HARNESS_ROLE is not a role name" "$root/acme/infra"
# Failures: outside the root, missing repo, customer only.
check 64 "usage" "$tmp/elsewhere"
# No HARNESS_CODE_ROOT at all (install.sh route): the default root under $HOME, and usage still prints.
out=$(cd "$tmp/elsewhere" && env -u HARNESS_CODE_ROOT HOME="$tmp" "$ccmux" -n 2>&1); got=$?
if [ "$got" = 64 ] && [[ "$out" =~ usage ]]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: without HARNESS_CODE_ROOT: got $got: $out"; fi
check 66 "no such repo" "$tmp/elsewhere" acme/missing
check 66 "no such repo" "$tmp/elsewhere" infra
check 66 "not under" "$tmp" elsewhere
check 66 "not under" "$root" acme

# Where the window's claude comes from. PATH first, by absolute path (the
# window gets the tmux server's PATH, not this one), even for a repo whose
# shell has one too.
mkdir -p "$tmp/dbin" "$root/acme/cli/.shell/bin" "$root/acme/blocked"; : >"$root/acme/blocked/.blocked"
printf '#!/bin/sh\nexit 0\n' >"$root/acme/cli/.shell/bin/claude"; chmod +x "$root/acme/cli/.shell/bin/claude"
ok "session=acme-app repo=$root/acme/app${nl}role=unset window=claude${cl}" "$tmp/elsewhere" acme/app
ok "session=acme-cli .*${cl}" "$tmp/elsewhere" acme/cli
# No claude on PATH (the VS Code extension's host): the repo's devenv shell,
# through direnv exec. The stub direnv puts <repo>/.shell/bin first on PATH,
# as a devenv shell with harness.claudeCode.enable does, and fails like an
# .envrc not yet allowed where <repo>/.blocked exists.
cat >"$tmp/dbin/direnv" <<'EOF'
#!/bin/sh
[ "$1" = exec ] || exit 0
d=$2; shift 2
[ ! -e "$d/.blocked" ] || { echo "direnv: error $d/.envrc is blocked" >&2; exit 1; }
echo "direnv: loading $d/.envrc" >&2
PATH="$d/.shell/bin:$PATH" exec "$@"
EOF
chmod +x "$tmp/dbin/direnv"
PATH="$tmp/dbin" ok "session=acme-cli repo=$root/acme/cli${nl}role=unset window=claude${nl}claude=$root/acme/cli/\.shell/bin/claude \(direnv exec $root/acme/cli\)$" "$tmp/elsewhere" acme/cli
PATH="$tmp/dbin" HARNESS_PROJECT=acme/cli HARNESS_ROLE=work ok "${nl}role=work window=work${nl}claude=$root/acme/cli/\.shell/bin/claude \(direnv exec $root/acme/cli\)$" "$root/acme/cli"
# Neither: an error that names the option, never `command not found`.
nocli="; harness\.claudeCode\.enable = true in $root/acme/[a-z]+/devenv\.nix puts claude in its shell \(with allow_unfree: true in devenv\.yaml\), then direnv allow$"
PATH="$tmp/dbin" check 69 "^ccmux: no claude on PATH or in $root/acme/app's devenv shell${nocli}" "$tmp/elsewhere" acme/app
PATH="$tmp/dbin" check 69 "^ccmux: no claude on PATH, and $root/acme/blocked's devenv shell does not load \(.*direnv allow $root/acme/blocked\)${nocli}" "$tmp/elsewhere" acme/blocked
PATH=/var/empty check 69 "^ccmux: no claude on PATH, and no direnv on PATH to load $root/acme/cli's devenv shell${nocli}" "$tmp/elsewhere" acme/cli

# --- Live: the role in real windows, on a private tmux server -------------
# A stub claude records the role its window got, the window's name and the
# server's global role, then closes its window. The tmux is the one ccmux
# runs; TMUX_TMPDIR and the unset TMUX keep it off the user's server, and
# stdin from /dev/null makes the final attach fail instead of taking a
# terminal. HOME keeps the user's tmux.conf and shell rc out.
unset TMUX TMUX_PANE
export TMUX_TMPDIR="$tmp/tmux"; mkdir -p "$TMUX_TMPDIR" "$tmp/bin" "$root/bilibo/harness"
# shellcheck disable=SC2016  # writeShellApplication's literal `export PATH="<runtime inputs>:$PATH"`
tmux_path=$(sed -n 's/^export PATH="\(.*\):\$PATH"$/\1/p' "$ccmux")
live_env=(HOME="$tmp" XDG_CONFIG_HOME="$tmp/.config" PATH="$tmp/bin:$tmux_path:$PATH")
trap 'env "${live_env[@]}" tmux kill-server 2>/dev/null; rm -rf "$tmp"' EXIT
cat >"$tmp/bin/claude" <<EOF
#!$BASH
printf 'role=%s window=%s global=%s\n' "\${HARNESS_ROLE-unset}" "\$(tmux display-message -p '#{window_name}')" "\$(tmux show-environment -g HARNESS_ROLE 2>/dev/null || echo unset)" >>"$tmp/ran"
tmux kill-window
EOF
chmod +x "$tmp/bin/claude"; : >"$tmp/ran"
# live <want-regex> <cwd> [VAR=value...] <ccmux> [args...]
live() {
  local want="$1" dir="$2" before line i; shift 2
  before=$(wc -l <"$tmp/ran")
  (cd "$dir" && env "${live_env[@]}" "$@" </dev/null >/dev/null 2>&1)
  for i in $(seq 100); do [ "$(wc -l <"$tmp/ran")" -gt "$before" ] && break; sleep 0.1; done
  line=$(sed -n "$((before + 1))p" "$tmp/ran")
  if [[ "$line" =~ $want ]]; then pass=$((pass+1)); else
    fail=$((fail+1)); echo "FAIL (want /$want/): cd $dir && ${*/#"$ccmux"/ccmux}"; echo "  ${line:-no window ran (after ${i}x0.1 s)}"; fi
}
center=(HARNESS_PROJECT=bilibo/harness HARNESS_ROLE=center)
# No server yet: the center's own window carries the role; the server it
# starts has none in its global environment.
live '^role=center window=center global=unset$' "$root/bilibo/harness" "${center[@]}" "$ccmux"
# The center launching a work repo, in a new server and session.
live '^role=unset window=claude global=unset$' "$root/bilibo/harness" "${center[@]}" "$ccmux" acme/app --worktree
# A server some center shell started (global HARNESS_ROLE=center), holding
# acme-infra already: new session and new window both drop it.
env "${live_env[@]}" tmux kill-server 2>/dev/null
for i in $(seq 50); do env "${live_env[@]}" tmux ls >/dev/null 2>&1 || break; sleep 0.1; done
env "${live_env[@]}" HARNESS_ROLE=center tmux new-session -d -s acme-infra -c "$tmp" 'sleep 60'
live '^role=unset window=claude global=HARNESS_ROLE=center$' "$root/bilibo/harness" "${center[@]}" "$ccmux" acme/app
live '^role=unset window=claude global=HARNESS_ROLE=center$' "$root/bilibo/harness" "${center[@]}" "$ccmux" acme/infra
# And a work repo's own shell, into that existing session: its role.
live '^role=work window=work global=HARNESS_ROLE=center$' "$root/acme/infra" HARNESS_PROJECT=acme/infra HARNESS_ROLE=work "$ccmux"
# No claude where ccmux runs: the window runs the repo shell's, through the
# stub direnv, and the role handling is the same.
cat >"$root/acme/cli/.shell/bin/claude" <<EOF
#!$BASH
printf 'shell-claude role=%s window=%s\n' "\${HARNESS_ROLE-unset}" "\$(tmux display-message -p '#{window_name}')" >>"$tmp/ran"
tmux kill-window
EOF
live '^shell-claude role=unset window=claude$' "$tmp/elsewhere" PATH="$tmp/dbin:$tmux_path" "$ccmux" acme/cli

echo "ccmux-test ($(basename "$ccmux")): $pass passed, $fail failed"
[ "$fail" = 0 ]
