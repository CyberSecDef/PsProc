#Requires -Version 7.0
<#
.SYNOPSIS
    Installs, mounts or removes the PowerShell proc: drive.
.DESCRIPTION
    -Install copies the module into your CurrentUser module path (so it can be imported
    by name, which SHiPS relies on). On Linux proc: maps to the real /proc, imports it, and mounts proc: in the global scope so
    the drive survives after this script returns. -AddToProfile also mounts it in every
    new session.
.EXAMPLE
    .\Install-ProcDrive.ps1 -Install -AddToProfile
.EXAMPLE
    .\Install-ProcDrive.ps1 -Uninstall -RemoveFiles
#>
[CmdletBinding(DefaultParameterSetName = 'Help')]
param(
    [Parameter(Mandatory, ParameterSetName = 'Install')]   [switch]$Install,
    [Parameter(ParameterSetName = 'Install')]              [switch]$AddToProfile,
    [Parameter(Mandatory, ParameterSetName = 'Uninstall')] [switch]$Uninstall,
    [Parameter(ParameterSetName = 'Uninstall')]            [switch]$RemoveFiles,
    [Parameter(Mandatory, ParameterSetName = 'Examples')]  [switch]$ShowExamples
)

$ErrorActionPreference = 'Stop'
$ModuleName   = 'ProcFileSystem'
# CurrentUser module path: Documents\PowerShell\Modules on Windows; on Linux MyDocuments is
# empty, and the user path is ~/.local/share/powershell/Modules (first PSModulePath entry).
$ModuleRoot   = if ($IsWindows) {
    Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'PowerShell\Modules'
} else {
    ($env:PSModulePath -split [IO.Path]::PathSeparator)[0]
}
$ProfilePath  = $PROFILE.CurrentUserAllHosts
$ProfileStart = '# >>> ProcFileSystem >>>'
$ProfileEnd   = '# <<< ProcFileSystem <<<'

function Install-ProcDrive {
    Write-Host 'Installing PowerShell proc: drive...' -ForegroundColor Cyan

    if (-not (Get-Module -ListAvailable -Name SHiPS)) {
        Write-Host 'Installing SHiPS module...' -ForegroundColor Yellow
        Install-Module -Name SHiPS -Scope CurrentUser -Force
    }

    $manifest = Join-Path $PSScriptRoot "$ModuleName.psd1"
    if (-not (Test-Path $manifest)) { throw "$ModuleName.psd1 not found next to this script ($PSScriptRoot)" }
    $version = (Import-PowerShellDataFile $manifest).ModuleVersion
    $target  = Join-Path $ModuleRoot "$ModuleName\$version"

    Write-Host "Copying module to $target" -ForegroundColor Yellow
    New-Item -ItemType Directory -Force -Path $target | Out-Null
    Copy-Item -Force (Join-Path $PSScriptRoot "$ModuleName.psd1"), (Join-Path $PSScriptRoot "$ModuleName.psm1") $target

    # Drop any copy already loaded from elsewhere (e.g. imported by path) before re-importing.
    Get-PSDrive -Name proc -Scope Global -ErrorAction SilentlyContinue | Remove-PSDrive -Force
    Get-Module $ModuleName | Remove-Module -Force
    Import-Module $ModuleName -RequiredVersion $version -Global -Force
    Mount-ProcDrive

    if ($AddToProfile) { Add-ProfileBlock }

    Write-Host "`nproc: drive is mounted." -ForegroundColor Green
    Write-Host '  cd proc:; ls; cat cpuinfo' -ForegroundColor White
    if (-not $AddToProfile) {
        Write-Host "`nIt lasts for this session only. Re-run with -AddToProfile to mount it in every session." -ForegroundColor Gray
    }
}

function Add-ProfileBlock {
    $block = @"
$ProfileStart
if (Get-Module -ListAvailable -Name $ModuleName) {
    Import-Module $ModuleName
    Mount-ProcDrive
}
$ProfileEnd
"@
    $existing = if (Test-Path $ProfilePath) { Get-Content $ProfilePath -Raw } else { '' }
    if ($existing -and $existing.Contains($ProfileStart)) {
        Write-Host "Profile already mounts proc: ($ProfilePath)" -ForegroundColor Green
        return
    }
    New-Item -ItemType Directory -Force -Path (Split-Path $ProfilePath) | Out-Null
    Add-Content -Path $ProfilePath -Value "`n$block"
    Write-Host "Added proc: mount to $ProfilePath" -ForegroundColor Green
}

function Remove-ProfileBlock {
    if (-not (Test-Path $ProfilePath)) { return }
    $text = Get-Content $ProfilePath -Raw
    $pattern = '(?s)\r?\n?' + [regex]::Escape($ProfileStart) + '.*?' + [regex]::Escape($ProfileEnd) + '\r?\n?'
    if ($text -match $pattern) {
        $rest = ($text -replace $pattern, "`n").Trim()
        if ($rest) { Set-Content -Path $ProfilePath -Value $rest } else { Remove-Item $ProfilePath }
        Write-Host "Removed proc: mount from $ProfilePath" -ForegroundColor Green
    }
}

function Uninstall-ProcDrive {
    if (Get-PSDrive -Name proc -Scope Global -ErrorAction SilentlyContinue) {
        Remove-PSDrive -Name proc -Scope Global -Force
        Write-Host 'proc: drive removed' -ForegroundColor Green
    } else {
        Write-Host 'proc: drive not mounted' -ForegroundColor Yellow
    }
    if (Get-Module $ModuleName) {
        Remove-Module $ModuleName -Force
        Write-Host "$ModuleName module unloaded" -ForegroundColor Green
    }
    if ($RemoveFiles) {
        $dir = Join-Path $ModuleRoot $ModuleName
        if (Test-Path $dir) {
            Remove-Item -Recurse -Force $dir
            Write-Host "Deleted $dir" -ForegroundColor Green
        }
        Remove-ProfileBlock
    }
}

function Show-Examples {
    @'

=== PowerShell proc: Drive Usage Examples ===

Navigation:
  cd proc:                     # enter the drive
  ls                           # list entries (PID directories included)
  cd net; ls                   # network files
  cd sys\kernel                # kernel info

Reading files (each file comes back as ONE string; split it into lines yourself):
  cat cpuinfo
  cat meminfo
  (cat proc:\meminfo) -split "`r?`n" | Select-String MemAvailable
  cat net\dev; cat net\tcp; cat net\tcp6; cat net\route; cat net\arp
  cat sys\kernel\hostname

Processes:
  ls proc:\ | Where-Object Name -match '^\d+$'      # all PIDs
  cat self\status                                    # this shell
  cat <PID>\status; cat <PID>\stat; cat <PID>\maps
  (cat proc:\<PID>\cmdline) -split "`0"              # argv, NUL-separated like Linux

Notes:
  -Raw is not supported by the SHiPS provider; it is not needed (content is one string).
  Process directories are live; other entries are cached until 'ls -Force'.

'@ | Write-Host
}

switch ($PSCmdlet.ParameterSetName) {
    'Install'   { Install-ProcDrive }
    'Uninstall' { Uninstall-ProcDrive }
    'Examples'  { Show-Examples }
    default {
        Write-Host 'PowerShell proc: Drive Setup' -ForegroundColor Cyan
        Write-Host '  .\Install-ProcDrive.ps1 -Install [-AddToProfile]   # install module, mount proc:'
        Write-Host '  .\Install-ProcDrive.ps1 -Uninstall [-RemoveFiles]  # unmount; optionally delete module + profile entry'
        Write-Host '  .\Install-ProcDrive.ps1 -ShowExamples              # usage examples'
    }
}
