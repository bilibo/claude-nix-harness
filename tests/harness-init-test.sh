#!/usr/bin/env bash
#   harness-init-test.sh <path-to-harness> [<settings.json>]
#
# `harness init --dry-run` under a temp HOME and code root: it prints every
# file a new repo gets and creates nothing, not even the repo directory. On
# an existing repo with its own devenv.nix, the shell step stops for approval;
# with --yes it reaches the checks, where the stub direnv has linked
# <settings.json> (a store path; default: the harness itself) as the repo's
# .claude/settings.json, and the settings test must get the repo's own path.
# A repo's own devenv.lock is shown as the inputs it pins and stops the same.
# A repo with the guard rails off (harness.enable = false) gets no settings
# file; init reports it and exits 0 without the checks. The role the shell
# exports is reported; center (the harness checkout) gets the settings test
# in its center mode, and a warning in a repo that is not the checkout.
# With no claude on the host PATH (the default here: PATH is empty) the
# template turns harness.claudeCode.enable on and devenv.yaml gets
# allow_unfree: true; with one, both stay commented out. A claude in a store
# directory (a shell's) or under ~/.vscode-server (the extension's) is not
# the host's.
set -uo pipefail
harness="${1:?usage: harness-init-test.sh <harness> [<settings.json>]}"
settings="${2:-$harness}"
pass=0; fail=0
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/home"

check() { # check <description> <want-regex>
  if [[ "$out" =~ $2 ]]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $1 (/$2/)"; printf '%s\n' "$out" | sed 's/^/  /'; fi
}
init() { # init <args...>: sets out and rc; $HOST_PATH is the host's PATH (default: nothing), $STORE its NIX_STORE_DIR
  out=$(env -i HOME="$tmp/home" PATH="${HOST_PATH:-/var/empty}" ${STORE:+"NIX_STORE_DIR=$STORE"} HARNESS_CODE_ROOT="$tmp/code" HARNESS_WSL_MARKER="${WSL_MARKER:-/var/empty/none}" "$harness" init "$@" 2>&1); rc=$?
}

init --dry-run acme/demo
if [ "$rc" = 0 ]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: init --dry-run exits $rc"; fi
check "the repo path"         "harness init: $tmp/code/acme/demo \\(project acme/demo\\)"
for f in devenv.yaml devenv.nix .envrc CLAUDE.md; do check "plans $f" "would write +$f"; done
check "plans .gitignore"       'would add +\.gitignore: \.claude/settings\.json'
check "plans .worktreeinclude" 'would add +\.worktreeinclude: \.claude/settings\.json'
check "no shell step"          'shell step skipped'
check "default ref is the published repo" 'harness: +github:bilibo/claude-nix-harness \(default\)'
refute_store_warning() { if [[ "$out" =~ 'would pin a store path' ]]; then fail=$((fail+1)); echo "FAIL: store-path warning on the default ref"; else pass=$((pass+1)); fi; }
refute_store_warning
if [ -z "$(find "$tmp" -mindepth 1 -not -path "$tmp/home")" ]; then pass=$((pass+1))
else fail=$((fail+1)); echo "FAIL: --dry-run created files:"; find "$tmp" -mindepth 1 -not -path "$tmp/home" | sed 's/^/  /'; fi

init --dry-run --harness github:bilibo/claude-nix-harness acme/demo
check "--harness names the ref" 'harness: +github:bilibo/claude-nix-harness \(--harness\)'
HARNESS_REF=path:/somewhere
out=$(env -i HOME="$tmp/home" PATH=/var/empty HARNESS_CODE_ROOT="$tmp/code" HARNESS_REF="$HARNESS_REF" "$harness" init --dry-run acme/demo 2>&1)
check "HARNESS_REF names the ref" 'harness: +path:/somewhere \(HARNESS_REF\)'
# Shared flags before the command land on it too.
out=$(env -i HOME="$tmp/home" PATH=/var/empty HARNESS_CODE_ROOT="$tmp/code" "$harness" --dry-run init acme/demo 2>&1)
check "--dry-run before the command" 'would write +devenv\.yaml'
if [ ! -e "$tmp/code" ]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $tmp/code was created"; fi

init
if [ "$rc" = 64 ]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: init without a target exits $rc, want 64"; fi
out=$("$harness" init --help 2>&1)
check "init --help" 'harness init <customer>/<repo>'
out=$("$harness" check --help 2>&1)
check "check --help" 'harness check \[<repo>\]'

# An existing repo with its own devenv.nix: the shell step prints it and,
# without --yes or a terminal, stops before any `direnv allow`. direnv and
# devenv are stubs that log their calls. The direnv stub's `allow` links
# $SETTINGS (none when empty: a repo with the guard rails off), and its
# `exec` runs a command given by absolute path in the caller's environment.
mkdir -p "$tmp/bin" "$tmp/foreign"; echo '{ pkgs, ... }: { enterShell = "foreign code"; }' >"$tmp/foreign/devenv.nix"
printf '#!/bin/sh\necho "direnv $*" >>"$CALLS"\n[ "$1" = version ] && echo 2.38.2\n[ "$1" = allow ] && [ -n "${2:-}" ] && [ -n "$SETTINGS" ] && mkdir -p "$2/.claude" && ln -sfn "$SETTINGS" "$2/.claude/settings.json"\n[ "$1" = exec ] && case "$3" in /*) shift 2; exec "$@" ;; esac\nexit 0\n' >"$tmp/bin/direnv"
printf '#!/bin/sh\nexit 0\n' >"$tmp/bin/devenv"; chmod +x "$tmp/bin/direnv" "$tmp/bin/devenv"
shell_init() { # shell_init <args...>: init on $repo_dir (default: the foreign repo) with the stubs, no terminal, $ROLE as the shell's HARNESS_ROLE; sets out and rc
  : >"$tmp/calls"
  out=$(env -i HOME="$tmp/home" PATH="$tmp/bin" CALLS="$tmp/calls" SETTINGS="$settings" HARNESS_CODE_ROOT="$tmp/code" ${ROLE:+"HARNESS_ROLE=$ROLE"} "$harness" init "$@" "${repo_dir:-$tmp/foreign}" 2>&1 </dev/null); rc=$?
}
shell_init
if [ "$rc" != 0 ]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: a foreign devenv.nix without --yes exits 0"; fi
check "the foreign file printed" 'foreign/devenv\.nix \(not written by harness init\).*foreign code'
check "refused, --yes named"     'not approved: devenv\.nix; .*re-run with --yes'
if grep -q 'direnv allow' "$tmp/calls"; then fail=$((fail+1)); echo "FAIL: direnv allow ran without approval"; else pass=$((pass+1)); fi
shell_init --yes --verbose
if grep -q "^direnv allow $tmp/foreign\$" "$tmp/calls"; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: --yes did not reach direnv allow: $(tr '\n' ';' <"$tmp/calls")"; fi
# The repo is not at /repo, the fixtures' root: the settings test gets the
# repo's path (the --verbose trace shows the call), so its literal-path
# checks are the only ones that can fail against the /repo fixture.
check "settings test gets the repo path" "project-settings-test\.sh $tmp/foreign/\.claude/settings\.json $tmp/foreign[[:space:]]"
check "settings linked from the store"   'ok +\.claude/settings\.json -> /nix/store/'
if [[ "$out" =~ 'FAIL: full deny set' ]]; then fail=$((fail+1)); echo "FAIL: the settings test did not read the linked file"; else pass=$((pass+1)); fi
check "role unset reported as work"      'role +work \(HARNESS_ROLE unset'

# The role the shell exports: work is reported and checked as before.
# center, the harness checkout's (sandbox off; scripts/install.sh inits the
# checkout), is accepted with one notice and the settings test in its center
# mode; in a repo without the harness's own devenv/devenv.nix and
# lib/settings.nix it also warns, and still goes on. (The settings test
# itself cannot run here, no bash on the stub PATH: the --verbose trace
# shows the call.)
ROLE=work shell_init --yes --verbose
check "role work reported"               $'role +work\n'
check "role work reaches the checks"     "project-settings-test\\.sh $tmp/foreign/\\.claude/settings\\.json $tmp/foreign[[:space:]]"
refute_center() { # refute_center <description>: no center notice or warning in $out
  if [[ "$out" == *'harness.role = "center"'* || "$out" == *"the command center's file"* ]]; then fail=$((fail+1)); echo "FAIL: $1"; else pass=$((pass+1)); fi
}
refute_center "role work treated as center"
ROLE=center shell_init --yes --verbose
check "center: notice"                   "role +center: the command center's file, sandbox off by design; the settings test runs in center mode"
check "center outside the checkout: warned" 'warn +harness\.role = "center" but .*/foreign is not the harness checkout \(no devenv/devenv\.nix and lib/settings\.nix\)'
check "center: settings test in center mode" "project-settings-test\\.sh $tmp/foreign/\\.claude/settings\\.json center $tmp/foreign[[:space:]]"
if [[ "$out" == *"that is the harness checkout's role"* ]]; then fail=$((fail+1)); echo "FAIL: role center still refused"; else pass=$((pass+1)); fi
# The harness checkout itself: its own module and settings source, no warning.
mkdir -p "$tmp/checkout/devenv" "$tmp/checkout/lib"; : >"$tmp/checkout/devenv/devenv.nix"; : >"$tmp/checkout/lib/settings.nix"
ROLE=center repo_dir="$tmp/checkout" shell_init --yes --verbose
check "checkout: notice"                 "role +center: the command center's file"
check "checkout: settings test in center mode" "project-settings-test\\.sh $tmp/checkout/\\.claude/settings\\.json center $tmp/checkout[[:space:]]"
if [[ "$out" == *'is not the harness checkout'* ]]; then fail=$((fail+1)); echo "FAIL: the harness checkout warned as not the checkout"; else pass=$((pass+1)); fi

# A repo with its own devenv.lock and nothing else foreign: the inputs it
# pins are printed, and without --yes no `direnv allow` runs.
mkdir -p "$tmp/locked"
echo '{"nodes":{"nixpkgs":{"locked":{"type":"github","owner":"NixOS","repo":"nixpkgs","rev":"0123abc"}},"root":{"inputs":{"nixpkgs":"nixpkgs"}}},"root":"root","version":7}' >"$tmp/locked/devenv.lock"
repo_dir="$tmp/locked" shell_init
if [ "$rc" != 0 ]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: a foreign devenv.lock without --yes exits 0"; fi
check "the lock's inputs printed" 'locked/devenv\.lock \(not written by harness init\).*nixpkgs: github:NixOS/nixpkgs @ 0123abc'
check "the lock refused"          'not approved: devenv\.lock;'
if grep -q 'direnv allow' "$tmp/calls"; then fail=$((fail+1)); echo "FAIL: direnv allow ran with an unapproved lock"; else pass=$((pass+1)); fi

# A repo whose owner turned the guard rails off (harness.enable = false):
# the shell loads (DEVENV_ROOT) without the harness (no HARNESS_PROJECT) and
# devenv writes no settings file. init says so and exits 0 without the
# checks; a shell that did not load at all still fails as before.
mkdir -p "$tmp/off"; echo '{ ... }: { harness.enable = false; }' >"$tmp/off/devenv.nix"
off_init() { # off_init [<VAR=value>...]: init --yes on the off repo, nothing linked; sets out and rc
  : >"$tmp/calls"
  out=$(env -i HOME="$tmp/home" PATH="$tmp/bin" CALLS="$tmp/calls" SETTINGS= HARNESS_CODE_ROOT="$tmp/code" "$@" "$harness" init --yes --verbose "$tmp/off" 2>&1 </dev/null); rc=$?
}
off_init DEVENV_ROOT="$tmp/off"
if [ "$rc" = 0 ]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: a repo with the guard rails off exits $rc"; printf '%s\n' "$out" | sed 's/^/  /'; fi
check "guard rails off reported" 'off +the shell loads without the guard rails: harness\.enable = false in devenv\.nix'
if [ -e "$tmp/off/.claude/settings.json" ] || [ -L "$tmp/off/.claude/settings.json" ]; then fail=$((fail+1)); echo "FAIL: a settings file in the repo with the guard rails off"; else pass=$((pass+1)); fi
if [[ "$out" =~ project-settings-test|hook-test|Ready\. ]]; then fail=$((fail+1)); echo "FAIL: the checks ran with the guard rails off"; else pass=$((pass+1)); fi
off_init
if [ "$rc" != 0 ]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: a shell that did not load exits 0"; fi
check "not loaded is still an error" 'settings\.json was not written: the devenv shell did not load'

# A WSL host (fake marker): the dry run says so, and a real write (no shell
# step) puts harness.platform = "wsl" into devenv.nix; elsewhere the line
# stays commented out.
touch "$tmp/wsl"
WSL_MARKER="$tmp/wsl" init --dry-run acme/demo
check "wsl noted in the dry run" 'platform +wsl \(harness\.platform in devenv\.nix\)'
WSL_MARKER="$tmp/wsl" init --no-shell acme/wsl
if grep -q -E '^    platform = "wsl";' "$tmp/code/acme/wsl/devenv.nix"; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: harness.platform not set on a WSL host"; fi
init --no-shell acme/plain
if grep -q -E '^    # platform = "wsl";' "$tmp/code/acme/plain/devenv.nix"; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: platform line not commented out off WSL"; fi
if [[ "$out" =~ 'platform   wsl' ]]; then fail=$((fail+1)); echo "FAIL: wsl noted off WSL"; else pass=$((pass+1)); fi
# The off switch is in the template, commented out, first in the harness block.
if grep -A1 -x -F '  harness = {' "$tmp/code/acme/plain/devenv.nix" | grep -q -E '^    # enable = false; +# guard rails off'; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: no commented-out enable = false in the template's harness block"; fi
# The role line right after it, commented out and marked as the harness
# checkout's; no template ever sets a role.
if grep -A2 -x -F '  harness = {' "$tmp/code/acme/plain/devenv.nix" | sed -n 3p | grep -q -E '^    # role = "center"; +# the harness checkout only \(the command center\): no sandbox there; never a work repo$'; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: no commented-out role = \"center\" after enable in the template"; fi
if grep -q -E '^ *role *=' "$tmp/code/acme/plain/devenv.nix" "$tmp/code/acme/wsl/devenv.nix"; then fail=$((fail+1)); echo "FAIL: a template sets harness.role"; else pass=$((pass+1)); fi

# claudeCode.enable. has/lacks <description> <file> <regex>: a line in the file.
has()   { if grep -q -E "$3" "$2" 2>/dev/null; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $1 (/$3/ in $2)"; sed 's/^/  /' "$2" 2>/dev/null; fi; }
lacks() { if grep -q -E "$3" "$2" 2>/dev/null; then fail=$((fail+1)); echo "FAIL: $1 (/$3/ in $2)"; sed 's/^/  /' "$2"; else pass=$((pass+1)); fi; }
on='^    claudeCode\.enable = true; +# the CLI for tmux/ccmux sessions; the VS Code extension brings its own$'
off='^    # claudeCode\.enable = true; +# claude, tmux and jq in this shell'
# No claude on the host PATH (acme/plain above): on, allow_unfree with it,
# and the report says so, the dry run included.
has   "no host claude: claudeCode.enable on"   "$tmp/code/acme/plain/devenv.nix" "$on"
has   "no host claude: allow_unfree"           "$tmp/code/acme/plain/devenv.yaml" '^allow_unfree: true +# for harness\.claudeCode\.enable in devenv\.nix: claude-code is unfree$'
check "no host claude: reported"               'claude +none on the host PATH: claudeCode\.enable = true in devenv\.nix, allow_unfree: true in devenv\.yaml'
init --dry-run acme/demo
check "no host claude: reported in the dry run" 'claude +none on the host PATH: claudeCode\.enable = true'
# A claude on the host PATH (a native install, a profile, the home module):
# both stay commented out.
mkdir -p "$tmp/hostbin"; printf '#!/bin/sh\n' >"$tmp/hostbin/claude"; chmod +x "$tmp/hostbin/claude"
HOST_PATH="$tmp/hostbin" init --no-shell acme/hosted
has   "host claude: claudeCode.enable commented" "$tmp/code/acme/hosted/devenv.nix" "$off"
lacks "host claude: claudeCode.enable not set"   "$tmp/code/acme/hosted/devenv.nix" '^ *claudeCode\.enable'
has   "host claude: allow_unfree commented"      "$tmp/code/acme/hosted/devenv.yaml" '^# allow_unfree: true +# for harness\.claudeCode\.enable'
lacks "host claude: allow_unfree not set"        "$tmp/code/acme/hosted/devenv.yaml" '^allow_unfree'
check "host claude: reported"                    "claude +$tmp/hostbin/claude on the host PATH: claudeCode\\.enable left commented out in devenv\\.nix"
# A claude only in a store directory (init run from a repo shell that has
# one) or under ~/.vscode-server (the extension's copy) is not the host's.
mkdir -p "$tmp/store/abc-claude-code/bin" "$tmp/home/.vscode-server/bin/x/bin"
cp "$tmp/hostbin/claude" "$tmp/store/abc-claude-code/bin/claude"; cp "$tmp/hostbin/claude" "$tmp/home/.vscode-server/bin/x/bin/claude"
STORE="$tmp/store" HOST_PATH="$tmp/store/abc-claude-code/bin:$tmp/home/.vscode-server/bin/x/bin" init --no-shell acme/shelled
has   "shell's claude only: claudeCode.enable on" "$tmp/code/acme/shelled/devenv.nix" "$on"
has   "shell's claude only: allow_unfree"         "$tmp/code/acme/shelled/devenv.yaml" '^allow_unfree: true'
check "shell's claude only: reported as none"     'claude +none on the host PATH'
# ... and one after them on PATH still is.
STORE="$tmp/store" HOST_PATH="$tmp/store/abc-claude-code/bin:$tmp/hostbin" init --dry-run acme/demo
check "host claude after a shell's: found"       "claude +$tmp/hostbin/claude on the host PATH"

echo "harness-init-test: $pass passed, $fail failed"
[ "$fail" = 0 ]
