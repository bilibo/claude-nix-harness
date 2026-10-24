#!/usr/bin/env bash
# env-guard: the guard hook. Registered for SessionStart, CwdChanged,
# FileChanged, ConfigChange and PreToolUse, from managed settings on a
# managed host and from the repo's .claude/settings.json (devenv module)
# everywhere; the Setup branch below is ready but not registered.
#
# Fail closed: any unexpected error exits 2, which blocks on PreToolUse and
# ConfigChange (together with onFailure = "block" in the hook registration).
# The same for the environment: the env-file preamble below discards what
# `direnv export` says, so before every Bash command the hook checks that
# the nearest .envrc can load (check_env) and refuses the command with the
# reason when it cannot. Needs Claude Code >= 2.1.295. lib/hooks.nix puts jq, direnv, sed and
# coreutils from the store first on PATH, so the guard never runs the
# user's copies of them.
#
# Every regex lives in a variable: bash word-splits an inline `=~` pattern
# on spaces, so `[[ x =~ a b ]]` is a syntax error.
set -uo pipefail
PATH="@path@:${PATH:-}"
trap 'echo "env-guard: internal error, denying" >&2; exit 2' ERR

# Substituted by lib/hooks.nix from the harness.* options: 0 or 1, and a
# colon-separated list where `~` means $HOME and empty means everywhere.
ALLOW_LOCAL_COMMITS="@allowLocalCommits@"
ALLOW_MEMORY_EDITS="@allowMemoryEdits@"
ENFORCEMENT_ROOTS="@enforcementRoots@"

input=$(cat)
event=$(jq -r '.hook_event_name // empty' <<<"$input")
# `cwd` follows worktrees and `cd`; CLAUDE_PROJECT_DIR stays at the start root.
cwd=$(jq -r '.cwd // empty' <<<"$input")

deny() { printf 'env-guard: %s\n' "$1" >&2; exit 2; }

# check_env <cwd>: refuse the command unless direnv can load the .envrc
# nearest to <cwd>; a directory without one passes. `direnv status` (3 ms)
# says whether that .envrc is allowed without loading it, which covers an
# edit since the last `direnv allow`. The export itself (0.2 s warm, seconds
# after a change, measured 2026-10-23) runs only when the files direnv
# watches in a harness repo, or the direnv and devenv binaries, differ from
# the last good run, or when that run's DEVENV_PROFILE is gone from the
# store; the record lives under ~/.cache/claude-nix-harness (no record, or
# an unwritable cache, means the export runs every time). A refusal names
# the first error line and what fixes it.
check_env() {
  local st rcpath dir fp cache key profile stored out err rc first fix
  [ -d "$1" ] || return 0
  st=$(cd "$1" && direnv status --json 2>/dev/null) || deny "direnv status failed in $1 (run: direnv status)"
  rcpath=$(jq -r '.state.foundRC.path // empty' <<<"$st")
  [ -n "$rcpath" ] || return 0
  dir="${rcpath%/.envrc}"
  [ "$(jq -r '.state.foundRC.allowed // 0' <<<"$st")" = 0 ] \
    || deny "direnv export failed in $dir: $rcpath is blocked. Run \`direnv allow\` to approve its content (fix: direnv allow $dir)"
  fp=$( (cd "$dir" && stat -c '%n %Y %s %i' .envrc devenv.nix devenv.yaml devenv.lock devenv.local.nix devenv.local.yaml 2>/dev/null; readlink -f "$(command -v direnv)" "$(command -v devenv 2>/dev/null || echo /dev/null)" 2>/dev/null) ) || true
  cache="${XDG_CACHE_HOME:-$HOME/.cache}/claude-nix-harness/direnv-ok"
  key=$(printf '%s' "$dir" | sha256sum | cut -c1-16)
  if [ -r "$cache/$key" ]; then
    profile=$(head -n 1 "$cache/$key"); stored=$(tail -n +2 "$cache/$key")
    if [ "$stored" = "$fp" ] && { [ -z "$profile" ] || [ -e "$profile" ]; }; then return 0; fi
  fi
  # direnv skips the load when its state variables say this .envrc is
  # loaded and unchanged (a session started inside the devenv shell), so
  # they are unset: the export then evaluates every time it runs.
  out=$(mktemp)
  if err=$(cd "$dir" && env -u DIRENV_DIR -u DIRENV_FILE -u DIRENV_DIFF -u DIRENV_WATCHES direnv export json 2>&1 >"$out"); then rc=0; else rc=$?; fi
  if [ "$rc" != 0 ] || grep -q 'is blocked' <<<"$err"; then
    rm -f "$out"
    first=$(grep -i -m1 'error' <<<"$err" || grep -v '^$' <<<"$err" | tail -n 1 || true)
    if grep -q 'is blocked' <<<"$err"; then fix="direnv allow $dir"; else fix="the devenv error (devenv shell in $dir shows it)"; fi
    deny "direnv export failed in $dir: ${first:-exit $rc} (fix: $fix)"
  fi
  # The export lists what differs from this environment: a profile already
  # in it (the session's own devenv shell) is the current one.
  profile=$(jq -r '.DEVENV_PROFILE // empty' "$out" 2>/dev/null) || profile=""
  [ -n "$profile" ] || profile="${DEVENV_PROFILE:-}"
  rm -f "$out"
  { mkdir -p "$cache" && printf '%s\n%s\n' "$profile" "$fp" > "$cache/$key"; } 2>/dev/null || true
  return 0
}

# Project rules apply when there are no roots, when cwd is unknown (fail
# closed), when cwd is under a root, or when the call names a path under a
# root (`git -C ~/code/git/x push` from a session started elsewhere). The
# universal rules apply regardless.
in_scope=1
roots=()
if [ -n "$ENFORCEMENT_ROOTS" ] && [ -n "$cwd" ]; then
  in_scope=0
  IFS=: read -ra raw <<<"$ENFORCEMENT_ROOTS"
  for r in "${raw[@]}"; do
    r="${r/#\~/$HOME}"; roots+=("${r%/}")
  done
  under_root() { # under_root <path>
    local p="$1" r
    for r in "${roots[@]}"; do [[ "$p" == "$r" || "$p" == "$r/"* ]] && return 0; done
    return 1
  }
  mentions_root() { # mentions_root <normalised command text>
    local t="$1" r rl
    for r in "${roots[@]}"; do
      rl="${r,,}"
      [[ "$t" == *"$rl"* || "$t" == *"~${rl#"${HOME,,}"}"* ]] && return 0
    done
    return 1
  }
  under_root "$cwd" && in_scope=1
fi

case "$event" in
  SessionStart|CwdChanged|FileChanged|Setup)
    [ -n "${CLAUDE_ENV_FILE:-}" ] || exit 0
    # A worktree .envrc is auto-allowed only when byte-identical to the main
    # checkout's .envrc, and only if that one is itself allowed. Never use
    # direnv.toml whitelist.prefix for this: it is path-only and never re-prompts.
    if [[ "$cwd" == */.claude/worktrees/* && -f "$cwd/.envrc" ]]; then
      main="${cwd%%/.claude/worktrees/*}"
      if cmp -s "$main/.envrc" "$cwd/.envrc" \
         && (cd "$main" && direnv status --json 2>/dev/null) \
            | jq -e --arg p "$main/.envrc" '.state.foundRC.path==$p and .state.foundRC.allowed==0' >/dev/null; then
        (cd "$cwd" && direnv allow) || true
      fi
    fi
    # Executed by Claude Code as a preamble before every Bash command, in that
    # command's cwd. Per-command evaluation is robust to EnterWorktree and to
    # devenv.nix edits; the find line cleans the .devenv/shell-*.sh files that
    # every `devenv direnv-export` leaves behind (decision 7.3 in the brief).
    # direnv and devenv by store path, resolved here outside the sandbox (the
    # user's devenv, the hook's direnv): with the read fence on,
    # `~/.nix-profile` (a symlink) is not mounted back into the sandbox, so
    # the profile's bin directory is off PATH there (live, 2026-10-21).
    # devenv creates `$XDG_RUNTIME_DIR/devenv-<hash>` before it evaluates and
    # the sandbox mounts /run/user/<uid> read-only, so the export runs with
    # the sandbox's TMPDIR as its runtime directory (devenv ignores
    # DEVENV_RUNTIME). The command's own XDG_RUNTIME_DIR is untouched: direnv
    # exports only what the devenv shell changed (live, 2026-10-22).
    tool_path=""
    for t in direnv devenv; do
      if p=$(command -v "$t"); then tool_path="$tool_path${tool_path:+:}$(dirname "$(readlink -f "$p")")"; fi
    done
    {
      [ -z "$tool_path" ] || printf 'export PATH="%s:$PATH"\n' "$tool_path"
      cat <<'ENV'
if command -v direnv >/dev/null 2>&1; then eval "$(XDG_RUNTIME_DIR="${TMPDIR:-/tmp}" direnv export bash 2>/dev/null)"; fi
if [ -d .devenv ]; then find .devenv -maxdepth 1 -name 'shell-*.sh' -mmin +10 -delete 2>/dev/null; fi
ENV
    } > "$CLAUDE_ENV_FILE"
    exit 0 ;;

  ConfigChange)
    src=$(jq -r '.source // empty' <<<"$input")
    case "$src" in
      user_settings|policy_settings) deny "config change to $src blocked" ;;
      # .claude/settings.local.json outranks the repo's settings.json for
      # scalar keys (sandbox.enabled, defaultMode) and is applied live, so
      # under the roots a change to it is refused (project rule).
      local_settings) [ "$in_scope" = 1 ] && deny "config change to $src blocked" ;;
    esac
    exit 0 ;;

  PreToolUse)
    tool=$(jq -r '.tool_name // empty' <<<"$input")
    case "$tool" in
      Edit|Write|NotebookEdit|MultiEdit)
        f=$(jq -r '.tool_input.file_path // .tool_input.notebook_path // empty' <<<"$input")
        # The patterns below are literal: make the path absolute and fold `.`
        # and `..` first. Both the path as named (`-s`, so a home-manager
        # ~/.bashrc, a link into the store, still matches its own name) and
        # its target (a link in the repo to ~/.bashrc) must pass.
        [[ "$f" == /* ]] || f="$cwd/$f"
        check_edit() { # check_edit <absolute path>
          [ "$in_scope" = 1 ] || { under_root "$1" && in_scope=1; }
          # The one carve-out under ~/.claude is auto-memory, when the host allows it.
          if [ "$ALLOW_MEMORY_EDITS" = 1 ]; then
            case "$1" in
              "$HOME"/.claude/projects/*/memory/*) return 0 ;;
            esac
          fi
          # The user's own Claude and Nix config, and every file that runs code
          # at their next shell, git or tmux start, outside the sandbox.
          case "$1" in
            "$HOME"/.claude/*|"$HOME"/.claude.json|"$HOME"/.config/*|"$HOME"/.ssh/*|\
            "$HOME"/.bashrc|"$HOME"/.bash_profile|"$HOME"/.bash_login|"$HOME"/.profile|\
            "$HOME"/.zshrc|"$HOME"/.zprofile|"$HOME"/.zshenv|"$HOME"/.zlogin|\
            "$HOME"/.gitconfig|"$HOME"/.tmux.conf|"$HOME"/.bashrc.d/*|"$HOME"/.local/bin/*)
              deny "edit of $1 is forbidden (user config)" ;;
          esac
          if [ "$in_scope" = 1 ]; then
            case "$1" in
              */.claude/settings*.json|*/.claude/hooks/*|*/.claude/skills/*|*/.claude-plugin/*|\
              */devenv.nix|*/devenv.yaml|*/devenv.lock|*/devenv.local.*|*/.envrc|*/.env|*/.env.*|*.tfvars|*.tfvars.json|*.tfstate|\
              */.git/hooks/*|*/.git/config)
                deny "edit of $1 is forbidden (config/env/credentials/plugin)" ;;
            esac
          fi
        }
        check_edit "$(realpath -sm -- "$f")"
        check_edit "$(realpath -m -- "$f")"
        exit 0 ;;

      Bash)
        cmd=$(jq -r '.tool_input.command // empty' <<<"$input")
        # Normalise: lowercase, strip backslashes, collapse whitespace, strip
        # quotes. Catches `bash -c '...'`, `env X=1 git push`, `git 'push'`,
        # `git -C . push`, `git pu\sh` and a backslash-newline continuation.
        # `nc` keeps case, for the few flags where case is the meaning.
        nc=$(printf '%s' "$cmd" | tr -d '\\' | tr -s '[:space:]' ' ' | tr -d "'\"")
        n="${nc,,}"
        [ "$in_scope" = 1 ] || { mentions_root "$n" && in_scope=1; }
        b='(^|[ ;&|(])'       # start of a (sub)command
        e='( |$)'             # end of a word

        # 1. git history and index writes (project rule)
        if [ "$in_scope" = 1 ]; then
        git_ops='push|reset|rebase|merge|cherry-pick|revert|am|filter-branch|filter-repo|reflog +(expire|delete)|branch +-[dm]|branch +(-f|--force)|tag +-d|tag +(-f|--force)|stash +(drop|clear|pop)|checkout( +[^ ;&|]+)* +--|checkout +(-f|--force|\.[^ ]*)|switch +(-f|--force|--discard-changes)|worktree +remove( +[^ ;&|]+)* +(-f|--force)|restore|clean|gc|prune|update-ref|symbolic-ref|notes|commit-tree'
        [ "$ALLOW_LOCAL_COMMITS" = 1 ] || git_ops="commit|$git_ops"
        # `/usr/bin/git`, `git -C . push`, `git --git-dir=.git push`.
        re="(^|[^a-z0-9_.-])git( +-[-a-z]+(=[^ ]*| +[^ ]+)?)* +($git_ops)$e"
        [[ "$n" =~ $re ]] && deny "git history/index write blocked"
        # `-C`/`-B` reset an existing branch; lowercased they read as the harmless `-c`/`-b`.
        re='(^|[^a-zA-Z0-9_.-])git( +[^ ;&|]+)* +(switch +-C|checkout +-B)( |$)'
        [[ "$nc" =~ $re ]] && deny "git history/index write blocked"
        # `git checkout <ref> <path>...` discards edits to those paths; the
        # branch-creating forms take a start point and are the exception.
        re='(^|[^a-z0-9_.-])git( +-[-a-z]+(=[^ ]*| +[^ ]+)?)* +checkout( +-[^ ;&|]+)* +[^- ;&|][^ ;&|]* +[^- ;&|][^ ;&|]*'
        creates='checkout( +[^ ;&|]+)* +(-b|--orphan|-t|--track)( |$)'
        [[ "$n" =~ $re ]] && ! [[ "$n" =~ $creates ]] && deny "git history/index write blocked"
        re='git_dir=|git_work_tree=|git_index_file=|git_config_global=|git_config_system='
        [[ "$n" =~ $re ]] && deny "git env redirect blocked"
        fi

        # 2. cloud and infrastructure writes (project rule)
        if [ "$in_scope" = 1 ]; then
        re="(^|[^a-z])(terraform|tofu|terragrunt)( +-[^ ]+)* +(apply|destroy|import|taint|untaint|state|force-unlock|workspace +(new|delete|select))$e"
        [[ "$n" =~ $re ]] && deny "terraform write blocked"
        re="(^|[^a-z])az .* (create|delete|update|set|start|stop|restart|deploy|purge|assign|remove|rotate|regenerate|invoke|run|import|restore|scale)$e"
        [[ "$n" =~ $re ]] && deny "az write blocked"
        re='(^|[^a-z])az +(deployment|group +(create|delete)|rest +.*--method +(post|put|patch|delete))'
        [[ "$n" =~ $re ]] && deny "az deployment/rest write blocked"
        re='(^|[^a-z])(func +azure +functionapp +publish|pulumi +(up|destroy)|bicep +publish)'
        [[ "$n" =~ $re ]] && deny "deploy blocked"
        fi

        # 3. credentials (universal)
        re='(^|[^a-z])az +(login|logout|account +(set|clear|get-access-token)|ad +sp +credential|keyvault +(secret|key|certificate) +(show|download|list|backup))'
        [[ "$n" =~ $re ]] && deny "credential operation blocked"
        # A secret path anywhere blocks, unless the whole command is one simple
        # command whose verb cannot show content: one line (the normaliser
        # folds newlines, so the raw command is checked), no pipe, no `$(`,
        # backtick or `>(` substitution, no input redirection, and none of
        # the options that read file names from a file, whose errors echo
        # each line (`file -f`, `--files0-from`, `--pathspec-from-file`). A
        # reader list cannot be completed (dd, tr, perl, `git show
        # <ref>:.env`, a bare `< .env`).
        cred_files='(\.env([^a-z0-9]|$)|\.tfvars|\.tfstate|\.azure/|\.terraform\.d/|credentials\.json|\.claude\.json|\.credentials|/\.ssh/|id_(rsa|ed25519)|\.netrc|\.npmrc|\.pypirc|\.aws/|\.git-credentials|\.config/gh/)'
        harmless='^(ls|stat|file|du|wc|rm|git rm|test|\[|echo|printf|touch)( [^;&|<$`(]*)?$'
        list_opts='--files0-from|--files-from|--pathspec-from-file|(^| )file( +-[a-z]+)* +-[a-z]*f'
        if [[ "$n" =~ $cred_files ]]; then
          safe=0
          [[ "$cmd" != *$'\n'* ]] && [[ "$n" =~ $harmless ]] && ! [[ "$n" =~ $list_opts ]] && safe=1
          [ "$safe" = 1 ] || deny "credential file access blocked"
        fi

        # 4. system and config (universal)
        re="(^|[^a-z])(sudo|doas|pkexec|su|run0)$e"
        [[ "$n" =~ $re ]] && deny "privilege escalation blocked"
        re='(^|[^a-z])(nix +(profile|upgrade-nix|registry|store +(gc|delete|optimise))|nix-env|nix-collect-garbage|nixos-rebuild|nh +(os +(switch|boot|test)|home +switch)|nix-channel|home-manager +switch|systemctl|journalctl +--vacuum|wsl\.exe|wslconfig)'
        [[ "$n" =~ $re ]] && deny "system change blocked"
        re="$b(powershell|pwsh|cmd)(\.exe)?( |$)|$b[^ ]*\.exe( |$)|/mnt/c/"
        [[ "$n" =~ $re ]] && deny "Windows executable blocked"
        # Shell-side writes to the files the Edit tool may not touch (project rule).
        if [ "$in_scope" = 1 ]; then
        config_files='(devenv\.(nix|yaml|lock|local)|\.envrc|\.claude/|\.claude-plugin|\.git/hooks|\.git/config|\.config/nix|\.config/direnv)'
        # `2>/dev/null`, `>&2` and friends write no file; every `>` left after
        # dropping them does (`1>`, `2>`, `&>`, `>>` included).
        w=$(printf '%s' "$n" | sed -E 's#[0-9]*>&[0-9]+##g; s#[0-9]*>/dev/null##g')
        writers="(&?>|$b(tee|mv|cp|rm|ln|install|truncate|chmod|chattr|patch|dd)$e|sed +-[a-z]*i|perl +-[a-z]*i)"
        if [[ "$n" =~ $config_files ]] && [[ "$w" =~ $writers ]]; then
          deny "shell write to config file blocked"
        fi
        fi

        # 5. plugin and mod loading (universal)
        re='(^|[^a-z])claude +plugin +(install|marketplace|enable|update|add)'
        [[ "$n" =~ $re ]] && deny "plugin install blocked"
        re='--plugin-(dir|url)|claude_code_plugin_dirs=|--mcp-config|--agents( |=)'
        [[ "$n" =~ $re ]] && deny "plugin sideload blocked"

        # 6. nested sessions that would skip the repo's rules (project rule;
        # for `ccmux` universal: it only launches into the code root).
        # Without managed settings the repo file is the only rule source, and
        # these flags replace or bypass it for the child session (`--bare`
        # skips every hook); `--add-dir` widens the child's working
        # directories, which the sandbox lets it write. `ccmux [<project>]`
        # hands the rest to `claude`. Arguments stop at a command separator
        # so a flag in a later command does not count; one inside quotes or
        # after a backslash is text (`-p "a; b" --bare`), as is the `&` of
        # `2>&1` and `&>`, so this rule reads the command with those turned
        # into `_`, which only adds matches. A renamed copy of the binary
        # gets past this; the sandbox is the layer for that.
        launcher=ccmux; [ "$in_scope" = 0 ] || launcher='claude|ccmux'
        q=$(printf '%s' "$cmd" | jq -Rsj 'gsub("(?<q>\"(\\\\.|[^\"\\\\])*\"|\\x27[^\\x27]*\\x27|\\\\.|>&|&>)"; .q | gsub("[;&|]"; "_"))' | tr -d '\\' | tr -s '[:space:]' ' ' | tr -d "'\"")
        re="(^|[^a-z])($launcher)( +[^ ;&|]+)* +--(bare|setting-sources|settings|permission-mode|dangerously-skip-permissions|allow-dangerously-skip-permissions|add-dir)( |=|$)"
        [[ "${q,,}" =~ $re ]] && deny "claude launch flag blocked"

        # 7. the environment the command is about to run in must load
        # (universal; the env-file preamble below is fail-open on its own).
        check_env "$cwd"
        exit 0 ;;
    esac
    exit 0 ;;
esac
exit 0
