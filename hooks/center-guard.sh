# center-guard: the command center's part of env-guard.sh. Not a script of
# its own: lib/hooks.nix splices it into env-guard.sh below the substituted
# variables when the hook is built for `harness.role = "center"`
# (docs/command-center.md), and makes the two config-file refusals ask it
# first: the Edit check calls center_open, the shell-write rule (rule 4)
# center_shell_ok. A work repo's hook is env-guard.sh untouched, byte for
# byte.
#
# The center sets up and changes other repos, so their devenv.nix,
# devenv.yaml, devenv.lock, .envrc and .claude/ content (skills, agents,
# commands, hooks) are open to it: git shows those edits, and direnv asks
# again for the devenv files and .envrc. Still refused: all of it under
# CENTER_ROOT, and in every repo the files that switch the rules off unseen
# (.claude/settings.json, .claude/settings.local.json, devenv.local.*) and
# the rest of the project list (.env*, tfvars, tfstate, .git/hooks,
# .git/config, .claude-plugin/). Every other rule is a work repo's.
CENTER_ROOT="@centerRoot@"
# The root as named and as it resolves, for a link on the way to it.
center_roots=("$(realpath -sm -- "$CENTER_ROOT")" "$(realpath -m -- "$CENTER_ROOT")")

# center_open <absolute path>: 0 when the center may write it. Lower case
# on both sides, so another spelling of the root is still the root.
center_open() {
  local p="${1,,}/" r
  [ -n "$cwd" ] && [[ "$1" == /* ]] || return 1
  for r in "${center_roots[@]}"; do [[ "$p" == "${r,,}/"* ]] && return 1; done
  case "$p" in
    # Your dotfiles (~/.claude, ~/.config, ~/.bashrc, ...), and links that
    # point wherever the writing process stands.
    "${HOME,,}"/.*|/proc/*|/dev/*) return 1 ;;
    */.claude/|*/.claude/settings*|*/devenv.local.*|*/.env/|*/.env.*|*.tfvars/|*.tfvars.json/|*.tfstate/|\
    */.git/hooks/*|*/.git/config/|*/.claude-plugin/*|*/.config/nix/*|*/.config/direnv/*) return 1 ;;
  esac
}

# center_shell_ok: 0 when the center may run this shell write to a config
# file. One simple command on one line: no `;`, `&`, `|`, `<`, `$`,
# backtick, parenthesis, brace, glob or `=`, any of which can move or hide
# where it writes. Every word naming a config file is an absolute path
# (`/...` or `~/...`, no `..`) that center_open allows as named and as it
# resolves; under cp, mv, ln, install, patch or dd every argument is, so a
# destination directory cannot carry a config file into the root. A
# relative name is refused: the session starts in the root, and the hook
# does not follow `cd`, `-C` or a script to where the command writes.
center_shell_ok() {
  local special='[][;&|<$`(){}*?=]' dots='(^|/)\.\.(/|$)' copy="$b(cp|mv|ln|install|patch|dd)$e"
  local words word i=0 named=0
  [[ "$cmd" != *$'\n'* ]] && ! [[ "$nc" =~ $special ]] || return 1
  read -ra words <<<"${nc//>/ }"
  for word in "${words[@]}"; do
    i=$((i + 1))
    if [[ "${word,,}" =~ $config_files ]]; then
      named=1
    else
      # Not a config file: only a copy's arguments count, not its options.
      [[ "$n" =~ $copy ]] && [ "$i" -gt 1 ] || continue
      [[ "$word" == -* && "$word" != */* ]] && continue
    fi
    # shellcheck disable=SC2088  # the `~/` of the command text, expanded here
    case "$word" in "~/"*) word="$HOME/${word#"~/"}" ;; /*) ;; *) return 1 ;; esac
    [[ "$word" =~ $dots ]] && return 1
    center_open "$(realpath -sm -- "$word")" && center_open "$(realpath -m -- "$word")" || return 1
  done
  # The rule fired on a config file name: one of the words must carry it.
  [ "$named" = 1 ]
}
