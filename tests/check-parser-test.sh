#!/usr/bin/env bash
#   check-parser-test.sh <path-to-harness> <fixtures-dir>
#
# `harness check --parse` over two saved stream-json transcripts: what the
# verdicts see is tool output only. (a) the model's prose claims a denial
# and even quotes the hook's message, the command's description echoes it,
# but the tool result is the file's content: the refusal pattern must not
# match and the content must. (b) the hook refused, in the tool result: the
# pattern must match. The pattern is check.sh's `blocked` plus the hook's
# own message, as the credential case expects it.
#
# Then `harness check --dry-run` on fake repos, one per sandbox state and
# role. In the command center (the settings file's sandbox off, the repo's
# HARNESS_ROLE center) the seven cases only the sandbox holds print one
# `skip` line each and are not listed to run; the hook cases are. A repo
# with the sandbox on, or off without role center, lists every case, the
# latter with a warning; another repo's HARNESS_ROLE in this shell does not
# count; a masked settings file (/dev/null) leaves it to the role. Last,
# which claude the sessions would run (stub direnv), and the exit 69 when
# there is none.
set -uo pipefail
harness="${1:?usage: check-parser-test.sh <harness> <fixtures-dir>}"
fixtures="${2:?usage: check-parser-test.sh <harness> <fixtures-dir>}"
pass=0; fail=0
blocked='env-guard:|denied|Read-only file system|not permitted'

parse() { out=$("$harness" check --parse "$fixtures/$1" 2>&1); rc=$?; }
check() { # check <description> <want-regex>
  if [[ "$out" =~ $2 ]]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $1 (/$2/ not in: $out)"; fi
}
refute() { # refute <description> <forbidden-regex>
  if [[ "$out" =~ $2 ]]; then fail=$((fail+1)); echo "FAIL: $1 (/$2/ matched in: $out)"; else pass=$((pass+1)); fi
}

parse check-prose-denial.jsonl
if [ "$rc" = 0 ]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: --parse exits $rc"; fi
check  "the tool's output is seen"            'name = AzureCloud'
refute "prose denial not seen"                "$blocked"
refute "the final result text not seen"       'Permission denied'
refute "the command's description not seen"   'echo of the expected refusal'

parse check-tool-denial.jsonl
check  "the hook's refusal is seen"           'env-guard: credential file access blocked'
check  "the refusal matches the pattern"      "$blocked"
refute "the model's comment not seen"         'the file was not read'

out=$("$harness" check --parse "$fixtures/does-not-exist.jsonl" 2>&1); rc=$?
if [ "$rc" = 66 ]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: a missing transcript exits $rc, want 66"; fi

# --dry-run by role. No direnv on PATH: the role comes from the shell's
# HARNESS_ROLE when DEVENV_ROOT is the repo, else there is none.
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
tmp=$(cd "$tmp" && pwd -P)
sandbox_cases="sandbox ssh-agent home-write repo-write env-deny cred-sandbox git-hookspath"
hook_cases="devenv-env git-commit cred-read config-write edit-envrc nested-flags hooks-registered"
fake_repo() { # fake_repo <name> <settings JSON | @symlink target>
  mkdir -p "$tmp/$1/.claude"; : >"$tmp/$1/.envrc"
  case "$2" in @*) ln -s "${2#@}" "$tmp/$1/.claude/settings.json" ;; *) printf '%s\n' "$2" >"$tmp/$1/.claude/settings.json" ;; esac
}
dry_run() { # dry_run <name> [VAR=value...]: harness check --dry-run on the fake repo; sets out and rc
  local r="$tmp/$1"; shift
  out=$(env -i HOME="$tmp" PATH=/var/empty "$@" "$harness" check --dry-run "$r" 2>&1); rc=$?
}
all_listed() { # all_listed <label>: every case listed to run, none skipped
  local c
  for c in $sandbox_cases $hook_cases; do check "$1: $c listed" "would +$c "; done
  refute "$1: nothing skipped" 'skip  '
  check  "$1: summary" 'dry run, no session started, 0 skipped'
}

fake_repo center '{"sandbox":{"enabled":false}}'
dry_run center DEVENV_ROOT="$tmp/center" HARNESS_ROLE=center
if [ "$rc" = 0 ]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: --dry-run in the center exits $rc"; fi
check "center: role line" 'role: center, sandbox off: the cases only the sandbox holds are skipped'
for c in $sandbox_cases; do
  check  "center: $c skipped"  "skip  $c +sandbox off \\(role center\\): [[:alpha:]]"
  refute "center: $c not run"  "would +$c "
done
for c in $hook_cases; do check "center: $c listed" "would +$c "; done
check  "center: summary"      'dry run, no session started, 7 skipped'
refute "center: no warning"   'warn  '

fake_repo work '{"sandbox":{"enabled":true}}'
dry_run work DEVENV_ROOT="$tmp/work" HARNESS_ROLE=work
all_listed "work"
dry_run work
all_listed "work, no role"
refute "work: no warning" 'warn  '
dry_run work DEVENV_ROOT="$tmp/work" HARNESS_ROLE=center
all_listed "sandbox on, role center"

fake_repo broken '{"sandbox":{"enabled":false}}'
dry_run broken DEVENV_ROOT="$tmp/broken" HARNESS_ROLE=work
all_listed "sandbox off, role work"
check "sandbox off, role work: warned" 'warn  sandbox off in \.claude/settings\.json and the role is work: only the command center'
dry_run broken
all_listed "sandbox off, no role"
check "sandbox off, no role: warned" 'warn  sandbox off .* the role is work'
dry_run broken DEVENV_ROOT="$tmp/work" HARNESS_ROLE=center
all_listed "another repo's role"

fake_repo masked @/dev/null
dry_run masked DEVENV_ROOT="$tmp/masked" HARNESS_ROLE=center
check "masked, role center: summary" 'dry run, no session started, 7 skipped'
dry_run masked
all_listed "masked, no role"
refute "masked: no warning" 'warn  '

# The claude the sessions run, in the header: from the repo's own shell, its
# PATH's (a store directory included); else `direnv exec <repo>`'s, the
# repo shell's or the host's beneath it, never another shell's (a claude in
# a store directory on this PATH); without direnv, or when the repo's shell
# does not load, a host claude outside the store. None: the dry run says so
# and still lists; a real run exits 69 before any session. The stub direnv
# puts <repo>/.shell/bin first on PATH, as a devenv shell with
# harness.claudeCode.enable does, and fails like an .envrc not yet allowed
# where <repo>/.blocked exists.
mkdir -p "$tmp/dbin" "$tmp/hostbin" "$tmp/store/abc-claude-code/bin" "$tmp/cli/.shell/bin"
fake_repo cli '{"sandbox":{"enabled":true}}'
fake_repo blocked '{"sandbox":{"enabled":true}}'; : >"$tmp/blocked/.blocked"
for f in "$tmp/hostbin/claude" "$tmp/store/abc-claude-code/bin/claude" "$tmp/cli/.shell/bin/claude"; do printf '#!/bin/sh\nexit 0\n' >"$f"; chmod +x "$f"; done
cat >"$tmp/dbin/direnv" <<'EOF'
#!/bin/sh
[ "$1" = exec ] || exit 0
d=$2; shift 2
[ ! -e "$d/.blocked" ] || { echo "direnv: error $d/.envrc is blocked" >&2; exit 1; }
PATH="$d/.shell/bin:$PATH" exec "$@"
EOF
chmod +x "$tmp/dbin/direnv"
other="$tmp/store/abc-claude-code/bin" # another shell's claude, by NIX_STORE_DIR
nocli="; harness\\.claudeCode\\.enable = true in $tmp/[a-z]+/devenv\\.nix puts claude in its shell \\(with allow_unfree: true in devenv\\.yaml\\), then direnv allow"
dry_run work DEVENV_ROOT="$tmp/work" PATH="$other" NIX_STORE_DIR="$tmp/store"
check "own shell: its claude"            "claude: $other/claude \\(PATH, the repo's shell\\)"
dry_run cli PATH="$other:$tmp/dbin" NIX_STORE_DIR="$tmp/store"
check "another shell's: the repo shell's" "claude: $tmp/cli/\\.shell/bin/claude \\(direnv exec $tmp/cli\\)"
dry_run work PATH="$tmp/hostbin:$tmp/dbin"
check "repo shell without: the host's"   "claude: $tmp/hostbin/claude \\(direnv exec $tmp/work\\)"
dry_run work PATH="$tmp/hostbin"
check "no direnv: the host's"            "claude: $tmp/hostbin/claude \\(PATH, the host's\\)"
dry_run blocked PATH="$other:$tmp/hostbin:$tmp/dbin" NIX_STORE_DIR="$tmp/store"
check "not loading: the host's"          "claude: $tmp/hostbin/claude \\(PATH, the host's\\)"
check "not loading: warned"              "warn  $tmp/blocked's devenv shell does not load from here: .*direnv allow $tmp/blocked"
dry_run work PATH="$other" NIX_STORE_DIR="$tmp/store"
check "only another shell's: none"       "claude: none \\(no claude on the host PATH, and no direnv on PATH to ask $tmp/work's devenv shell${nocli}\\)"
check "none: the dry run still lists"    'dry run, no session started, 0 skipped'
real_run() { # real_run <name> [VAR=value...]: harness check on the fake repo, sessions and all; only where no claude resolves
  local r="$tmp/$1"; shift
  out=$(env -i HOME="$tmp" PATH=/var/empty "$@" "$harness" check "$r" 2>&1); rc=$?
}
for c in "work PATH=$tmp/dbin|no claude in $tmp/work's devenv shell or on the host PATH" \
         "blocked PATH=$tmp/dbin|no claude on the host PATH, and $tmp/blocked's devenv shell does not load \\(.*direnv allow $tmp/blocked\\)" \
         "work PATH=$other NIX_STORE_DIR=$tmp/store|no claude on the host PATH, and no direnv on PATH to ask $tmp/work's devenv shell"; do
  read -r -a a <<<"${c%%|*}"
  real_run "${a[@]}"
  if [ "$rc" = 69 ]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: no claude (${c%%|*}) exits $rc, want 69: $out"; fi
  check  "no claude (${a[0]}): the error"         "^harness check: ${c#*|}${nocli}$"
  refute "no claude (${a[0]}): no session started" 'transcripts:'
done

echo "check-parser-test: $pass passed, $fail failed"
[ "$fail" = 0 ]
