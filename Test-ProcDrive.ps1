#Requires -Version 7.0
<#
.SYNOPSIS
    Test, demo and benchmark runner for the PowerShell proc: drive.
.DESCRIPTION
    -RunTests runs the Pester suite in .\Tests and exits with the number of failed tests,
    so it can gate CI. Add -IncludeInstaller to also run the installer round trip (it
    touches your CurrentUser module path and profile, and restores them).
.EXAMPLE
    .\Test-ProcDrive.ps1 -RunTests
#>
[CmdletBinding(DefaultParameterSetName = 'Help')]
param(
    [Parameter(Mandatory, ParameterSetName = 'Tests')]     [switch]$RunTests,
    [Parameter(ParameterSetName = 'Tests')]                [switch]$IncludeInstaller,
    [Parameter(Mandatory, ParameterSetName = 'Demo')]      [switch]$Demo,
    [Parameter(Mandatory, ParameterSetName = 'Benchmark')] [switch]$Benchmark
)

function Get-ProcLines([string]$Path) {
    # SHiPS returns each file as one string, and -Raw is not supported; split it here.
    (Get-Content $Path) -split "`r?`n" | Where-Object { $_ -ne '' }
}

function Initialize-ProcDrive {
    if (Get-PSDrive proc -ErrorAction SilentlyContinue) { return }
    Import-Module (Join-Path $PSScriptRoot 'ProcFileSystem.psd1') -Force -WarningAction SilentlyContinue
    Mount-ProcDrive
}

function Invoke-ProcTests {
    $pester = Get-Module -ListAvailable Pester | Where-Object Version -ge '5.0' | Sort-Object Version -Descending | Select-Object -First 1
    if (-not $pester) { throw 'Pester 5 or later is required: Install-Module Pester -MinimumVersion 5.0 -Scope CurrentUser' }
    Import-Module $pester -Force
    $config = New-PesterConfiguration
    $config.Run.Path = Join-Path $PSScriptRoot 'Tests'
    $config.Run.PassThru = $true
    $config.Output.Verbosity = 'Detailed'
    if (-not $IncludeInstaller) { $config.Filter.ExcludeTag = 'Installer' }
    $result = Invoke-Pester -Configuration $config
    exit $result.FailedCount
}

function Show-Demo {
    Initialize-ProcDrive
    $kv = { param($path) $h = @{}; foreach ($l in Get-ProcLines $path) { $k, $v = $l -split ':\s*', 2; $h[$k.Trim()] = "$v".Trim() }; $h }

    Write-Host "`n=== proc: Drive Demo ===" -ForegroundColor Cyan
    $uptime = [double]((Get-Content proc:\uptime).Split()[0])
    Write-Host ("Host      {0}" -f (Get-Content proc:\sys\kernel\hostname).Trim())
    Write-Host ("OS        {0}" -f (Get-Content proc:\version).Trim())
    Write-Host ("Uptime    {0:N1} hours" -f ($uptime / 3600))
    Write-Host ("Load      {0}" -f (Get-Content proc:\loadavg).Trim())

    $cpu = & $kv proc:\cpuinfo
    $logical = @(Get-ProcLines proc:\cpuinfo | Where-Object { $_ -match '^processor' }).Count
    Write-Host ("CPU       {0} ({1} logical)" -f $cpu['model name'], $logical)

    $mem = & $kv proc:\meminfo
    $gb = { param($v) [math]::Round([long]($v -replace ' kB') / 1MB, 1) }
    Write-Host ("Memory    {0} GB total, {1} GB available, {2} GB page cache" -f (& $gb $mem.MemTotal), (& $gb $mem.MemAvailable), (& $gb $mem.Cached))

    $tcp = @(Get-ProcLines proc:\net\tcp | Select-Object -Skip 1)
    $listen = @($tcp | Where-Object { ($_.Trim() -split '\s+')[3] -eq '0A' }).Count
    Write-Host ("Network   {0} IPv4 TCP sockets ({1} listening), {2} interfaces" -f $tcp.Count, $listen, @(Get-ProcLines proc:\net\dev | Select-Object -Skip 2).Count)
    Write-Host ("Processes {0}" -f @(Get-ChildItem proc:\ | Where-Object Name -match '^\d+$').Count)

    $self = & $kv proc:\self\status
    Write-Host ("Self      {0} pid {1}, {2} threads, RSS {3}" -f $self.Name, $self.Pid, $self.Threads, $self.VmRSS)
}

function Invoke-Benchmark {
    Initialize-ProcDrive
    Write-Host "`n=== proc: Drive Benchmark (ms, median of 5) ===" -ForegroundColor Cyan
    $cases = [ordered]@{
        'ls proc:\ (incl. PIDs)' = { Get-ChildItem proc:\ }
        'cpuinfo'                = { Get-Content proc:\cpuinfo }
        'meminfo'                = { Get-Content proc:\meminfo }
        'stat'                   = { Get-Content proc:\stat }
        'loadavg'                = { Get-Content proc:\loadavg }
        'net\dev'                = { Get-Content proc:\net\dev }
        'net\tcp'                = { Get-Content proc:\net\tcp }
        'net\route'              = { Get-Content proc:\net\route }
        'self\stat'              = { Get-Content proc:\self\stat }
        'self\status'            = { Get-Content proc:\self\status }
        'self\cmdline'           = { Get-Content proc:\self\cmdline }
    }
    foreach ($name in $cases.Keys) {
        $times = 1..5 | ForEach-Object { (Measure-Command { $null = & $cases[$name] }).TotalMilliseconds } | Sort-Object
        Write-Host ("  {0,-26} {1,8:N1}" -f $name, $times[2])
    }
}

switch ($PSCmdlet.ParameterSetName) {
    'Tests'     { Invoke-ProcTests }
    'Demo'      { Show-Demo }
    'Benchmark' { Invoke-Benchmark }
    default {
        Write-Host 'proc: Drive Test Suite' -ForegroundColor Cyan
        Write-Host '  .\Test-ProcDrive.ps1 -RunTests [-IncludeInstaller]  # Pester suite; exit code = failures'
        Write-Host '  .\Test-ProcDrive.ps1 -Demo                          # summary of the system via proc:'
        Write-Host '  .\Test-ProcDrive.ps1 -Benchmark                     # read timings'
    }
}
