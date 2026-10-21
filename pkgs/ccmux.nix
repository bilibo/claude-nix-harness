# ccmux [-n] [<customer>/<repo> | <path>] [claude args...]
# Starts or attaches the project's tmux session and runs claude in a window.
# HARNESS_PROJECT is exported by the harness devenv shell, so inside a repo
# (or its worktree) the project argument is optional; for a clone outside the
# code root the shell also exports HARNESS_PROJECT_DIR. `-n` prints the
# resolution and exits, for tests/ccmux-test.sh. `ccode` is the former name
# and stays as a second entry point in bin/.
{
  pkgs,
  codeRoot ? "$HOME/code/git",
}:
let
  ccmux = pkgs.writeShellApplication {
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

      if [ "$dry" = 1 ]; then
        printf 'session=%s repo=%s' "$session" "$repo"
        [ $# -eq 0 ] || printf ' args=%s' "$*"
        echo; exit 0
      fi

      printf -v command '%q ' claude "$@"
      # Keep the window open after claude exits so the pane can be inspected.
      window="$command; exec \"\$SHELL\""
      if tmux has-session -t "=$session" 2>/dev/null; then
        tmux new-window -t "=$session" -c "$repo" "$window"
      else
        tmux new-session -d -s "$session" -c "$repo" "$window"
      fi
      if [ -n "''${TMUX:-}" ]; then
        exec tmux switch-client -t "=$session"
      else
        exec tmux attach-session -t "=$session"
      fi
    '';
  };
in
pkgs.symlinkJoin {
  name = "ccmux";
  paths = [ ccmux ];
  postBuild = "ln -s ccmux $out/bin/ccode";
}
