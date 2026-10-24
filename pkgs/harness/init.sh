#!/usr/bin/env bash
#   harness init <customer>/<repo> | <path> [--harness <flakeref>] [--force] [--no-shell]
#                [--dry-run] [--yes] [--verbose]
#
# Section 3 of the runbook as a subcommand. Renders the files a repo needs to
# import the harness devenv module (devenv.yaml, devenv.nix, .envrc,
# .gitignore, .worktreeinclude, CLAUDE.md), then does the first shell entry
# (direnv allow, approval of the files require_allowed names, which makes
# devenv write .claude/settings.json) and runs the repo's static checks on
# the result: project-settings-test.sh on the generated file, hook-test.sh on
# the hook it names, ccmux's resolution. A repo whose devenv.nix sets
# harness.enable = false loads with no settings file: init says so and stops
# there, exit 0. The role the shell exports (HARNESS_ROLE) is reported:
# with harness.role = "center", the harness checkout's own (sandbox off),
# the settings test runs in its center mode, and a center role in a repo
# that is not the harness checkout gets a warning. A new directory under
# $HARNESS_CODE_ROOT/<customer>/<repo> (default ~/code/git), or an existing
# repo given by path. Files that exist are left alone and reported; --force
# overwrites the harness-owned ones (devenv.yaml, .envrc). .gitignore and
# .worktreeinclude only gain the lines they lack; CLAUDE.md gains the
# contract block if it has none. --dry-run prints the files it would write
# and creates nothing; --verbose traces the shell step. devenv.yaml,
# devenv.nix, .envrc or a devenv.local.* that this run did not write are the
# repo's own code, which the shell step approves and runs as you: they are
# printed and need a y, or --yes. So does a devenv.lock that is there before
# the first load, shown as the inputs it pins (a re-run on a repo init set
# up earlier asks about its own lock too).
#
# The harness input is the same ref bootstrap installs from: --harness, else
# HARNESS_REF, else the receipt's. A `path:` checkout is the form for
# developing the harness; a repo meant to outlive the checkout pins a git URL
# instead: --harness github:bilibo/claude-nix-harness, which is also the
# default when none of them is set. A `path:/nix/store/...` ref makes init warn: garbage
# collection removes it.
# devenv.lock records the revision either way; `devenv update harness` moves
# it. On a WSL host (binfmt WSLInterop, or WSL_DISTRO_NAME) the devenv.nix
# gets harness.platform = "wsl", which hides /mnt/c and /run/WSL from the
# sandbox. On a host with no claude on PATH (the plain WSL host, whose
# Claude Code is the VS Code extension's bundled binary) it gets
# harness.claudeCode.enable = true, the CLI for tmux and ccmux sessions, and
# devenv.yaml gets allow_unfree: true (claude-code is unfree); a claude on
# PATH leaves both commented out. A PATH directory in the Nix store is a
# shell's, not the host's (init run from inside a repo shell), and one under
# ~/.vscode-server is the extension's own: neither counts.
# shellcheck disable=SC2016  # single quotes are deliberate where direnv or bash must see the `$`
set -euo pipefail

# Run straight from a checkout (bash pkgs/harness/init.sh), the checkout is the ref.
HARNESS_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)
HARNESS_REF="${HARNESS_REF:-path:$HARNESS_DIR}"
HARNESS_REF_FROM="${HARNESS_REF_FROM:-checkout}"
HARNESS_TESTS="${HARNESS_TESTS:-$HARNESS_DIR/tests}"
WSL_MARKER="${HARNESS_WSL_MARKER:-/proc/sys/fs/binfmt_misc/WSLInterop}"
FORCE=0; DRY=0; NO_SHELL=0; VERBOSE=0; YES=0; target=""
usage() { sed -n '/^#   harness /,/^# shellcheck/{/^# shellcheck/q;s/^# \{0,1\}//;p;}' "$0"; }
while [ $# -gt 0 ]; do
  case "$1" in
    --harness) HARNESS_REF="${2:?--harness needs a flake reference}"; HARNESS_REF_FROM=--harness; shift ;;
    --force) FORCE=1 ;;
    --dry-run) DRY=1 ;;
    --no-shell) NO_SHELL=1 ;;
    --verbose) VERBOSE=1 ;;
    --yes) YES=1 ;;
    -h|--help) usage; exit 0 ;;
    -*) echo "harness init: unknown argument $1 (see --help)" >&2; exit 64 ;;
    *) [ -z "$target" ] || { echo "harness init: one target only" >&2; exit 64; }; target="$1" ;;
  esac
  shift
done
[ -n "$target" ] || { echo "usage: harness init <customer>/<repo> | <path> (see --help)" >&2; exit 64; }

root="${HARNESS_CODE_ROOT:-$HOME/code/git}"; root="${root%/}"
die() { echo "harness init: $1" >&2; exit "${2:-1}"; }
note() { printf '%-10s %s\n' "$1" "$2"; }

# The same rule as ccmux: <customer>/<repo> is relative to the code root,
# anything else is a path.
if [[ "$target" == */* && "$target" != /* && "$target" != .* ]]; then
  repo="$root/$target"; project="$target"
else
  repo=$(cd "$target" 2>/dev/null && pwd -P) || die "no such directory: $target (a new repo is <customer>/<repo> under $root)"
  project=""
  if [[ "$repo" == "$root/"*/* ]]; then rel="${repo#"$root/"}"; IFS=/ read -r a b _ <<<"$rel"; project="$a/$b"; fi
fi
name="${repo##*/}"
[ "$DRY" = 1 ] || mkdir -p "$repo"

# For the shell step: the nix profile may not be on this shell's PATH yet, and
# Nix-built fetchers need the CA bundle named (bootstrap.sh, CA_BUNDLE).
for d in "$HOME/.nix-profile/bin" /nix/var/nix/profiles/default/bin; do [ -d "$d" ] && [[ ":$PATH:" != *":$d:"* ]] && PATH="$d:$PATH"; done
if [ -z "${NIX_SSL_CERT_FILE:-}" ]; then
  for f in /etc/pki/ca-trust/extracted/pem/tls-ca-bundle.pem /etc/pki/tls/certs/ca-bundle.crt /etc/ssl/certs/ca-certificates.crt; do
    [ -r "$f" ] && { export NIX_SSL_CERT_FILE="$f"; break; }
  done
fi

# put <relpath> <content> [owned]: write a file that does not exist; report
# one that does. `owned` files are overwritten with --force. One left alone
# goes in `foreign`, for the approval before the shell step.
foreign=()
put() {
  local f="$repo/$1" content="$2" owned="${3:-}"
  if [ -e "$f" ]; then
    if [ "$(cat "$f")" = "$content" ]; then note unchanged "$1"
    elif [ "$FORCE" = 1 ] && [ -n "$owned" ]; then write "$1" "$content" overwrite
    else note differs "$1 (left alone${owned:+; --force overwrites})"; foreign+=("$1"); fi
  else write "$1" "$content" write; fi
}
write() { # write <relpath> <content> <verb>
  if [ "$DRY" = 1 ]; then note "would $3" "$1"; else printf '%s\n' "$2" >"$repo/$1"; note "$3" "$1"; fi
}
ensure_lines() { # ensure_lines <relpath> <line>...
  local rel="$1" f="$repo/$1" l added=0; shift
  for l in "$@"; do
    grep -q -x -F "$l" "$f" 2>/dev/null && continue
    if [ "$DRY" = 1 ]; then note "would add" "$rel: $l"; else printf '%s\n' "$l" >>"$f"; fi; added=1
  done
  if [ "$added" = 0 ]; then note unchanged "$rel"; elif [ "$DRY" = 0 ]; then note "added to" "$rel"; fi
}

echo "harness init: $repo ($(if [ -n "$project" ]; then echo "project $project"; else echo "outside $root: ccmux needs an explicit path"; fi))"
echo "harness:   $HARNESS_REF ($HARNESS_REF_FROM)"
platform_line='    # platform = "wsl";                # hides /mnt/c and /run/WSL from the sandbox'
if [ -e "$WSL_MARKER" ] || [ -n "${WSL_DISTRO_NAME:-}" ]; then
  platform_line='    platform = "wsl";                  # this host is WSL: /mnt/c and /run/WSL hidden from the sandbox'
  note platform 'wsl (harness.platform in devenv.nix)'
fi
# The host's claude, if any (header): the first on PATH outside the store
# (NIX_STORE_DIR when Nix is relocated) and outside VS Code's server.
host_claude=""
IFS=: read -r -a path_dirs <<<"$PATH"
for d in "${path_dirs[@]}"; do
  case "$d" in "${NIX_STORE_DIR:-/nix/store}"/*|"$HOME"/.vscode-server*) continue ;; esac
  if [ -f "$d/claude" ] && [ -x "$d/claude" ]; then host_claude="$d/claude"; break; fi
done
claude_line='    # claudeCode.enable = true;        # claude, tmux and jq in this shell, for a host without claude'
unfree_line='# allow_unfree: true  # for harness.claudeCode.enable in devenv.nix: claude-code is unfree'
if [ -z "$host_claude" ]; then
  claude_line='    claudeCode.enable = true;          # the CLI for tmux/ccmux sessions; the VS Code extension brings its own'
  unfree_line='allow_unfree: true  # for harness.claudeCode.enable in devenv.nix: claude-code is unfree'
  note claude 'none on the host PATH: claudeCode.enable = true in devenv.nix, allow_unfree: true in devenv.yaml'
else
  note claude "$host_claude on the host PATH: claudeCode.enable left commented out in devenv.nix"
fi
if [[ "$HARNESS_REF" == path:/nix/store/* ]]; then
  note warn "devenv.yaml would pin a store path that garbage collection removes: pass --harness github:bilibo/claude-nix-harness or --harness path:<checkout>"
fi

put devenv.yaml "# The harness module writes .claude/settings.json (deny rules, hooks,
# sandbox) at every shell entry. devenv.lock pins the harness revision;
# \`devenv update harness\` moves it.
inputs:
  harness:
    url: $HARNESS_REF
    flake: false
imports:
  - harness/devenv
$unfree_line" owned

put devenv.nix "# Project tools and harness options. Allow rules for this project go in
# harness.settings here, proposed as a diff by an agent and committed by you,
# never in .claude/settings.local.json (the hook refuses it). Every harness
# option is listed, the unused ones commented out. Adding a tool, a
# toolchain, a variable or a network host, and the \`direnv allow\` after
# each change: https://github.com/bilibo/claude-nix-harness/blob/main/docs/project-devenv.md
{ pkgs, ... }:
{
  name = \"$name\";
  # Names from search.nixos.org/packages; an unfree one needs allow_unfree: true in devenv.yaml.
  packages = [
    pkgs.git
    pkgs.jq
  ];
  # languages.rust.enable = true;      # a toolchain; cargo's hosts go in extraAllowedDomains
  # env.ARM_TENANT_ID = \"...\";         # identifiers only; secrets stay in .env
  harness = {
    # enable = false;                  # guard rails off for this repo: no rules file, hook or sandbox
    # role = \"center\";                 # the harness checkout only (the command center): no sandbox there; never a work repo
    # allowMemoryEdits = true;         # Claude keeps its auto-memory under ~/.claude/projects
    # allowLocalCommits = true;        # commits on the worktree branch; push stays impossible
    # readFence = true;                # hide the rest of \$HOME from sandboxed commands
    # extraAllowRead = [ \"~/.cargo\" ]; # with readFence: what the project reads under \$HOME
    # allowConnectors = true;          # claude.ai connectors, MCP servers outside the sandbox
$platform_line
$claude_line
    # extraDeny = [ \"Bash(az devops *)\" ];
    # extraAllowedDomains = [ \"dev.azure.com\" ];              # sandbox allowlist, unmanaged host only
    # settings.permissions.allow = [ \"Bash(terraform plan *)\" ];
  };
}"

# require_allowed last: on the first load `use devenv` creates devenv.lock,
# then the three files are reported as pending and the next `direnv allow`
# approves them (see the shell step below).
put .envrc 'eval "$(devenv direnvrc)"
use devenv
require_allowed devenv.nix devenv.yaml devenv.lock' owned

ensure_lines .gitignore '.devenv/' '.direnv/' '.claude/settings.json' '.claude/settings.local.json' '.claude/worktrees/'
# A `claude --worktree` session starts in .claude/worktrees/<name> with only
# these files, so it has the repo's rules before devenv regenerates them.
ensure_lines .worktreeinclude '.claude/settings.json'

contract="## Environment contract (claude-nix-harness)

This repo is governed by claude-nix-harness. \`.claude/settings.json\` is
generated by the devenv module at every shell entry and carries the deny
rules, the hooks and the Bash sandbox; tools come from the devenv shell
(\`devenv.nix\`), not from the host.

- A refusal (\`env-guard: ...\`, a deny rule naming \`Bash(...)\`, a sandbox
  error) is expected behaviour. Do not work around it: propose a diff or ask.
- You do not commit or push. Stage with \`git add\`, diff, branch; the human
  commits from their own terminal.
- Never edit \`devenv.nix\`, \`devenv.yaml\`, \`devenv.lock\`, \`.envrc\` or
  anything under \`.claude/\`. A project allow rule goes in \`devenv.nix\`
  (\`harness.settings.permissions.allow\`), proposed as a diff.
- \`~/.ssh\`, \`~/.azure\` and other credential paths are hidden from your
  commands; clone over HTTPS."
if [ -e "$repo/CLAUDE.md" ]; then
  if grep -q -F 'claude-nix-harness' "$repo/CLAUDE.md"; then note unchanged CLAUDE.md
  elif [ "$DRY" = 1 ]; then note "would add" "CLAUDE.md: the environment contract"
  else printf '\n%s\n' "$contract" >>"$repo/CLAUDE.md"; note "added to" CLAUDE.md; fi
else
  put CLAUDE.md "# $name

$contract"
fi

# Runbook 3.6: a directory with that manifest is a plugin, and the plugin
# rules refuse it.
if find "$repo/.claude" -path '*/.claude-plugin/plugin.json' -print -quit 2>/dev/null | grep -q .; then
  die "a plugin manifest exists under $repo/.claude (.claude-plugin/plugin.json): remove it, plugins do not load from a repo"
fi

if [ "$DRY" = 0 ] && ! git -C "$repo" rev-parse --git-dir >/dev/null 2>&1; then
  git -C "$repo" init -q -b main; note "git init" "main (commit when ready; agents never do)"
fi

if [ "$DRY" = 1 ] || [ "$NO_SHELL" = 1 ]; then echo "harness init: files done; shell step skipped"; exit 0; fi

# ---------------------------------------------------------------- first shell entry
for t in direnv devenv jq; do command -v "$t" >/dev/null || die "$t not on PATH: run harness bootstrap first (or --no-shell)" 69; done
[ "$VERBOSE" = 0 ] || set -x
v=$(direnv version); [ "$(printf '%s\n%s\n' 2.38 "$v" | sort -V | head -1)" = 2.38 ] || die "direnv $v is older than 2.38 (require_allowed)" 69

# `direnv allow` below approves the repo's files and the first load runs
# them as you, outside any sandbox: one this run did not write is read first.
# A devenv.lock that is here before the first load is the repo's, not the
# one `use devenv` creates: it pins every input, nixpkgs included, so its
# inputs are shown (the raw file is not readable) and approved with the rest.
for f in devenv.local.nix devenv.local.yaml devenv.lock; do if [ -e "$repo/$f" ]; then foreign+=("$f"); fi; done
if [ ${#foreign[@]} -gt 0 ]; then
  for f in "${foreign[@]}"; do
    printf '\n==> %s (not written by harness init)\n' "$repo/$f"
    if [ "$f" = devenv.lock ]; then
      jq -r '.nodes | to_entries[] | select(.value.locked) | .value.locked as $l
        | "  \(.key): \($l.type):\($l.owner // "")\(if $l.owner then "/" else "" end)\($l.repo // $l.path // $l.url // "") @ \($l.rev // $l.narHash // "?")"' \
        "$repo/$f" 2>/dev/null || echo "  (not a lock file jq can read)"
    else cat "$repo/$f"; fi
  done
  if [ "$YES" = 0 ]; then
    printf '\napprove and load these? [y/N] '; a=""
    if [ -t 0 ]; then read -r a || a=""; else { read -r a </dev/tty; } 2>/dev/null || a=""; fi
    [[ "$a" == [yY] ]] || die "not approved: ${foreign[*]}; read them, then re-run with --yes (or --no-shell to skip the shell step)"
  fi
fi

echo
echo "==> direnv allow (the .envrc), then the first load: devenv fetches its inputs and writes .claude/settings.json"
direnv allow "$repo"
# The first load exports DIRENV_REQUIRED with the files require_allowed
# found unapproved; `direnv allow` in that environment approves them.
(
  cd "$repo"
  eval "$(direnv export bash)"
  if [ -n "${DIRENV_REQUIRED:-}" ]; then
    echo "==> direnv allow (${DIRENV_REQUIRED//:/, })"
    direnv allow
  fi
)
pending=$(direnv exec "$repo" bash -c 'printf %s "${DIRENV_REQUIRED:-}"' 2>/dev/null || true)
[ -z "$pending" ] || die "files still pending approval after two allows: $pending"

# ---------------------------------------------------------------- checks
echo
settings="$repo/.claude/settings.json"
if [ -L "$settings" ] && [ -r "$settings" ] && [[ "$(readlink -f "$settings")" == /nix/store/* ]]; then
  note ok ".claude/settings.json -> $(readlink "$settings")"
elif [ -L "$settings" ]; then
  die ".claude/settings.json is a dangling symlink (direnv reload rewrites it)"
elif [ "$(direnv exec "$repo" "$BASH" -c 'printf %s "${DEVENV_ROOT:+loaded}${HARNESS_PROJECT:+ harness}"' 2>/dev/null)" = loaded ]; then
  # The shell loaded and the module exported nothing: the repo owner turned
  # the guard rails off (harness.enable = false), so there is nothing to check.
  note off "the shell loads without the guard rails: harness.enable = false in devenv.nix (or devenv.yaml does not import harness/devenv)"
  exit 0
else
  die ".claude/settings.json was not written: the devenv shell did not load (direnv status in $repo)"
fi
# The role the shell exports (HARNESS_ROLE): work, the default, in every
# repo init sets up; center in the harness checkout (the command center,
# which scripts/install.sh initializes too), whose file has the sandbox off
# by design: the settings test runs in its center mode there. A center role
# in a repo without the harness's own module and settings source is a work
# repo set up wrong: a warning, not a stop.
role=$(direnv exec "$repo" "$BASH" -c 'printf %s "${HARNESS_ROLE:-}"' 2>/dev/null || true)
mode=""
if [ "$role" = center ]; then
  mode=center
  note role "center: the command center's file, sandbox off by design; the settings test runs in center mode"
  [ -f "$repo/devenv/devenv.nix" ] && [ -f "$repo/lib/settings.nix" ] \
    || note warn "harness.role = \"center\" but $repo is not the harness checkout (no devenv/devenv.nix and lib/settings.nix): a work repo leaves role unset, or it runs without the sandbox; remove the line from devenv.nix, direnv allow"
else
  note role "${role:-work (HARNESS_ROLE unset: a harness revision before harness.role)}"
fi
bash "$HARNESS_TESTS/project-settings-test.sh" "$settings" ${mode:+"$mode"} "$repo" || die "the generated settings file fails the harness checks"
hook=$(jq -r '.hooks.PreToolUse[0].hooks[0].command' "$settings")
bash "$HARNESS_TESTS/hook-test.sh" "$hook" || die "the repo's hook fails the unit tests"
# ccmux -n prints the session line, the role and window line, then where
# the window's claude comes from: one note. Its error names what is missing.
if res=$(direnv exec "$repo" ccmux -n 2>/dev/null); then note ok "ccmux -n: ${res//$'\n'/; }"
else note warn "ccmux -n failed: $({ direnv exec "$repo" ccmux -n 2>&1 || true; } | grep -m1 '^ccmux:' || echo 'run it in the repo shell to see why')"; fi
{ set +x; } 2>/dev/null

cat <<NEXT

Ready. From your own terminal:
  cd $repo && ccmux                                  # a session in the project's tmux session
  cd $repo && claude -p 'list the tools on PATH'    # the runbook's smoke test
  harness check $repo                               # the runbook's live checks (API calls)
In VS Code, open $repo; mkhl.direnv asks to allow once per devenv.nix/devenv.yaml/devenv.lock change.
NEXT
