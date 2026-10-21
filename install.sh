#!/bin/sh
# install.sh [<project-dir>]
#
# One-off setup of a plain Linux host for claude-nix-harness: Nix (the
# nix-installer at artifacts.nixos.org), devenv and direnv from this repo's
# flake, the direnv shell hook, the direnv and tmux settings the harness
# relies on, then `direnv allow` and a first build of the project shell.
# Updates afterwards are devenv's and nix's own tooling; the script is safe
# to run again.
#
# POSIX sh until Nix exists. The Nix installer asks for sudo itself; the one
# other privileged step, a sysctl, is offered and can be declined.
set -eu

here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
target=${1:-$here}
target=$(CDPATH= cd -- "$target" && pwd -P)
# Tests point these at scratch files.
nix_profile_sh=${HARNESS_NIX_PROFILE_SH:-/nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh}
nix_installer=${HARNESS_NIX_INSTALLER:-/nix/nix-installer}
# The installer leaves flakes off; this turns them on for every nix call here.
export NIX_CONFIG="experimental-features = nix-command flakes"
installed=""
later=""

say() { printf '%s\n' "$*"; }
note() { installed="$installed
  $*"; }
defer() { later="$later
  $*"; }
ask() { # ask <question>: yes on y/Y
  printf '%s [y/N] ' "$1"
  read -r a || a=""
  case "$a" in y|Y) return 0;; *) return 1;; esac
}

preflight() {
  for c in curl git; do
    command -v "$c" >/dev/null 2>&1 || { say "install.sh: $c is required"; exit 1; }
  done
  command -v sudo >/dev/null 2>&1 || say "no sudo: privileged steps will be printed, not run"
  if command -v sysctl >/dev/null 2>&1; then
    # Ubuntu 23.10+ confines unprivileged user namespaces; the Claude Code
    # sandbox (bubblewrap) needs them and refuses to run without.
    if [ "$(sysctl -n kernel.apparmor_restrict_unprivileged_userns 2>/dev/null || echo 0)" = 1 ]; then
      offer_sysctl kernel.apparmor_restrict_unprivileged_userns 0
    fi
    if [ "$(sysctl -n kernel.unprivileged_userns_clone 2>/dev/null || echo 1)" = 0 ]; then
      offer_sysctl kernel.unprivileged_userns_clone 1
    fi
  fi
}

offer_sysctl() { # offer_sysctl <key> <value>
  dropin=/etc/sysctl.d/99-claude-nix-harness.conf
  say "$1 is $( [ "$2" = 0 ] && echo 1 || echo 0 ): the Claude Code sandbox needs unprivileged user namespaces."
  say "This would run:  sudo sysctl -w $1=$2"
  say "and persist it:  echo '$1 = $2' | sudo tee -a $dropin"
  if command -v sudo >/dev/null 2>&1 && ask "Apply with sudo now?" \
     && sudo sysctl -w "$1=$2" && printf '%s = %s\n' "$1" "$2" | sudo tee -a "$dropin" >/dev/null; then
    note "sysctl $1=$2, persisted in $dropin"
  else
    # Declined, or sudo failed (a container's /proc/sys is read-only).
    defer "sudo sysctl -w $1=$2 && echo '$1 = $2' | sudo tee -a $dropin"
  fi
}

shell_hooks() {
  bashrc="$HOME/.bashrc"; zshrc="$HOME/.zshrc"
  # ~/.bashrc is created only when there is no rc file at all; a zsh-only
  # user keeps their setup.
  if { [ -e "$bashrc" ] || [ ! -e "$zshrc" ]; } && ! grep -qF 'direnv hook bash' "$bashrc" 2>/dev/null; then
    [ -e "$bashrc" ] || note "created $bashrc"
    printf '\n# claude-nix-harness\neval "$(direnv hook bash)"\n' >> "$bashrc"
    note "direnv hook in $bashrc"
  fi
  if [ -e "$zshrc" ] && ! grep -qF 'direnv hook zsh' "$zshrc"; then
    printf '\n# claude-nix-harness\neval "$(direnv hook zsh)"\n' >> "$zshrc"
    note "direnv hook in $zshrc"
  fi
}

host_config() {
  toml="$HOME/.config/direnv/direnv.toml"
  if [ -e "$toml" ]; then
    say "$toml exists, left as is; compare with $here/pkgs/direnv.toml"
  else
    mkdir -p "$HOME/.config/direnv"
    cat "$here/pkgs/direnv.toml" > "$toml"   # not cp: a read-only source must not make a read-only copy
    note "$toml"
  fi
  mkdir -p "$HOME/.config/tmux"
  cat "$here/pkgs/tmux.conf" > "$HOME/.config/tmux/harness.conf"
  if ! grep -qF 'source-file ~/.config/tmux/harness.conf' "$HOME/.tmux.conf" 2>/dev/null; then
    printf '\n# claude-nix-harness\nsource-file ~/.config/tmux/harness.conf\n' >> "$HOME/.tmux.conf"
    note "tmux settings in ~/.config/tmux/harness.conf, sourced from ~/.tmux.conf"
  fi
}

install_nix() {
  if command -v nix >/dev/null 2>&1; then
    return
  fi
  say "Installing Nix with nix-installer (multi-user daemon); it asks for sudo itself."
  # Not `curl | sh`: sh has no pipefail, so a failed download would run an
  # empty script and look like a successful install.
  installer=$(mktemp)
  curl -sSfL https://artifacts.nixos.org/nix-installer -o "$installer"
  sh "$installer" install
  rm -f "$installer"
  # The installer edits the shell rc files; this shell has not read them.
  [ -r "$nix_profile_sh" ] && . "$nix_profile_sh"
  if ! command -v nix >/dev/null 2>&1; then
    say "Nix is installed but not on this shell's PATH yet. Open a new terminal and run $0 again."
    exit 2
  fi
  note "Nix (nix-installer)"
}

install_tools() {
  # `nix profile install` became `nix profile add` in Nix 2.29.
  if nix profile add --help >/dev/null 2>&1; then verb=add; else verb=install; fi
  # No `path:` prefix: a git checkout is then read through git, tracked
  # files only, so an ignored .env never lands in the store.
  nix profile "$verb" "$here#devenv" "$here#direnv"
  note "devenv and direnv in the user profile, from $here"
}

build_project() {
  cd "$target"
  [ -e .envrc ] || { say "$target has no .envrc; onboard it first (docs/runbook.md, section 3)"; exit 1; }
  # `direnv allow` records the require_allowed files only once the .envrc has
  # been evaluated, so: allow, evaluate (which builds the shell), allow again.
  bash -c 'direnv allow . && eval "$(direnv export bash)" && direnv allow .'
  note "project shell built in $target"
}

self_check() {
  cd "$target"
  mode=$(devenv shell -- jq -r .permissions.disableBypassPermissionsMode .claude/settings.json 2>/dev/null || echo missing)
  if [ "$mode" = disable ]; then
    say "harness: .claude/settings.json generated, bypass mode disabled"
  else
    say "harness: .claude/settings.json is missing or not the harness one ($mode); the project does not import harness/devenv?"
    exit 3
  fi
  if devenv shell -- sh -c 'echo "{}" | "$(jq -r ".hooks.PreToolUse[0].hooks[0].command" .claude/settings.json)"' >/dev/null 2>&1; then
    say "harness: the guard hook runs"
  else
    say "harness: the guard hook named in .claude/settings.json did not run"
    exit 3
  fi
}

summary() {
  say ""
  say "Installed:$installed"
  if [ -n "$later" ]; then
    say ""
    say "Declined, run later:$later"
  fi
  say ""
  say "Start:  open a new terminal, then  cd $target && ccmux   (or open the folder in VS Code with the direnv extension)"
  say "Update: devenv update  (project inputs);  git pull here, then  NIX_CONFIG='experimental-features = nix-command flakes' nix profile upgrade --all  (devenv, direnv)"
  if [ -e "$nix_installer" ]; then
    say "Undo:   $nix_installer uninstall   (removes Nix; the repo and your rc files stay)"
  fi
}

preflight
install_nix
install_tools
# After the tools, so an rc file never calls a direnv that is not there yet.
shell_hooks
host_config
build_project
self_check
summary
