#!/usr/bin/env bash
#   project-settings-test.sh <settings.json> [fenced|center] [<repo-root>]
#
# `fenced`: the file was generated with `readFence = true`; the read fence
# checks replace the default's "no fence" check. `center`: the command
# center's file (`harness.role = "center"`): the sandbox is off, so the
# sandbox checks become one, "off, nothing under it but the credential
# list"; the setup-file rules name the checkout only and the guard is the
# center's; every other check is the work repo's. `<repo-root>`: the path the
# file was generated for, where its literal entries point; default /repo,
# the flake fixtures' root. harness init passes the real repo.
#
# The repo's .claude/settings.json as the devenv module writes it. On a host
# without managed settings this file is the whole harness, so every layer it
# is supposed to carry is asserted here, and every hook it names must run.
# shellcheck disable=SC2016  # the filters are jq, where $repo is a jq variable
set -uo pipefail
f="${1:?usage: project-settings-test.sh <settings.json> [fenced|center] [<repo-root>]}"
mode=""; repo=/repo
for a in "${@:2}"; do case "$a" in fenced|center) mode="$a" ;; *) repo="$a" ;; esac; done
pass=0; fail=0

check() { # check <description> <jq filter that must be true; $repo is the repo root>
  if jq -e --arg repo "$repo" "$2" "$f" >/dev/null 2>&1; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $1 ($2)"; fi
}

check "full deny set, not the universal subset" '.permissions.deny | index("Bash(git commit)") and index("Bash(terraform apply)") and index("Bash(sudo)") and index("Bash(nh os switch)") and index("Bash(nh home switch *)")'
check "bypass mode disabled"                    '.permissions.disableBypassPermissionsMode == "disable"'
check "guard registered on every writing tool"  '.hooks.PreToolUse[0].matcher == "Bash|Edit|Write|NotebookEdit"'
check "guard failure blocks"                    '.hooks.PreToolUse[0].hooks[0].onFailure == "block"'
check "settings changes guarded"                '.hooks.ConfigChange[0].matcher | test("user_settings") and test("local_settings")'
check "env preamble hooks present"              '.hooks | has("SessionStart") and has("CwdChanged") and has("FileChanged")'
check "agent socket stripped"                   '[.sandbox.credentials.envVars[] | select(.name == "SSH_AUTH_SOCK" and .mode == "deny")] | length == 1'
check "account connectors off"                  '.disableClaudeAiConnectors == true'
check "no co-author trailer"                    '.includeCoAuthoredBy == false'
# In user scope it turns the sandbox's Bash auto-allow off (2026-10-22); in
# a repo file it is ignored. Never written.
check "no subprocess scrub key"                 '.env.CLAUDE_CODE_SUBPROCESS_ENV_SCRUB == null'
check "no github token inside the sandbox"      '[.sandbox.credentials.envVars[] | select(.mode == "deny") | .name] | index("GITHUB_TOKEN") and index("GH_TOKEN")'
check "no managed-only keys in a repo file"     '(has("allowManagedHooksOnly") or has("strictKnownMarketplaces") or has("disableSideloadFlags") or has("pluginConfigs") or (.sandbox.network // {} | has("strictAllowlist"))) | not'
check "rules-off files refused in every repo"   '.permissions.deny | index("Edit(**/.claude/settings.json)") and index("Edit(**/.claude/settings.local.json)") and index("Edit(**/devenv.local.*)")'
# The hook a work repo runs carries nothing of the center's (lib/hooks.nix).
guard=$(jq -r '.hooks.PreToolUse[0].hooks[0].command' "$f")
if [ "$mode" = center ]; then
  # Bash commands run unconfined and are prompted; the deny rules and the
  # hook above are the work repo's but for the setup files, which are
  # refused in this checkout only (`//` + the path), so the center can set
  # up other repos. A filesystem or network block would qualify a sandbox
  # that is off.
  check "sandbox off, only the credential list" '.sandbox.enabled == false and (.sandbox | keys) == ["credentials", "enabled"]'
  check "own setup files refused by absolute path" '.permissions.deny | index("Edit(/" + $repo + "/devenv.nix)") and index("Edit(/" + $repo + "/**/devenv.nix)") and index("Edit(/" + $repo + "/devenv.yaml)") and index("Edit(/" + $repo + "/devenv.lock)") and index("Edit(/" + $repo + "/.envrc)") and index("Edit(/" + $repo + "/.claude/hooks/**)") and index("Edit(/" + $repo + "/**/.claude/skills/**)")'
  check "other repos' setup files open"         '.permissions.deny | index("Edit(**/devenv.nix)") or index("Edit(**/devenv.yaml)") or index("Edit(**/devenv.lock)") or index("Edit(**/.envrc)") or index("Edit(**/.claude/hooks/**)") or index("Edit(**/.claude/skills/**)") | not'
  if grep -qx "CENTER_ROOT=\"$repo\"" "$guard"; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: the guard is not the center's for $repo: $guard"; fi
else
  check "setup files refused in every repo"     '.permissions.deny | index("Edit(**/devenv.nix)") and index("Edit(**/.envrc)") and index("Edit(**/.claude/skills/**)") and (map(select(startswith("Edit(//"))) == [])'
  if grep -q 'CENTER_ROOT\|center_' "$guard"; then fail=$((fail+1)); echo "FAIL: a work repo's guard carries the center's code: $guard"; else pass=$((pass+1)); fi
  check "sandbox on and mandatory"              '.sandbox.enabled == true and .sandbox.failIfUnavailable == true and .sandbox.allowUnsandboxedCommands == false'
  check "ssh key files hidden"                  '.sandbox.filesystem.denyRead | index("~/.ssh")'
  check "cloud and github credentials hidden"   '.sandbox.filesystem.denyRead | index("~/.aws") and index("~/.config/gh") and index("~/.git-credentials")'
  # The `**/` entries are asserted for presence only: Linux skips glob write
  # entries (lib/settings.nix); `~/.claude` is the one that holds there.
  check "own settings not writable from the shell" '.sandbox.filesystem.denyWrite | index("**/.claude/settings.json") and index("**/.claude/settings.local.json") and index("~/.claude")'
  # Linux honours literal write entries only: the repo's own files by absolute path.
  check "own files denied by literal path"      '.sandbox.filesystem.denyWrite | index($repo + "/.claude/settings.json") and index($repo + "/.claude/settings.local.json") and index($repo + "/.git/hooks") and index($repo + "/.git/config") and index($repo + "/.claude-plugin")'
  # A literal entry is masked as an unreadable device node, and devenv reads
  # devenv.local.* when they exist: with them listed, no shell evaluated inside
  # the sandbox (2026-10-22). The hook refuses writes to them by name.
  check "devenv.local.* readable by devenv"     '.sandbox.filesystem.denyWrite | (index($repo + "/devenv.local.nix") or index($repo + "/devenv.local.yaml")) | not'
  check "worktrees stay writable"               '.sandbox.filesystem.denyWrite | index("**/.claude") | not'
  if [ "$mode" = fenced ]; then
    check "home hidden from the shell"          '.sandbox.filesystem.denyRead | index("~/")'
    check "repo and shell entry paths readable" '.sandbox.filesystem.allowRead | index($repo) and index("~/.nix-profile") and index("~/.local/share/direnv") and index("~/.claude/shell-snapshots") and index("~/.cargo")'
    check "credentials stay hidden"             '.sandbox.filesystem.allowRead | index("~/.claude") or index("~/") | not'
  else
    check "no read fence by default"            '.sandbox.filesystem.denyRead | index("~/") | not'
    check "no allowRead without the fence"      '.sandbox.filesystem | has("allowRead") | not'
  fi
fi

# Every hook the file names is a store path that exists, is executable and
# accepts an event it does not handle.
while read -r h; do
  if [ -x "$h" ] && printf '{"hook_event_name":"Stop"}' | "$h" >/dev/null 2>&1; then
    pass=$((pass+1))
  else
    fail=$((fail+1)); echo "FAIL: hook not runnable: $h"
  fi
done < <(jq -r '[.hooks[][].hooks[].command] | unique[]' "$f")

echo "project-settings-test: $pass passed, $fail failed"
[ "$fail" = 0 ]
