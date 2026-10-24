<#
.SYNOPSIS
  The Windows route: provision NixOS-WSL from your host flake.

.DESCRIPTION
  Run from a checkout of claude-nix-harness on Windows 11 (Windows PowerShell 5.1
  or newer; WSL 2.4 or newer from the Store). Idempotent: every step checks before
  it acts, so rerunning is the update path. It sets up the system only; the harness
  itself comes afterwards, inside the distro, as the user (Done prints the commands).

    1. distro      only when the distro is not registered: resolve the latest
                   NixOS-WSL release (or -Tag), download nixos.wsl into Downloads,
                   verify it against the published sha256, wsl --install --from-file.
    2. system      first time: scripts/wsl/bootstrap.sh puts the host configuration
                   (-HostRepo: a git URL, or a Windows folder copied in) at /etc/nixos
                   as a git checkout owned by the default user, builds
                   nixosConfigurations.<Output> and switches to it.
                   afterwards: scripts/wsl/update.sh pulls --ff-only and switches.
                   The box never commits. -NoSwitch builds and prints the activation
                   command instead, for the hosts where a human switches generations.
    3. .wslconfig  if the host configuration carries windows/wslconfig, it becomes
                   %USERPROFILE%\.wslconfig (a differing existing file is backed up).
    4. restart     wsl --shutdown, so .wslconfig and wsl.conf apply.
    5. verify      scripts/wsl/verify.sh: user, DNS, HTTPS, Nix, the sandbox
                   prerequisites; the managed tree only on a managed host.

  The host configuration is yours: a flake whose nixosConfigurations.<Output>
  imports NixOS-WSL and carries the sandbox prerequisites (user namespaces,
  bubblewrap and socat, flakes and the devenv cache); examples/nixos-wsl-plain.nix
  is the shape. Then, inside the distro, `harness bootstrap` installs the harness
  as the user and `harness init` sets up each work repo. The stricter option is
  the managed layer: the flake also imports this repository's NixOS and home
  modules (examples/nixos-wsl-host.nix; README, "Usage"). The image only
  bootstraps the first install; afterwards everything moves through the host
  flake's inputs.

.PARAMETER HostRepo
  Git URL of the host configuration flake, or a Windows folder holding it. A folder
  is copied in on the first install only; without .git it gets a local repository
  with one baseline commit, and you add the remote (bootstrap prints how).
.PARAMETER Output
  The nixosConfigurations attribute to switch to. Default: nixos-wsl.
.PARAMETER Tag
  NixOS-WSL release tag to install from. Default: latest.
.PARAMETER NoSwitch
  Build the system but do not activate it; the commands to do so are printed.
.PARAMETER DistroName
  WSL distribution name. Default: NixOS.
.PARAMETER InstallDir
  Where the distribution's disk lives. Default: %USERPROFILE%\WSL\<DistroName>.
.PARAMETER SkipVerify
  Do not run scripts/wsl/verify.sh after the restart.

.EXAMPLE
  powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\install-wsl.ps1 -HostRepo https://github.com/you/nixos-config
.EXAMPLE
  powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\install-wsl.ps1 -HostRepo C:\src\nixos-config -Output work -NoSwitch
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)]
  [string] $HostRepo,
  [string] $Output = 'nixos-wsl',
  [string] $Tag = 'latest',
  [switch] $NoSwitch,
  [string] $DistroName = 'NixOS',
  [string] $InstallDir = '',
  [switch] $SkipVerify
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$env:WSL_UTF8 = '1'                      # wsl.exe prints UTF-8 instead of UTF-16
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

if ($InstallDir -eq '') { $InstallDir = Join-Path $env:USERPROFILE "WSL\$DistroName" }
$ReleaseApi   = 'https://api.github.com/repos/nix-community/NixOS-WSL/releases'
$ScriptsDir   = $PSScriptRoot                          # <checkout>\scripts
$WslConfigDst = Join-Path $env:USERPROFILE '.wslconfig'
$Stamp        = Get-Date -Format 'yyyyMMdd-HHmmss'
$LogDir       = Join-Path $env:TEMP 'claude-nix-harness'
$Log          = Join-Path $LogDir "install-wsl-$Stamp.log"

function Step([string] $msg) { Write-Host "`n== $msg" -ForegroundColor Cyan }
function Info([string] $msg) { Write-Host "   $msg" }

# Run a native executable without PowerShell 5.1 turning its stderr into a
# terminating error. Output goes to the host (and the transcript); the only
# value returned is the exit code.
function Invoke-Native {
  param([string] $Exe, [string[]] $Arguments)
  $prev = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  try {
    & $Exe @Arguments | Out-Host
    return $LASTEXITCODE
  } finally {
    $ErrorActionPreference = $prev
  }
}

function Invoke-Wsl([string[]] $Arguments) {
  $code = Invoke-Native 'wsl.exe' $Arguments
  if ($code -ne 0) { throw "wsl.exe $($Arguments -join ' ') exited with $code" }
}

# Capture a command's stdout from inside the distro (UTF-8 thanks to WSL_UTF8).
function Read-Wsl([string[]] $Arguments) {
  $prev = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  try { return @(& wsl.exe @Arguments 2>$null | ForEach-Object { "$_" }) }
  finally { $ErrorActionPreference = $prev }
}

# C:\path\to\dir -> /mnt/c/path/to/dir (WSL's default automount root).
function ConvertTo-WslPath([string] $WindowsPath) {
  $full = (Resolve-Path $WindowsPath).Path
  if ($full -notmatch '^([A-Za-z]):\\(.*)$') { throw "not a drive path: $full" }
  return '/mnt/' + $Matches[1].ToLower() + '/' + ($Matches[2] -replace '\\', '/')
}

New-Item -ItemType Directory -Force $LogDir | Out-Null
$transcribing = $false
try { Start-Transcript -Path $Log | Out-Null; $transcribing = $true } catch { }

try {
  # ---- 0. preflight --------------------------------------------------------
  Step 'Preflight'
  Info "harness:   $ScriptsDir"
  Info "host repo: $HostRepo"
  Info "output:    $Output$(if ($NoSwitch) { '  (build only)' })"
  Info "distro:    $DistroName at $InstallDir"
  Info "image:     NixOS-WSL release '$Tag' (fetched only if the distro is missing)"
  $build = [Environment]::OSVersion.Version.Build
  if ($build -lt 22621) {
    Write-Warning "Windows build $build is older than 22621 (22H2); mirrored networking in .wslconfig needs 22H2 or newer."
  }
  if ((Invoke-Native 'wsl.exe' @('--version')) -ne 0) {
    throw "WSL is not installed or too old. Run 'wsl --install --no-distribution', reboot, then rerun."
  }
  foreach ($f in @('wsl\bootstrap.sh', 'wsl\update.sh', 'wsl\verify.sh')) {
    if (-not (Test-Path (Join-Path $ScriptsDir $f))) { throw "missing scripts\$f; run from a checkout of claude-nix-harness" }
  }
  $hostIsFolder = Test-Path $HostRepo -PathType Container
  if ($hostIsFolder) {
    if (-not (Test-Path (Join-Path $HostRepo 'flake.nix'))) { throw "$HostRepo has no flake.nix" }
    $hostArg = ConvertTo-WslPath $HostRepo
  } else {
    $hostArg = $HostRepo
  }

  # ---- 1. distro (image fetched only when needed) --------------------------
  Step "Distro $DistroName"
  $registered = Read-Wsl @('--list', '--quiet') | ForEach-Object { $_.Trim() } | Where-Object { $_ }
  if ($registered -contains $DistroName) {
    Info 'already registered, skipping image download and install'
  } else {
    $api = if ($Tag -eq 'latest') { "$ReleaseApi/latest" } else { "$ReleaseApi/tags/$Tag" }
    Info "resolving NixOS-WSL release '$Tag'"
    $rel = Invoke-RestMethod -Uri $api -Headers @{ 'User-Agent' = 'claude-nix-harness install-wsl.ps1' }
    $imgAsset = @($rel.assets | Where-Object { $_.name -eq 'nixos.wsl' })
    $sumAsset = @($rel.assets | Where-Object { $_.name -eq 'nixos.wsl.sha256' })
    if ($imgAsset.Count -ne 1 -or $sumAsset.Count -ne 1) {
      throw "release $($rel.tag_name) does not carry nixos.wsl + nixos.wsl.sha256"
    }
    Info "release $($rel.tag_name), published $($rel.published_at)"

    $imageDir  = Join-Path $env:USERPROFILE "Downloads\nixos-wsl-$($rel.tag_name)"
    $imagePath = Join-Path $imageDir 'nixos.wsl'
    $sumPath   = Join-Path $imageDir 'nixos.wsl.sha256'
    New-Item -ItemType Directory -Force $imageDir | Out-Null

    if ((Invoke-Native 'curl.exe' @('-sSL', '--fail', '-o', $sumPath, $sumAsset[0].browser_download_url)) -ne 0) {
      throw 'checksum download failed'
    }
    $expected = ((Get-Content -Raw $sumPath) -split '\s+')[0].ToLower()
    if (Test-Path $imagePath) {
      Info "present: $imagePath"
    } else {
      Info ("downloading nixos.wsl ({0:N0} MB)" -f ($imgAsset[0].size / 1MB))
      if ((Invoke-Native 'curl.exe' @('-sSL', '--fail', '-o', $imagePath, $imgAsset[0].browser_download_url)) -ne 0) {
        throw 'image download failed'
      }
    }
    $actual = (Get-FileHash $imagePath -Algorithm SHA256).Hash.ToLower()
    if ($actual -ne $expected) {
      throw "sha256 mismatch for $imagePath`n  published $expected`n  got       $actual`nDelete the file and rerun."
    }
    Info 'sha256 matches the published checksum'

    New-Item -ItemType Directory -Force $InstallDir | Out-Null
    Invoke-Wsl @('--install', '--from-file', $imagePath, '--name', $DistroName, '--location', $InstallDir, '--no-launch')
    Info "installed $($rel.tag_name) into $InstallDir"
  }

  # ---- 2. system -----------------------------------------------------------
  $switchArg = if ($NoSwitch) { '--no-switch' } else { '--switch' }
  $isCheckout = (Invoke-Native 'wsl.exe' @('-d', $DistroName, '-u', 'root', '--', 'test', '-d', '/etc/nixos/.git')) -eq 0
  if ($isCheckout) {
    Step "System: pull + switch (/etc/nixos is a checkout) -> #$Output"
    Invoke-Wsl @('-d', $DistroName, '-u', 'root', '--cd', $ScriptsDir, '--', 'sh', './wsl/update.sh', $Output, $switchArg)
  } else {
    Step "System: first install, /etc/nixos <- $HostRepo -> #$Output"
    Invoke-Wsl @('-d', $DistroName, '-u', 'root', '--cd', $ScriptsDir, '--', 'sh', './wsl/bootstrap.sh', $hostArg, $Output, $switchArg)
  }

  # ---- 3. .wslconfig from the host configuration ---------------------------
  Step '.wslconfig'
  $src = Read-Wsl @('-d', $DistroName, '-u', 'root', '--', 'sh', '-c', 'test -f /etc/nixos/windows/wslconfig && cat /etc/nixos/windows/wslconfig')
  if ($src.Count -eq 0) {
    Info 'host configuration has no windows/wslconfig; leaving the current file alone'
  } else {
    $text = ($src -join "`n") + "`n"
    $same = (Test-Path $WslConfigDst) -and ((Get-Content -Raw $WslConfigDst) -eq $text)
    if ($same) {
      Info "unchanged: $WslConfigDst"
    } else {
      if (Test-Path $WslConfigDst) {
        Copy-Item $WslConfigDst "$WslConfigDst.bak-$Stamp"
        Info "existing file backed up to $WslConfigDst.bak-$Stamp"
      }
      [IO.File]::WriteAllText($WslConfigDst, $text)
      Info "written: $WslConfigDst"
    }
  }

  # ---- 4. restart + 5. verify ----------------------------------------------
  if ($NoSwitch) {
    Step 'Not restarting: nothing was activated'
  } else {
    Step 'Restart WSL (apply .wslconfig and wsl.conf)'
    Invoke-Wsl @('--shutdown')
    Info 'VM stopped; the next launch picks up the new settings'
    if (-not $SkipVerify) {
      Step 'Verify'
      Invoke-Wsl @('-d', $DistroName, '--cd', $ScriptsDir, '--', 'sh', './wsl/verify.sh')
    }
  }

  Step 'Done'
  Info "system:  $Output$(if ($NoSwitch) { ' (built, not activated)' })"
  Info "log:     $Log"
  Info ''
  Info "Next, inside the distro (wsl -d $DistroName), as your user:"
  Info '  nix run github:bilibo/claude-nix-harness#harness -- bootstrap'
  Info '  harness init <customer>/<repo>      # once per work repo'
  Info 'The guard rails then apply inside those repos. Claude Code comes from its'
  Info 'VS Code extension on Windows: open a repo over Remote-WSL and it runs its'
  Info 'bundled binary inside the distro. For tmux sessions (ccmux) a work repo'
  Info 'gets a CLI claude from its own shell; harness init sets that up'
  Info '(harness.claudeCode.enable). For rules everywhere, the stricter option is'
  Info 'the managed layer: import the harness NixOS and home modules in the host'
  Info 'flake (examples/nixos-wsl-host.nix).'
}
catch {
  Write-Host "`nFAILED: $($_.Exception.Message)" -ForegroundColor Red
  Write-Host "log: $Log"
  if ($transcribing) { Stop-Transcript | Out-Null }
  exit 1
}
if ($transcribing) { Stop-Transcript | Out-Null }
exit 0
