#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Generate a subway map visualization of the PsProc codebase structure.

.DESCRIPTION
    This script generates a visual representation of the PsProc filesystem as a 
    subway/metro map, showing the hierarchical relationships between different 
    components using colored lines and stations.
    
    The map shows:
    - System Info Line (Red): System information files like cpuinfo, meminfo, version
    - Network Line (Teal): Network-related files in /proc/net/
    - Configuration Line (Orange): System configuration in /proc/sys/
    - Devices Line (Coral): Device information in /proc/devices/
    - Process Line (Blue): Process-related directories like /proc/self/ and /proc/[PID]/
    - Storage Line (Purple): Storage and filesystem information

.PARAMETER OutputPath
    Path where the subway map image will be saved. Default is 'codebase-subway-map.png'

.PARAMETER Open
    Open the generated image after creation

.EXAMPLE
    .\New-SubwayMap.ps1
    Generates the subway map and saves it as 'codebase-subway-map.png'

.EXAMPLE
    .\New-SubwayMap.ps1 -OutputPath "my-map.png" -Open
    Generates the subway map, saves it as 'my-map.png', and opens it

.NOTES
    Requires Python 3 with matplotlib and numpy packages installed.
    The script will check for dependencies and offer to install them if missing.
#>

[CmdletBinding()]
param(
    [Parameter()]
    [string]$OutputPath = "codebase-subway-map.png",
    
    [Parameter()]
    [switch]$Open
)

$ErrorActionPreference = 'Stop'

# Get script directory
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path

Write-Host "PsProc Subway Map Generator" -ForegroundColor Cyan
Write-Host "===========================" -ForegroundColor Cyan
Write-Host

# Check for Python
Write-Host "Checking for Python..." -NoNewline
try {
    $pythonVersion = python3 --version 2>&1
    Write-Host " Found: $pythonVersion" -ForegroundColor Green
} catch {
    Write-Host " Not Found" -ForegroundColor Red
    Write-Error "Python 3 is required. Please install Python 3 from https://www.python.org/"
}

# Check for required Python packages
Write-Host "Checking for required Python packages..." -NoNewline
$pipList = pip3 list 2>&1 | Out-String

$missingPackages = @()
if ($pipList -notmatch 'matplotlib') {
    $missingPackages += 'matplotlib'
}
if ($pipList -notmatch 'numpy') {
    $missingPackages += 'numpy'
}

if ($missingPackages.Count -gt 0) {
    Write-Host " Missing: $($missingPackages -join ', ')" -ForegroundColor Yellow
    Write-Host
    Write-Host "Installing missing packages..." -ForegroundColor Yellow
    try {
        pip3 install $missingPackages --quiet --user
        Write-Host "Packages installed successfully!" -ForegroundColor Green
    } catch {
        Write-Error "Failed to install required packages. Please run: pip3 install matplotlib numpy"
    }
} else {
    Write-Host " All packages found" -ForegroundColor Green
}

Write-Host
Write-Host "Generating subway map..." -ForegroundColor Cyan

# Run the Python script
$pythonScript = Join-Path $ScriptDir "Generate-SubwayMap.py"

if (-not (Test-Path $pythonScript)) {
    Write-Error "Generate-SubwayMap.py not found in $ScriptDir"
}

try {
    python3 $pythonScript --output $OutputPath
    
    # Verify the file was created
    if (Test-Path $OutputPath) {
        $fileInfo = Get-Item $OutputPath
        Write-Host
        Write-Host "Success! Subway map generated:" -ForegroundColor Green
        Write-Host "  File: $($fileInfo.FullName)" -ForegroundColor White
        Write-Host "  Size: $([math]::Round($fileInfo.Length / 1KB, 2)) KB" -ForegroundColor White
        
        # Open the file if requested
        if ($Open) {
            Write-Host
            Write-Host "Opening subway map..." -ForegroundColor Cyan
            if ($IsWindows -or $env:OS -match 'Windows') {
                Start-Process $OutputPath
            } elseif ($IsMacOS) {
                & open $OutputPath
            } else {
                try {
                    & xdg-open $OutputPath 2>&1 | Out-Null
                } catch {
                    Write-Host "Could not auto-open file. Please open manually: $OutputPath" -ForegroundColor Yellow
                }
            }
        }
    } else {
        Write-Error "Subway map generation failed - output file not created"
    }
} catch {
    Write-Error "Failed to generate subway map: $_"
}

Write-Host
