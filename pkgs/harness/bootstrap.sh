#!/usr/bin/env bash
#   harness bootstrap [--no-root] [--no-profile] [--trusted-user] [--account-sync]
#                     [--code-root <dir>] [--harness <flakeref>]
#   harness upgrade   [the bootstrap flags]
#   harness doctor    [--code-root <dir>]
#   harness reset     [--no-root]
#   each also takes --dry-run, --yes, --verbose
#
# Takes a Linux host that has Nix (scripts/install.sh puts it there: on
# Fedora 44 or newer from Fedora's own packages, on any other distro with the
# nix-installer) and Claude Code to the unmanaged-host shape of the README:
# direnv >= 2.38, devenv, ccmux and harness from this flake (`nix profile
# add`, pinned by flake.lock), and the user-side configuration the home
# module would write on a managed host: direnv.toml, the tmux rules, the
# direnv hook for bash and zsh, HARNESS_CODE_ROOT, the session PATH for
# GUI-launched VS Code, mkhl.direnv. No harness module and no managed
# settings: repos that import `harness/devenv` carry the rules (`harness
# init` sets one up). scripts/install.sh does the root steps `nix run`
# needs, then runs `harness bootstrap`, which finds them done and does the
# rest.
#
# NixOS (/etc/NIXOS, or ID=nixos in os-release: the marker is not visible
# from inside a sandboxed session) is the unmanaged shape without root
# steps: /etc/nix/nix.conf and the sysctls belong to the system
# configuration, so --no-root is implied and the nix.settings and
# boot.kernel.sysctl lines are printed where the host lacks them. A user file
# that is a symlink into the Nix store is home-manager's: it is skipped and
# the option that sets it is printed; the rest is written as on any host.
# Independently of detection, root_write refuses any target that resolves
# into the store. WSL (binfmt WSLInterop, or WSL_DISTRO_NAME) is reported in
# the host line; `harness init` sets harness.platform = "wsl" there.
#
# Idempotent: every step checks before it writes, so re-run it after a
# change. `upgrade` is bootstrap that also moves the profile packages to the
# harness ref's current flake.lock. scripts/install.sh owns the root steps
# that come before Nix (dnf on Fedora, the SELinux label, the nix-daemon
# socket); root is needed here for /etc/nix/nix.conf (the devenv cache;
# flakes where the installer left them off) and the one kernel setting the
# Claude Code sandbox cannot run without: where the kernel confines unprivileged user
# namespaces. Ubuntu 23.10 and later do it through AppArmor
# (kernel.apparmor_restrict_unprivileged_userns = 1): the fix is the
# profile from the Claude Code sandboxing docs, /etc/apparmor.d/bwrap, an
# unconfined profile for /usr/bin/bwrap with `userns`, then an AppArmor
# reload; the machine-wide sysctl stays as it is. Older Debian kernels gate
# them with kernel.unprivileged_userns_clone: a sysctl plus a drop-in under
# /etc/sysctl.d. Either is asked for on its own (--yes answers it);
# declined, the command is printed for later and doctor keeps reporting it.
# Those steps go
# through sudo and say what they do first. --no-root skips them; --no-profile
# skips the `nix profile` step for a host that gets direnv, devenv and ccmux
# some other way (the README's "your own configuration"). `doctor` changes
# nothing and reports every prerequisite, `claude doctor`, and, run in a
# harness repo, the repo's settings symlink, direnv approval and hooks; exit
# 1 when one the harness needs is missing. claude and tmux are not among
# them: no host claude is an info line (the VS Code extension brings its
# own, a repo's harness.claudeCode.enable the CLI), no tmux a warning
# (ccmux brings its own; attaching by hand needs one). That is the host
# half of the runbook's verification section. --dry-run prints every step
# and the command it would run, runs none of them and never calls sudo;
# --verbose prints each command first.
#
# The harness ref (what `nix profile add` installs from): --harness, else
# HARNESS_REF, else the receipt's, else github:bilibo/claude-nix-harness. A `path:/nix/store/...` ref warns: a
# later upgrade cannot move it.
#
# --trusted-user adds you to Nix's trusted-users. Not needed: the devenv
# cache goes into the root-owned nix.conf as a substituter, which is what
# devenv checks for. A trusted user can pass any option to the daemon
# (unsigned paths, other caches, sandbox off), and agents run as you, so the
# default keeps that door shut.
#
# The user-scope ~/.claude/settings.json gets the keys a repo file cannot
# carry: sandbox.network.strictAllowlist = true (an unlisted host is refused
# inside the sandbox instead of prompting; user-or-managed scope), and
# syncClaudeAiSkills = false and syncClaudeAiPlugins = false, so sessions
# load no skills or plugins from the claude.ai account (the harness reviews
# none of them, and a plugin can carry hooks). Only `false` is honoured,
# from user scope or above. --account-sync opts back in: the two keys are
# not written, and a `false` already there is removed. Account sync off is
# the default since 2026-10-24; --no-account-sync, which turned it off
# before, is still accepted and names the default (the later of the two
# flags wins). The
# other keys of that file are kept as they are. Never
# env.CLAUDE_CODE_SUBPROCESS_ENV_SCRUB: in user scope it turns the sandbox's
# Bash auto-allow off, so every command prompts (2026-10-22, changelog); a
# copy an earlier bootstrap wrote is removed.
#
# The receipt, ~/.local/state/claude-nix-harness/receipt.json, lists what
# bootstrap put on the host: profile packages, files (whole files, marker
# blocks, merged keys), dnf packages and root steps, the VS Code extension,
# the harness ref and revision. Each bootstrap and upgrade adds to it.
#
# `reset` reverses what the receipt lists and removes the receipt last;
# without a receipt nothing is recorded and it does nothing. When the
# receipt says scripts/install.sh ran the nix-installer, Nix goes
# too (/nix/nix-installer uninstall); the dnf packages likewise. It asks
# before it starts unless --yes; it never touches the code root, so delete a
# test repo by hand.
# shellcheck disable=SC1091,SC2015,SC2016,SC2088  # system files are not inputs; `x && ok || miss` reports, ok never fails; jq filters go through jq_edit; ~ in messages is text
set -euo pipefail

CMD="${HARNESS_CMD:-bootstrap}"   # bootstrap, upgrade, doctor or reset: pkgs/harness.nix sets it
NO_ROOT=0; NO_PROFILE=0; TRUSTED_USER=0; ACCOUNT_SYNC=0; YES=0; DRY_RUN=0; VERBOSE=0
CODE_ROOT="${HARNESS_CODE_ROOT:-$HOME/code/git}"
# Run straight from a checkout (bash pkgs/harness/bootstrap.sh), the checkout is the ref.
HARNESS_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)
HARNESS_REF="${HARNESS_REF:-path:$HARNESS_DIR}"
HARNESS_REF_FROM="${HARNESS_REF_FROM:-checkout}"
usage() { sed -n '/^#   harness /,/^# shellcheck/{/^# shellcheck/q;s/^# \{0,1\}//;p;}' "$0"; }
ORIG_ARGS=("$@")   # upgrade hands them to the upgraded harness (handover_steps)
while [ $# -gt 0 ]; do
  case "$1" in
    --yes) YES=1 ;;
    --dry-run) DRY_RUN=1 ;;
    --verbose) VERBOSE=1 ;;
    --no-root) NO_ROOT=1 ;;
    --no-profile) NO_PROFILE=1 ;;
    --trusted-user) TRUSTED_USER=1 ;;
    --account-sync) ACCOUNT_SYNC=1 ;;
    --no-account-sync) ACCOUNT_SYNC=0 ;;   # the default since 2026-10-24; kept for old command lines
    --code-root) CODE_ROOT="${2:?--code-root needs a directory}"; shift ;;
    --harness) HARNESS_REF="${2:?--harness needs a flake reference}"; HARNESS_REF_FROM=--harness; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "harness $CMD: unknown argument $1 (see --help)" >&2; exit 64 ;;
  esac
  shift
done
CODE_ROOT="${CODE_ROOT%/}"

# The marker text predates the harness CLI; it stays so that blocks written by
# earlier versions are still found (scripts/install.sh writes the same one).
MARK_BEGIN="# --- claude-nix-harness (scripts/bootstrap-fedora.sh) ---"
MARK_END="# --- end claude-nix-harness ---"
DEVENV_CACHE="https://devenv.cachix.org"
DEVENV_KEY="devenv.cachix.org-1:w1cLUi8dv3hnoSPGAuibQv+f9TZLr6cv/Hm9XgU50cw="
MIN_CLAUDE="2.1.295"   # onFailure: block in hook registrations
MIN_DIRENV="2.38"      # require_allowed in .envrc
MIN_TMUX="3.2"         # extended-keys
RECEIPT="$HOME/.local/state/claude-nix-harness/receipt.json"
# The built-in list: what bootstrap installs, and what upgrade falls back to
# on a host without a receipt.
PROFILE_PKGS=(direnv devenv ccmux harness)
# The host files pkgs/ ships; pkgs/harness.nix points these at the store.
DIRENV_TOML="${HARNESS_DIRENV_TOML:-$HARNESS_DIR/pkgs/direnv.toml}"
TMUX_CONF="${HARNESS_TMUX_CONF:-$HARNESS_DIR/pkgs/tmux.conf}"
# The system files the root steps touch; the tests point these, and the
# os-release and CA bundle below, at a scratch directory.
NIX_CONF="${HARNESS_NIX_CONF:-/etc/nix/nix.conf}"
SYSCTL_DROPIN="${HARNESS_SYSCTL_DROPIN:-/etc/sysctl.d/99-claude-nix-harness.conf}"
APPARMOR_PROFILE="${HARNESS_APPARMOR_PROFILE:-/etc/apparmor.d/bwrap}"
NIX_INSTALLER="${HARNESS_NIX_INSTALLER:-/nix/nix-installer}"
OS_RELEASE="${HARNESS_OS_RELEASE:-/etc/os-release}"
NIXOS_MARKER="${HARNESS_NIXOS_MARKER:-/etc/NIXOS}"
WSL_MARKER="${HARNESS_WSL_MARKER:-/proc/sys/fs/binfmt_misc/WSLInterop}"
DEFERRED=()   # declined root steps, printed at the end as commands for later

# Nix-built tools (devenv's fetcher included) look for the CA bundle at the
# NixOS and Debian path, or where NIX_SSL_CERT_FILE points. Fedora 44 keeps
# it only here (the legacy /etc/pki/tls/certs/ca-bundle.crt and
# /etc/ssl/certs/ca-bundle.crt links are gone, which is also why Fedora's
# own profile.d/nix-daemon.sh fails to set the variable).
CA_BUNDLE="${HARNESS_CA_BUNDLE:-}"
for f in /etc/pki/ca-trust/extracted/pem/tls-ca-bundle.pem /etc/pki/tls/certs/ca-bundle.crt /etc/ssl/certs/ca-certificates.crt; do
  [ -z "$CA_BUNDLE" ] && [ -r "$f" ] && CA_BUNDLE="$f"
done

missing=0; nmiss=0; nwarn=0
ok()   { printf 'ok    %s\n' "$*"; }
miss() { printf 'MISSING %s\n' "$*"; missing=1; nmiss=$((nmiss+1)); }
warn() { printf 'warn  %s\n' "$*"; nwarn=$((nwarn+1)); }
info() { printf 'info  %s\n' "$*"; }   # a shape the harness supports, not a gap: counted nowhere
step() { printf '\n==> %s\n' "$*"; }
die()  { echo "harness $CMD: $*" >&2; exit 1; }
ver_ge() { [ "$(printf '%s\n%s\n' "$2" "$1" | sort -V | head -1)" = "$2" ]; }  # ver_ge <have> <want>
in_list() { local x="$1"; shift; printf '%s\n' "$@" | grep -q -x -F -e "$x"; }  # in_list <word> <list...>
json_list() { jq -n '$ARGS.positional' --args "$@"; }

# Fedora's profile.d puts ~/.nix-profile/bin and the default profile on PATH
# for new shells; this shell may predate install.sh's dnf step. Fedora's package
# first, then the nix-installer's. The test sets the list empty: on a
# nix-installer host the default profile's real nix would otherwise outrun
# the stub (2026-10-22).
NIX_PROFILE_D="${HARNESS_NIX_PROFILE_D-/etc/profile.d/nix-daemon.sh:/nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh}"
nix_path() {
  local -a files; local f
  unset __ETC_PROFILE_NIX_SOURCED
  IFS=: read -r -a files <<<"$NIX_PROFILE_D"
  for f in "${files[@]}"; do
    # shellcheck disable=SC1090
    [ -r "$f" ] && . "$f"
  done
  [ -n "${NIX_SSL_CERT_FILE:-}" ] || [ -z "$CA_BUNDLE" ] || export NIX_SSL_CERT_FILE="$CA_BUNDLE"
  return 0
}

# ---------------------------------------------------------------- changes
# Every write to the host goes through these, so --dry-run prints what would
# happen and runs nothing, sudo included, and --verbose prints each command.
run() { # run [-q] <command...>; -q drops the command's stdout
  local quiet=0
  [ "$1" = -q ] && { quiet=1; shift; }
  if [ "$DRY_RUN" = 1 ]; then printf '    would run:'; printf ' %q' "$@"; echo; return 0; fi
  if [ "$VERBOSE" = 1 ]; then printf '    +'; printf ' %q' "$@"; echo; fi
  if [ "$quiet" = 1 ]; then "$@" >/dev/null; else "$@"; fi
}

# ask <question>: y/N from the terminal. --yes and --dry-run answer y (the
# dry run then prints what it would run); no terminal at all answers n.
ask() {
  local a=""
  [ "$YES" != 1 ] && [ "$DRY_RUN" != 1 ] || return 0
  printf '%s [y/N] ' "$1"
  if [ -t 0 ]; then read -r a || a=""; else { read -r a </dev/tty; } 2>/dev/null || a=""; fi
  case "$a" in y|Y) return 0 ;; *) return 1 ;; esac
}

put_file() { # put_file <path> <content> [append]
  if [ "$DRY_RUN" = 1 ]; then printf '    would %s %s\n' "${3:-write}" "$1"; return 0; fi
  mkdir -p "$(dirname "$1")"
  if [ "${3:-}" = append ]; then printf '%s\n' "$2" >>"$1"; else printf '%s\n' "$2" >"$1"; fi
}

write_if_differs() { # write_if_differs <path> <content>
  if [ ! -e "$1" ] || [ "$(cat "$1")" != "$2" ]; then
    step "write $1"; put_file "$1" "$2"
  fi
}

jq_edit() { # jq_edit <file> <jq args...>: rewrite a JSON file, the rest of it kept
  local f="$1" tmp; shift
  if [ "$DRY_RUN" = 1 ]; then echo "    would rewrite $f (jq)"; return 0; fi
  mkdir -p "$(dirname "$f")"; [ -s "$f" ] || echo '{}' >"$f"
  tmp=$(mktemp)
  jq "$@" "$f" >"$tmp" && mv "$tmp" "$f"
}

root_write() { # root_write <path> <content> [<NixOS option>]: a root-owned 0644 file, through sudo
  local tmp real
  # A store symlink is the NixOS configuration's: `install` would replace it
  # with a plain file that the next rebuild silently restores.
  real=$(readlink -f "$1" 2>/dev/null || true)
  [[ "$real" != /nix/store/* ]] || die "$1 is a symlink into the Nix store ($real): the system configuration owns it; set ${3:-the matching option} in configuration.nix instead"
  if [ "$DRY_RUN" = 1 ]; then echo "    would run: sudo install -m 0644 -o root -g root <new content> $1"; return 0; fi
  tmp=$(mktemp); printf '%s\n' "$2" >"$tmp"
  run sudo install -m 0644 -o root -g root "$tmp" "$1"; rm -f "$tmp"
}

# without_block <file>: the file without the harness block.
without_block() {
  awk -v b="$MARK_BEGIN" -v e="$MARK_END" '$0 == b { skip = 1 } !skip { print } $0 == e { skip = 0 }' "$1" 2>/dev/null || true
}

# put_block <file> <content>: the harness block, marked, after whatever else
# the file holds; an older block is replaced. Recorded in the receipt as a
# block, so reset strips it and leaves the rest.
put_block() {
  local want
  want=$(without_block "$1")
  want="${want:+$want
}$MARK_BEGIN
$2
$MARK_END"
  write_if_differs "$1" "$want"
  record_file block "$1"
}

# The file tmux reads: ~/.tmux.conf when it exists (tmux stops at the first
# file it finds), else ~/.config/tmux/tmux.conf.
tmux_file() { if [ -e "$HOME/.tmux.conf" ]; then echo "$HOME/.tmux.conf"; else echo "$HOME/.config/tmux/tmux.conf"; fi; }
tilde() { printf '~/%s' "${1#"$HOME/"}"; }   # tilde <path under $HOME>: for messages

# home-manager writes dotfiles as symlinks into the store; the bootstrap must
# not replace them and doctor must not report them missing.
hm_owned() { [[ "$(readlink -f "$1" 2>/dev/null)" == /nix/store/* ]]; }
HM_SKIPPED=()
hm_skip() { # hm_skip <file> <home-manager option that sets it>
  HM_SKIPPED+=("$1")
  step "$(tilde "$1") is home-manager's (a store symlink): left alone; it is set by $2"
}
# How many of the user files the bootstrap writes are home-manager's (the host line).
hm_owned_count() {
  local f n=0
  for f in "$HOME/.config/direnv/direnv.toml" "$(tmux_file)" "$HOME/.bashrc" "$HOME/.zshrc" "$HOME/.claude/settings.json" \
           "$HOME/.config/environment.d/50-claude-nix-harness.conf" "$HOME/.config/Code/User/settings.json"; do
    hm_owned "$f" && n=$((n+1))
  done
  echo "$n"
}

selinux_on() { command -v getenforce >/dev/null 2>&1 && command -v matchpathcon >/dev/null 2>&1 && [ "$(getenforce 2>/dev/null)" != Disabled ]; }

# ---------------------------------------------------------------- receipt
# What this run put on the host, or found there in the harness's shape;
# write_receipt adds it to the receipt. scripts/install.sh hands over its own
# root steps in HARNESS_ROOT_PACKAGES and HARNESS_ROOT_STEPS.
R_PROFILE=(); R_FILES=(); R_EXT=()
read -r -a R_ROOT_PKGS <<<"${HARNESS_ROOT_PACKAGES:-}"
read -r -a R_ROOT_STEPS <<<"${HARNESS_ROOT_STEPS:-}"

record_file() { # record_file <file|block|keys> <path> [<key path as a JSON array>...]
  R_FILES+=("$(jq -cn --arg k "$1" --arg p "$2" '{kind: $k, path: $p} + ($ARGS.positional | map(fromjson) | if . == [] then {} else {keys: .} end)' --args "${@:3}")")
}

write_receipt() {
  local old=null new
  [ -s "$RECEIPT" ] && old=$(jq -c . "$RECEIPT" 2>/dev/null || echo null)
  new=$(jq -n --argjson old "$old" \
    --arg ref "$HARNESS_REF" --arg rev "${HARNESS_REV:-unknown}" --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg root "$CODE_ROOT" \
    --argjson profile "$(json_list "${R_PROFILE[@]}")" \
    --argjson files "$(printf '%s\n' "${R_FILES[@]}" | jq -s .)" \
    --argjson pkgs "$(json_list "${R_ROOT_PKGS[@]}")" \
    --argjson steps "$(json_list "${R_ROOT_STEPS[@]}")" \
    --argjson ext "$(json_list "${R_EXT[@]}")" '
    def union(a; b): (a // []) + b | unique;
    { version: 1,
      harness: {ref: $ref, rev: $rev},
      timestamp: $ts,
      firstWritten: ($old.firstWritten // $ts),
      codeRoot: $root,
      profile: union($old.profile; $profile),
      files: (($old.files // []) + $files | group_by(.path)
              | map(.[0] + {keys: (map(.keys // []) | add | unique)} | if .keys == [] then del(.keys) else . end)),
      root: {packages: union($old.root.packages; $pkgs), steps: union($old.root.steps; $steps)},
      vscodeExtensions: union($old.vscodeExtensions; $ext) }')
  step "write the receipt $RECEIPT"
  [ "$VERBOSE" = 1 ] && printf '%s\n' "$new"
  put_file "$RECEIPT" "$new"
}

RECEIPT_JSON=""; HAVE_RECEIPT=0
load_receipt() {
  if jq -e '.version == 1' "$RECEIPT" >/dev/null 2>&1; then RECEIPT_JSON=$(cat "$RECEIPT"); HAVE_RECEIPT=1; fi
}
rq() { jq -r "$1" <<<"$RECEIPT_JSON"; }  # rq <filter>: from the receipt, one value per line

# ---------------------------------------------------------------- preflight
# shellcheck disable=SC1090  # the tests point this at a fake os-release
[ -r "$OS_RELEASE" ] && . "$OS_RELEASE"
# Fedora 44 or newer packages Nix itself: the dnf route. Everything else got
# Nix from the nix-installer (scripts/install.sh, which also did the dnf
# step); from here on the steps are the same.
HOST=generic; WSL=0
[ "${ID:-}" = fedora ] && [ "${VERSION_ID:-0}" -ge 44 ] 2>/dev/null && HOST=fedora
{ [ -e "$NIXOS_MARKER" ] || [ "${ID:-}" = nixos ]; } && HOST=nixos
{ [ -e "$WSL_MARKER" ] || [ -n "${WSL_DISTRO_NAME:-}" ]; } && WSL=1
# NixOS: the root files are the system configuration's (nixos_steps).
[ "$HOST" != nixos ] || NO_ROOT=1
[ "$CMD" = doctor ] || [ "$(id -u)" != 0 ] || die "run as your own user; sudo is used where root is needed"

# ---------------------------------------------------------------- root steps
root_steps() {
  local conf="$NIX_CONF" want flakes=""
  # The harness block in nix.conf: the devenv cache; flakes when nothing else
  # turns them on (Fedora's package does, the nix-installer leaves them off);
  # trusted-users only on request (header).
  # Everything but a previous harness block, then the block.
  want=$(without_block "$conf")
  grep -q -E '^experimental-features' <<<"$want" || flakes="
experimental-features = nix-command flakes"
  want="${want:+$want
}$MARK_BEGIN$flakes
extra-substituters = $DEVENV_CACHE
extra-trusted-public-keys = $DEVENV_KEY"
  [ "$TRUSTED_USER" = 1 ] && want="$want
trusted-users = root $USER"
  want="$want
$MARK_END"
  if [ "$(cat "$conf" 2>/dev/null)" != "$want" ]; then
    step "write $conf (harness block: devenv cache${flakes:+, flakes}$([ "$TRUSTED_USER" = 1 ] && echo ", trusted-users"))"
    root_write "$conf" "$want" "nix.settings.substituters, nix.settings.trusted-public-keys and nix.settings.experimental-features"
    systemctl is-active -q nix-daemon.service 2>/dev/null && run sudo systemctl restart nix-daemon.service
  fi
  R_ROOT_STEPS+=(nix.conf)

  userns_steps
}

# The Claude Code sandbox is bubblewrap, which needs unprivileged user
# namespaces. Ubuntu 23.10 and later confine them through AppArmor, older
# Debian kernels gate them with unprivileged_userns_clone; with either on,
# `failIfUnavailable` refuses every Claude command. userns_restricted sets
# USERNS_KEY and USERNS_VAL (the sysctl and the value that lifts it) and
# fails when nothing confines them, or when the AppArmor restriction is on
# but the bwrap profile already lifts it; APPARMOR_ON says the restriction
# is on either way.
USERNS_KEY=""; USERNS_VAL=""; APPARMOR_ON=0
userns_restricted() {
  USERNS_KEY=""; USERNS_VAL=""; APPARMOR_ON=0
  command -v sysctl >/dev/null 2>&1 || return 1
  if [ "$(sysctl -n kernel.apparmor_restrict_unprivileged_userns 2>/dev/null || echo 0)" = 1 ]; then
    APPARMOR_ON=1; USERNS_KEY=kernel.apparmor_restrict_unprivileged_userns; USERNS_VAL=0
    [ ! -e "$APPARMOR_PROFILE" ] || { USERNS_KEY=""; USERNS_VAL=""; return 1; }
  elif [ "$(sysctl -n kernel.unprivileged_userns_clone 2>/dev/null || echo 1)" = 0 ]; then USERNS_KEY=kernel.unprivileged_userns_clone; USERNS_VAL=1
  else return 1; fi
}

# The profile from the Claude Code sandboxing docs (section "Ubuntu 24.04
# and later", read 2026-10-23), verbatim after the marker: bwrap alone may
# create user namespaces, the sysctl stays on for everything else.
APPARMOR_TEXT="$MARK_BEGIN
abi <abi/4.0>,
include <tunables/global>
profile bwrap /usr/bin/bwrap flags=(unconfined) {
  userns,
  include if exists <local/bwrap>
}"

# NixOS: what root_steps would write, printed as configuration.nix lines
# where the host lacks it.
NIXOS_NIX_SETTINGS='  nix.settings = {
    experimental-features = [ "nix-command" "flakes" ];
    substituters = [ "'$DEVENV_CACHE'" ];
    trusted-public-keys = [ "'$DEVENV_KEY'" ];
  };'
nixos_steps() {
  local lack=()
  grep -q -E '^experimental-features.*flakes' "$NIX_CONF" 2>/dev/null || lack+=(flakes)
  grep -q -F "$DEVENV_CACHE" "$NIX_CONF" 2>/dev/null || lack+=("the devenv cache")
  if [ ${#lack[@]} -gt 0 ]; then
    step "NixOS: $NIX_CONF is the system configuration's and lacks ${lack[*]}; add to configuration.nix and rebuild:"
    printf '%s\n' "$NIXOS_NIX_SETTINGS"
  fi
  if userns_restricted; then
    step "NixOS: user namespaces are confined ($USERNS_KEY = $((1 - USERNS_VAL))), and the Claude Code sandbox (bubblewrap) needs them; in configuration.nix:"
    printf '  boot.kernel.sysctl."%s" = %s;\n' "$USERNS_KEY" "$USERNS_VAL"
  fi
}

# A kernel setting, so it is asked for on its own: what runs is shown,
# --yes answers it, and a decline prints it for later (doctor keeps
# reporting the restriction).
userns_steps() {
  local key val l deferred
  userns_restricted || return 0
  key=$USERNS_KEY; val=$USERNS_VAL
  if [ "$key" = kernel.apparmor_restrict_unprivileged_userns ]; then
    step "user namespaces: AppArmor confines them ($key = 1), and the Claude Code sandbox (bubblewrap) needs them"
    echo "    this writes $APPARMOR_PROFILE (the bwrap profile from the Claude Code sandboxing docs) and runs sudo systemctl reload apparmor"
    if ask "    apply with sudo now?"; then
      root_write "$APPARMOR_PROFILE" "$APPARMOR_TEXT" "security.apparmor.policies"
      run sudo systemctl reload apparmor
      R_ROOT_STEPS+=(apparmor)
    else
      deferred="printf '%s\\n'"; while IFS= read -r l; do deferred="$deferred '$l'"; done <<<"$APPARMOR_TEXT"
      DEFERRED+=("$deferred | sudo tee $APPARMOR_PROFILE && sudo systemctl reload apparmor")
      warn "declined: every Claude command is refused until it runs (harness doctor keeps reporting it)"
    fi
    return 0
  fi
  step "user namespaces: $key is $((1 - val)), and the Claude Code sandbox (bubblewrap) needs them"
  echo "    this runs: sudo sysctl -w $key=$val, and writes $SYSCTL_DROPIN so it holds across reboots"
  if ask "    apply with sudo now?"; then
    run sudo sysctl -w "$key=$val"
    root_write "$SYSCTL_DROPIN" "$key = $val" "boot.kernel.sysctl.\"$key\""
    R_ROOT_STEPS+=(sysctl)
  else
    DEFERRED+=("sudo sysctl -w $key=$val && echo '$key = $val' | sudo tee $SYSCTL_DROPIN")
    warn "declined: every Claude command is refused until it runs (harness doctor keeps reporting it)"
  fi
}

# ---------------------------------------------------------------- user steps
# After `upgrade` has moved the profile, the user steps belong to the harness
# now in the profile, not to the one running: this process is the old build,
# and its user steps are the old ones. On 2026-10-22 that wrote the scrub key
# back into ~/.claude/settings.json right after upgrading to the build that
# removes it. The wrapper exports its own store path as HARNESS_SELF; when
# the profile's differs, the rest of the run is the new wrapper's
# `bootstrap --no-root --no-profile` with the original flags (the root and
# profile steps are done). No profile entry, or the same path: carry on.
handover_steps() {
  [ "$CMD" = upgrade ] && [ "$NO_PROFILE" = 0 ] || return 0
  local new
  new=$(readlink -f "$HOME/.nix-profile/bin/harness" 2>/dev/null || true)
  if [ "$DRY_RUN" = 1 ]; then echo "    would hand the user steps to the upgraded harness (${new:-$HOME/.nix-profile/bin/harness})"; return 0; fi
  [ -n "$new" ] && [ "$new" != "${HARNESS_SELF:-}" ] || return 0
  step "hand the user steps to the upgraded harness ($new)"
  exec "$new" bootstrap --no-root --no-profile "${ORIG_ARGS[@]}"
}

profile_has() { # profile_has <name>
  nix profile list --json 2>/dev/null \
    | jq -e --arg n "$1" '.elements | if type == "object" then has($n) else map((.attrPath // "") | endswith("." + $n)) | any end' >/dev/null
}
profile_url() { # profile_url <name>: the flake the profile entry was added from
  nix profile list --json 2>/dev/null \
    | jq -r --arg n "$1" '.elements | if type == "object" then (.[$n].originalUrl // "") else (map(select((.attrPath // "") | endswith("." + $n))) | .[0].originalUrl // "") end'
}

profile_steps() {
  local sub=install name url
  nix_path
  if ! command -v nix >/dev/null; then
    [ "$DRY_RUN" = 1 ] || die "nix not on PATH: scripts/install.sh installs it (Fedora's packages, or the nix-installer elsewhere)"
    for name in "${PROFILE_PKGS[@]}"; do step "nix profile add $HARNESS_REF#$name"; run nix profile add "$HARNESS_REF#$name"; done
    return 0
  fi
  nix store info >/dev/null 2>&1 || nix store ping >/dev/null 2>&1 || die "the nix daemon does not answer (systemctl status nix-daemon.socket)"
  nix profile add --help >/dev/null 2>&1 && sub=add
  for name in "${PROFILE_PKGS[@]}"; do
    if profile_has "$name"; then
      if [ "$CMD" = upgrade ]; then
        url=$(profile_url "$name")
        if [ "$url" = "$HARNESS_REF" ]; then step "nix profile upgrade $name"; run nix profile upgrade "$name"
        else
          step "nix profile: $name from $HARNESS_REF (was ${url:-unknown})"
          # Built first: a bad ref or no network then fails here, with the old entry still in place.
          run nix build --no-link "$HARNESS_REF#$name"
          run nix profile remove "$name"; run nix profile "$sub" "$HARNESS_REF#$name"
        fi
      fi
    else
      step "nix profile $sub $HARNESS_REF#$name"
      [ "$name" = direnv ] && echo "    (direnv builds from source while nixpkgs ships < $MIN_DIRENV; a few minutes once)"
      run nix profile "$sub" "$HARNESS_REF#$name"
    fi
    R_PROFILE+=("$name")
  done
}

user_steps() {
  # direnv: the home module's programs.direnv.config.global.
  local f="$HOME/.config/direnv/direnv.toml" direnv_toml
  direnv_toml="$MARK_BEGIN
$(cat "$DIRENV_TOML")"
  if hm_owned "$f"; then hm_skip "$f" "programs.direnv.config.global (pkgs/direnv.toml), or the harness home module"
  elif [ -e "$f" ] && ! grep -q -F "$MARK_BEGIN" "$f"; then
    warn "$f exists and is not the harness one; merge by hand: strict_env, warn_timeout = \"2m\", load_dotenv = false, no whitelist"
  else
    write_if_differs "$f" "$direnv_toml"; record_file file "$f"
  fi

  # tmux: the home module's programs.tmux.extraConfig, a marked block after
  # whatever else the file tmux reads holds (tmux_file). An older block is
  # replaced, so a changed pkgs/tmux.conf reaches a bootstrapped host on the
  # next bootstrap or upgrade.
  local tf; tf=$(tmux_file)
  if hm_owned "$tf"; then hm_skip "$tf" "programs.tmux.extraConfig = builtins.readFile pkgs/tmux.conf"
  else put_block "$tf" "$(cat "$TMUX_CONF")"; fi

  # bash: the direnv hook and the code root (home.sessionVariables), in
  # ~/.bashrc.d, which Fedora's stock ~/.bashrc sources after /etc/bashrc has
  # run profile.d, so the nix profile is already on PATH here. No
  # HARNESS_EXPECT_MANAGED: this host has no managed settings by design.
  local root_expr="$CODE_ROOT"
  [[ "$root_expr" == "$HOME/"* ]] && root_expr="\$HOME/${root_expr#"$HOME/"}"
  f="$HOME/.bashrc.d/claude-nix-harness.sh"
  write_if_differs "$f" "$MARK_BEGIN
export HARNESS_CODE_ROOT=\"$root_expr\"
# Fedora's own profile.d/nix-daemon.sh only knows the legacy bundle paths.
[ -n \"\${NIX_SSL_CERT_FILE:-}\" ] || export NIX_SSL_CERT_FILE=\"${CA_BUNDLE:-/etc/pki/ca-trust/extracted/pem/tls-ca-bundle.pem}\"
if command -v direnv >/dev/null 2>&1; then eval \"\$(direnv hook bash)\"; fi"
  record_file file "$f"

  # Another distro's ~/.bashrc does not source ~/.bashrc.d, so it gets one
  # line (a marked block) to do so. No rc file at all: ~/.bashrc is created,
  # unless the person runs zsh (a ~/.zshrc and nothing else). A ~/.zshrc
  # gets the same three lines as a block of its own.
  local rc="$HOME/.bashrc" zrc="$HOME/.zshrc"
  if hm_owned "$rc"; then hm_skip "$rc" "programs.direnv.enableBashIntegration (the hook) and home.sessionVariables.HARNESS_CODE_ROOT"
  elif { [ -e "$rc" ] || [ ! -e "$zrc" ]; } && ! without_block "$rc" | grep -q 'bashrc\.d'; then
    put_block "$rc" '[ -r ~/.bashrc.d/claude-nix-harness.sh ] && . ~/.bashrc.d/claude-nix-harness.sh'
  fi
  if hm_owned "$zrc"; then hm_skip "$zrc" "programs.direnv.enableZshIntegration and home.sessionVariables.HARNESS_CODE_ROOT"
  elif [ -e "$zrc" ]; then
    put_block "$zrc" "export HARNESS_CODE_ROOT=\"$root_expr\"
[ -n \"\${NIX_SSL_CERT_FILE:-}\" ] || export NIX_SSL_CERT_FILE=\"${CA_BUNDLE:-/etc/ssl/certs/ca-certificates.crt}\"
if command -v direnv >/dev/null 2>&1; then eval \"\$(direnv hook zsh)\"; fi"
  fi

  # GUI session PATH: VS Code launched from the menu (and the claude it spawns)
  # otherwise never sees the nix profile. systemd user environment generator;
  # takes effect at the next login.
  f="$HOME/.config/environment.d/50-claude-nix-harness.conf"
  if hm_owned "$f"; then hm_skip "$f" "home.sessionPath and home.sessionVariables"
  else
    write_if_differs "$f" "$MARK_BEGIN
PATH=\$HOME/.nix-profile/bin:/nix/var/nix/profiles/default/bin:\$HOME/.local/bin:\$PATH
NIX_SSL_CERT_FILE=${CA_BUNDLE:-/etc/pki/ca-trust/extracted/pem/tls-ca-bundle.pem}"
    record_file file "$f"
  fi

  [ -d "$CODE_ROOT" ] || { step "mkdir $CODE_ROOT"; run mkdir -p "$CODE_ROOT"; }

  # Claude Code user settings: the keys a repo file cannot carry (header).
  # Merged with jq so the rest of the file (theme, model, ...) stays.
  local cs="$HOME/.claude/settings.json" want keys=('["sandbox","network","strictAllowlist"]')
  want='{sandbox: {network: {strictAllowlist: true}}}'
  if [ "$ACCOUNT_SYNC" = 0 ]; then
    want="$want + {syncClaudeAiSkills: false, syncClaudeAiPlugins: false}"
    keys+=('["syncClaudeAiSkills"]' '["syncClaudeAiPlugins"]')
  fi
  if hm_owned "$cs"; then hm_skip "$cs" "programs.claude-code.settings (sandbox.network.strictAllowlist = true$([ "$ACCOUNT_SYNC" = 0 ] && echo ", syncClaudeAiSkills and syncClaudeAiPlugins = false"))"
  elif ! jq -e --argjson w "$(jq -n "$want")" '. as $s | ($s * $w) == $s' "$cs" >/dev/null 2>&1; then
    step "set the user-scope keys in $cs (strict network allowlist$([ "$ACCOUNT_SYNC" = 0 ] && echo ", account sync off"))"
    jq_edit "$cs" --argjson w "$(jq -n "$want")" '. * $w'
  fi
  record_file keys "$cs" "${keys[@]}"
  # --account-sync: a `false` an earlier bootstrap (or anyone) wrote would
  # keep sync off, so it goes; a key that is absent or true is left alone.
  if [ "$ACCOUNT_SYNC" = 1 ] && ! hm_owned "$cs" \
     && jq -e '.syncClaudeAiSkills == false or .syncClaudeAiPlugins == false' "$cs" >/dev/null 2>&1; then
    step "remove syncClaudeAiSkills and syncClaudeAiPlugins = false from $cs (--account-sync)"
    jq_edit "$cs" 'if .syncClaudeAiSkills == false then del(.syncClaudeAiSkills) else . end
      | if .syncClaudeAiPlugins == false then del(.syncClaudeAiPlugins) else . end'
  fi
  # Written by the bootstrap for a few hours on 2026-10-22: with it Claude
  # Code stops auto-allowing sandboxed Bash commands (header).
  if ! hm_owned "$cs" && jq -e '.env.CLAUDE_CODE_SUBPROCESS_ENV_SCRUB' "$cs" >/dev/null 2>&1; then
    step "remove env.CLAUDE_CODE_SUBPROCESS_ENV_SCRUB from $cs (it turns the sandbox's Bash auto-allow off)"
    jq_edit "$cs" 'del(.env.CLAUDE_CODE_SUBPROCESS_ENV_SCRUB) | if .env == {} then del(.env) else . end'
  fi

  # VS Code: mkhl.direnv loads the devenv shell into the window (runbook,
  # daily flow); direnv.path makes it work before the next login too.
  local vs="$HOME/.config/Code/User/settings.json"
  if hm_owned "$vs"; then hm_skip "$vs" "programs.vscode.profiles.default: userSettings (direnv.path.executable) and extensions (mkhl.direnv)"
  elif command -v code >/dev/null 2>&1; then
    if ! code --list-extensions 2>/dev/null | grep -q -i -x 'mkhl.direnv'; then
      step "code --install-extension mkhl.direnv"
      run -q code --install-extension mkhl.direnv
    fi
    R_EXT+=(mkhl.direnv)
    local direnv_bin
    nix_path; direnv_bin=$(command -v direnv 2>/dev/null || echo "$HOME/.nix-profile/bin/direnv")
    if ! jq -e --arg p "$direnv_bin" --arg c "$CA_BUNDLE" \
         '.["direnv.path.executable"] == $p and .["direnv.extraEnv"].NIX_SSL_CERT_FILE == $c' "$vs" >/dev/null 2>&1; then
      step "set direnv.path.executable and direnv.extraEnv.NIX_SSL_CERT_FILE in $vs"
      jq_edit "$vs" --arg p "$direnv_bin" --arg c "$CA_BUNDLE" \
        '. + {"direnv.path.executable": $p} | .["direnv.extraEnv"] = ((.["direnv.extraEnv"] // {}) + {NIX_SSL_CERT_FILE: $c})'
    fi
    record_file keys "$vs" '["direnv.path.executable"]' '["direnv.extraEnv","NIX_SSL_CERT_FILE"]'
  fi
}

# ---------------------------------------------------------------- reset
# strip_block <file>: the file without the harness block; removes the file
# when nothing else is left.
strip_block() {
  local f="$1" rest
  [ -e "$f" ] || return 0
  grep -q -F "$MARK_BEGIN" "$f" || return 0
  rest=$(without_block "$f")
  if [ -z "$(printf '%s' "$rest" | tr -d '[:space:]')" ]; then step "remove $f"; run rm -f "$f"
  else step "remove the harness block from $f"; put_file "$f" "$rest"; fi
}

# strip_keys <file> <key paths, JSON>: the harness's keys out of a JSON file,
# then the objects they leave empty.
strip_keys() {
  local f="$1" k="$2"
  [ -s "$f" ] && jq -e --argjson k "$k" '. as $doc | any($k[]; . as $p | $doc | try (getpath($p) != null) catch false)' "$f" >/dev/null 2>&1 || return 0
  step "remove the harness keys from $f"
  jq_edit "$f" --argjson k "$k" 'reduce $k[] as $p (.; try delpaths([$p]) catch .)
    | reduce ($k[] | . as $p | range(length - 1; 0; -1) | $p[:.]) as $q (.; if getpath($q) == {} then delpaths([$q]) else . end)'
}

reset_steps() {
  local pkgs=() steps=() profile=() exts=() nix_from="" i p f kind keys answer key
  load_receipt
  [ "$HAVE_RECEIPT" = 1 ] || { echo "no receipt at $RECEIPT: nothing recorded, nothing to reset"; exit 0; }
  mapfile -t pkgs < <(rq '.root.packages[]?')
  mapfile -t steps < <(rq '.root.steps[]?')
  mapfile -t profile < <(rq '.profile[]?')
  mapfile -t exts < <(rq '.vscodeExtensions[]?')
  # Who put Nix there: dnf (Fedora), the nix-installer, or nobody we know.
  in_list nix "${pkgs[@]}" && nix_from=dnf
  in_list nix-installer "${steps[@]}" && nix_from=installer

  echo "This removes, on this host (from the receipt):"
  if [ "$NO_ROOT" = 1 ]; then echo "  root:  nothing (--no-root)"
  else
    [ ${#pkgs[@]} -eq 0 ] || echo "  root:  the packages ${pkgs[*]} (and the dependencies dnf pulled in with them)"
    case "$nix_from" in
      dnf) echo "  root:  nix-daemon.socket, /nix and /etc/nix, the nixbld build users" ;;
      installer) echo "  root:  Nix, by $NIX_INSTALLER uninstall (/nix, /etc/nix, the build users, its lines in the system rc files)" ;;
      *)
        in_list nix-daemon.socket "${steps[@]}" && echo "  root:  nix-daemon.socket disabled (Nix stays; install.sh enables it again)"
        in_list nix.conf "${steps[@]}" && echo "  root:  the harness block in $NIX_CONF" ;;
    esac
    in_list selinux "${steps[@]}" && echo "  root:  the SELinux rule for the daemon socket"
    in_list sysctl "${steps[@]}" && echo "  root:  $SYSCTL_DROPIN, and the kernel's user-namespace restriction back on"
    in_list apparmor "${steps[@]}" && echo "  root:  $APPARMOR_PROFILE (bwrap may no longer create user namespaces), AppArmor reloaded"
  fi
  if [ -n "$nix_from" ]; then
    echo "  user:  the nix profile and state (~/.nix-profile, ~/.local/state/nix), ~/.cache/nix,"
    echo "         ~/.cache/devenv, the direnv allow database (~/.local/share/direnv)"
  elif [ ${#profile[@]} -gt 0 ]; then
    echo "  user:  the profile packages ${profile[*]}"
    in_list direnv "${profile[@]}" && echo "  user:  the direnv allow database (~/.local/share/direnv)"
  fi
  rq '.files[] | "  \(.kind | . + " " * (6 - length)) \(.path)\(if .keys then " (" + (.keys | map(join(".")) | join(", ")) + ")" else "" end)"'
  [ ${#exts[@]} -eq 0 ] || echo "  VS Code extension ${exts[*]} and its settings"
  echo "  the receipt, last"
  echo "Not touched: $CODE_ROOT (delete a test repo by hand), the rest of Claude Code's own files."
  if [ "$YES" != 1 ] && [ "$DRY_RUN" != 1 ]; then
    printf "Type 'reset' to continue: "; read -r answer; [ "$answer" = reset ] || die "aborted"
  fi

  if [ "$NO_ROOT" != 1 ]; then
    [ "$DRY_RUN" = 1 ] || sudo -v || die "sudo is needed for the root part (or pass --no-root)"
    # The nix-installer's uninstall stops the daemon itself.
    if [ "$nix_from" = dnf ] || { [ -z "$nix_from" ] && in_list nix-daemon.socket "${steps[@]}"; }; then
      step "disable the nix daemon"
      run sudo systemctl disable --now nix-daemon.socket nix-daemon.service 2>/dev/null || true
    fi
    local installed=()
    for p in "${pkgs[@]}"; do rpm -q "$p" >/dev/null 2>&1 && installed+=("$p"); done
    if [ ${#installed[@]} -gt 0 ]; then step "dnf remove ${installed[*]}"; run sudo dnf remove -y "${installed[@]}"; fi
    case "$nix_from" in
      dnf)
        step "remove /nix and /etc/nix"
        run sudo rm -rf /nix /etc/nix ;;
      installer)
        if [ -x "$NIX_INSTALLER" ]; then step "uninstall Nix ($NIX_INSTALLER uninstall)"; run sudo "$NIX_INSTALLER" uninstall --no-confirm
        else warn "$NIX_INSTALLER is gone: Nix left as it is"; fi ;;
      *)
        if in_list nix.conf "${steps[@]}" && grep -q -F "$MARK_BEGIN" "$NIX_CONF" 2>/dev/null; then
          step "remove the harness block from $NIX_CONF"
          root_write "$NIX_CONF" "$(without_block "$NIX_CONF")"
        fi ;;
    esac
    if in_list selinux "${steps[@]}" && selinux_on; then
      step "remove the SELinux rule for the daemon socket"
      run sudo semanage fcontext -d '/nix/var/nix/daemon-socket(/.*)?' 2>/dev/null || true
    fi
    if in_list sysctl "${steps[@]}"; then
      step "remove $SYSCTL_DROPIN and put the kernel's user-namespace restriction back"
      key=$(sed -n 's/ *=.*//p' "$SYSCTL_DROPIN" 2>/dev/null | head -1)
      case "$key" in
        kernel.apparmor_restrict_unprivileged_userns) run sudo sysctl -w "$key=1" ;;
        kernel.unprivileged_userns_clone) run sudo sysctl -w "$key=0" ;;
      esac
      run sudo rm -f "$SYSCTL_DROPIN"
    fi
    if in_list apparmor "${steps[@]}"; then
      if grep -q -F "$MARK_BEGIN" "$APPARMOR_PROFILE" 2>/dev/null; then
        step "remove $APPARMOR_PROFILE and reload AppArmor"
        run sudo rm -f "$APPARMOR_PROFILE"; run sudo systemctl reload apparmor
      elif [ -e "$APPARMOR_PROFILE" ]; then warn "$APPARMOR_PROFILE no longer carries the harness marker: left alone"; fi
    fi
    if [ "$nix_from" = dnf ]; then
      step "remove the nixbld build users"
      for i in $(seq 1 10); do run sudo userdel "nixbld-$i" 2>/dev/null || true; done
      run sudo groupdel nixbld 2>/dev/null || true
    fi
  fi

  if [ -n "$nix_from" ]; then
    step "remove the nix profile, caches and the direnv allow database"
    run rm -rf "$HOME/.nix-profile" "$HOME/.nix-defexpr" "$HOME/.nix-channels" "$HOME/.local/state/nix" \
           "$HOME/.cache/nix" "$HOME/.cache/devenv" "$HOME/.local/share/devenv" "$HOME/.local/share/direnv"
  else
    nix_path
    for p in "${profile[@]}"; do
      if command -v nix >/dev/null 2>&1 && profile_has "$p"; then step "nix profile remove $p"; run nix profile remove "$p"; fi
    done
    if in_list direnv "${profile[@]}" && [ -d "$HOME/.local/share/direnv" ]; then
      step "remove the direnv allow database"; run rm -rf "$HOME/.local/share/direnv"
    fi
  fi
  while IFS=$'\t' read -r kind f keys; do
    case "$kind" in
      file)
        if grep -q -F "$MARK_BEGIN" "$f" 2>/dev/null; then step "remove $f"; run rm -f "$f"
        elif [ -e "$f" ]; then warn "$f no longer carries the harness marker: left alone"; fi ;;
      block) strip_block "$f" ;;
      keys) strip_keys "$f" "$keys" ;;
    esac
  done < <(rq '.files[] | [.kind, .path, ((.keys // []) | tojson)] | @tsv')
  if [ ${#exts[@]} -gt 0 ] && command -v code >/dev/null 2>&1; then
    for p in "${exts[@]}"; do
      if code --list-extensions 2>/dev/null | grep -q -i -x "$p"; then
        step "code --uninstall-extension $p"; run -q code --uninstall-extension "$p" 2>/dev/null || true
      fi
    done
  fi
  if [ -e "$RECEIPT" ]; then
    step "remove the receipt $RECEIPT"
    run rm -f "$RECEIPT"; run rmdir --ignore-fail-on-non-empty "$(dirname "$RECEIPT")"
  fi
  cat <<NEXT

Reset done$([ "$DRY_RUN" = 1 ] && echo " (dry run: nothing changed)"). From zero again: open a new terminal (this one still has the old
PATH), delete a test repo if you want \`harness init\` from scratch, e.g.
  rm -rf $CODE_ROOT/raul/harness-test
then scripts/install.sh (from a checkout, or the curl line in the README) and
the rest of the runbook's "From zero" list. Log out and in once at the end for
GUI-launched VS Code.
NEXT
}

# ---------------------------------------------------------------- report
report() {
  nix_path
  local v route="" tf fix host="${PRETTY_NAME:-unknown}" hm
  case "$HOST" in
    fedora) route="nix from Fedora's packages" ;;
    nixos) hm=$(hm_owned_count); route="nix from the system configuration, $hm home-manager owned file$([ "$hm" = 1 ] || echo s) skipped" ;;
    *) [ -x "$NIX_INSTALLER" ] && route="nix from the nix-installer" ;;
  esac
  [ "$WSL" = 0 ] || host="WSL2 ($host)"
  echo "host: $host ($(uname -m))$(selinux_on && echo ", SELinux $(getenforce)")${route:+, $route}"
  echo "harness: ${HARNESS_REV:-unknown}, ref $HARNESS_REF ($HARNESS_REF_FROM)"
  if [ -s "$RECEIPT" ]; then ok "receipt $RECEIPT (harness $(jq -r '.harness.rev // "?"' "$RECEIPT" 2>/dev/null), $(jq -r '.timestamp // "?"' "$RECEIPT" 2>/dev/null))"
  else warn "no receipt at $RECEIPT: reset has nothing to undo, upgrade uses the built-in package list (harness bootstrap writes one)"; fi

  if command -v nix >/dev/null 2>&1; then
    v=$(nix --version | awk '{print $NF}')
    if nix store info >/dev/null 2>&1 || nix store ping >/dev/null 2>&1; then ok "nix $v, daemon answers"; else miss "nix $v installed but the daemon does not answer (systemctl enable --now nix-daemon.socket)"; fi
    fix="harness bootstrap writes the line"; [ "$HOST" != nixos ] || fix="nix.settings in configuration.nix; harness bootstrap prints the block"
    grep -q -E '^experimental-features.*flakes' "$NIX_CONF" 2>/dev/null && ok "flakes enabled in $NIX_CONF" || miss "flakes not enabled in $NIX_CONF ($fix)"
    grep -q -F "$DEVENV_CACHE" "$NIX_CONF" 2>/dev/null && ok "devenv cache in $NIX_CONF" || warn "devenv cache not in $NIX_CONF: devenv builds more from source ($fix)"
    if selinux_on; then
      if matchpathcon -n /nix/var/nix/daemon-socket/socket 2>/dev/null | grep -q var_run_t; then ok "SELinux: daemon socket directory labeled var_run_t"
      else miss "SELinux: daemon socket directory labeled $(matchpathcon -n /nix/var/nix/daemon-socket/socket 2>/dev/null), systemd cannot create the socket (sudo semanage fcontext -a -t var_run_t '/nix/var/nix/daemon-socket(/.*)?'; sudo restorecon -RF /nix/var/nix/daemon-socket)"; fi
      if systemctl is-active -q auditd 2>/dev/null; then warn "SELinux denials go to auditd, not the journal: sudo ausearch -m avc -ts recent | grep nix"
      elif journalctl -q -b -g 'avc.*(nix|/nix/)' --no-pager 2>/dev/null | grep -q .; then warn "SELinux denials mentioning nix in this boot's journal: journalctl -b -g avc"
      else ok "no SELinux denials mentioning nix in this boot's journal"; fi
    fi
  else
    miss "nix (scripts/install.sh installs it: Fedora's packages, or the nix-installer elsewhere)"
  fi

  if [ -n "$CA_BUNDLE" ]; then ok "CA bundle for Nix-built tools: $CA_BUNDLE (NIX_SSL_CERT_FILE)"; else miss "no CA bundle found for NIX_SSL_CERT_FILE: devenv cannot fetch over https"; fi
  if command -v direnv >/dev/null 2>&1; then
    v=$(direnv version); ver_ge "$v" "$MIN_DIRENV" && ok "direnv $v ($(command -v direnv))" || miss "direnv $v is older than $MIN_DIRENV (require_allowed): nix profile add $HARNESS_REF#direnv"
  else miss "direnv >= $MIN_DIRENV (nix profile add $HARNESS_REF#direnv)"; fi
  if command -v devenv >/dev/null 2>&1; then ok "devenv $(devenv version 2>/dev/null | awk '{print $NF}') ($(command -v devenv))"; else miss "devenv (nix profile add $HARNESS_REF#devenv)"; fi
  if command -v ccmux >/dev/null 2>&1; then ok "ccmux ($(command -v ccmux))"; else warn "ccmux not on the host PATH (the devenv shell of a harness repo has it; nix profile add $HARNESS_REF#ccmux for everywhere)"; fi

  for t in bwrap socat; do command -v "$t" >/dev/null 2>&1 && ok "$t ($(command -v "$t"))" || miss "$t (bubblewrap and socat from your distro's packages; the devenv shell's claude-code brings its own): the sandbox refuses to start without it"; done
  v=$(cat /proc/sys/user/max_user_namespaces 2>/dev/null || echo 0)
  [ "$v" -gt 0 ] && ok "user namespaces enabled (max $v)" || miss "user namespaces disabled: bubblewrap cannot run"
  if command -v sysctl >/dev/null 2>&1; then
    fix="harness bootstrap offers the sysctl"; [ "$HOST" != nixos ] || fix="boot.kernel.sysctl in configuration.nix"
    if userns_restricted; then
      case "$USERNS_KEY" in
        kernel.apparmor_restrict_unprivileged_userns) miss "AppArmor confines unprivileged user namespaces ($USERNS_KEY = 1) and $APPARMOR_PROFILE is missing: bubblewrap cannot run; ${fix/offers the sysctl/writes the profile}" ;;
        *) miss "$USERNS_KEY = 0: bubblewrap cannot run; $fix" ;;
      esac
    elif [ "$APPARMOR_ON" = 1 ]; then
      ok "AppArmor confines unprivileged user namespaces; $APPARMOR_PROFILE lifts it for bwrap"
      [ "$(readlink -f "$(command -v bwrap 2>/dev/null || echo /usr/bin/bwrap)")" = /usr/bin/bwrap ] || warn "the profile is for /usr/bin/bwrap but bwrap on PATH is $(command -v bwrap): the sandbox may still be refused"
    else ok "no sysctl confines unprivileged user namespaces"; fi
  fi
  if bwrap --ro-bind / / --dev /dev --proc /proc --unshare-all --die-with-parent -- /bin/true 2>/dev/null; then ok "bubblewrap works here"; else miss "bubblewrap cannot create a sandbox here"; fi
  # ccmux carries its own tmux and a repo's harness.claudeCode.enable puts
  # one in its shell, so a host without tmux still runs sessions; `tmux
  # attach` or `tmux ls` from a plain terminal does not work there.
  if command -v tmux >/dev/null 2>&1; then v=$(tmux -V | awk '{print $2}'); ver_ge "${v//[a-z]/}" "$MIN_TMUX" && ok "tmux $v" || warn "tmux $v is older than $MIN_TMUX (extended-keys)"
  else warn "tmux not on the host PATH: ccmux brings its own and harness.claudeCode.enable puts one in a repo's shell; tmux attach from a plain terminal needs your distro's package"; fi
  command -v jq >/dev/null 2>&1 && ok "jq" || miss "jq (your distro's package)"
  command -v git >/dev/null 2>&1 && ok "git $(git --version | awk '{print $3}')" || miss "git (your distro's package)"

  if command -v claude >/dev/null 2>&1; then
    v=$(claude --version 2>/dev/null | awk '{print $1}')
    ver_ge "$v" "$MIN_CLAUDE" && ok "claude $v ($(command -v claude), autoUpdates=$(jq -r 'if has("autoUpdates") then .autoUpdates else "default" end' "$HOME/.claude.json" 2>/dev/null))" || miss "claude $v is older than $MIN_CLAUDE (onFailure: block)"
  # No host-wide claude is a supported shape (the plain WSL host): VS Code's
  # extension runs its bundled binary, and repos bring the CLI.
  else info "claude not on the host PATH: the VS Code extension brings its own; repos get the CLI from harness.claudeCode.enable (harness init turns it on on such a host)"; fi
  local cs="$HOME/.claude/settings.json"
  if jq -e '.sandbox.network.strictAllowlist == true' "$cs" >/dev/null 2>&1; then ok "strict network allowlist in $cs (unlisted hosts refused, not prompted)"
  else miss "sandbox.network.strictAllowlist is not true in $cs (user-or-managed scope; the repo file cannot set it)"; fi
  if jq -e '.env.CLAUDE_CODE_SUBPROCESS_ENV_SCRUB' "$cs" >/dev/null 2>&1; then miss "env.CLAUDE_CODE_SUBPROCESS_ENV_SCRUB in $cs: Claude Code stops auto-allowing sandboxed Bash commands, every command prompts (harness bootstrap removes it)"; fi
  if jq -e '.syncClaudeAiSkills == false and .syncClaudeAiPlugins == false' "$cs" >/dev/null 2>&1; then ok "account-synced skills and plugins off in $cs"
  else warn "account-synced skills and plugins load (syncClaudeAiSkills, syncClaudeAiPlugins not false in $cs; the harness reviews none of them): harness bootstrap turns them off, unless run with --account-sync"; fi
  [ -r /etc/claude-code/managed-settings.json ] && warn "/etc/claude-code/managed-settings.json exists: this host carries managed settings, the harness assumed none" || ok "no managed settings (unmanaged host: the repo file is the whole harness)"

  # From inside a session `code` is on PATH but dies before printing (the
  # shell's LD_LIBRARY_PATH makes the host binary load a Nix glibc, measured
  # 2026-10-21), so an extension verdict there would be a false MISSING.
  if ! command -v code >/dev/null 2>&1; then warn "code not on PATH: VS Code steps skipped"
  else
    v=$(code --version 2>/dev/null | head -1 || true)
    if [ -z "$v" ]; then warn "code is on PATH but answers nothing (from inside a session the shell's library path breaks the host binary): VS Code steps skipped, run doctor from your own terminal"
    else
      ok "code $v"
      code --list-extensions 2>/dev/null | grep -q -i -x 'anthropic.claude-code' && ok "VS Code extension anthropic.claude-code" || warn "VS Code extension anthropic.claude-code not installed"
      code --list-extensions 2>/dev/null | grep -q -i -x 'mkhl.direnv' && ok "VS Code extension mkhl.direnv" || miss "VS Code extension mkhl.direnv (code --install-extension mkhl.direnv)"
    fi
  fi

  [ -d "$CODE_ROOT" ] && ok "code root $CODE_ROOT" || miss "code root $CODE_ROOT (ccmux resolves <customer>/<repo> under it)"
  if hm_owned "$HOME/.config/direnv/direnv.toml"; then ok "direnv.toml (home-manager)"
  elif grep -q -F "$MARK_BEGIN" "$HOME/.config/direnv/direnv.toml" 2>/dev/null; then ok "direnv.toml"
  elif [ -e "$HOME/.config/direnv/direnv.toml" ]; then warn "~/.config/direnv/direnv.toml exists and is not the harness one (strict_env, warn_timeout, load_dotenv = false)"
  else miss "~/.config/direnv/direnv.toml"; fi
  tf=$(tmux_file)
  if hm_owned "$tf"; then ok "tmux config $(tilde "$tf") (home-manager)"
  else grep -q -F "$MARK_BEGIN" "$tf" 2>/dev/null && ok "tmux harness block in $(tilde "$tf")" || miss "tmux harness block in $(tilde "$tf")"; fi
  if hm_owned "$HOME/.bashrc"; then ok "~/.bashrc (home-manager: the direnv hook and HARNESS_CODE_ROOT come from it)"
  else
    grep -q 'direnv hook bash' "$HOME/.bashrc.d/claude-nix-harness.sh" 2>/dev/null && ok "direnv hook and HARNESS_CODE_ROOT in ~/.bashrc.d" || miss "~/.bashrc.d/claude-nix-harness.sh"
    if [ -e "$HOME/.bashrc" ] || [ ! -e "$HOME/.zshrc" ]; then
      grep -q 'bashrc\.d' "$HOME/.bashrc" 2>/dev/null && ok "~/.bashrc sources ~/.bashrc.d" || miss "~/.bashrc does not source ~/.bashrc.d (harness bootstrap adds the line)"
    fi
  fi
  if hm_owned "$HOME/.zshrc"; then ok "~/.zshrc (home-manager)"
  elif [ -e "$HOME/.zshrc" ]; then grep -q 'direnv hook zsh' "$HOME/.zshrc" && ok "direnv hook in ~/.zshrc" || miss "~/.zshrc has no direnv hook (harness bootstrap adds it)"; fi
  if hm_owned "$HOME/.config/environment.d/50-claude-nix-harness.conf"; then ok "session PATH (home-manager)"
  else [ -r "$HOME/.config/environment.d/50-claude-nix-harness.conf" ] && ok "session PATH (environment.d; next login)" || warn "no environment.d PATH entry: GUI-launched VS Code will not see the nix profile"; fi
  [ -n "${HARNESS_EXPECT_MANAGED:-}" ] && warn "HARNESS_EXPECT_MANAGED is set but this host has no managed settings" || true
}

# claude doctor: Claude Code's own install and settings check, one line here
# (--verbose prints all of it).
claude_doctor() {
  local out rc
  command -v claude >/dev/null 2>&1 || return 0   # the report already says so
  out=$(timeout 60 claude doctor </dev/null 2>&1); rc=$?
  [ "$VERBOSE" = 1 ] && printf '%s\n' "$out" | sed 's/^/      /'
  if [ "$rc" = 0 ] && grep -q -i 'no installation issues' <<<"$out"; then ok "claude doctor: no installation issues"
  else warn "claude doctor: $(grep -i -m1 -E 'issue|warn|error|fail' <<<"$out" || echo "exit $rc") (run claude doctor)"; fi
}

# repo_report: the harness repo in the current directory, the same things
# `harness init` checks after the first shell entry.
repo_report() {
  local s=.claude/settings.json h n=0
  echo; echo "repo: $PWD"
  # A session's sandbox masks the repo's own .claude files as character
  # devices (measured 2026-10-21): nothing about the repo can be read here.
  if [ -c "$s" ]; then warn "$s is masked by the sandbox (a character device): doctor runs inside a Claude Code session; run it from your own terminal to check the repo"; return 0
  elif [ -L "$s" ] && [ ! -e "$s" ]; then miss "$s is a dangling symlink to $(readlink "$s") (direnv reload rewrites it)"
  elif [ -L "$s" ] && [[ "$(readlink -f "$s")" == /nix/store/* ]]; then ok "$s -> $(readlink "$s")"
  elif [ -L "$s" ]; then miss "$s points outside /nix/store ($(readlink -f "$s")): not the devenv module's file"
  else miss "$s is a plain file, not the devenv module's store symlink (anything can edit it; direnv reload rewrites it)"; fi
  if ! command -v direnv >/dev/null 2>&1; then miss "direnv not on PATH: the repo shell cannot load"
  elif direnv status 2>/dev/null | grep -q -E '^Found RC allowed (0|true)$'; then ok "direnv: .envrc allowed"
  else miss "direnv: .envrc not allowed (read it, then direnv allow)"; fi
  [ -e "$s" ] || return 0
  # Every hook the file names exists, is executable and accepts an event it
  # does not handle (tests/project-settings-test.sh).
  while read -r h; do
    if [ -x "$h" ] && printf '{"hook_event_name":"Stop"}' | "$h" >/dev/null 2>&1; then n=$((n+1))
    else miss "hook not runnable: $h"; fi
  done < <(jq -r '[.hooks[][].hooks[].command] | unique[]' "$s" 2>/dev/null)
  [ "$n" -gt 0 ] && ok "$n hooks in $s runnable" || miss "no runnable hook in $s"
}

summary() { echo; echo "harness $CMD: $nmiss missing, $nwarn warnings"; }

case "$CMD" in
  reset)
    reset_steps; exit 0 ;;
  doctor)
    # A report goes on past a probe that fails.
    set +e
    report
    claude_doctor
    { [ -e .claude/settings.json ] || [ -L .claude/settings.json ]; } && [ -f .envrc ] && repo_report
    summary ;;
  bootstrap|upgrade)
    if [[ "$HARNESS_REF" == path:/nix/store/* ]]; then
      warn "the harness ref is this harness's store path ($HARNESS_REF_FROM): a later upgrade cannot move it; pass --harness github:bilibo/claude-nix-harness or --harness path:<checkout>"
    fi
    if [ "$CMD" = upgrade ]; then
      load_receipt
      [ "$HAVE_RECEIPT" = 0 ] || [ -z "$(rq '.profile[]?')" ] || mapfile -t PROFILE_PKGS < <(rq '.profile[]')
    fi
    [ "$NO_ROOT" = 1 ] || { [ "$DRY_RUN" = 1 ] || sudo -v || die "sudo is needed for /etc/nix/nix.conf and the user-namespace setting (or pass --no-root after doing those by hand)"; root_steps; }
    [ "$HOST" != nixos ] || nixos_steps
    [ "$NO_PROFILE" = 1 ] || profile_steps
    handover_steps
    user_steps
    write_receipt
    echo
    report
    summary
    if [ ${#DEFERRED[@]} -gt 0 ]; then
      echo; echo "Declined, run later (every Claude command is refused until then):"; printf '  %s\n' "${DEFERRED[@]}"
    fi
    cat <<NEXT

Next: open a new terminal (PATH and NIX_SSL_CERT_FILE come from profile.d and ~/.bashrc.d), then
  harness init <customer>/<repo>                  # a harness repo under $CODE_ROOT
  harness check $CODE_ROOT/<customer>/<repo>       # the live checks (API calls)
Log out and in once so GUI-launched VS Code gets the nix profile on PATH.
NEXT
    ;;
  *) die "unknown command (bootstrap, upgrade, doctor or reset)" ;;
esac
[ "$missing" = 0 ]
