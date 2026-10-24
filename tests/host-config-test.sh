#!/usr/bin/env bash
#   host-config-test.sh <direnv.toml> <tmux.conf>
#
# The two host settings files pkgs/ ships: the home module reads them on a
# managed host and install.sh copies them on a bootstrapped one, so the
# settings the sandbox and ccmux rely on are asserted here once.
set -uo pipefail
toml="${1:?usage: host-config-test.sh <direnv.toml> <tmux.conf>}"
tmux="${2:?usage: host-config-test.sh <direnv.toml> <tmux.conf>}"
pass=0; fail=0
check() { # check <description> <shell test>
  if eval "$2" >/dev/null 2>&1; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $1 ($2)"; fi
}
check "strict env"          'grep -q "^strict_env = true" "$toml"'
check "no dotenv"           'grep -q "^load_dotenv = false" "$toml"'
check "warn timeout"        'grep -q "^warn_timeout = \"2m\"" "$toml"'
check "no whitelist"        '! grep -qE "^\s*whitelist" "$toml"'
check "direnv vars dropped" 'grep -q "set-environment -gu DIRENV_DIR$" "$tmux"'
check "extended keys"       'grep -q "set -g extended-keys on" "$tmux"'
check "project vars dropped" 'grep -q "set-environment -gu HARNESS_PROJECT_DIR$" "$tmux"'
check "role var dropped"    'grep -q "set-environment -gu HARNESS_ROLE$" "$tmux"'
echo "pass=$pass fail=$fail"
[ "$fail" = 0 ]
