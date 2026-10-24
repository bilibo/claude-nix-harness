# ccmux [-n] [<customer>/<repo> | <path>] [claude args...]
# Starts or attaches the project's tmux session and runs claude in a window.
# HARNESS_PROJECT is exported by the harness devenv shell, so inside a repo
# (or its worktree) the project argument is optional; for a clone outside the
# code root the shell also exports HARNESS_PROJECT_DIR. HARNESS_ROLE (center
# or work), exported next to it, names the window and goes into its
# environment. claude is the one on PATH, else the target repo's devenv
# shell's (`direnv exec`), else an error naming harness.claudeCode.enable.
# `-n` prints the resolution and exits, for tests/ccmux-test.sh.
{
  pkgs,
  codeRoot ? "$HOME/code/git",
}:
pkgs.writeShellApplication {
  name = "ccmux";
  runtimeInputs = [ pkgs.tmux ];
  text = ''
    usage() { echo "usage: ccmux [<customer>/<repo> | <path>] [claude args]  (inside a repo under $root, the project is optional)" >&2; exit 64; }
    die() { echo "ccmux: $*" >&2; exit 66; }
    # Physical path, like the `pwd -P` in resolve, so a symlinked root still matches.
    root="''${HARNESS_CODE_ROOT:-${codeRoot}}"
    root=$(cd "$root" 2>/dev/null && pwd -P) || die "no such directory: $root"

    # resolve <dir>: the <customer>/<repo> containing <dir>, or die.
    resolve() {
      local p rel a b
      p=$(cd "$1" 2>/dev/null && pwd -P) || die "no such directory: $1"
      [[ "$p" == "$root/"* ]] || die "$p is not under $root/<customer>/<repo>"
      rel="''${p#"$root/"}"
      IFS=/ read -r a b _ <<<"$rel"
      [ -n "$a" ] && [ -n "$b" ] || die "$p is not under $root/<customer>/<repo>"
      printf '%s/%s' "$a" "$b"
    }

    dry=0
    if [ "''${1:-}" = "-n" ] || [ "''${1:-}" = "--dry-run" ]; then dry=1; shift; fi

    if [ $# -ge 1 ] && [[ "$1" != -* ]]; then
      arg="$1"; shift
      if [[ "$arg" != /* && "$arg" != .* && -d "$root/$arg" ]]; then
        project=$(resolve "$root/$arg")
      elif [ -d "$arg" ]; then
        project=$(resolve "$arg")
      else
        die "no such repo: $root/$arg (give <customer>/<repo>, or a path to a repo under $root)"
      fi
    elif [ -n "''${HARNESS_PROJECT:-}" ]; then
      project="$HARNESS_PROJECT"
    elif [[ "$PWD" == "$root/"* ]]; then
      project=$(resolve "$PWD")
    else
      usage
    fi

    if [ -n "''${HARNESS_PROJECT_DIR:-}" ] && [ "$project" = "''${HARNESS_PROJECT:-}" ]; then
      repo="$HARNESS_PROJECT_DIR"
    else
      repo="$root/$project"
    fi
    [ -d "$repo" ] || die "no such repo: $repo"
    session="''${project//\//-}"

    # HARNESS_ROLE is the role of HARNESS_PROJECT, the shell's own project:
    # the window carries it, and is named after it, only when it opens that
    # project. Into any other project (the center launching a work repo) the
    # window starts without it and that repo's shell sets its own (direnv,
    # before every Bash command), so a work session never reads `center`.
    # The window sets or clears it itself, since the tmux server's global
    # environment is that of whichever client started the server, possibly
    # a center shell; the client drops it, so a server started here has none.
    role="" name=claude setrole="unset HARNESS_ROLE"
    if [ "$project" = "''${HARNESS_PROJECT:-}" ]; then role="''${HARNESS_ROLE:-}"; fi
    if [ -n "$role" ]; then
      [[ "$role" =~ ^[a-z][a-z0-9-]*$ ]] || die "HARNESS_ROLE is not a role name: $role"
      name="$role" setrole="export HARNESS_ROLE=$role"
    fi

    # The window's claude. The launching PATH's first (a host-wide install,
    # or the repo shell ccmux runs in), by absolute path: the one `-n`
    # reports. Else the target repo's devenv shell
    # (harness.claudeCode.enable): the window runs `direnv exec <repo>
    # claude`, so claude starts in that shell's environment. On a host whose
    # Claude Code is the VS Code extension's bundled binary, that is the only
    # CLI there is.
    nocli() { echo "ccmux: $1; harness.claudeCode.enable = true in $repo/devenv.nix puts claude in its shell (with allow_unfree: true in devenv.yaml), then direnv allow" >&2; exit 69; }
    direnv=$(type -P direnv || true)
    if claude=$(type -P claude); then
      via=PATH
    elif [ -z "$direnv" ]; then
      nocli "no claude on PATH, and no direnv on PATH to load $repo's devenv shell"
    else
      rc=0
      claude=$("$direnv" exec "$repo" "$BASH" -c 'type -P claude || exit 3' 2>/dev/null) || rc=$?
      case "$rc" in
        0) via="direnv exec $repo" ;;
        3) nocli "no claude on PATH or in $repo's devenv shell" ;;
        *) nocli "no claude on PATH, and $repo's devenv shell does not load (read its .envrc and devenv files, then direnv allow $repo)" ;;
      esac
    fi

    if [ "$dry" = 1 ]; then
      printf 'session=%s repo=%s' "$session" "$repo"
      [ $# -eq 0 ] || printf ' args=%s' "$*"
      printf '\nrole=%s window=%s' "''${role:-unset}" "$name"
      [ -n "$role" ] || [ -z "''${HARNESS_ROLE:-}" ] || printf ' (HARNESS_ROLE=%s is for %s)' "$HARNESS_ROLE" "''${HARNESS_PROJECT:-no project}"
      printf '\nclaude=%s (%s)' "$claude" "$via"
      echo; exit 0
    fi
    unset HARNESS_ROLE

    if [ "$via" = PATH ]; then
      printf -v command '%q ' "$claude" "$@"
    else
      printf -v command '%q ' "$direnv" exec "$repo" claude "$@"
    fi
    # Keep the window open after claude exits so the pane can be inspected.
    window="$setrole; $command; exec \"\$SHELL\""
    if tmux has-session -t "=$session" 2>/dev/null; then
      tmux new-window -t "=$session" -n "$name" -c "$repo" "$window"
    else
      tmux new-session -d -s "$session" -n "$name" -c "$repo" "$window"
    fi
    if [ -n "''${TMUX:-}" ]; then
      exec tmux switch-client -t "=$session"
    else
      exec tmux attach-session -t "=$session"
    fi
  '';
}
