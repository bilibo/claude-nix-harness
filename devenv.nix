# This repo is its own harnessed project and the template install.sh users
# clone: Claude Code and tmux come from this shell.
{ ... }:
{
  name = "claude-nix-harness";
  harness.claudeCode.enable = true;
}
