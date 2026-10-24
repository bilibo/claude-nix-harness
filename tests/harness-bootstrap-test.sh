#!/usr/bin/env bash
#   harness-bootstrap-test.sh <path-to-harness>
#
# `harness bootstrap`, `doctor` and `reset` on a generic (non-Fedora) host
# with every host command stubbed: sudo (runs `install` as a plain copy and
# logs the rest), nix, sysctl, systemctl and the tools doctor looks for; a
# fake HOME, and the system files under a scratch directory (HARNESS_NIX_CONF,
# HARNESS_SYSCTL_DROPIN, HARNESS_NIX_INSTALLER, HARNESS_OS_RELEASE,
# HARNESS_CA_BUNDLE; HARNESS_NIX_PROFILE_D empty, so the stub nix wins on a
# nix-installer host). Asserts the root steps (nix.conf with and without a
# flakes line; the AppArmor bwrap profile offered, declined and accepted
# where AppArmor confines user namespaces, the sysctl where an older kernel
# does; never dnf, which is scripts/install.sh's), the user files per
# rc-file layout (none, Fedora's ~/.bashrc.d, a plain ~/.bashrc, zsh only,
# an existing ~/.tmux.conf, a foreign direnv.toml), the user-scope Claude
# Code keys (account sync off by default, --account-sync opting back in,
# --no-account-sync still accepted), idempotent re-runs, the
# receipt, reset undoing all of it, upgrade building before it removes and
# handing the user steps to the upgraded harness, reset doing nothing without
# a receipt, the store-symlink guard on nix.conf, a NixOS host (no root step,
# the configuration.nix lines printed, home-manager's files left alone), the
# Fedora host line from doctor and a WSL host line. Assumes no
# controlling terminal; the stub directory is the whole PATH.
set -uo pipefail
harness="${1:?usage: harness-bootstrap-test.sh <harness>}"
pass=0; fail=0
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
log="$tmp/calls"
mark='# --- claude-nix-harness (scripts/bootstrap-fedora.sh) ---'
mkdir -p "$tmp/bin" "$tmp/etc" "$tmp/nix"; touch "$tmp/ca.pem"
# The nix-installer's uninstaller, where scripts/install.sh leaves it.
printf '#!/bin/sh\n' >"$tmp/nix/nix-installer"; chmod +x "$tmp/nix/nix-installer"

stub() { printf '#!/bin/sh\necho "%s $*" >>"$CALLS"\n%s\n' "$1" "$2" >"$tmp/bin/$1"; chmod +x "$tmp/bin/$1"; }
# sudo: `install SRC DST` lands as a copy under $tmp; a sysctl flips the fake
# restriction the way the kernel would (RESTRICTED: the AppArmor one,
# CLONE_RESTRICTED: unprivileged_userns_clone); the rest is logged only.
stub sudo 'case "$1" in
  install) shift; while [ $# -gt 2 ]; do shift; done; mkdir -p "$(dirname "$2")"; cp "$1" "$2" ;;
  sysctl) case "$3" in
    kernel.apparmor_restrict_unprivileged_userns=0) rm -f "$RESTRICTED" ;; kernel.apparmor_restrict_unprivileged_userns=1) touch "$RESTRICTED" ;;
    kernel.unprivileged_userns_clone=1) rm -f "$CLONE_RESTRICTED" ;; kernel.unprivileged_userns_clone=0) touch "$CLONE_RESTRICTED" ;;
  esac ;;
esac; exit 0'
# nix: a profile that remembers what was added ($PROFILE_STATE, one name per line).
stub nix 'case "$1" in
  --version) echo "nix (Nix) 2.30.0" ;;
  profile) case "$2" in
    list) printf "{\"elements\":{"; sep=""; for n in $(cat "$PROFILE_STATE" 2>/dev/null); do printf "%s\"%s\":{}" "$sep" "$n"; sep=","; done; echo "}}" ;;
    add) [ "$3" = --help ] || echo "${3##*#}" >>"$PROFILE_STATE" ;;
    remove) grep -v -x -e "$3" "$PROFILE_STATE" >"$PROFILE_STATE.new" 2>/dev/null; mv "$PROFILE_STATE.new" "$PROFILE_STATE" ;;
  esac ;;
esac; exit 0'
stub sysctl 'case "$1 $2" in
  "-n kernel.apparmor_restrict_unprivileged_userns") if [ -e "$RESTRICTED" ]; then echo 1; else echo 0; fi; exit 0 ;;
  "-n kernel.unprivileged_userns_clone") if [ -e "$CLONE_RESTRICTED" ]; then echo 0; else echo 1; fi; exit 0 ;;
  "-n "*) exit 1 ;; esac; exit 0'
stub systemctl 'exit 0'
stub rpm 'exit 1'
stub direnv 'echo 2.38.2'
stub devenv 'echo "devenv 2.4.0"'
stub ccmux ''
stub bwrap ''
stub socat ''
stub tmux 'echo "tmux 3.5a"'
stub claude 'case "$1" in --version) echo "2.1.305 (Claude Code)" ;; doctor) echo "No installation issues found" ;; esac'

ubuntu() { printf 'ID=ubuntu\nVERSION_ID="24.04"\nPRETTY_NAME="Ubuntu 24.04"\n' >"$tmp/os-release"; }
ubuntu

# harness <home> <command> [args...]: with the stubs, no terminal; sets out
# and rc, empties the log. ROOT_STEPS is what scripts/install.sh hands over
# (the installer by default; set it empty for a host that had Nix already).
harness() {
  local home="$1" cmd="$2"; shift 2
  : >"$log"
  out=$(cd "$tmp" && env -i HOME="$home" PATH="$tmp/bin" TMPDIR="$tmp" CALLS="$log" RESTRICTED="$tmp/restricted" CLONE_RESTRICTED="$tmp/clone-restricted" USER=tester \
    PROFILE_STATE="$tmp/profile" HARNESS_REF=github:bilibo/claude-nix-harness HARNESS_ROOT_STEPS="${ROOT_STEPS-nix-installer}" \
    HARNESS_OS_RELEASE="$tmp/os-release" HARNESS_NIX_CONF="$tmp/etc/nix.conf" HARNESS_SYSCTL_DROPIN="$tmp/etc/99-userns.conf" HARNESS_APPARMOR_PROFILE="$tmp/etc/apparmor-bwrap" \
    HARNESS_NIX_INSTALLER="$tmp/nix/nix-installer" HARNESS_CA_BUNDLE="$tmp/ca.pem" HARNESS_NIX_PROFILE_D= \
    HARNESS_NIXOS_MARKER=/var/empty/none HARNESS_WSL_MARKER="${WSL_MARKER:-/var/empty/none}" \
    "$harness" "$cmd" "$@" 2>&1 </dev/null); rc=$?
}
ok()   { pass=$((pass+1)); }
bad()  { fail=$((fail+1)); echo "FAIL: $1"; printf '%s\n' "$out" | sed 's/^/  /'; }
exits()    { if [ "$rc" = "$2" ]; then ok; else bad "$1 (want exit $2, got $rc)"; fi; }
says()     { if [[ "$out" =~ $2 ]]; then ok; else bad "$1 (/$2/)"; fi; }
refutes()  { if [[ "$out" =~ $2 ]]; then bad "$1 (/$2/ matched)"; else ok; fi; }
called()   { if grep -q -E -e "$2" "$log"; then ok; else bad "$1 (/$2/ not in the calls: $(tr '\n' ';' <"$log"))"; fi; }
uncalled() { if grep -q -E -e "$2" "$log"; then bad "$1 (/$2/ in the calls)"; else ok; fi; }
file_has() { if grep -q -E -e "$3" "$2" 2>/dev/null; then ok; else bad "$1 (/$3/ not in $2)"; fi; }
file_is()  { if [ "$(cat "$2" 2>/dev/null)" = "$3" ]; then ok; else bad "$1 ($2 is: $(cat "$2" 2>/dev/null))"; fi; }
absent()   { if [ -e "$2" ]; then bad "$1 ($2 exists)"; else ok; fi; }
count_is() { local n; n=$(grep -c -F -e "$3" "$2" 2>/dev/null); if [ "${n:-0}" = "$4" ]; then ok; else bad "$1 ($3 appears ${n:-0} times in $2, want $4)"; fi; }
in_json()  { if jq -e "$3" "$2" >/dev/null 2>&1; then ok; else bad "$1 ($3 false in $2)"; fi; }

# 1. A fresh host, user namespaces confined by AppArmor, --yes: every root
# and user step; the bwrap profile, not the sysctl.
touch "$tmp/restricted"; profile="$tmp/etc/apparmor-bwrap"
h="$tmp/home1"; mkdir -p "$h/.claude"; receipt="$h/.local/state/claude-nix-harness/receipt.json"
# The scrub key an earlier bootstrap wrote (2026-10-22), next to a key of the user's own.
echo '{"theme":"dark","env":{"CLAUDE_CODE_SUBPROCESS_ENV_SCRUB":"1"}}' >"$h/.claude/settings.json"
harness "$h" bootstrap --yes
exits "fresh bootstrap" 0
says "nothing missing"             'harness bootstrap: 0 missing'
says "ran to the end"              'harness init <customer>/<repo>'
uncalled "no sysctl for AppArmor"  'sysctl -w'
absent "no sysctl drop-in" "$tmp/etc/99-userns.conf"
file_has "profile header" "$profile" '^profile bwrap /usr/bin/bwrap flags=\(unconfined\) \{$'
file_has "profile userns" "$profile" '^  userns,$'
file_has "profile abi" "$profile" '^abi <abi/4.0>,$'
count_is "profile marker" "$profile" "$mark" 1
called "apparmor reloaded"         '^sudo systemctl reload apparmor$'
file_has "flakes in nix.conf" "$tmp/etc/nix.conf" '^experimental-features = nix-command flakes$'
file_has "devenv cache" "$tmp/etc/nix.conf" '^extra-substituters = https://devenv.cachix.org$'
count_is "nix.conf block" "$tmp/etc/nix.conf" "$mark" 1
for p in direnv devenv ccmux harness; do called "profile add $p" "^nix profile add github:bilibo/claude-nix-harness#$p$"; done
count_is "~/.bashrc created with the block" "$h/.bashrc" "$mark" 1
file_has "~/.bashrc sources the file" "$h/.bashrc" '^\[ -r ~/.bashrc.d/claude-nix-harness.sh \] && \. ~/.bashrc.d/claude-nix-harness.sh$'
file_has "bash hook" "$h/.bashrc.d/claude-nix-harness.sh" 'direnv hook bash'
file_has "code root" "$h/.bashrc.d/claude-nix-harness.sh" 'export HARNESS_CODE_ROOT="\$HOME/code/git"'
absent "no ~/.zshrc made up" "$h/.zshrc"
file_has "direnv.toml" "$h/.config/direnv/direnv.toml" '^strict_env = true$'
count_is "tmux block" "$h/.config/tmux/tmux.conf" "$mark" 1
absent "no ~/.tmux.conf made up" "$h/.tmux.conf"
file_has "environment.d" "$h/.config/environment.d/50-claude-nix-harness.conf" '^PATH='
in_json "strict allowlist" "$h/.claude/settings.json" '.sandbox.network.strictAllowlist == true'
in_json "scrub key removed, the user's key kept" "$h/.claude/settings.json" '.env == null and .theme == "dark"'
in_json "account sync off by default" "$h/.claude/settings.json" '.syncClaudeAiSkills == false and .syncClaudeAiPlugins == false'
in_json "account sync keys recorded" "$receipt" '[.files[] | select(.path | endswith("/.claude/settings.json")) | .keys[]] | any(. == ["syncClaudeAiSkills"]) and any(. == ["syncClaudeAiPlugins"])'
says "doctor sees account sync off" 'ok    account-synced skills and plugins off in '
in_json "receipt steps" "$receipt" '.root.steps | index("apparmor") and index("nix.conf") and index("nix-installer") and (index("sysctl") | not)'
in_json "bashrc recorded as a block" "$receipt" '[.files[] | select(.path | endswith("/.bashrc")) | .kind] == ["block"]'
in_json "profile recorded" "$receipt" '(.profile | sort) == ["ccmux","devenv","direnv","harness"]'
uncalled "no dnf off fedora"       'dnf'
says "doctor sees the profile"     "ok    AppArmor confines unprivileged user namespaces; $profile lifts it for bwrap"
says "doctor sees the rc wiring"   'ok    ~/.bashrc sources ~/.bashrc.d'
says "doctor names the tmux file"  'ok    tmux harness block in ~/.config/tmux/tmux.conf'

# 2. Again: nothing written twice, no second profile.
harness "$h" bootstrap --yes
exits "re-run" 0
uncalled "no second profile"       'install .*apparmor-bwrap|systemctl reload apparmor'
uncalled "nix.conf not rewritten"  'install .*nix.conf'
refutes "rc file not rewritten"    "==> write $h/.bashrc"
count_is "one block in ~/.bashrc" "$h/.bashrc" "$mark" 1
count_is "one block in tmux.conf" "$h/.config/tmux/tmux.conf" "$mark" 1
count_is "one block in nix.conf" "$tmp/etc/nix.conf" "$mark" 1

# 3. Declined (no --yes, no terminal): reported, printed for later, not in
# the receipt, offered again next time; doctor keeps naming it.
touch "$tmp/restricted"; rm -f "$profile"
h2="$tmp/home2"; mkdir -p "$h2"
harness "$h2" bootstrap
exits "declined leaves a MISSING" 1
says "declined reported"           'warn  declined: every Claude command is refused'
says "printed for later"           "Declined, run later.*printf .*'abi <abi/4.0>,' .*'  userns,' .*\| sudo tee $profile && sudo systemctl reload apparmor"
says "the report names it"         "MISSING AppArmor confines unprivileged user namespaces \(kernel.apparmor_restrict_unprivileged_userns = 1\) and $profile is missing"
uncalled "not applied"             'sysctl -w|install .*apparmor-bwrap|reload apparmor'
absent "no profile" "$profile"
in_json "not in the receipt" "$h2/.local/state/claude-nix-harness/receipt.json" '.root.steps | (index("sysctl") or index("apparmor")) | not'
harness "$h2" bootstrap
says "offered again"               'user namespaces: AppArmor confines them \(kernel.apparmor_restrict_unprivileged_userns = 1\)'
harness "$h2" doctor
exits "doctor on the confined host" 1
says "doctor names the profile"    "MISSING AppArmor confines unprivileged user namespaces .*$profile is missing.*harness bootstrap writes the profile"
says "doctor host line"            'host: Ubuntu 24.04 .*nix from the nix-installer'
rm -f "$tmp/restricted"

# 4. Fedora's stock ~/.bashrc (sources ~/.bashrc.d): no block added to it.
h3="$tmp/home3"; mkdir -p "$h3"
printf '# .bashrc\nif [ -d ~/.bashrc.d ]; then for rc in ~/.bashrc.d/*; do . "$rc"; done; fi\n' >"$h3/.bashrc"
harness "$h3" bootstrap --yes
count_is "no block in a sourcing ~/.bashrc" "$h3/.bashrc" "$mark" 0
file_has "bashrc.d file still written" "$h3/.bashrc.d/claude-nix-harness.sh" 'direnv hook bash'
says "doctor accepts it"           'ok    ~/.bashrc sources ~/.bashrc.d'

# 5. zsh only: the block goes to ~/.zshrc, ~/.bashrc is not created.
h4="$tmp/home4"; mkdir -p "$h4"; echo '# zsh' >"$h4/.zshrc"
harness "$h4" bootstrap --yes
absent "no ~/.bashrc for a zsh user" "$h4/.bashrc"
file_has "zsh hook" "$h4/.zshrc" 'direnv hook zsh'
file_has "zsh code root" "$h4/.zshrc" 'export HARNESS_CODE_ROOT='
count_is "zsh block" "$h4/.zshrc" "$mark" 1
in_json "zshrc recorded as a block" "$h4/.local/state/claude-nix-harness/receipt.json" '[.files[] | select(.path | endswith("/.zshrc")) | .kind] == ["block"]'
says "doctor sees the zsh hook"    'ok    direnv hook in ~/.zshrc'

# 6. A plain ~/.bashrc and a ~/.zshrc: each gets its block, once, the rest
# kept. This host had Nix already (no installer step in its receipt).
h5="$tmp/home5"; mkdir -p "$h5"; echo 'export EDITOR=vi' >"$h5/.bashrc"; echo '# zsh' >"$h5/.zshrc"
ROOT_STEPS="" harness "$h5" bootstrap --yes; ROOT_STEPS="" harness "$h5" bootstrap --yes
count_is "one block in a plain ~/.bashrc" "$h5/.bashrc" "$mark" 1
file_has "the rest of ~/.bashrc kept" "$h5/.bashrc" '^export EDITOR=vi$'
count_is "one block in ~/.zshrc" "$h5/.zshrc" "$mark" 1

# 7. An existing ~/.tmux.conf: the block goes there, since tmux stops at it.
h6="$tmp/home6"; mkdir -p "$h6"; echo 'set -g mouse on' >"$h6/.tmux.conf"
harness "$h6" bootstrap --yes
count_is "block in ~/.tmux.conf" "$h6/.tmux.conf" "$mark" 1
file_has "the rest of ~/.tmux.conf kept" "$h6/.tmux.conf" '^set -g mouse on$'
absent "no second tmux file" "$h6/.config/tmux/tmux.conf"
says "doctor names ~/.tmux.conf"   'ok    tmux harness block in ~/.tmux.conf'

# 8. A foreign direnv.toml: warned about, left alone.
h7="$tmp/home7"; mkdir -p "$h7/.config/direnv"; echo '[global]' >"$h7/.config/direnv/direnv.toml"
harness "$h7" bootstrap --yes
says "foreign direnv.toml"         'warn  .*direnv.toml exists and is not the harness one'
file_is "left alone" "$h7/.config/direnv/direnv.toml" '[global]'

# 9. A nix.conf that already enables flakes: no second line, the rest kept.
printf 'build-users-group = nixbld\nexperimental-features = nix-command flakes\n' >"$tmp/etc/nix.conf"
harness "$h7" bootstrap --yes
count_is "one flakes line" "$tmp/etc/nix.conf" 'experimental-features' 1
file_has "the rest of nix.conf kept" "$tmp/etc/nix.conf" '^build-users-group = nixbld$'
file_has "the cache added" "$tmp/etc/nix.conf" '^extra-substituters'

# 10. --dry-run on a fresh home: the steps printed, nothing written, no sudo.
touch "$tmp/restricted"; rm -f "$profile"; h8="$tmp/home8"; mkdir -p "$h8"
harness "$h8" bootstrap --dry-run
says "dry run shows the profile"   "would run: sudo install -m 0644 -o root -g root <new content> $profile"
says "dry run shows the reload"    'would run: sudo systemctl reload apparmor'
absent "dry run writes no profile" "$profile"
absent "dry run writes no rc file" "$h8/.bashrc"
absent "dry run writes no receipt" "$h8/.local/state/claude-nix-harness/receipt.json"
uncalled "dry run calls no sudo"   '^sudo'
rm -f "$tmp/restricted"

# 11. Fedora 44: doctor's host line names the dnf route (scripts/install.sh
# runs dnf; the harness never does).
printf 'ID=fedora\nVERSION_ID=44\nPRETTY_NAME="Fedora Linux 44"\n' >"$tmp/os-release"
h9="$tmp/home9"; mkdir -p "$h9"
harness "$h9" doctor
says "fedora host line"            "nix from Fedora's packages"
uncalled "no dnf from doctor"      'dnf'
ubuntu

# 12. reset on the first host (installer route, profile written): all undone.
printf '%s\n' "$mark" 'profile bwrap /usr/bin/bwrap flags=(unconfined) {' '  userns,' '}' >"$profile"
harness "$h" reset --yes
exits "reset" 0
says "plan names the uninstaller"  "root:  Nix, by $tmp/nix/nix-installer uninstall"
says "plan names the profile"      "root:  $profile \(bwrap may no longer create user namespaces\), AppArmor reloaded"
called "uninstall"                 "^sudo $tmp/nix/nix-installer uninstall --no-confirm$"
called "profile removed"           "^sudo rm -f $profile$"
called "apparmor reloaded on reset" '^sudo systemctl reload apparmor$'
uncalled "no sysctl on reset"      'sysctl -w'
uncalled "no rm -rf /nix without dnf" 'rm -rf /nix'
uncalled "no daemon stop: the uninstaller does it" 'systemctl disable'
absent "~/.bashrc (only the block) removed" "$h/.bashrc"
absent "bashrc.d file removed" "$h/.bashrc.d/claude-nix-harness.sh"
absent "direnv.toml removed" "$h/.config/direnv/direnv.toml"
absent "tmux.conf removed" "$h/.config/tmux/tmux.conf"
absent "environment.d removed" "$h/.config/environment.d/50-claude-nix-harness.conf"
in_json "user settings keys stripped" "$h/.claude/settings.json" '.sandbox == null and .env == null and (has("syncClaudeAiSkills") or has("syncClaudeAiPlugins") | not) and .theme == "dark"'
absent "receipt removed" "$receipt"
rm -f "$tmp/restricted"

# 13. reset on the plain-rc host: the blocks stripped, the rest kept.
harness "$h5" reset --yes
file_is "~/.bashrc without the block" "$h5/.bashrc" 'export EDITOR=vi'
count_is "~/.zshrc without the block" "$h5/.zshrc" "$mark" 0
file_has "the rest of ~/.zshrc kept" "$h5/.zshrc" '^# zsh$'
called "profile removed without Nix going" '^nix profile remove direnv$'

# 14. upgrade from another ref (the stub's entries carry no originalUrl): each
# package is built before its profile entry is removed. The resets above
# emptied the stub's profile. The profile then holds a harness that is not
# the running one (a stub under the fake home): the user steps go to it.
printf '%s\n' direnv devenv ccmux harness >"$tmp/profile"
mkdir -p "$h7/.nix-profile/bin"
printf '#!/bin/sh\necho "new-harness $*" >>"$CALLS"\n' >"$h7/.nix-profile/bin/harness"; chmod +x "$h7/.nix-profile/bin/harness"
harness "$h7" upgrade --yes
exits "upgrade" 0
called "user steps handed to the upgraded harness" '^new-harness bootstrap --no-root --no-profile --yes$'
refutes "old user steps not run"   'harness upgrade: [0-9]+ missing'
b=$(grep -n -m1 -x -F 'nix build --no-link github:bilibo/claude-nix-harness#direnv' "$log" | cut -d: -f1)
r=$(grep -n -m1 -x -F 'nix profile remove direnv' "$log" | cut -d: -f1)
if [ -n "$b" ] && [ -n "$r" ] && [ "$b" -lt "$r" ]; then ok; else bad "upgrade builds direnv before removing it (build at ${b:-none}, remove at ${r:-none}: $(tr '\n' ';' <"$log"))"; fi

# 15. reset on a host that never ran bootstrap: no receipt, nothing touched.
h10="$tmp/home10"; mkdir -p "$h10/.local/share/direnv/allow"; touch "$h10/.local/share/direnv/allow/x"
harness "$h10" reset --yes
exits "reset without a receipt" 0
says "nothing recorded"            'no receipt at .*: nothing recorded, nothing to reset'
uncalled "no sudo"                 '^sudo'
uncalled "no profile remove"       'nix profile remove'
file_is "direnv allow database kept" "$h10/.local/share/direnv/allow/x" ''

# 16. nix.conf is a symlink into the store (a NixOS system file) on a host
# that is not detected as NixOS: root_write refuses, nothing is installed.
store=$(readlink -f "$harness")   # any real store path; its content does not matter
rm -f "$tmp/etc/nix.conf"; ln -s "$store" "$tmp/etc/nix.conf"
h11="$tmp/home11"; mkdir -p "$h11"
harness "$h11" bootstrap --yes
exits "store symlink refused" 1
says "names the store and the option" "nix.conf is a symlink into the Nix store \($store\): the system configuration owns it; set nix.settings.substituters"
uncalled "nothing installed over it" 'install .*nix.conf'
if [ -L "$tmp/etc/nix.conf" ]; then ok; else bad "the symlink was replaced"; fi

# 17. NixOS, home-manager owns ~/.bashrc, direnv.toml and tmux.conf: no sudo
# at all, the configuration.nix lines printed, those three files untouched
# and named in the host line, the rest written as on any host.
printf 'ID=nixos\nVERSION_ID="26.11"\nPRETTY_NAME="NixOS 26.11 (Xantusia)"\n' >"$tmp/os-release"
touch "$tmp/restricted"; rm -f "$profile"; : >"$tmp/profile"
h12="$tmp/home12"; mkdir -p "$h12/.config/direnv" "$h12/.config/tmux"
ln -s "$store" "$h12/.bashrc"; ln -s "$store" "$h12/.config/direnv/direnv.toml"; ln -s "$store" "$h12/.config/tmux/tmux.conf"
harness "$h12" bootstrap --yes
uncalled "no sudo on nixos"        '^sudo'
says "nix.settings printed"        'NixOS: .*nix.conf is the system configuration.s and lacks flakes the devenv cache.*nix\.settings = \{.*experimental-features = \[ "nix-command" "flakes" \];'
says "sysctl as a NixOS option"    'boot\.kernel\.sysctl\."kernel\.apparmor_restrict_unprivileged_userns" = 0;'
says "bashrc skipped"              '~/\.bashrc is home-manager.s \(a store symlink\): left alone; it is set by programs\.direnv\.enableBashIntegration'
says "direnv.toml skipped"         '~/\.config/direnv/direnv\.toml is home-manager.s .*programs\.direnv\.config\.global'
says "tmux.conf skipped"           '~/\.config/tmux/tmux\.conf is home-manager.s .*programs\.tmux\.extraConfig'
for f in .bashrc .config/direnv/direnv.toml .config/tmux/tmux.conf; do
  if [ -L "$h12/$f" ] && [ "$(readlink "$h12/$f")" = "$store" ]; then ok; else bad "$f was changed"; fi
done
file_has "bashrc.d still written" "$h12/.bashrc.d/claude-nix-harness.sh" 'direnv hook bash'
in_json "user settings still written" "$h12/.claude/settings.json" '.sandbox.network.strictAllowlist == true'
in_json "no root step in the receipt" "$h12/.local/state/claude-nix-harness/receipt.json" '.root.steps == ["nix-installer"]'
for p in direnv devenv ccmux harness; do called "profile add $p on nixos" "^nix profile add github:bilibo/claude-nix-harness#$p$"; done
says "host line"                   'host: NixOS 26.11 \(Xantusia\) .*nix from the system configuration, 3 home-manager owned files skipped'
says "doctor: hm bashrc ok"        'ok    ~/\.bashrc \(home-manager'
says "doctor: hm direnv.toml ok"   'ok    direnv\.toml \(home-manager\)'
says "doctor: hm tmux ok"          'ok    tmux config ~/\.config/tmux/tmux\.conf \(home-manager\)'
says "doctor: nixos fix for flakes" 'MISSING flakes not enabled in .*nix.settings in configuration.nix'
says "doctor: nixos fix for userns" 'MISSING AppArmor confines unprivileged user namespaces .*boot.kernel.sysctl in configuration.nix'
refutes "no bootstrap sysctl offer" 'apply with sudo now|would run: sudo'
harness "$h12" doctor
says "doctor host line"            'host: NixOS 26.11 .*3 home-manager owned files skipped'
rm -f "$tmp/restricted" "$tmp/etc/nix.conf"
ubuntu

# 18. WSL: the host line says so; nothing else changes here.
touch "$tmp/wsl"
WSL_MARKER="$tmp/wsl" harness "$h11" doctor
says "wsl host line"               'host: WSL2 \(Ubuntu 24.04\) '

# 19. An older Debian kernel (kernel.unprivileged_userns_clone = 0): the
# sysctl path as before, no profile; reset puts the restriction back.
rm -f "$tmp/restricted" "$profile"; touch "$tmp/clone-restricted"
h13="$tmp/home13"; mkdir -p "$h13"
harness "$h13" bootstrap --yes
says "clone sysctl offered"        'user namespaces: kernel.unprivileged_userns_clone is 0'
called "clone sysctl applied"      '^sudo sysctl -w kernel.unprivileged_userns_clone=1$'
file_is "clone drop-in" "$tmp/etc/99-userns.conf" 'kernel.unprivileged_userns_clone = 1'
absent "no profile for the clone sysctl" "$profile"
uncalled "no apparmor reload"      'reload apparmor'
in_json "sysctl in the receipt" "$h13/.local/state/claude-nix-harness/receipt.json" '.root.steps | index("sysctl") and (index("apparmor") | not)'
says "doctor sees the sysctl gone" 'ok    no sysctl confines'
harness "$h13" reset --yes
says "plan names the sysctl"       "root:  $tmp/etc/99-userns.conf, and the kernel's user-namespace restriction back on"
called "clone restriction back"    '^sudo sysctl -w kernel.unprivileged_userns_clone=0$'
called "clone drop-in removed"     "^sudo rm -f $tmp/etc/99-userns.conf$"
rm -f "$tmp/clone-restricted" "$tmp/etc/99-userns.conf"

# 20. --account-sync: the two keys are not written, a `false` already there
# (the old --no-account-sync, or the default since 2026-10-24) is removed,
# the user's own keys kept, doctor warns; --no-account-sync is still
# accepted and puts the default back.
h14="$tmp/home14"; mkdir -p "$h14/.claude"; cs14="$h14/.claude/settings.json"
harness "$h14" bootstrap --yes --account-sync
refutes "--account-sync accepted"  'unknown argument'
in_json "--account-sync writes neither key" "$cs14" '(has("syncClaudeAiSkills") or has("syncClaudeAiPlugins") | not) and .sandbox.network.strictAllowlist == true'
in_json "--account-sync records neither key" "$h14/.local/state/claude-nix-harness/receipt.json" '[.files[] | select(.path | endswith("/.claude/settings.json")) | .keys[]] == [["sandbox","network","strictAllowlist"]]'
says "doctor warns with sync on"   'warn  account-synced skills and plugins load .*unless run with --account-sync'
echo '{"theme":"dark","syncClaudeAiSkills":false,"syncClaudeAiPlugins":false}' >"$cs14"
harness "$h14" bootstrap --yes --account-sync
says "the falses removed"          "remove syncClaudeAiSkills and syncClaudeAiPlugins = false from $cs14 \(--account-sync\)"
in_json "sync on again, the user's key kept" "$cs14" '(has("syncClaudeAiSkills") or has("syncClaudeAiPlugins") | not) and .theme == "dark"'
harness "$h14" bootstrap --yes --account-sync
refutes "nothing to remove the second time" 'remove syncClaudeAiSkills'
harness "$h14" bootstrap --yes --no-account-sync
refutes "--no-account-sync accepted" 'unknown argument'
in_json "--no-account-sync is the default" "$cs14" '.syncClaudeAiSkills == false and .syncClaudeAiPlugins == false and .theme == "dark"'
harness "$h14" bootstrap --yes --account-sync --no-account-sync
in_json "the last of the two flags wins" "$cs14" '.syncClaudeAiSkills == false and .syncClaudeAiPlugins == false'
harness "$h14" bootstrap --dry-run --account-sync
says "dry run names the removal"   'remove syncClaudeAiSkills and syncClaudeAiPlugins = false'
in_json "dry run leaves the falses" "$cs14" '.syncClaudeAiSkills == false and .syncClaudeAiPlugins == false'

echo "harness-bootstrap-test: $pass passed, $fail failed"
[ "$fail" = 0 ]
