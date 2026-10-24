# The command center

Decided 2026-10-24, revised that afternoon: the center runs without the
Bash sandbox. The host is a plain box with no host-wide rules: a session's
rules come from the `.claude/settings.json` of the directory it started
in, and work repos under `~/code/git/<customer>/<repo>` keep the full set.
In this checkout you start the session that launches work sessions
(`ccmux <customer>/<repo>`), reads their staged diffs, writes proposals
(diffs for files the rules refuse) and maintains the harness code, staged
for you to commit. A work session proposes; you decide here
(`docs/sessions.md` section 4).

Decided 2026-10-24, evening: the center is deliberately open. Its job is
setting up new repos and changing existing ones, so it writes their
`devenv.nix`, `devenv.yaml`, `devenv.lock`, `.envrc` and `.claude/`
skills and hooks (section 4). Its own stay closed, and so does every
repo's `.claude/settings*.json` and `devenv.local.*`. To lock it down, set
`harness.role = "work";` in this checkout's `devenv.nix` (one line, then
`direnv allow`: the work repo's rules and sandbox), or do the work from a
locked repo.

## 1. The role

`harness.role` in a repo's `devenv.nix`: `work` by default, `center` in
this checkout (`harness init` refuses a work repo that sets it).

| | `work` (default) | `center` |
|---|---|---|
| Deny rules, hook | the full set | the same, but other repos' setup files are open (section 4); the memory carve-out (section 7) |
| Bash sandbox | on: writes confined to the repo, network allowlist, credential paths hidden, `/mnt/c` hidden on WSL | off: no allowlist, no confinement, `/mnt/c` readable (a command naming `/mnt/c/` is still refused, hook rule 4) |
| A Bash command | runs unprompted inside the sandbox | Claude Code's permission prompt (section 3) |
| Memory, read fence | off; `readFence` opt-in | memory on by default (section 7); fence off |
| Packages | `ccmux`; claude, tmux, jq with `claudeCode.enable` | claude, tmux, jq, `ccmux`, nixfmt, statix, deadnix, shellcheck |
| `HARNESS_ROLE` | `work` | `center` |

In practice the center only meets the git and self-protection rules.
`ccmux` names the tmux window after the role; a work session launched from
here starts without `HARNESS_ROLE`, and its repo's shell sets `work`.
Rules follow where the session starts: this checkout's file governs `git
-C ~/code/git/<c>/<r> diff --cached` and every other command from here,
and its hook has no enforcement roots, so project rules apply to any path
(`hooks/env-guard.sh:81-107`). The setup-file rules are the exception:
`hooks/center-guard.sh`, spliced into the center's build of the hook only
(`lib/hooks.nix:37-49`), holds them to this checkout. A work repo's hook
is `env-guard.sh` untouched: nothing of the center's reaches its store
path.

## 2. The pinned import

The checkout's `devenv.yaml` imports `harness/devenv` from
`github:bilibo/claude-nix-harness` (`flake: false`), locked in
`devenv.lock` as in a work repo, not `./devenv` from the working tree.
With `./devenv`, devenv tracked `hooks/` and `lib/` while `require_allowed`
covers only `devenv.nix`, `devenv.yaml` and `devenv.lock`: an agent's
uncommitted edit became the live hook at your next shell entry. Now the
rules move only when `devenv.lock` does, which `require_allowed` flags.
Try an edit first on a copy (CLAUDE.md) or in a `path:` test repo.

## 3. Starting it, and what asks first

```
ccmux bilibo/claude-nix-harness                     # tmux session bilibo-claude-nix-harness
cd ~/code/git/bilibo/claude-nix-harness && claude   # without tmux; work sessions still open in tmux
```

- **Bash asks** for every command no allow rule matches (a `-p` session
  takes that as a refusal). This line in the checkout's `devenv.nix`, then
  `direnv allow`, quiets it: `harness.settings.permissions.allow = [
  "Bash(*)" ];`. Deny rules and the hook still win; but then nothing asks
  before a command or a script runs, and section 5 is the whole picture.
- **Reads** are open across your home; the Read tool's deny rules still
  refuse the credential paths (`lib/deny-rules.nix:45-78`). Leave
  `blockReadsOutsideWorkingDirectories` unset: it hides the work repos.
- **Launch.** `ccmux` starts `claude` through tmux in the work repo
  (`pkgs/ccmux.nix`), so the new session loads that repo's rules, then
  switches your client to it (prefix + `L` comes back). The hook refuses
  `ccmux` with `--bare`, `--setting-sources`, `--settings` and the other
  flags that would start it without them (rule 6, `:288-303`).

## 4. What it may and may not write

| | Edit and Write tools | A shell command |
|---|---|---|
| Another repo's `devenv.nix`, `devenv.yaml`, `devenv.lock`, `.envrc`, `.claude/` skills, agents, commands, hooks | allowed | allowed as one simple command naming it by absolute path (`echo ... >> ~/code/git/<c>/<r>/.envrc`, `sed -i`, `cp`, `rm`); refused with a relative name, `cd`, `;`, `&&`, `\|`, `<`, `$`, a glob, `..` |
| The same files in this checkout, and `devenv/devenv.nix` | refused | refused |
| Any repo's `.claude/settings.json`, `.claude/settings.local.json`, `devenv.local.*`, `.env*`, `.git/hooks`, `.git/config`, `.claude-plugin/` | refused | refused |

The open files show in `git diff`, and direnv asks again before a changed
`devenv.nix`, `devenv.yaml`, `devenv.lock` or `.envrc` loads; the settings
files and `devenv.local.*` switch a repo's rules off with neither. A
center session can write `harness.enable = false` into a work repo: read
the diff before you `direnv allow` there.

| Refused | By | Why it matters |
|---|---|---|
| Commit, push, reset, rebase, ... in any repo: `git -C <path>`, `cd <path> && git ...`, `bash -c '...'`, `--git-dir=`, `GIT_DIR=` | hook rule 1 (`hooks/env-guard.sh:212-229`) after the normaliser (`:201-207`); deny rules (`lib/deny-rules.nix:159-198`) | you alone commit and push; a push from here would land in a customer repo unreviewed |
| Switching rules off: the last two rows above | Edit check (`:187-194`) asking `center_open` (`hooks/center-guard.sh:21-34`); commands that name them (`:270-280`) asking `center_shell_ok` (`center-guard.sh:36-66`); deny rules, this checkout's by absolute path (`lib/deny-rules.nix:239-276`); settings-change block (`:149-158`); bypass mode off; `claude` and `ccmux` launch flags (rule 6, `:288-303`) | a session that can rewrite its rules has none; you edit these by hand from a diff |
| Credentials named in a command or a Read (`.env`, `~/.ssh`, `~/.azure`, `az login`, ...), cloud writes, `sudo`, system changes, plugin installs, Windows executables | hook rules 2 to 5 (`:231-241`, `:243-261`, `:263-269`, `:282-286`); deny rules | the same everywhere; credentials by text only (section 5) |

## 5. What the sandbox no longer does here

It stopped scripts; the hook reads command text. Accepted for the center
on 2026-10-24:

- **Credentials.** `~/.ssh`, `~/.aws`, `~/.azure`, `~/.config/gh`,
  `~/.git-credentials`, `~/.netrc`, `~/.gnupg` and `SSH_AUTH_SOCK` are in
  reach. Whether Claude Code still strips the secret variables listed under
  `sandbox.credentials` with the sandbox off is not verified: assume they
  are set. The hook refuses `cat ~/.ssh/id_ed25519`; a script is not caught.
- **Network.** No allowlist: a script reaches any host with what it read.
  `gh pr merge` or `gh api -X PUT` is no git command and no rule names
  it, and a script's `git push` never meets the text rule. A hardware key
  or a passphrase key kept out of the agent (README, "Git over SSH") still
  asks you; a stored HTTPS token or a logged-in `gh` does not.
- **Writes.** A command writes wherever you can: the work repos,
  `~/.bashrc`, `~/.config`, `~/.claude/settings.json` (user scope: every
  session on the host, the work repos' strict allowlist key included),
  this checkout's `.claude/settings.local.json`, any repo's git config
  (`git config core.hooksPath` picks the hook your next commit runs). An
  edit asks first, or is refused (`:178-194` and section 4: your config,
  this checkout's setup files, any repo's settings files, `devenv.local.*`
  and `.env*`); a command is refused only when it names one of those
  (`:270-280`), and `~/.bashrc` is not one.

The Bash prompt stands in for all three: read a command, and any script
it runs, before you approve it. With `Bash(*)` allowed nothing asks.

## 6. Known gaps (2026-10-24)

- **tmux** (roadmap 2.8): moot here. Open in the work repos, whose
  sandboxed `tmux send-keys` reaches the server, the center's pane too.
- **`devenv update`** passes every rule: a session can move `devenv.lock`
  to what the input URL serves. Read `git diff devenv.lock` first.
- **Self-protection is text.** A script, or `devenv shell -O
  harness.<option>:bool ...` (re-links the rules file; not tried),
  rewrites the rules without naming them, and so do `rm -rf <repo>/.claude`
  and `cp -r x/.claude <repo>/`, which name no file the rules know. A
  work repo's sandbox `denyWrite` stops all of these; here only the prompt
  does.

## 7. Memory

`center` turns `allowMemoryEdits` on; work repos keep it off. The Edit
and Write tools may write `~/.claude/projects/<slug>/memory/`; the rest of
`~/.claude` stays refused to them, transcripts (`*.jsonl`) included
(`lib/deny-rules.nix:114-139`, `hooks/env-guard.sh:172-186`). A shell
write there is refused when the command names `.claude/` (`:270-280`;
`center_open` keeps your dotfiles closed).

Why: memory makes the checkout an orchestrator (which repos are in
flight, what was proposed, what you decided). The risk accepted: every
later session here reads it as context, unreviewed, so anything a session
picked up once (a hostile README, a crafted diff, a peer's message) can
steer later ones. The carve-out matches any project's slug (`:175`,
roadmap 2.9), so a session here can write a work repo's memory; Claude
Code asks first: refuse it. Read what is stored:
`ls ~/.claude/projects/-home-raulk-code-git-bilibo-claude-nix-harness/memory/`.

## 8. Setting it up

Staged 2026-10-24. The hook refuses `devenv.nix`, `devenv.yaml` and
`devenv/devenv.nix` to a session, so they came as patches that day
(`~/code/git/bilibo/module.patch` and `center.patch`; they replace
`offswitch.patch` and `cc.patch`). From your own terminal, with no `direnv
allow` until `devenv.lock` names a revision that has `harness.role`: before
that the shell fails to evaluate and the hook refuses every command.

```
git apply ../module.patch ../center.patch
git add devenv devenv.nix devenv.yaml && git diff --cached     # read it all
git commit && git push
devenv update harness                 # devenv.lock -> the revision just pushed
jq -r '.nodes.harness.locked.rev' devenv.lock; git rev-parse origin/main   # the same
direnv allow
echo "$HARNESS_ROLE"; jq '.sandbox.enabled' .claude/settings.json          # center, false
grep CENTER_ROOT "$(jq -r '.hooks.PreToolUse[0].hooks[0].command' .claude/settings.json)"   # this checkout
git commit devenv.lock && git push   # then restart the command-center session
```

Every later harness change: push, `devenv update harness`, `direnv allow`.
