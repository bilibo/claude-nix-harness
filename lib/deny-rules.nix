# Deny rules are prefix/glob matches that hold in every permission mode and
# against user-tier mods, but `git -C . push`, `bash -c '...'` and scripts
# that open files themselves get past them; the hook and the sandbox exist
# for that.
#
# Two sets because deny rules cannot be scoped by directory: with
# enforcementRoots set, managed settings carry only `universal`, and
# `project` comes from the repo's .claude/settings.json and from the hook,
# which can see `cwd`.
#
# Path rules use `**/` or `~/`: in user-scope settings a leading `/` anchors
# at ~/.claude, not at the project root.
{ lib }:
{
  allowLocalCommits ? false,
  # Globs cannot express "everything but", so this swaps the blanket
  # ~/.claude rule for an enumerated list; the hook keeps the rest of
  # ~/.claude/projects (transcripts) closed.
  allowMemoryEdits ? false,
  # "all" or "universal"
  scope ? "all",
}:
let
  # Bare form and argument form both, since `git commit *` does not match a
  # plain `git commit` with no arguments.
  bash =
    cmds:
    lib.concatMap (c: [
      "Bash(${c})"
      "Bash(${c} *)"
    ]) cmds;

  # ---------------------------------------------------------------- universal
  credentials =
    bash [
      "az login"
      "az logout"
      "az account set"
      "az account clear"
      "az account get-access-token"
      "az ad sp credential"
      "az keyvault secret"
      "az keyvault key"
      "az keyvault certificate"
    ]
    ++ [
      "Read(**/.env)"
      "Read(**/.env.*)"
      "Read(**/*.tfvars)"
      "Read(**/*.tfvars.json)"
      "Read(**/*.tfstate)"
      "Read(**/*.tfstate.backup)"
      "Read(**/.terraform/**)"
      "Read(**/.git/devenv-base/**)"
      "Read(~/.azure/**)"
      "Read(~/.terraform.d/**)"
      "Read(~/.ssh/**)"
      "Read(~/.gnupg/**)"
      "Read(~/.aws/**)"
      "Read(~/.netrc)"
      "Read(~/.npmrc)"
      "Read(~/.pypirc)"
      "Read(~/.claude/.credentials.json)"
      "Read(~/.claude.json)"
    ];

  system =
    bash [
      "sudo"
      "doas"
      "su"
      "pkexec"
      "run0"
      "nix profile"
      "nix-env"
      "nixos-rebuild"
      "nix-channel"
      "nix-collect-garbage"
      "nix upgrade-nix"
      "home-manager switch"
      "systemctl"
      "wsl.exe"
      "cmd.exe"
    ]
    ++ [
      "Bash(*.exe)"
      "Bash(*.exe *)"
      "Bash(powershell*)"
      "Bash(pwsh*)"
    ];

  plugins = bash [ "claude plugin" ] ++ [
    "Bash(claude * --plugin-dir *)"
    "Bash(claude * --plugin-url *)"
  ];

  # A `Read` deny also blocks Edit/Write (2.1.228+); the Edit rules stay
  # explicit anyway.
  claudeHome =
    if allowMemoryEdits then
      [
        "Edit(~/.claude/*.json)"
        "Edit(~/.claude/*.md)"
        "Edit(~/.claude/.credentials.json)"
        "Edit(~/.claude/settings.json)"
        "Edit(~/.claude/settings.local.json)"
        "Edit(~/.claude/CLAUDE.md)"
        "Edit(~/.claude/keybindings.json)"
        "Edit(~/.claude/hooks/**)"
        "Edit(~/.claude/skills/**)"
        "Edit(~/.claude/plugins/**)"
        "Edit(~/.claude/commands/**)"
        "Edit(~/.claude/agents/**)"
        "Edit(~/.claude/rules/**)"
        "Edit(~/.claude/output-styles/**)"
        "Edit(~/.claude/workflows/**)"
        "Edit(~/.claude/routines/**)"
        "Edit(~/.claude/local/**)"
        "Edit(~/.claude/projects/*/*.jsonl)"
      ]
    else
      [ "Edit(~/.claude/**)" ];

  # Files that run code at the user's next shell, git or tmux start, outside
  # the sandbox. `~/.config/**` matches the sandbox's denyWrite of ~/.config.
  userConfig = claudeHome ++ [
    "Edit(~/.bashrc)"
    "Edit(~/.bash_profile)"
    "Edit(~/.profile)"
    "Edit(~/.zshrc)"
    "Edit(~/.zprofile)"
    "Edit(~/.zshenv)"
    "Edit(~/.gitconfig)"
    "Edit(~/.tmux.conf)"
    "Edit(~/.ssh/**)"
    "Edit(~/.config/**)"
  ];

  # ------------------------------------------------------------------ project
  gitHistory = bash (
    lib.optionals (!allowLocalCommits) [ "git commit" ]
    ++ [
      "git push"
      "git reset"
      "git rebase"
      "git merge"
      "git cherry-pick"
      "git revert"
      "git restore"
      "git checkout --"
      "git clean"
      "git stash drop"
      "git stash clear"
      "git stash pop"
      "git branch -D"
      "git branch -d"
      "git tag -d"
      "git reflog expire"
      "git filter-branch"
      "git filter-repo"
      "git update-ref"
      "git symbolic-ref"
      "git gc"
      "git prune"
      "git am"
    ]
  );

  cloudWrite =
    bash [
      "terraform apply"
      "terraform destroy"
      "terraform import"
      "terraform state"
      "terraform taint"
      "terraform untaint"
      "terraform force-unlock"
      "tofu apply"
      "tofu destroy"
      "tofu import"
      "tofu state"
      "terragrunt apply"
      "terragrunt destroy"
      "az deployment"
      "az rest"
      "az group create"
      "az group delete"
      "func azure functionapp publish"
      "pulumi up"
      "pulumi destroy"
      "bicep publish"
    ]
    ++ [
      "Bash(az * create *)"
      "Bash(az * delete *)"
      "Bash(az * update *)"
      "Bash(az * set *)"
      "Bash(az * start *)"
      "Bash(az * stop *)"
      "Bash(az * restart *)"
      "Bash(az * purge *)"
      "Bash(az * assign *)"
      "Bash(az * remove *)"
      "Bash(az * regenerate *)"
      "Bash(az * import *)"
    ];

  # The agent proposes changes to these as a diff in its reply, never writes them.
  projectConfig = [
    "Edit(**/devenv.nix)"
    "Edit(**/devenv.yaml)"
    "Edit(**/devenv.lock)"
    "Edit(**/devenv.local.*)"
    "Edit(**/.envrc)"
    "Edit(**/.env)"
    "Edit(**/.env.*)"
    "Edit(**/.claude/settings.json)"
    "Edit(**/.claude/settings.local.json)"
    "Edit(**/.claude/hooks/**)"
    # Drop this one only if agents must author skills; enable
    # `allowManagedHooksOnly` or `strictPluginOnlyCustomization` first.
    "Edit(**/.claude/skills/**)"
    "Edit(**/.claude-plugin/**)"
  ];

  universal = credentials ++ system ++ plugins ++ userConfig;
  project = gitHistory ++ cloudWrite ++ projectConfig;
in
if scope == "universal" then universal else universal ++ project
