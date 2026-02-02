# PowerShell proc: Drive

A PowerShell 7+ module that implements a Linux `/proc` pseudo-filesystem using SHiPS (Script Hierarchy in PowerShell). This provides a familiar, filesystem-like interface for accessing Windows system information.

## Features

This implementation mirrors many `/proc` components found in Linux:

### Root Level Files
- **cpuinfo** - CPU information (cores, MHz, cache, etc.)
- **meminfo** - Memory statistics (total, free, available, swap)
- **version** - OS version and build information
- **uptime** - System uptime in seconds
- **loadavg** - Load average and process counts
- **stat** - CPU time statistics and system stats
- **mounts** - Mounted drives/filesystems
- **cmdline** - Current process command line
- **filesystems** - Supported filesystem types
- **swaps** - Pagefile/swap usage
- **partitions** - Disk partition information
- **modules** - Loaded Windows drivers (kernel modules)

### Directories

#### `/proc/net/`
- **dev** - Network interface statistics
- **route** - IP routing table
- **arp** - ARP cache
- **tcp** - Active TCP connections
- **udp** - Active UDP endpoints

#### `/proc/sys/kernel/`
- **hostname** - System hostname
- **ostype** - Operating system type
- **osrelease** - OS release version
- **version** - Full kernel version string

#### `/proc/devices/`
- **block** - Block device major numbers
- **character** - Character device major numbers

#### `/proc/self/`
- **cmdline** - Current process command line
- **status** - Current process status
- **stat** - Current process statistics
- **environ** - Environment variables

#### `/proc/[PID]/`
Each running process has a directory with:
- **cmdline** - Process command line
- **status** - Process status information
- **stat** - Process statistics
- **environ** - Process environment (limited)
- **maps** - Memory mappings

## Requirements

- **PowerShell 7.0+** (PowerShell Core)
- **SHiPS Module** (installed automatically)
- **Windows** (tested on Windows 10/11)

## Installation

### Quick Install

```powershell
# Run the installation script
.\Install-ProcDrive.ps1 -Install
```

### Manual Installation

```powershell
# Install SHiPS module
Install-Module -Name SHiPS -Scope CurrentUser

# Import the module
Import-Module .\ProcFileSystem.psm1

# Create the proc: drive
New-PSDrive -Name proc -PSProvider SHiPS -Root 'ProcFileSystem#ProcRoot'
```

## Usage

### Basic Navigation

```powershell
# Navigate to proc drive
cd proc:

# List all entries
ls

# Read CPU information
cat cpuinfo

# Read memory information
cat meminfo

# Navigate to network information
cd net
cat dev
```

### Example Queries

#### System Information
```powershell
# Get total memory
(cat proc:\meminfo | Select-String 'MemTotal').ToString().Split()[1]

# Count CPU cores
((cat proc:\cpuinfo -Raw) -split 'processor\s+:').Count - 1

# Get system uptime in hours
[math]::Round((cat proc:\uptime).Split()[0] / 3600, 2)
```

#### Network Information
```powershell
# View network interfaces
cat proc:\net\dev

# View routing table
cat proc:\net\route

# View TCP connections
cat proc:\net\tcp

# Count active TCP connections
((cat proc:\net\tcp) -split "`n" | Select -Skip 1).Count
```

#### Process Information
```powershell
# List all process IDs
ls proc:\ | Where Name -match '^\d+$' | Select -ExpandProperty Name

# Get current process info
cat proc:\self\status

# Get specific process command line (replace 1234 with PID)
cat proc:\1234\cmdline

# Find all PowerShell processes
ls proc:\ | Where Name -match '^\d+$' | ForEach-Object {
    $status = cat "$($_.FullName)\status" -Raw
    if ($status -match 'pwsh|powershell') {
        [PSCustomObject]@{
            PID = $_.Name
            Info = $status
        }
    }
}
```

#### System Statistics
```powershell
# View system statistics
cat proc:\stat

# Get boot time
(cat proc:\stat | Select-String 'btime').ToString().Split()[1]

# View loaded drivers/modules
cat proc:\modules | Select -First 10
```

## Integration with PowerShell

The proc: drive integrates seamlessly with PowerShell cmdlets:

```powershell
# Search for specific information
Get-Content proc:\cpuinfo | Select-String 'model name'

# Use PowerShell filtering
Get-ChildItem proc:\net | Where-Object Name -eq 'tcp'

# Combine with other cmdlets
(cat proc:\meminfo | Select-String 'MemFree').ToString() | 
    ForEach-Object { $_.Split()[1] } | 
    ForEach-Object { [int]$_ / 1MB }

# Monitor changes (requires external Watch function)
while ($true) {
    Clear-Host
    cat proc:\uptime
    cat proc:\loadavg
    Start-Sleep -Seconds 1
}
```

## Comparison with Linux /proc

| Linux Path | Windows proc: | Notes |
|------------|---------------|-------|
| /proc/cpuinfo | proc:\cpuinfo | Full CPU details |
| /proc/meminfo | proc:\meminfo | Memory statistics |
| /proc/version | proc:\version | OS version |
| /proc/uptime | proc:\uptime | System uptime |
| /proc/loadavg | proc:\loadavg | Simulated load average |
| /proc/net/dev | proc:\net\dev | Network interfaces |
| /proc/net/tcp | proc:\net\tcp | TCP connections |
| /proc/[pid]/cmdline | proc:\[pid]\cmdline | Process command line |
| /proc/[pid]/status | proc:\[pid]\status | Process status |
| /proc/sys/kernel/hostname | proc:\sys\kernel\hostname | System hostname |

## Limitations

Some differences from Linux `/proc`:

1. **Load Average** - Windows doesn't have a native load average, so this is simulated using CPU usage
2. **Process Environment** - Windows security prevents reading other processes' environment variables
3. **Memory Details** - Some Linux-specific memory categories (buffers, cached) are not directly applicable
4. **Real-time Updates** - Some values are cached by SHiPS for performance
5. **Write Operations** - This implementation is read-only (Linux /proc has some writable files in /proc/sys)

## Performance Notes

- The SHiPS provider caches results by default for better performance
- Process directories are not cached to show current processes
- Use `ls -Force` to refresh cached content
- Large directories (many processes) may take time to enumerate

## Uninstallation

```powershell
# Remove the proc: drive
.\Install-ProcDrive.ps1 -Uninstall

# Or manually
Remove-PSDrive -Name proc
Remove-Module ProcFileSystem
```

## Advanced Usage

### Creating Custom Views

```powershell
# Create a function to display memory usage
function Get-ProcMemory {
    $meminfo = cat proc:\meminfo | ConvertFrom-StringData -Delimiter ':'
    [PSCustomObject]@{
        TotalGB = [math]::Round([int]$meminfo.MemTotal.Trim().Split()[0] / 1MB, 2)
        FreeGB = [math]::Round([int]$meminfo.MemFree.Trim().Split()[0] / 1MB, 2)
        UsedPercent = [math]::Round((1 - ([int]$meminfo.MemFree.Trim().Split()[0] / [int]$meminfo.MemTotal.Trim().Split()[0])) * 100, 2)
    }
}

Get-ProcMemory
```

### Monitoring Scripts

```powershell
# Monitor network traffic
$previous = cat proc:\net\dev -Raw
while ($true) {
    Start-Sleep -Seconds 5
    $current = cat proc:\net\dev -Raw
    Clear-Host
    Write-Host "Network Traffic:" -ForegroundColor Cyan
    $current
    $previous = $current
}
```

## Troubleshooting

### Module Not Loading
```powershell
# Ensure PowerShell 7+
$PSVersionTable.PSVersion

# Check SHiPS installation
Get-Module -ListAvailable SHiPS
```

### Drive Not Appearing
```powershell
# Check if drive exists
Get-PSDrive proc

# Recreate drive
New-PSDrive -Name proc -PSProvider SHiPS -Root 'ProcFileSystem#ProcRoot'
```

### Permission Errors
Some operations require elevated privileges. Run PowerShell as Administrator if needed.

## Contributing

This is a read-only implementation. Contributions welcome for:
- Additional /proc components
- Performance optimizations
- Better Windows-specific adaptations
- Bug fixes

## License

MIT License - feel free to use and modify

## References

- [Linux /proc documentation](https://www.kernel.org/doc/Documentation/filesystems/proc.txt)
- [SHiPS Module](https://github.com/PowerShell/SHiPS)
- [PowerShell Documentation](https://docs.microsoft.com/powershell/)

## Author

Created as a demonstration of PowerShell's extensibility and cross-platform concepts.
