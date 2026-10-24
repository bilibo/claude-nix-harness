# The default Windows route is the plain host, examples/nixos-wsl-plain.nix; this file is the stricter opt-in.
#
# The managed NixOS-WSL host shape, the managed Windows row of the README's
# host table. scripts/install-wsl.ps1 installs NixOS-WSL, puts your nixos-config
# flake at /etc/nixos and switches to its nixosConfigurations.<name>; that
# flake imports NixOS-WSL, home-manager, this repository's two modules and
# a file like this one. Build-only material, like nixos-host.nix; the
# human (or the installer they run) switches generations.
#
#   inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";  # the branch this flake is built against
#   inputs.nixos-wsl = { url = "github:nix-community/NixOS-WSL"; inputs.nixpkgs.follows = "nixpkgs"; };
#   inputs.home-manager = { url = "github:nix-community/home-manager"; inputs.nixpkgs.follows = "nixpkgs"; };
#   inputs.harness = { url = "github:bilibo/claude-nix-harness"; inputs.nixpkgs.follows = "nixpkgs"; };
#   ...
#   nixosConfigurations.nixos-wsl = nixpkgs.lib.nixosSystem {
#     system = "x86_64-linux";
#     specialArgs = { inherit inputs; };
#     modules = [
#       inputs.nixos-wsl.nixosModules.default
#       inputs.home-manager.nixosModules.home-manager
#       inputs.harness.nixosModules.harness
#       ./nixos-wsl-host.nix
#     ];
#   };
{ inputs, pkgs, ... }:
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
      # metadata: chmod and chown work on /mnt/c files. Sessions never see
      # /mnt/c anyway: the harness's wsl platform denies it in the sandbox.
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

  ######## harness ###########################################################
  harness.enable = true; # platform auto-detects "wsl" from wsl.enable
  security = {
    # The Claude Code sandbox is bubblewrap; the module asserts this.
    allowUserNamespaces = true;
    sudo.wheelNeedsPassword = false; # the image's user has no password
  };

  home-manager = {
    useGlobalPkgs = true;
    useUserPackages = true;
    users.${user} = {
      imports = [ inputs.harness.homeModules.harness ];
      harness.enable = true; # direnv >= 2.38, devenv, tmux, programs.claude-code, ccmux
      # home-manager wires the direnv hook and the HARNESS_* session variables
      # only into shells it manages; the harness module leaves that to the host.
      programs.bash.enable = true;
      home.stateVersion = "26.05";
    };
  };
  # claude-code is unfree in nixpkgs.
  nixpkgs.config.allowUnfree = true;
  # The home module takes devenv from your nixpkgs, and a harness shell needs
  # devenv >= 2.4: the 26.05 release branch's 2.1.2 dies with "structuredAttrs:
  # command not found" on today's dev shells. On nixos-unstable (above) that
  # holds. On a stable branch that ships an older devenv, take this flake's
  # pinned package instead and drop `inputs.nixpkgs.follows` on the harness
  # input, so it keeps the nixpkgs it was built with:
  #   nixpkgs.overlays = [
  #     (_final: prev: {
  #       inherit (inputs.harness.packages.${prev.stdenv.hostPlatform.system}) devenv;
  #     })
  #   ];

  ######## Nix ###############################################################
  nix.settings = {
    experimental-features = [
      "nix-command"
      "flakes"
    ];
    # The devenv cache the harness repos expect (scripts/install.sh prints the
    # same block for a hand-written configuration.nix).
    substituters = [ "https://devenv.cachix.org" ];
    trusted-public-keys = [ "devenv.cachix.org-1:w1cLUi8dv3hnoSPGAuibQv+f9TZLr6cv/Hm9XgU50cw=" ];
  };
  # Unpatched binaries (VS Code server, prebuilt CLIs) run through nix-ld.
  programs.nix-ld.enable = true;

  ######## users / packages ##################################################
  users.users.${user}.extraGroups = [ "wheel" ];

  environment.systemPackages = with pkgs; [
    git # wsl/update.sh pulls /etc/nixos with it
    bubblewrap # the Claude Code sandbox
    socat # its network proxy
    curl
    jq
  ];

  time.timeZone = "UTC";
  system.stateVersion = "26.05";
}
