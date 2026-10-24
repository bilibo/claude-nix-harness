#!/bin/sh
# What a NixOS-WSL host should look like after install-wsl.ps1, run as the
# default user. Prints; does not judge beyond the last two lines.
#   wsl -d <distro> --cd <checkout>/scripts -- sh ./wsl/verify.sh
#
# Two shapes. A plain host (the default since 2026-10-24) carries only the
# sandbox prerequisites and tmux; the harness comes afterwards from `harness
# bootstrap` as the user, so the managed-layer checks are skipped, tmux is
# judged, and the user tools and claude are reported, not judged (no claude
# on the host by design: the VS Code extension on Windows runs its own over
# Remote-WSL, and work repos get one from harness.claudeCode.enable). A
# managed host (the configuration imports this repository's NixOS and home
# modules, so /etc/claude-code/managed-settings.json exists) gets every check.
ok=0; bad=0
check() { # check <label> <command...>
  label="$1"; shift
  if "$@" >/dev/null 2>&1; then echo "ok   $label"; ok=$((ok + 1)); else echo "FAIL $label"; bad=$((bad + 1)); fi
}
note() { # note <label> <command...>: reported, never counted
  label="$1"; shift
  if "$@" >/dev/null 2>&1; then echo "info $label: yes"; else echo "info $label: no"; fi
}
MANAGED=0
[ -e /etc/claude-code/managed-settings.json ] && MANAGED=1

echo "== host"
printf '%s, ' "$(sed -n 's/^PRETTY_NAME="\(.*\)"/\1/p' /etc/os-release)"; uname -r
echo "user $(id -un) (uid $(id -u)), groups: $(id -Gn)"
echo "hostname $(hostname)"
grep -E '^(default|hostname|enabled|appendWindowsPath|generateResolvConf)=' /etc/wsl.conf 2>/dev/null | tr '\n' ' '; echo

echo "== network"
grep -v '^#' /etc/resolv.conf | head -n 2
check "DNS resolves github.com"            getent hosts github.com
check "HTTPS reaches cache.nixos.org"      curl -sSf -o /dev/null --max-time 20 https://cache.nixos.org/nix-cache-info

echo "== nix"
nix --version
check "flakes enabled"                     sh -c 'nix config show | grep -E "^experimental-features = .*flakes"'
check "devenv cache configured"            sh -c 'nix config show | grep -E "^substituters = .*devenv.cachix.org"'

echo "== host configuration and sandbox prerequisites"
check "/etc/nixos is a git checkout"       test -d /etc/nixos/.git
check "user namespaces on"                 sh -c '[ "$(sysctl -n user.max_user_namespaces 2>/dev/null || echo 0)" -gt 0 ]'
for t in bwrap socat git; do check "$t on PATH" command -v "$t"; done
check "Windows PATH not appended"          sh -c '! printf %s "$PATH" | tr ":" "\n" | grep -q "^/mnt/c/Program"'

echo "== harness"
if [ "$MANAGED" = 1 ]; then
  check "managed tree at /etc/claude-code"   test -r /etc/claude-code/managed-settings.json
  check "strict network allowlist"           sh -c 'grep -q "\"strictAllowlist\": *true" /etc/claude-code/managed-settings.json'
  check "managed hook executable"            test -x /etc/claude-code/hooks/env-guard.sh
  for t in direnv devenv ccmux claude; do check "$t on PATH" command -v "$t"; done
  # Session variables come from home-manager's shell files, so ask a login shell.
  check "HARNESS_EXPECT_MANAGED in a login shell" bash -lc '[ -n "${HARNESS_EXPECT_MANAGED:-}" ]'
  check "direnv hook in a login shell"         bash -lc 'grep -qs "direnv hook" ~/.bashrc ~/.profile ~/.bash_profile'
else
  echo "unmanaged host: managed-layer checks skipped"
  # The host configuration carries tmux: ccmux sessions are tmux sessions,
  # and the bootstrap writes its tmux config.
  check "tmux on PATH"                       command -v tmux
  # Right after install the bootstrap has not run yet: report, do not judge.
  # Its nix profile is on the NixOS PATH; its direnv hook is in ~/.bashrc.d.
  for t in direnv devenv ccmux; do note "$t on PATH" command -v "$t"; done
  note "claude on PATH" command -v claude
  echo "info claude: not in the host configuration, by design; the Claude Code extension in VS Code on Windows runs its bundled binary here over Remote-WSL, and work repos get a CLI claude for tmux/ccmux sessions from harness.claudeCode.enable in their devenv shell"
  note "direnv hook in the bash startup files" sh -c 'grep -qs "direnv hook" ~/.bashrc ~/.profile ~/.bash_profile ~/.bashrc.d/claude-nix-harness.sh'
  command -v harness >/dev/null 2>&1 \
    || echo "next, inside the distro: nix run github:bilibo/claude-nix-harness#harness -- bootstrap, then harness init <customer>/<repo> per work repo"
fi

echo "== systemd"
systemctl is-system-running 2>/dev/null || true
systemctl --failed --no-legend --no-pager 2>/dev/null | head -n 5

echo "== result: $ok ok, $bad failed"
[ "$bad" -eq 0 ]
