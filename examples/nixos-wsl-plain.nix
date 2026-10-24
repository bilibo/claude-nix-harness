# Managed layer on top (examples/nixos-wsl-host.nix): add the harness and
# home-manager inputs, import nixosModules.harness, and give the user the
# harness home module; harness.enable = true in both.
#
# The plain NixOS-WSL host shape, the default Windows route of the README's
# host table. scripts/install-wsl.ps1 installs NixOS-WSL, puts your
# nixos-config flake at /etc/nixos and switches to its
# nixosConfigurations.<name>; that flake imports NixOS-WSL and a file like
# this one, and no harness module. The harness comes afterwards, inside the
# distro, as the user:
#   nix run github:bilibo/claude-nix-harness#harness -- bootstrap
#   harness init <customer>/<repo>      # once per work repo
# Its guard rails then apply inside those repos; a session elsewhere keeps
# whatever your own settings allow. Build-only material, like
# nixos-host.nix; the human (or the installer they run) switches generations.
#
#   inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
#   inputs.nixos-wsl = { url = "github:nix-community/NixOS-WSL"; inputs.nixpkgs.follows = "nixpkgs"; };
#   ...
#   nixosConfigurations.nixos-wsl = nixpkgs.lib.nixosSystem {
#     system = "x86_64-linux";
#     modules = [
#       inputs.nixos-wsl.nixosModules.default
#       ./nixos-wsl-plain.nix
#     ];
#   };
{ pkgs, ... }:
let
  user = "me"; # the account `wsl -d <distro>` logs in as; uid 1000 either way
in
{
  ######## WSL ###############################################################
  wsl = {
    enable = true;
    defaultUser = user;
    # The Windows PATH is long, lives on the slow /mnt/c mount and would be
    # searched by every command; keep it off and re-add the few tools worth
    # calling at the END of PATH (environment.extraInit below). .exe files
    # still run from any path.
    interop.includePath = false;
    wslConf = {
      # metadata: chmod and chown work on /mnt/c files. Sessions in harness
      # repos never see /mnt/c: `harness init` sets the wsl platform there,
      # which denies it in the sandbox.
      automount.options = "metadata,uid=1000,gid=100,umask=022,fmask=011";
      # Leave resolv.conf and hosts to WSL; with dnsTunneling=true in
      # .wslconfig every lookup goes through the Windows resolver (VPN and
      # split DNS follow).
      network.generateResolvConf = true;
      network.generateHosts = true;
    };
  };
  environment.extraInit = ''
    export PATH="$PATH:/mnt/c/Windows/System32:/mnt/c/Windows"
  '';

  networking = {
    hostName = "nixos-wsl";
    # NixOS-WSL masks firewall.service, so the open system runs no Linux
    # firewall; the Hyper-V firewall on Windows is the one in effect
    # (inbound blocked, outbound open). Should you enable networking.nftables,
    # trust loopback0: mirrored networking hairpins every 127.0.0.1 packet
    # through it, and a firewall that does not trust it breaks
    # `curl localhost:3000`.
    firewall.trustedInterfaces = [ "loopback0" ];
  };

  ######## sandbox prerequisites #############################################
  # Not Claude Code configuration: no settings, rules or hooks. These are what
  # `harness bootstrap` needs from the system and, on NixOS, prints instead of
  # writing; `harness doctor` reports each one. Numbered as in the README.
  security = {
    # 1. User namespaces: the Claude Code Bash sandbox is bubblewrap.
    allowUserNamespaces = true;
    sudo.wheelNeedsPassword = false; # the image's user has no password
  };
  # 4. Claude Code is unfree in nixpkgs. The bootstrap's packages and a repo's
  # shell (allow_unfree in its devenv.yaml) do not read this; it lets this
  # configuration carry claude-code, or the managed home module, later.
  nixpkgs.config.allowUnfree = true;

  ######## Nix ###############################################################
  nix.settings = {
    # 3. Flakes and the devenv cache: exactly the block `harness bootstrap`
    # prints when /etc/nix/nix.conf lacks them.
    experimental-features = [
      "nix-command"
      "flakes"
    ];
    substituters = [ "https://devenv.cachix.org" ];
    trusted-public-keys = [ "devenv.cachix.org-1:w1cLUi8dv3hnoSPGAuibQv+f9TZLr6cv/Hm9XgU50cw=" ];
  };
  # Unpatched binaries (VS Code server, the Claude Code extension's bundled
  # binary, prebuilt CLIs) run through nix-ld.
  programs.nix-ld.enable = true;

  ######## users / packages ##################################################
  users.users.${user}.extraGroups = [ "wheel" ];

  environment.systemPackages = with pkgs; [
    git # wsl/update.sh pulls /etc/nixos with it
    # 2. The Claude Code sandbox and its network proxy.
    bubblewrap
    socat
    curl
    jq
    # ccmux sessions are tmux sessions: `harness bootstrap` writes its tmux
    # config (a marked block in ~/.tmux.conf, or ~/.config/tmux/tmux.conf
    # when there is no ~/.tmux.conf) and `harness doctor` wants it on PATH.
    tmux
    # direnv, devenv, ccmux and harness come from `harness bootstrap`.
    # claude is deliberately not installed on the host. The VS Code extension
    # on Windows runs its bundled binary inside WSL over Remote-WSL, which is
    # enough for interactive use; work repos bring their own claude (and
    # tmux) for tmux/ccmux sessions through harness.claudeCode.enable in their
    # devenv shell, which `harness init` writes.
  ];

  time.timeZone = "UTC";
  system.stateVersion = "26.05";
}
