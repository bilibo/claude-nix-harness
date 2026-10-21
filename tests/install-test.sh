#!/usr/bin/env bash
#   install-test.sh <install.sh>
#
# Runs install.sh against a fake HOME with curl, sudo, nix, direnv, devenv,
# sysctl and jq stubbed on PATH, so it runs anywhere and installs nothing.
# Every stub appends its argv to $tmp/calls. `nix` is only on PATH when a
# case puts it there; the sysctl stub reports the Ubuntu user-namespace
# restriction while $tmp/restricted exists.
set -uo pipefail
script="${1:?usage: install-test.sh <install.sh>}"
script=$(cd "$(dirname "$script")" && pwd -P)/$(basename "$script")
repo=$(dirname "$script")
pass=0; fail=0
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/stubs" "$tmp/nixbin" "$tmp/home" "$tmp/tools"
# Only these reach the script, so the host's own nix never does; the
# profile path and the uninstaller path are overridden below for the same
# reason.
for t in sh bash grep cp mkdir sed tee cat dirname basename mv rm head tail mktemp; do
  ln -s "$(command -v "$t")" "$tmp/tools/$t"
done

stub() { # stub <dir> <name> [body]
  printf '#!%s\necho "%s $*" >> "%s/calls"\n%s\nexit 0\n' "$BASH" "$2" "$tmp" "${3:-}" > "$1/$2"
  chmod +x "$1/$2"
}
for s in curl sudo jq git; do stub "$tmp/stubs" "$s"; done
# direnv logs where it ran: the script allows "." after a cd.
printf '#!%s\necho "direnv $* (cwd $PWD)" >> "%s/calls"\nexit 0\n' "$BASH" "$tmp" > "$tmp/stubs/direnv"; chmod +x "$tmp/stubs/direnv"
# The self-check reads the generated settings through the shell.
stub "$tmp/stubs" devenv 'case "$*" in *disableBypassPermissionsMode*) echo disable;; esac'
# curl writes nothing, so the installer runs as an empty script. `nix profile
# add --help` decides add vs install; every nix call must see flakes enabled.
stub "$tmp/nixbin" nix 'echo "  NIX_CONFIG=${NIX_CONFIG:-}" >> "'"$tmp"'/calls"; [ "${1:-}" = profile ] && [ "${2:-}" = add ] && [ "${3:-}" = --help ] && exit 0'
stub "$tmp/stubs" sysctl 'case "$*" in *apparmor_restrict_unprivileged_userns*) [ -e "'"$tmp"'/restricted" ] && echo 1 || echo 0;; *) echo 1;; esac'

# run <answer-to-prompts> [args...]: runs the script with stubs first on PATH.
run() {
  local answer="$1"; shift
  rm -f "$tmp/calls"; : > "$tmp/calls"
  HOME="$tmp/home" PATH="$tmp/stubs:$tmp/nixbin:$tmp/tools" \
    HARNESS_NIX_PROFILE_SH="$tmp/nix-daemon.sh" HARNESS_NIX_INSTALLER="$tmp/nix-installer" \
    sh "$script" "$@" > "$tmp/out" 2>&1 <<< "$answer"
  echo "exit=$?" >> "$tmp/out"
}
check() { # check <description> <regex over the calls log>
  if grep -qE "$2" "$tmp/calls"; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $1 (/$2/)"; sed 's/^/  /' "$tmp/calls"; fi
}
check_absent() { if grep -qE "$2" "$tmp/calls"; then fail=$((fail+1)); echo "FAIL: $1 (/$2/ present)"; else pass=$((pass+1)); fi; }
file_has() { # file_has <file> <fixed string> [count]
  local n; n=$(grep -cF -- "$2" "$1" 2>/dev/null)
  if [ "$n" = "${3:-1}" ]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $1 should contain '$2' ${3:-1} time(s), has $n"; fi
}
out_has() { if grep -qE -- "$1" "$tmp/out"; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: output lacks /$1/"; sed 's/^/  /' "$tmp/out"; fi; }
out_lacks() { if grep -qE -- "$1" "$tmp/out"; then fail=$((fail+1)); echo "FAIL: output has /$1/"; else pass=$((pass+1)); fi; }

# Download fails: stop with curl's error, not with "open a new terminal".
mv "$tmp/nixbin/nix" "$tmp/nix.stub"
printf '#!%s\necho "curl $*" >> "%s/calls"\nexit 22\n' "$BASH" "$tmp" > "$tmp/stubs/curl"
run y
out_has 'exit=22'
out_lacks 'again'
stub "$tmp/stubs" curl

# Fresh host: no nix, no rc files at all. Nothing in $HOME is touched before Nix is in.
run y
check "nix installer fetched"      '^curl .*artifacts\.nixos\.org/nix-installer'
# The stub installer puts no nix on PATH, as a real one does for a shell
# that has not sourced the profile yet: stop and say to run again.
out_has 'exit=2'
out_has 'again'
[ -e "$tmp/home/.bashrc" ] && { fail=$((fail+1)); echo "FAIL: .bashrc edited before Nix exists"; } || pass=$((pass+1))

# With nix on PATH: profile installs from this repo, rc lines, config files, allow, build, self-check.
mv "$tmp/nix.stub" "$tmp/nixbin/nix"
run y
check_absent "no second installer"   '^curl'
check "flakes on for every nix call" '^  NIX_CONFIG=experimental-features = nix-command flakes'
check_absent "a nix call without"    '^  NIX_CONFIG=$'
check_absent "no flag words"         '^nix --extra-experimental-features'
check "add probed"                   '^nix profile add --help'
check "devenv from this checkout"    "^nix profile add .*$repo#devenv"
check "direnv from this checkout"    "^nix profile add .*$repo#direnv"
check_absent "no path: source"       'path:'
# `direnv allow` records the require_allowed files only once the .envrc has
# been evaluated, so the script allows, exports, allows again.
if [ "$(grep -c '^direnv allow' "$tmp/calls")" = 2 ] && grep -q '^direnv export' "$tmp/calls"; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: allow, export, allow"; grep '^direnv' "$tmp/calls" | sed 's/^/  /'; fi
check "self-check reads settings"    '^devenv shell -- jq .*disableBypassPermissionsMode'
check "self-check runs the hook"     '^devenv shell -- .*PreToolUse'
file_has "$tmp/home/.bashrc" 'eval "$(direnv hook bash)"'
[ -e "$tmp/home/.zshrc" ] && { fail=$((fail+1)); echo "FAIL: .zshrc must not be created"; } || pass=$((pass+1))
file_has "$tmp/home/.config/direnv/direnv.toml" 'strict_env = true'
file_has "$tmp/home/.tmux.conf" 'source-file ~/.config/tmux/harness.conf'
file_has "$tmp/home/.config/tmux/harness.conf" 'set -g extended-keys on'
out_has "NIX_CONFIG='experimental-features = nix-command flakes' nix profile upgrade --all"

# Again, with a zsh rc and the user's own direnv.toml: nothing doubled, nothing overwritten.
printf '[global]\nstrict_env = false\n' > "$tmp/home/.config/direnv/direnv.toml"
touch "$tmp/home/.zshrc"
run y
file_has "$tmp/home/.bashrc" 'direnv hook bash' 1
file_has "$tmp/home/.zshrc" 'eval "$(direnv hook zsh)"' 1
file_has "$tmp/home/.tmux.conf" 'source-file' 1
file_has "$tmp/home/.config/direnv/direnv.toml" 'strict_env = false' 1
out_has 'direnv.toml.*(kept|exists|left)'

# Ubuntu restriction, sudo declined: reported, no sudo, still exits 0, and
# reported again on the next run.
touch "$tmp/restricted"
run n
out_has 'apparmor_restrict_unprivileged_userns'
check_absent "no sudo when declined" '^sudo'
out_has 'exit=0'
run n
out_has 'apparmor_restrict_unprivileged_userns'
# Accepted: the sysctl is applied and persisted with sudo.
run y
check "sysctl applied with sudo"    '^sudo sysctl -w kernel.apparmor_restrict_unprivileged_userns=0'
check "sysctl persisted with sudo"  '^sudo .*99-claude-nix-harness.conf'
rm -f "$tmp/restricted"

# Run from elsewhere with no argument: the target is the script's own directory.
(cd "$tmp" && run y)
check "target is the repo"          "^direnv allow \. \(cwd $repo\)\$"
# An explicit target.
mkdir -p "$tmp/proj"; touch "$tmp/proj/.envrc"; (cd "$tmp" && run y "$tmp/proj")
check "explicit target"             "^direnv allow \. \(cwd $tmp/proj\)\$"
out_has 'new terminal'
# A target that was never onboarded stops before touching anything.
mkdir -p "$tmp/bare"; (cd "$tmp" && run y "$tmp/bare")
out_has 'no .envrc'
out_has 'exit=1'

# Nix present but not from this installer: no uninstall line. With it: the line.
run y
out_lacks 'nix-installer uninstall'
touch "$tmp/nix-installer"; run y
out_has 'nix-installer uninstall'
# sudo fails (wrong password, read-only /proc/sys in a container): deferred, not fatal.
touch "$tmp/restricted"; printf '#!%s\necho "sudo $*" >> "%s/calls"\nexit 1\n' "$BASH" "$tmp" > "$tmp/stubs/sudo"
run y
out_has 'exit=0'
out_has 'later'
rm -f "$tmp/restricted"; stub "$tmp/stubs" sudo
# zsh-only user: no ~/.bashrc is created.
rm -f "$tmp/home/.bashrc"; run y
[ -e "$tmp/home/.bashrc" ] && { fail=$((fail+1)); echo "FAIL: .bashrc created although .zshrc exists"; } || pass=$((pass+1))

echo "install-test: pass=$pass fail=$fail"
[ "$fail" = 0 ]
