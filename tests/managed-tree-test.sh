#!/usr/bin/env bash
#   managed-tree-test.sh <managed tree> [<managed tree>...]
#
# The mod policy of each managed tree (docs/sessions.md section 5): the
# harness ships no mods since 2026-10-24, so the tree has no marketplace
# directory and its settings register no marketplace and enable no plugin;
# the keys that refuse every mod on a managed host are all there.
set -uo pipefail
[ $# -gt 0 ] || { echo "usage: managed-tree-test.sh <managed tree> [<managed tree>...]" >&2; exit 64; }
pass=0; fail=0

ok() { # ok <description> <command...>
  local d="$1"; shift
  if "$@" >/dev/null 2>&1; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $d"; fi
}

for t in "$@"; do
  s="$t/managed-settings.json"
  echo "== $t"
  ok "settings and hooks present"                 test -f "$s" -a -x "$t/hooks/env-guard.sh"
  ok "no marketplace directory"                   test ! -e "$t/plugins"
  ok "nothing but settings and hooks in the tree" sh -c "[ \"\$(ls -A '$t' | tr '\n' ' ')\" = 'hooks managed-settings.json ' ]"
  ok "no marketplace registered"                  jq -e 'has("extraKnownMarketplaces") | not' "$s"
  ok "no plugin enabled"                          jq -e 'has("enabledPlugins") | not' "$s"
  ok "no prependPlugins (the guard loads on its own)" jq -e 'has("prependPlugins") | not' "$s"
  ok "the guard refuses every mod"                jq -e '.pluginConfigs["cc-plugin-sec-default@builtin"].options.allowManagedModsOnly == true' "$s"
  ok "no marketplace can be added"                jq -e '.strictKnownMarketplaces == []' "$s"
  ok "sideload flags refused"                     jq -e '.disableSideloadFlags == true' "$s"
  ok "only managed hooks run"                     jq -e '.allowManagedHooksOnly == true' "$s"
done

echo "managed-tree-test: $pass passed, $fail failed"
[ "$fail" = 0 ]
