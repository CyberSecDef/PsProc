<#
.SYNOPSIS
    Installation and usage script for the PowerShell proc: filesystem provider
.DESCRIPTION
    Installs SHiPS module if needed and sets up the proc: drive
.NOTES
    Requires PowerShell 7+
#>

[CmdletBinding()]
param(
    [switch]$Install,
    [switch]$Uninstall,
    [switch]$ShowExamples
)

function Install-ProcDrive {
    Write-Host "Installing PowerShell proc: drive..." -ForegroundColor Cyan
    
    # Check PowerShell version
    if ($PSVersionTable.PSVersion.Major -lt 7) {
        Write-Error "This script requires PowerShell 7 or later. Current version: $($PSVersionTable.PSVersion)"
        return
    }
    
    # Install SHiPS module if not present
    if (-not (Get-Module -ListAvailable -Name SHiPS)) {
        Write-Host "Installing SHiPS module..." -ForegroundColor Yellow
        Install-Module -Name SHiPS -Scope CurrentUser -Force -AllowClobber
    } else {
        Write-Host "SHiPS module already installed" -ForegroundColor Green
    }
    
    # Import the module
    $modulePath = Join-Path $PSScriptRoot "ProcFileSystem.psm1"
    if (-not (Test-Path $modulePath)) {
        Write-Error "ProcFileSystem.psm1 not found at: $modulePath"
        return
    }
    
    Write-Host "Importing ProcFileSystem module..." -ForegroundColor Yellow
    Import-Module $modulePath -Force
    
    # Create the proc: drive
    Write-Host "Creating proc: drive..." -ForegroundColor Yellow
    New-PSDrive -Name proc -PSProvider SHiPS -Root 'ProcFileSystem#ProcRoot'
    
    if (Test-Path proc:) {
        Write-Host "`nproc: drive successfully created!" -ForegroundColor Green
        Write-Host "`nYou can now navigate to proc: and explore system information:" -ForegroundColor Cyan
        Write-Host "  cd proc:" -ForegroundColor White
        Write-Host "  dir" -ForegroundColor White
        Write-Host "  cat cpuinfo" -ForegroundColor White
        Write-Host "  cat meminfo" -ForegroundColor White
        Write-Host "`nRun with -ShowExamples to see more usage examples" -ForegroundColor Gray
    } else {
        Write-Error "Failed to create proc: drive"
    }
}

function Uninstall-ProcDrive {
    Write-Host "Removing proc: drive..." -ForegroundColor Yellow
    
    if (Test-Path proc:) {
        Remove-PSDrive -Name proc -Force
        Write-Host "proc: drive removed successfully" -ForegroundColor Green
    } else {
        Write-Host "proc: drive not found" -ForegroundColor Yellow
    }
    
    # Remove the module
    if (Get-Module ProcFileSystem) {
        Remove-Module ProcFileSystem -Force
        Write-Host "ProcFileSystem module unloaded" -ForegroundColor Green
    }
}

function Show-Examples {
    Write-Host "`n=== PowerShell proc: Drive Usage Examples ===" -ForegroundColor Cyan
    Write-Host "`nBasic Navigation:" -ForegroundColor Yellow
    Write-Host "  cd proc:                    # Navigate to proc drive"
    Write-Host "  ls                          # List all proc entries"
    Write-Host "  cd net                      # Navigate to network info"
    Write-Host "  cd sys\kernel               # Navigate to kernel info"
    
    Write-Host "`nReading System Information:" -ForegroundColor Yellow
    Write-Host "  cat cpuinfo                 # CPU information"
    Write-Host "  cat meminfo                 # Memory information"
    Write-Host "  cat version                 # OS version"
    Write-Host "  cat uptime                  # System uptime"
    Write-Host "  cat loadavg                 # Load average"
    Write-Host "  cat stat                    # System statistics"
    
    Write-Host "`nNetwork Information:" -ForegroundColor Yellow
    Write-Host "  cat net\dev                 # Network device statistics"
    Write-Host "  cat net\route               # Routing table"
    Write-Host "  cat net\arp                 # ARP table"
    Write-Host "  cat net\tcp                 # TCP connections"
    Write-Host "  cat net\udp                 # UDP endpoints"
    
    Write-Host "`nProcess Information:" -ForegroundColor Yellow
    Write-Host "  ls | Where Name -match '^\d+$'  # List all process directories"
    Write-Host "  cat self\cmdline            # Current process command line"
    Write-Host "  cat self\status             # Current process status"
    Write-Host "  cat <PID>\cmdline           # Specific process command line"
    Write-Host "  cat <PID>\stat              # Specific process statistics"
    
    Write-Host "`nSystem Configuration:" -ForegroundColor Yellow
    Write-Host "  cat sys\kernel\hostname     # System hostname"
    Write-Host "  cat sys\kernel\ostype       # OS type"
    Write-Host "  cat sys\kernel\osrelease    # OS release version"
    Write-Host "  cat sys\kernel\version      # Kernel version"
    
    Write-Host "`nOther Information:" -ForegroundColor Yellow
    Write-Host "  cat mounts                  # Mounted filesystems"
    Write-Host "  cat swaps                   # Swap/pagefile usage"
    Write-Host "  cat partitions              # Partition information"
    Write-Host "  cat modules                 # Loaded drivers/modules"
    Write-Host "  cat filesystems             # Supported filesystems"
    
    Write-Host "`nAdvanced Usage:" -ForegroundColor Yellow
    Write-Host "  Get-Content proc:\meminfo | Select-String 'MemTotal'"
    Write-Host "  Get-ChildItem proc:\ | Where-Object Name -match '^\d+$' | Measure-Object"
    Write-Host "  (Get-Content proc:\cpuinfo -Raw) -split '`n`n' | Measure-Object"
    
    Write-Host "`nPowerShell Integration:" -ForegroundColor Yellow
    Write-Host "  # Monitor CPU info"
    Write-Host "  Watch { cat proc:\cpuinfo | Select -First 20 }"
    Write-Host "  "
    Write-Host "  # Get all TCP connections"
    Write-Host "  (cat proc:\net\tcp) -split '`n' | Select -Skip 1"
    Write-Host "  "
    Write-Host "  # Find processes by name"
    Write-Host "  ls proc:\ | Where Name -match '^\d+$' | ForEach {"
    Write-Host "      [PSCustomObject]@{"
    Write-Host "          PID = `$_.Name"
    Write-Host "          Status = cat `$_.FullName\status -Raw"
    Write-Host "      }"
    Write-Host "  }"
    
    Write-Host "`n" -NoNewline
}

# Main execution
if ($Install) {
    Install-ProcDrive
} elseif ($Uninstall) {
    Uninstall-ProcDrive
} elseif ($ShowExamples) {
    Show-Examples
} else {
    Write-Host "PowerShell proc: Drive Setup" -ForegroundColor Cyan
    Write-Host "Usage:" -ForegroundColor Yellow
    Write-Host "  .\Install-ProcDrive.ps1 -Install        # Install and create proc: drive"
    Write-Host "  .\Install-ProcDrive.ps1 -Uninstall      # Remove proc: drive"
    Write-Host "  .\Install-ProcDrive.ps1 -ShowExamples   # Show usage examples"
}
