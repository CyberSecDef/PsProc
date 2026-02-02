# proc: Drive Quick Reference

## Installation
```powershell
.\Install-ProcDrive.ps1 -Install
```

## Navigation Commands

| Command | Description |
|---------|-------------|
| `cd proc:` | Navigate to proc drive |
| `ls` | List current directory |
| `cd net` | Change to network directory |
| `cd ..` | Go up one level |
| `pwd` | Show current location |

## Common Files

### System Info
```powershell
cat cpuinfo          # CPU details
cat meminfo          # Memory stats
cat version          # OS version
cat uptime           # System uptime (seconds)
cat loadavg          # Load average
cat stat             # System statistics
```

### Network
```powershell
cat net\dev          # Network interface stats
cat net\route        # Routing table
cat net\arp          # ARP cache
cat net\tcp          # TCP connections
cat net\udp          # UDP endpoints
```

### System Config
```powershell
cat sys\kernel\hostname    # Computer name
cat sys\kernel\ostype      # OS type
cat sys\kernel\osrelease   # OS version
cat sys\kernel\version     # Full version string
```

### Storage
```powershell
cat mounts           # Mounted drives
cat swaps            # Page file usage
cat partitions       # Disk partitions
cat filesystems      # Supported filesystems
```

### Processes
```powershell
cat self\status      # Current process status
cat self\cmdline     # Current process command line
cat <PID>\status     # Specific process status
cat <PID>\cmdline    # Specific process command line
cat <PID>\stat       # Process statistics
```

## Useful One-Liners

### Memory Usage
```powershell
# Get free memory in GB
[math]::Round([int]((cat proc:\meminfo | Select-String 'MemFree').ToString().Split()[1]) / 1MB, 2)

# Calculate memory usage percentage
$m = cat proc:\meminfo | ConvertFrom-StringData -Delimiter ':'
100 - ([int]$m.MemFree.Trim().Split()[0] / [int]$m.MemTotal.Trim().Split()[0] * 100)
```

### CPU Information
```powershell
# Count logical processors
((cat proc:\cpuinfo -Raw) -split 'processor\s+:').Count - 1

# Get CPU model
(cat proc:\cpuinfo | Select-String 'model name' -List).ToString().Split(':')[1].Trim()
```

### Network Stats
```powershell
# Count active TCP connections
((cat proc:\net\tcp) -split "`n" | Select -Skip 1 | ? {$_.Trim()}).Count

# List network interfaces
(cat proc:\net\dev) -split "`n" | Select -Skip 2 | ? {$_.Trim()} | % {$_.Split(':')[0].Trim()}
```

### Process Queries
```powershell
# List all process IDs
ls proc:\ | ? Name -match '^\d+$' | Select -Expand Name

# Count running processes
(ls proc:\ | ? Name -match '^\d+$').Count

# Find PowerShell processes
ls proc:\ | ? Name -match '^\d+$' | % {
    $s = cat "$($_.FullName)\status" -Raw
    if ($s -match 'pwsh') { $_.Name }
}
```

### System Uptime
```powershell
# Uptime in hours
[math]::Round((cat proc:\uptime).Split()[0] / 3600, 2)

# Uptime in days
[math]::Round((cat proc:\uptime).Split()[0] / 86400, 2)

# Boot time
[DateTimeOffset]::FromUnixTimeSeconds([int](cat proc:\stat | Select-String 'btime').ToString().Split()[1])
```

## PowerShell Integration

### Filtering
```powershell
# Search cpuinfo for specific field
cat proc:\cpuinfo | Select-String 'cache size'

# Get specific meminfo value
cat proc:\meminfo | Select-String 'SwapTotal'
```

### Conversion
```powershell
# Convert meminfo to object
$mem = @{}
(cat proc:\meminfo) -split "`n" | % {
    if ($_ -match '^(\w+):\s+(\d+)') {
        $mem[$Matches[1]] = [int]$Matches[2]
    }
}
$mem.MemTotal
```

### Monitoring
```powershell
# Watch memory (requires custom Watch function or loop)
while ($true) {
    Clear-Host
    cat proc:\meminfo
    Start-Sleep -Seconds 5
}
```

## Comparison with Get-* Cmdlets

| proc: | PowerShell Equivalent |
|-------|----------------------|
| `cat cpuinfo` | `Get-CimInstance Win32_Processor` |
| `cat meminfo` | `Get-CimInstance Win32_OperatingSystem` |
| `cat net\tcp` | `Get-NetTCPConnection` |
| `cat net\dev` | `Get-NetAdapterStatistics` |
| `ls | ? Name -match '^\d+$'` | `Get-Process` |

## Tips

1. **Caching**: Most files are cached for performance. Use `ls -Force` to refresh
2. **Process Dirs**: Process directories update dynamically
3. **Wildcards**: Standard PowerShell wildcards work: `ls proc:\*info`
4. **Tab Completion**: Tab completion works in proc: drive
5. **Pipes**: Combine with PowerShell pipelines for powerful queries

## Common Patterns

### System Dashboard
```powershell
[PSCustomObject]@{
    Hostname = (cat proc:\sys\kernel\hostname).Trim()
    Uptime = "$([math]::Round((cat proc:\uptime).Split()[0] / 3600, 1)) hours"
    Processes = (ls proc:\ | ? Name -match '^\d+$').Count
    MemoryGB = [math]::Round([int]((cat proc:\meminfo | Select-String 'MemTotal').ToString().Split()[1]) / 1MB, 1)
    TCPConns = ((cat proc:\net\tcp) -split "`n" | Select -Skip 1 | ? {$_.Trim()}).Count
}
```

### Process Explorer
```powershell
ls proc:\ | ? Name -match '^\d+$' | % {
    $status = cat "$($_.FullName)\status" -Raw
    $name = ($status -split "`n" | Select-String 'Name:').ToString().Split("`t")[-1]
    $vm = ($status -split "`n" | Select-String 'VmSize:').ToString().Split("`t")[-1]
    [PSCustomObject]@{ PID = $_.Name; Name = $name; Memory = $vm }
} | Sort Memory -Descending | Select -First 10
```

### Network Monitor
```powershell
while ($true) {
    $tcp = ((cat proc:\net\tcp) -split "`n" | Select -Skip 1 | ? {$_.Trim()}).Count
    $udp = ((cat proc:\net\udp) -split "`n" | Select -Skip 1 | ? {$_.Trim()}).Count
    Clear-Host
    Write-Host "TCP: $tcp | UDP: $udp" -ForegroundColor Cyan
    Start-Sleep 2
}
```

## Troubleshooting

| Issue | Solution |
|-------|----------|
| Drive not found | Run `.\Install-ProcDrive.ps1 -Install` |
| Permission denied | Run PowerShell as Administrator |
| Slow performance | Some WMI queries take time; be patient |
| Empty directories | Check if process still exists |
| Module errors | Ensure PowerShell 7+ and SHiPS installed |

## Resources

- Full documentation: See README.md
- Examples: `.\Install-ProcDrive.ps1 -ShowExamples`
- Tests: `.\Test-ProcDrive.ps1 -RunTests`
- Demo: `.\Test-ProcDrive.ps1 -Demo`
