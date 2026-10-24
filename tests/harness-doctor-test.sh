#!/usr/bin/env bash
#   harness-doctor-test.sh <path-to-harness> <project-settings.json>
#
# `harness doctor` on a host that has nothing: an empty HOME, a PATH with no
# nix, claude, code, direnv or tmux (the Nix build sandbox is such a host).
# It must report MISSING lines, run to its summary and exit 1, never stop
# early; no claude is an info line and no tmux a warning, neither MISSING.
# Then the repo part, in three fake repos: the settings file as a
# store symlink (its hooks must run), as a dangling symlink, as a plain file.
# The host line for a NixOS and a WSL os-release (fake markers; the build
# sandbox has no /etc/os-release, so the plain case has no host at all).
set -uo pipefail
harness="${1:?usage: harness-doctor-test.sh <harness> <project-settings.json>}"
settings="${2:?usage: harness-doctor-test.sh <harness> <project-settings.json>}"
pass=0; fail=0
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/home"

# doctor <dir> [<path>]: harness doctor in <dir> with nothing (or only <path>)
# on PATH; sets out and rc.
doctor() {
  out=$(cd "$1" && env -i HOME="$tmp/home" PATH="${2:-/var/empty}" TMPDIR="$tmp" \
    HARNESS_OS_RELEASE="${OS_RELEASE:-/var/empty/none}" HARNESS_NIXOS_MARKER=/var/empty/none HARNESS_WSL_MARKER="${WSL_MARKER:-/var/empty/none}" \
    "$harness" doctor 2>&1); rc=$?
}
check() { # check <description> <want-regex>
  if [[ "$out" =~ $2 ]]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $1 (/$2/)"; printf '%s\n' "$out" | sed 's/^/  /'; fi
}
refute() { # refute <description> <forbidden-regex>
  if [[ "$out" =~ $2 ]]; then fail=$((fail+1)); echo "FAIL: $1 (/$2/ matched)"; printf '%s\n' "$out" | sed 's/^/  /'; else pass=$((pass+1)); fi
}
exits() { # exits <description> <want>
  if [ "$rc" = "$2" ]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $1 (want exit $2, got $rc)"; fi
}

mkdir -p "$tmp/empty"
doctor "$tmp/empty"
exits "doctor exits 1 when something is missing" 1
check "nix reported missing"    'MISSING nix'
check "direnv reported missing" 'MISSING direnv'
check "ran to the summary"      'harness doctor: [0-9]+ missing, [0-9]+ warnings'
refute "no shell error"         'unbound variable|syntax error|line [0-9]+:|command not found'
refute "no repo part outside a repo" 'repo: '
# No host claude is a supported shape (the plain WSL host: the VS Code
# extension's binary, the CLI from a repo's harness.claudeCode.enable): an
# info line, no claude doctor. No host tmux is a warning: ccmux carries its
# own, attaching by hand needs one.
check "no claude is an info line" 'info  claude not on the host PATH: the VS Code extension brings its own; repos get the CLI from harness\.claudeCode\.enable'
refute "no claude is not missing" 'MISSING claude'
refute "no claude doctor without claude" 'claude doctor:'
check "no tmux is a warning"    'warn  tmux not on the host PATH: ccmux brings its own'
refute "no tmux is not missing" 'MISSING tmux( [^h]|$)' # `tmux harness block` is the config file's line
# Counted: the same host with claude and tmux stubs has the same number
# missing and one warning fewer (tmux's; the info line counts nowhere).
summary_of() { [[ "$out" =~ harness\ doctor:\ ([0-9]+)\ missing,\ ([0-9]+)\ warnings ]] && echo "${BASH_REMATCH[1]} ${BASH_REMATCH[2]}"; }
read -r miss0 warn0 < <(summary_of)
mkdir -p "$tmp/cbin"
# shellcheck disable=SC2016  # the stub's own $1
printf '#!/bin/sh\ncase "$1" in --version) echo "2.1.305 (Claude Code)" ;; doctor) echo "No installation issues found" ;; esac\n' >"$tmp/cbin/claude"
printf '#!/bin/sh\necho "tmux 3.5a"\n' >"$tmp/cbin/tmux"; chmod +x "$tmp/cbin/claude" "$tmp/cbin/tmux"
doctor "$tmp/empty" "$tmp/cbin"
check "host claude reported"    'ok    claude 2\.1\.305 '
check "claude doctor with claude" 'ok    claude doctor: no installation issues'
check "host tmux reported"      'ok    tmux 3\.5a'
read -r miss1 warn1 < <(summary_of)
if [ -n "${miss0:-}" ] && [ "$miss0" = "${miss1:-}" ] && [ "$warn0" = "$((warn1 + 1))" ]; then pass=$((pass+1))
else fail=$((fail+1)); echo "FAIL: without claude and tmux: ${miss0:-?} missing, ${warn0:-?} warnings; with both: ${miss1:-?} missing, ${warn1:-?} warnings (want the same missing, one warning more)"; fi
printf '#!/bin/sh\necho "2.1.200 (Claude Code)"\n' >"$tmp/cbin/claude"
doctor "$tmp/empty" "$tmp/cbin"
check "an old host claude is still missing" 'MISSING claude 2\.1\.200 is older than'

mkdir -p "$tmp/repo/.claude"; touch "$tmp/repo/.envrc"
ln -s "$settings" "$tmp/repo/.claude/settings.json"
doctor "$tmp/repo"
exits "doctor in a repo, nothing on PATH" 1
check "repo part runs"          'repo: '
check "store symlink accepted"  'ok    \.claude/settings\.json -> /nix/store/'
check "hooks run"               'ok    [1-9][0-9]* hooks in \.claude/settings\.json runnable'
check "direnv missing in repo"  'MISSING direnv not on PATH'
refute "no unrunnable hook"     'hook not runnable'

rm "$tmp/repo/.claude/settings.json"; ln -s /nix/store/does-not-exist "$tmp/repo/.claude/settings.json"
doctor "$tmp/repo"
check "dangling symlink"        'MISSING \.claude/settings\.json is a dangling symlink'

rm "$tmp/repo/.claude/settings.json"; echo '{}' >"$tmp/repo/.claude/settings.json"
doctor "$tmp/repo"
check "plain file"              'MISSING \.claude/settings\.json is a plain file'
check "plain file without hooks" 'MISSING no runnable hook'

# Inside a session the sandbox masks the file as a character device: say so,
# never report the repo as broken. (-c follows the symlink.)
rm "$tmp/repo/.claude/settings.json"; ln -s /dev/null "$tmp/repo/.claude/settings.json"
doctor "$tmp/repo"
check "sandbox mask reported"   'warn  \.claude/settings\.json is masked by the sandbox'
refute "mask is no repo verdict" 'no runnable hook|plain file|dangling symlink|points outside'

# A `code` that answers nothing (the same sandbox): no extension verdict.
mkdir -p "$tmp/bin"; printf '#!/bin/sh\nexit 0\n' >"$tmp/bin/code"; chmod +x "$tmp/bin/code"
doctor "$tmp/empty" "$tmp/bin"
check "silent code reported"    'warn  code is on PATH but answers nothing'
refute "no extension verdict"   'VS Code extension [a-z]+\.' # the verdict names the extension; the claude info line does not

# The host line: NixOS from os-release alone (the /etc/NIXOS marker is not
# visible from inside a session), WSL from its marker.
printf 'ID=nixos\nPRETTY_NAME="NixOS 26.11 (Xantusia)"\n' >"$tmp/os-release"
OS_RELEASE="$tmp/os-release" doctor "$tmp/empty"
check "nixos host line"         'host: NixOS 26.11 \(Xantusia\) .*nix from the system configuration, 0 home-manager owned files skipped'
printf 'ID=ubuntu\nPRETTY_NAME="Ubuntu 26.10"\n' >"$tmp/os-release"; touch "$tmp/wsl"
OS_RELEASE="$tmp/os-release" WSL_MARKER="$tmp/wsl" doctor "$tmp/empty"
check "wsl host line"           'host: WSL2 \(Ubuntu 26.10\) '

out=$("$harness" --version 2>&1); rc=$?
exits "--version" 0; check "--version prints the revision" '^harness .+'
out=$("$harness" --help 2>&1); rc=$?
exits "--help" 0; check "--help lists the commands" 'bootstrap.*upgrade.*doctor.*init.*check.*reset'
out=$("$harness" doctor --help 2>&1); rc=$?
exits "doctor --help" 0; check "doctor --help is the bootstrap header" 'harness reset'
out=$("$harness" frobnicate 2>&1); rc=$?
exits "unknown command" 64

echo "harness-doctor-test: $pass passed, $fail failed"
[ "$fail" = 0 ]
