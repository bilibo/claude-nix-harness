#!/usr/bin/env bash
#   hook-test.sh <path-to-env-guard.sh> [--direnv-stub]
#
# Feeds hook JSON on stdin, no Claude Code needed (0 = allow, 2 = block).
# Add a case per hard limit you rely on; a case that stops passing after a
# regex change is the point of this file.
set -uo pipefail
hook="${1:?usage: hook-test.sh <env-guard.sh>}"
# The roots come from the built hook; with none, everything is in scope and
# the out-of-scope section is skipped. A command center's hook (CENTER_ROOT,
# lib/hooks.nix) runs every case from inside its checkout, then its own
# section; HOOK_TEST_CENTER runs that section against any hook.
ROOTS=$(sed -n 's/^ENFORCEMENT_ROOTS="\(.*\)"$/\1/p' "$hook")
CENTER="${HOOK_TEST_CENTER:-$(sed -n 's/^CENTER_ROOT="\(.*\)"$/\1/p' "$hook")}"
IN="${HOOK_TEST_IN:-${CENTER:-${ROOTS%%:*}/acme/infra}}"; IN="${IN/#\~/$HOME}"
OUT="${HOOK_TEST_OUT:-/tmp/p}"
pass=0; fail=0

run() { # run <expected-exit> <json>
  local want="$1" json="$2" got
  printf '%s' "$json" | "$hook" >/dev/null 2>&1; got=$?
  if [ "$got" = "$want" ]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL (want $want, got $got): $json"; fi
}
cwd="$IN"
bash_cmd() { printf '{"hook_event_name":"PreToolUse","tool_name":"Bash","cwd":"%s","tool_input":{"command":%s}}' "$cwd" "$(printf '%s' "$1" | jq -Rs .)"; }
edit_file() { printf '{"hook_event_name":"PreToolUse","tool_name":"Edit","cwd":"%s","tool_input":{"file_path":"%s"}}' "$cwd" "$1"; }
allow() { run 0 "$(bash_cmd "$1")"; }
block() { run 2 "$(bash_cmd "$1")"; }

# --- 1. git history -------------------------------------------------------
allow 'git status'
allow 'git add -A'
allow 'git diff --cached'
allow 'git log --oneline -20'
allow 'git switch -c feature/x'
allow 'git stash list'
allow 'git commitlint'              # prefix of a different word
block 'git commit -m "x"'
block 'git commit'
block 'git push origin main'
block "git 'push'"
block 'git -C . push'
block 'git -c user.name=x push'
block 'GIT_DIR=/tmp/x git push'
block 'bash -c "git commit -m x"'
block 'cd /tmp && git reset --hard HEAD~1'
block 'env FOO=1 git rebase -i main'
block 'git stash drop'
block 'git branch -D main'
block 'git update-ref refs/heads/main abc'
block 'git checkout -- .'
block 'git checkout main -- .envrc'
allow 'git checkout main && npm run build -- --watch'   # the `--` belongs to a later command
allow 'git checkout --track origin/x'
block 'git restore --staged .'
block 'timeout 10 git merge main'
block 'git push || true'
block 'echo hi; git push'
block 'direnv exec . git push'
block 'git --git-dir=.git push origin main'
block 'git --work-tree=. reset --hard'
block '/usr/bin/git push origin main'
# Discards of uncommitted work and forced ref moves.
block 'git checkout .'
block 'git checkout -f main'
block 'git checkout --force main'
block 'git switch -f main'
block 'git switch --force main'
block 'git switch --discard-changes main'
block 'git branch -f main HEAD~3'
block 'git branch --force main HEAD~3'
block 'git tag -f v1'
block 'git tag --force v1'
block 'git worktree remove -f x'
block 'git worktree remove --force x'
block 'git switch -C main'
block 'git checkout -B main'
block 'git checkout ./src'
block "git 'switch' -C main"
block $'git\tswitch -C main'
block 'git worktree remove wt --force'
allow 'git checkout -b x'
# A ref plus paths discards edits to those paths; a start point after -b/-t/--orphan does not.
block 'git checkout main src/a.ts'
block 'git checkout -q main src/a.ts'
block 'git -c x=y checkout main a b'
allow 'git checkout main'
allow 'git checkout -b x origin/x'
allow 'git checkout -t origin/x'
allow 'git checkout --orphan gh-pages'
allow 'git checkout main && ls a b'
allow 'git worktree remove x'

# --- 2. cloud / infra -----------------------------------------------------
allow 'terraform plan -out tf.plan'
allow 'terraform validate'
allow 'terraform show'
allow 'az account show'
allow 'az group list -o table'
allow 'az storage account show -n x'
block 'terraform apply tf.plan'
block 'terraform -chdir=infra apply'
block 'terraform state rm module.x'
block 'tofu destroy -auto-approve'
block 'terragrunt apply'
block 'az group create -n x -l westeurope'
block 'az storage account update -n x --https-only true'
block 'az deployment group create -g x -f main.bicep'
block 'az rest --method put --url https://management.azure.com/x'
block 'az rest --url x --method DELETE'
block 'az vm start -n x'
block 'func azure functionapp publish myapp'
block 'pulumi up'

# --- 3. credentials -------------------------------------------------------
allow 'ls -la'
allow 'cat README.md'
allow 'grep -r "resource" modules/'
allow 'grep -rn token src/'
allow 'cat tokenizer.py'
allow 'ls scripts/powershell/'
allow 'cat notes.exe.md'
block 'az login'
block 'az login --use-device-code'
block 'az account set -s x'
block 'az account get-access-token'
block 'az keyvault secret show --vault-name v -n s'
block 'cat .env'
block 'cat ./.env.local'
block 'cat terraform.tfvars'
block 'head -c 100 terraform.tfstate'
block 'cat ~/.azure/msal_token_cache.json'
block 'cat ~/.ssh/id_ed25519'
block 'python3 -c "print(open(\".env\").read())"'
block 'source .env'
block 'grep -r token ~/.azure/'
block 'base64 .env'
block 'diff /dev/null .env'
block 'sort terraform.tfvars'
# A secret path blocks whatever the verb; only one simple harmless command
# names one and passes.
block 'dd if=.env'
block 'tr a-z A-Z < .env'
block 'while read l; do echo $l; done < .env'
block 'perl -ne print .env'
block 'hexdump .env'
block 'envsubst < .env'
block 'git show HEAD:.env'
block 'git cat-file -p HEAD:.env'
block 'ls .env && cat .env'
block 'echo $(cat .env)'
block 'ls -la .env | head'
block $'echo .env\ncat .env'            # a second line: the normaliser folds newlines
block 'echo >(cat .env)'
block 'ls .env >(cat .env)'
block 'file -f .env'
block 'wc --files0-from=.env'
block 'du --files0-from=.env'
block 'git rm --pathspec-from-file=.env'
block 'file -b -f .env'
block 'file --files-from .env'
block 'cat ~/.aws/credentials'
block 'cat ~/.git-credentials'
block 'cat ~/.config/gh/hosts.yml'
allow 'ls -la .env'
allow 'stat .env'
allow 'rm .env.bak'
allow 'git rm --cached .env'
allow 'wc -c .env'
allow 'file .env'
allow 'echo .env >> .gitignore'
allow 'git show HEAD:README.md'
allow 'diff a.txt b.txt'

# --- 4. system / config ---------------------------------------------------
allow 'nix build .#foo'
allow 'nix flake check'
allow 'nix develop -c true'
block 'sudo ls'
block 'echo x | sudo tee /etc/foo'
block 'run0 ls'
block 'nix profile install nixpkgs#hello'
block 'nix-env -iA nixpkgs.hello'
block 'nixos-rebuild switch'
block 'nixos-rebuild build'               # denied as a whole, build included (handoff phase 1)
block 'home-manager switch'
block 'nh os switch'
block 'nh os boot .'
block 'nh os test'
block 'nh home switch'
block 'nh  os   switch ~/nixos-config'
allow 'nh os build'
allow 'nh search firefox'
block 'systemctl restart foo'
block 'cmd.exe /c dir'
block '/mnt/c/Windows/System32/cmd.exe'
block 'powershell.exe -c Get-Date'
block 'pwsh -c 1'
block 'clip.exe'
block 'echo x > devenv.nix'
block 'echo x >> .envrc'
block 'tee devenv.local.nix < x'
block 'sed -i s/a/b/ devenv.yaml'
block 'cp evil.json .claude/settings.json'
block 'rm -rf .claude/'
block 'ln -s /tmp/x .git/hooks/pre-commit'
block 'echo x 1> devenv.nix'
block 'echo x &> devenv.nix'
block 'true 2> devenv.nix'
allow 'ls .claude/ 2>/dev/null'
allow 'cat devenv.nix >/dev/null 2>&1'
allow 'cat devenv.nix'
allow 'git diff devenv.nix'

# --- 5. plugins / mods ----------------------------------------------------
allow 'claude --version'
allow 'claude -p "hello"'
block 'claude plugin install foo@bar'
block 'claude plugin marketplace add x'
block 'claude --plugin-dir ./evil -p hi'
block 'claude --plugin-url https://x -p hi'
block 'claude --mcp-config ./m.json -p hi'
block 'claude --agents ./a.json -p hi'
block 'CLAUDE_CODE_PLUGIN_DIRS=/tmp/x claude -p hi'
# A nested session launched with these flags would load none of the repo's
# rules (project rule; on a host without managed settings the repo is all
# there is).
block 'claude -p hi --setting-sources user'
block 'claude --setting-sources=user,local -p hi'
block 'claude --settings /tmp/loose.json -p hi'
block 'claude --settings=/tmp/loose.json -p hi'
block 'claude --permission-mode bypassPermissions -p hi'
block 'claude --permission-mode=acceptEdits -p hi'
block 'claude --dangerously-skip-permissions -p hi'
block 'claude --allow-dangerously-skip-permissions -p hi'
block 'cd sub && claude -p hi --settings x.json'
block 'bash -c "claude --dangerously-skip-permissions -p hi"'
block 'claude --bare -p hi'
# --add-dir widens the sandbox's write set and counts as a working directory.
block 'claude --add-dir /tmp/x -p hi'
block 'claude -p hi --add-dir=../other'
allow 'claude -p "summarise the settings reference"'
allow 'code --settings-file x'
allow 'claude --version; echo --settings'
# ccmux hands everything after its project to claude: the same flags, after
# a <customer>/<repo>, a path or nothing (2026-10-24: these all passed).
block 'ccmux cust/repo --bare'
block 'ccmux cust/repo --setting-sources user'
block 'ccmux cust/repo --dangerously-skip-permissions'
block 'ccmux cust/repo --plugin-dir x'
block 'ccmux cust/repo -p hi --settings=/tmp/loose.json'
block 'ccmux ~/code/git/cust/repo --permission-mode bypassPermissions'
block 'ccmux --add-dir /tmp/x'
block 'ccmux -n cust/repo --bare'
block "ccmux cust/repo '--bare'"
block 'bash -c "ccmux cust/repo --bare"'
block 'cd /tmp && env X=1 ccmux cust/repo --setting-sources=user'
block 'nix run .#ccmux -- cust/repo --bare'
block '/nix/store/x-ccmux/bin/ccmux cust/repo --bare'
# A separator inside quotes or escaped does not end the arguments.
block 'ccmux cust/repo -p "fix a; then b" --bare'
block 'claude -p "a && b" --dangerously-skip-permissions'
block 'claude -p a\; b --settings x.json'
block 'ccmux cust/repo -p hi 2>&1 --bare'
block 'claude -p hi &>/dev/null --settings x.json'
allow 'claude -p hi 2>&1 | head; echo --bare'
allow 'ccmux cust/repo --worktree'
allow 'ccmux cust/repo -p "hi"'
allow 'ccmux'
allow 'ccmux -n cust/repo'
allow 'ccmux cust/repo; echo --bare'
allow 'grep -rn "claude|--settings" .'
# Backslashes: an in-word escape and a line continuation both normalise away.
block 'git pu\sh origin main'
block $'git \\\npush origin main'
block 'claude --dangerously-skip-permis\sions -p hi'

# --- Edit / Write tool ----------------------------------------------------
run 0 "$(edit_file $IN/main.tf)"
run 0 "$(edit_file $IN/README.md)"
run 2 "$(edit_file $IN/devenv.nix)"
run 2 "$(edit_file $IN/devenv.local.nix)"
run 2 "$(edit_file $IN/.envrc)"
run 2 "$(edit_file $IN/.env)"
run 2 "$(edit_file $IN/.env.local)"
run 2 "$(edit_file $IN/terraform.tfvars)"
run 2 "$(edit_file $IN/.claude/settings.json)"
run 2 "$(edit_file $IN/.claude/settings.local.json)"
run 2 "$(edit_file $IN/.claude/skills/x/SKILL.md)"
run 2 "$(edit_file $IN/.claude/skills/x/.claude-plugin/plugin.json)"
run 2 "$(edit_file "$HOME/.claude/settings.json")"
run 2 "$(edit_file "$HOME/.claude.json")"
run 2 "$(edit_file "$HOME/.bashrc")"
# Files that run code at the user's next shell, git or tmux start.
run 2 "$(edit_file "$HOME/.zshrc")"
run 2 "$(edit_file "$HOME/.gitconfig")"
run 2 "$(edit_file "$HOME/.config/tmux/harness.conf")"
run 2 "$(edit_file "$HOME/.ssh/authorized_keys")"
# `..` and relative paths are resolved before matching.
run 2 "$(edit_file "$HOME/code/../.bashrc")"
run 2 "$(edit_file devenv.nix)"
run 0 "$(edit_file main.tf)"
# Auto-memory lives under ~/.claude/projects/<slug>/memory/. Allowed only when
# the host was built with allowMemoryEdits; nothing else under ~/.claude ever.
MEM=$(sed -n 's/^ALLOW_MEMORY_EDITS="\(.*\)"$/\1/p' "$hook")
mem="$HOME/.claude/projects/-home-x-repo/memory"
if [ "$MEM" = 1 ]; then
  run 0 "$(edit_file "$mem/MEMORY.md")"
  run 0 "$(edit_file "$mem/some-fact.md")"
  run 0 "{\"hook_event_name\":\"PreToolUse\",\"tool_name\":\"Write\",\"cwd\":\"$IN\",\"tool_input\":{\"file_path\":\"$mem/new.md\",\"content\":\"x\"}}"
else
  run 2 "$(edit_file "$mem/MEMORY.md")"
fi
run 2 "$(edit_file "$mem/../session.jsonl")"
run 2 "$(edit_file "$mem/../../../settings.json")"
run 2 "$(edit_file "$HOME/.claude/projects/-home-x-repo/session.jsonl")"
run 2 "$(edit_file "$HOME/.claude/projects/memory/x.md")"
run 2 "$(edit_file "$HOME/.claude/memory/x.md")"
run 2 "$(edit_file $IN/.git/hooks/pre-commit)"
run 2 "$(edit_file $IN/.git/config)"
run 2 "{\"hook_event_name\":\"PreToolUse\",\"tool_name\":\"Write\",\"cwd\":\"$IN\",\"tool_input\":{\"file_path\":\"$IN/.claude/hooks/x.sh\",\"content\":\"x\"}}"
run 2 "{\"hook_event_name\":\"PreToolUse\",\"tool_name\":\"NotebookEdit\",\"cwd\":\"$IN\",\"tool_input\":{\"notebook_path\":\"$IN/.envrc\"}}"
# The harness's own shell snippet and the user's bin directory run code too.
run 2 "{\"hook_event_name\":\"PreToolUse\",\"tool_name\":\"Write\",\"cwd\":\"$IN\",\"tool_input\":{\"file_path\":\"$HOME/.bashrc.d/claude-nix-harness.sh\",\"content\":\"x\"}}"
run 2 "{\"hook_event_name\":\"PreToolUse\",\"tool_name\":\"Write\",\"cwd\":\"$IN\",\"tool_input\":{\"file_path\":\"$HOME/.local/bin/claude\",\"content\":\"x\"}}"
# An edit through a symlink is judged by its target as well.
ln_dir=$(mktemp -d)
ln -s "$HOME/.bashrc" "$ln_dir/notes.txt"; ln -s "$HOME/.claude/settings.json" "$ln_dir/s.json"
cwd="$ln_dir"
run 2 "$(edit_file notes.txt)"
run 2 "$(edit_file s.json)"
cwd="$IN"; rm -rf "$ln_dir"

# --- Outside the enforcement roots: project rules off, universal rules on --
if [ -n "$ROOTS" ]; then
cwd="$OUT"
allow 'git commit -m "personal"'
allow 'git push origin main'
allow 'terraform apply'
allow 'echo x > devenv.nix'
allow 'az group create -n x'
run 0 "$(edit_file "$OUT/devenv.nix")"
run 0 "$(edit_file "$OUT/.envrc")"
run 0 "$(edit_file "$OUT/.claude/settings.json")"
block 'sudo ls'
block 'az login'
block 'cat .env'
block 'nixos-rebuild switch'
block 'claude --plugin-dir ./evil -p hi'
block 'cmd.exe /c dir'
run 2 "$(edit_file "$HOME/.claude/settings.json")"
run 2 "$(edit_file "$HOME/.bashrc")"
# Sessions outside the roots keep their launch flags and settings.local.json.
allow 'claude --dangerously-skip-permissions -p hi'
allow 'claude --settings /tmp/mine.json -p hi'
# ccmux only launches into the code root: its flags count everywhere.
block 'ccmux acme/infra --bare'
allow 'ccmux acme/infra --worktree'
run 0 "{\"hook_event_name\":\"ConfigChange\",\"source\":\"local_settings\",\"cwd\":\"$OUT\"}"
run 2 "{\"hook_event_name\":\"ConfigChange\",\"source\":\"user_settings\",\"cwd\":\"$OUT\"}"
# A session outside the roots that reaches into a repo under them.
block "git -C $IN push"
block "cd $IN && terraform apply"
block "bash -c 'cd ~${IN#"$HOME"} && git commit -m x'"
run 2 "$(edit_file "$IN/devenv.nix")"
run 2 "$(edit_file "$IN/.envrc")"
run 2 "$(edit_file "/x/..$IN/devenv.nix")"
# Unknown cwd fails closed.
run 2 '{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"git push"}}'
cwd="$IN"
fi

# --- The command center: other repos' setup files open, its own closed ----
# (docs/command-center.md). Every case above ran from inside the checkout.
if [ -n "$CENTER" ]; then
cwd="$CENTER"; other="${CENTER%/*/*}/acme/infra"
# Its own root, under any spelling, stays a work repo's.
run 2 "$(edit_file "$CENTER/devenv.nix")"
run 2 "$(edit_file "$CENTER/devenv.yaml")"
run 2 "$(edit_file "$CENTER/devenv.lock")"
run 2 "$(edit_file "$CENTER/.envrc")"
run 2 "$(edit_file "$CENTER/devenv/devenv.nix")"
run 2 "$(edit_file "$CENTER/.claude/settings.local.json")"
run 2 "$(edit_file "$CENTER/.claude/hooks/x.sh")"
run 2 "$(edit_file "$CENTER/.claude/skills/x/SKILL.md")"
run 2 "$(edit_file "${CENTER^^}/devenv.nix")"
run 2 "$(edit_file "$other/../../bilibo/claude-nix-harness/devenv.nix")"
# Every repo: the files that turn its rules off unseen, credentials, git's
# exec vectors, plugin manifests, your own config.
run 2 "$(edit_file "$other/.claude/settings.json")"
run 2 "$(edit_file "$other/.claude/settings.local.json")"
run 2 "$(edit_file "$other/devenv.local.nix")"
run 2 "$(edit_file "$other/devenv.local.yaml")"
run 2 "$(edit_file "$other/.env")"
run 2 "$(edit_file "$other/terraform.tfvars")"
run 2 "$(edit_file "$other/.git/hooks/pre-commit")"
run 2 "$(edit_file "$other/.git/config")"
run 2 "$(edit_file "$other/.claude/skills/x/.claude-plugin/plugin.json")"
run 2 "$(edit_file "$HOME/.claude/skills/x/SKILL.md")"
# Other repos' setup files: open to the Edit and Write tools.
run 0 "$(edit_file "$other/devenv.nix")"
run 0 "$(edit_file "$other/devenv.yaml")"
run 0 "$(edit_file "$other/devenv.lock")"
run 0 "$(edit_file "$other/.envrc")"
run 0 "$(edit_file "$other/.claude/skills/x/SKILL.md")"
run 0 "$(edit_file "$other/.claude/hooks/x.sh")"
run 0 "{\"hook_event_name\":\"PreToolUse\",\"tool_name\":\"Write\",\"cwd\":\"$CENTER\",\"tool_input\":{\"file_path\":\"$other/.envrc\",\"content\":\"use devenv\"}}"
# A link from elsewhere into the root is the root; an unknown cwd fails closed.
ln_dir=$(mktemp -d); ln -s "$CENTER/devenv.nix" "$ln_dir/devenv.nix"
run 2 "$(edit_file "$ln_dir/devenv.nix")"
block "echo x >> $ln_dir/devenv.nix"
rm -rf "$ln_dir"
run 2 "{\"hook_event_name\":\"PreToolUse\",\"tool_name\":\"Edit\",\"tool_input\":{\"file_path\":\"$other/devenv.nix\"}}"
# Shell writes: only one simple command naming another repo's file by an
# absolute path. A relative name is the root's: no following `cd`.
block 'echo x >> devenv.nix'
block 'cd ../../acme/infra && echo x >> devenv.nix'
block "echo x >> $CENTER/devenv.nix"
block "echo x >> $other/../../bilibo/claude-nix-harness/devenv.nix"
block "echo x >> \$(echo $CENTER)/devenv.nix"
block "echo x >> \$PWD/devenv.nix"
block "echo x >> ${CENTER%/*}/*/devenv.nix"
block "echo x >> ${CENTER%/*/*}/{acme/infra,bilibo/claude-nix-harness}/devenv.nix"
block 'echo x >> ~+/devenv.nix'
block 'echo x >> /proc/self/cwd/devenv.nix'
block "echo x >> $other/devenv.nix; echo y >> devenv.nix"
block "echo x >> $other/devenv.nix && cp $other/devenv.nix ."
block "echo x >> $other/devenv.nix"$'\n'"echo y >> devenv.nix"
block "printf x | tee $other/devenv.nix"
block "echo x >> $other/.claude/settings.json"
block "echo x >> $other/devenv.local.nix"
block "echo x >> $other/.git/hooks/pre-commit"
block "rm -rf $other/.claude/"
block "mv $other/.claude/settings.local.json /tmp/"
block "dd if=/tmp/x of=$other/devenv.nix"
block 'echo x >> ~/.claude/CLAUDE.md'
block 'echo x >> ~/.claude/projects/-home-x-repo/memory/MEMORY.md'
# A copy's destination counts too: it could carry a config file into the root.
block "cp $other/devenv.nix ."
block "cp $other/devenv.nix $CENTER"
block "mv $other/.envrc $CENTER/"
block "cp -t $CENTER $other/devenv.nix"
block "cp -t$CENTER $other/devenv.nix"
block "ln -sf $other/devenv.nix devenv"
allow "echo x >> $other/devenv.nix"
allow "echo 'use devenv' > $other/.envrc"
allow 'echo x >> ~/code/git/acme/infra/devenv.yaml'
allow "echo x >> $other/.claude/agents/a.md"
allow "sed -i s/a/b/ $other/devenv.yaml"
allow "rm $other/.envrc"
allow "rm -rf $other/.claude/skills/old"
allow "cp $other/devenv.nix $other/devenv.nix.bak"
allow "mv /tmp/x/devenv.lock $other/devenv.lock"
allow "cat $other/devenv.nix > /tmp/infra-devenv.nix"
allow 'harness init acme/new'
# Unchanged: git history in any repo, nested launches, the universal rules.
block "git -C $other push"
block "git -C $other commit -m x"
block "cd $other && git push"
block "bash -c 'cd $other && git reset --hard'"
block 'ccmux acme/infra --bare'
block "claude -p hi --settings $other/x.json"
block 'sudo ls'
block 'terraform apply'
allow "git -C $other diff --cached"
allow 'ccmux acme/infra'
# Started from (or moved into) another repo: its files by the Edit tool, any
# name; the shell still only by absolute path.
cwd="$other"
run 0 "$(edit_file devenv.nix)"
run 2 "$(edit_file "$CENTER/devenv.nix")"
block 'echo x >> devenv.nix'
allow "echo x >> $other/devenv.nix"
cwd="$IN"
fi

# --- Roots with capitals: the `~` form of a path under them still counts ---
upper=$(mktemp); sed 's|^ENFORCEMENT_ROOTS=.*|ENFORCEMENT_ROOTS="~/Code"|' "$hook" > "$upper"; chmod +x "$upper"
hook_main="$hook"; hook="$upper"; cwd="$OUT"
block 'git -C ~/Code/x push origin main'
allow 'git -C ~/elsewhere/x push origin main'
hook="$hook_main"; cwd="$IN"; rm -f "$upper"

# --- ConfigChange ---------------------------------------------------------
run 2 '{"hook_event_name":"ConfigChange","source":"user_settings"}'
run 2 '{"hook_event_name":"ConfigChange","source":"policy_settings"}'
run 0 '{"hook_event_name":"ConfigChange","source":"project_settings"}'
# settings.local.json outranks the repo file for scalar keys and hot-reloads;
# under the roots it is blocked, with no cwd it fails closed.
run 2 "{\"hook_event_name\":\"ConfigChange\",\"source\":\"local_settings\",\"cwd\":\"$IN\"}"
run 2 '{"hook_event_name":"ConfigChange","source":"local_settings"}'
run 0 "{\"hook_event_name\":\"ConfigChange\",\"source\":\"project_settings\",\"cwd\":\"$IN\"}"
run 0 "{\"hook_event_name\":\"ConfigChange\",\"source\":\"skills\",\"cwd\":\"$IN\"}"

# --- Session hooks: writes the env preamble -------------------------------
envfile=$(mktemp)
CLAUDE_ENV_FILE="$envfile" "$hook" <<<"{\"hook_event_name\":\"SessionStart\",\"cwd\":\"$IN\"}" >/dev/null 2>&1
if grep -q 'direnv export bash' "$envfile"; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: SessionStart did not write CLAUDE_ENV_FILE"; fi
# The read fence hides ~/.nix-profile: direnv must be on PATH by store path.
if grep -q '^export PATH="/nix/store/[^":]*direnv[^":]*/bin' "$envfile"; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: env preamble does not put direnv on PATH by store path"; sed 's/^/  /' "$envfile"; fi
# devenv needs a writable runtime directory; /run/user/<uid> is read-only in the sandbox.
if grep -q -F 'XDG_RUNTIME_DIR="${TMPDIR:-/tmp}" direnv export bash' "$envfile"; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: env preamble does not give devenv a writable runtime directory"; sed 's/^/  /' "$envfile"; fi
rm -f "$envfile"
# Other tools and events pass through.
run 0 "{\"hook_event_name\":\"PreToolUse\",\"tool_name\":\"Read\",\"cwd\":\"$IN\",\"tool_input\":{\"file_path\":\"$IN/.env\"}}"
run 0 '{"hook_event_name":"Stop"}'
# Garbage input must deny, not allow.
run 2 'not json at all'

# --- Worktree .envrc auto-allow: needs the hook built with the stub direnv ---
# (flake check hook-test-worktree). The stub logs its calls to DIRENV_STUB_LOG
# and answers `status` with DIRENV_STUB_STATUS.
if [ "${2:-}" = --direnv-stub ]; then
  wt=$(mktemp -d); main="$wt/main"; w="$main/.claude/worktrees/wt1"; mkdir -p "$w"
  echo 'use devenv' > "$main/.envrc"; cp "$main/.envrc" "$w/.envrc"
  export DIRENV_STUB_LOG="$wt/calls"
  allowed_main='{"state":{"foundRC":{"path":"'"$main/.envrc"'","allowed":0}}}'
  worktree_session() { # worktree_session <want 0|1 = ran direnv allow> <description> <status json>
    : > "$DIRENV_STUB_LOG"
    CLAUDE_ENV_FILE="$wt/env" DIRENV_STUB_STATUS="$3" "$hook" <<<"{\"hook_event_name\":\"SessionStart\",\"cwd\":\"$w\"}" >/dev/null 2>&1
    local got=0; grep -q '^direnv allow' "$DIRENV_STUB_LOG" && got=1
    if [ "$got" = "$1" ]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: worktree .envrc $2"; fi
  }
  worktree_session 1 "identical to an allowed main .envrc: allowed" "$allowed_main"
  worktree_session 0 "with the main .envrc not allowed: left alone" "${allowed_main/allowed\":0/allowed\":1}"
  echo '# changed' >> "$w/.envrc"
  worktree_session 0 "that differs from main: left alone" "$allowed_main"

  # --- The pre-command environment check (check_env) ---------------------
  # A Bash command in a directory whose .envrc cannot load is refused with
  # the reason; one without .envrc passes untouched; a good export is
  # remembered until the watched files or the devenv profile change.
  repo="$wt/repo"; mkdir -p "$repo"; echo 'use devenv' > "$repo/.envrc"; echo '{}' > "$repo/devenv.nix"
  export XDG_CACHE_HOME="$wt/cache"
  rc_ok='{"state":{"foundRC":{"path":"'"$repo/.envrc"'","allowed":0}}}'
  env_cmd() { # env_cmd <want exit> <description> <want stderr regex> <status json> <export rc> <export stderr> [<export json>]
    local got out
    : > "$DIRENV_STUB_LOG"
    out=$(cwd="$repo"; printf '%s' "$(bash_cmd 'echo hi')" | DIRENV_STUB_STATUS="$4" DIRENV_STUB_EXPORT_RC="$5" DIRENV_STUB_EXPORT_ERR="$6" DIRENV_STUB_EXPORT="${7:-}" "$hook" 2>&1 >/dev/null); got=$?
    if [ "$got" = "$1" ] && [[ "$out" =~ $3 ]]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: env check $2 (want $1 /$3/, got $got: $out)"; fi
  }
  exported() { # exported <want 0|1> <description>
    local got=0; grep -q '^direnv export' "$DIRENV_STUB_LOG" && got=1
    if [ "$got" = "$1" ]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: env check $2 (export ran: $got)"; fi
  }
  env_cmd 2 "export exits 1" "env-guard: direnv export failed in $repo: direnv: error evaluating devenv.nix: oops \(fix: the devenv error" "$rc_ok" 1 $'direnv: loading .envrc\ndirenv: error evaluating devenv.nix: oops'
  exported 1 "export exits 1: export ran"
  env_cmd 2 "export says blocked" "env-guard: direnv export failed in $repo: direnv: error $repo/.envrc is blocked\. Run .direnv allow. to approve its content \(fix: direnv allow $repo\)" "$rc_ok" 0 "direnv: error $repo/.envrc is blocked. Run \`direnv allow\` to approve its content"
  env_cmd 2 "status says not allowed" "env-guard: direnv export failed in $repo: $repo/.envrc is blocked\. Run .direnv allow. to approve its content \(fix: direnv allow $repo\)" "${rc_ok/allowed\":0/allowed\":1}" 0 ""
  exported 0 "status says not allowed: no export"
  env_cmd 0 "no .envrc" '^$' '{"state":{"foundRC":null}}' 1 "never called"
  exported 0 "no .envrc: no export"
  touch "$wt/profile"
  env_cmd 0 "good export" '^$' "$rc_ok" 0 "" "{\"DEVENV_PROFILE\":\"$wt/profile\"}"
  exported 1 "good export: export ran"
  env_cmd 0 "good export remembered" '^$' "$rc_ok" 1 "must not run"
  exported 0 "good export remembered: no export"
  touch -d 2020-01-01 "$repo/devenv.nix"
  env_cmd 2 "devenv.nix changed: export again" "direnv export failed in $repo" "$rc_ok" 1 "direnv: error after the change"
  exported 1 "devenv.nix changed: export ran"
  env_cmd 0 "good again" '^$' "$rc_ok" 0 "" "{\"DEVENV_PROFILE\":\"$wt/profile\"}"
  rm -f "$wt/profile"
  env_cmd 2 "profile gone: export again" "direnv export failed in $repo" "$rc_ok" 1 "direnv: error profile collected"
  exported 1 "profile gone: export ran"
  unset XDG_CACHE_HOME
  rm -rf "$wt"
fi

echo "hook-test: $pass passed, $fail failed"
[ "$fail" = 0 ]
