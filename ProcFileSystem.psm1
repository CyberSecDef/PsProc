using namespace Microsoft.PowerShell.SHiPS

<#
.SYNOPSIS
    PowerShell SHiPS provider that mimics Linux /proc filesystem
.DESCRIPTION
    Creates a proc: drive that provides read-only access to system information
    similar to Linux /proc pseudo-filesystem
.NOTES
    Requires: PowerShell 7+ on Windows and the SHiPS module. Load it through the module
    manifest (Import-Module ProcFileSystem): the manifest's RequiredModules loads SHiPS
    before this file's classes are parsed.
#>

if (-not $IsWindows) {
    throw 'ProcFileSystem requires Windows: it reads CIM, performance counters and the NetTCPIP cmdlets.'
}

#region Helpers
# Native helpers. Class bodies need their types at parse time, so classes never touch
# [ProcFs.Native] directly; they call the module functions below, which resolve it at
# runtime. (SHiPS runs class methods in its own runspace, where module functions are
# still visible.)
if (-not ('ProcFs.Native' -as [type])) {
    Add-Type -Namespace ProcFs -Name Native -MemberDefinition @'
[DllImport("shell32.dll", SetLastError = true)]
static extern IntPtr CommandLineToArgvW([MarshalAs(UnmanagedType.LPWStr)] string lpCmdLine, out int pNumArgs);
[DllImport("kernel32.dll")]
static extern IntPtr LocalFree(IntPtr hMem);

// Split a Windows command line exactly the way the C runtime builds argv.
public static string[] SplitCommandLine(string commandLine) {
    int argc;
    IntPtr argv = CommandLineToArgvW(commandLine, out argc);
    if (argv == IntPtr.Zero) throw new System.ComponentModel.Win32Exception();
    try {
        var args = new string[argc];
        for (int i = 0; i < argc; i++) args[i] = Marshal.PtrToStringUni(Marshal.ReadIntPtr(argv, i * IntPtr.Size));
        return args;
    } finally { LocalFree(argv); }
}

[DllImport("kernel32.dll", SetLastError = true)]
static extern IntPtr OpenProcess(uint dwDesiredAccess, bool bInheritHandle, int dwProcessId);
[DllImport("kernel32.dll")]
static extern bool CloseHandle(IntPtr hObject);
[DllImport("ntdll.dll")]
static extern int NtQueryInformationProcess(IntPtr hProcess, int infoClass, IntPtr info, int infoLength, out int returnLength);
const uint PROCESS_QUERY_LIMITED_INFORMATION = 0x1000;

// Parent PID via ProcessBasicInformation (class 0). Needs only limited query access,
// so it works for protected processes and never touches WMI. -1 if unavailable.
public static int GetParentProcessId(int pid) {
    IntPtr h = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, false, pid);
    if (h == IntPtr.Zero) return -1;
    try {
        // PROCESS_BASIC_INFORMATION is six pointer-sized fields; the parent is the sixth.
        int size = IntPtr.Size * 6;
        IntPtr buf = Marshal.AllocHGlobal(size);
        try {
            int ret;
            if (NtQueryInformationProcess(h, 0, buf, size, out ret) != 0) return -1;
            return (int)Marshal.ReadIntPtr(buf, IntPtr.Size * 5).ToInt64();
        } finally { Marshal.FreeHGlobal(buf); }
    } finally { CloseHandle(h); }
}

// Command line via ProcessCommandLineInformation (class 60, Windows 8.1+). Returns null
// when access is denied instead of waiting on a WMI query.
public static string GetCommandLine(int pid) {
    IntPtr h = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, false, pid);
    if (h == IntPtr.Zero) return null;
    try {
        int len;
        NtQueryInformationProcess(h, 60, IntPtr.Zero, 0, out len);
        if (len <= 0) return null;
        IntPtr buf = Marshal.AllocHGlobal(len);
        try {
            if (NtQueryInformationProcess(h, 60, buf, len, out len) != 0) return null;
            // UNICODE_STRING { USHORT Length; USHORT MaximumLength; PWSTR Buffer; }
            int bytes = Marshal.ReadInt16(buf) & 0xFFFF;
            IntPtr text = Marshal.ReadIntPtr(buf, IntPtr.Size);
            return bytes == 0 ? "" : Marshal.PtrToStringUni(text, bytes / 2);
        } finally { Marshal.FreeHGlobal(buf); }
    } finally { CloseHandle(h); }
}
'@
}

function Get-ProcProperty {
    # Many Process properties throw, or return $null, for protected processes and for
    # Idle/System when not elevated. Return $Default instead of failing the whole read.
    param([System.Diagnostics.Process]$Process, [string]$Name, $Default = $null)
    try { $value = $Process.$Name } catch { $value = $null }
    if ($null -eq $value) { $Default } else { $value }
}

function Get-ProcBootTime {
    # From the millisecond tick counter rather than CIM: no WMI round trip, and it works
    # under restricted tokens where WMI is denied.
    [datetime]::Now.AddMilliseconds(-[Environment]::TickCount64)
}

function Get-ProcTicks {
    # Linux reports CPU times in clock ticks (USER_HZ = 100). TimeSpan ticks are 100 ns.
    param([TimeSpan]$Time)
    [long]($Time.Ticks / 100000)
}

function Get-ProcState {
    # Windows has no process state; derive one from the threads like Linux would:
    # any running/ready thread -> R, every thread suspended -> T, otherwise S.
    param([System.Diagnostics.Process]$Process)
    $threads = Get-ProcProperty $Process 'Threads'
    if (-not $threads -or $threads.Count -eq 0) { return 'S (sleeping)' }
    $suspended = 0
    foreach ($t in $threads) {
        $state = try { [string]$t.ThreadState } catch { '' }
        if ($state -in 'Running', 'Ready', 'Standby') { return 'R (running)' }
        if ($state -eq 'Wait') {
            $reason = try { [string]$t.WaitReason } catch { '' }
            if ($reason -eq 'Suspended') { $suspended++ }
        }
    }
    if ($suspended -eq $threads.Count) { 'T (stopped)' } else { 'S (sleeping)' }
}

function Get-ProcNice {
    # Map the Windows priority class onto the Linux nice range (-20..19).
    param([System.Diagnostics.Process]$Process)
    switch ([string](Get-ProcProperty $Process 'PriorityClass' 'Normal')) {
        'Idle'        { 19 }
        'BelowNormal' { 10 }
        'AboveNormal' { -5 }
        'High'        { -10 }
        'RealTime'    { -20 }
        default       { 0 }
    }
}

function Get-ProcComm {
    # Linux truncates comm to TASK_COMM_LEN - 1 = 15 characters.
    param([System.Diagnostics.Process]$Process)
    $name = [string](Get-ProcProperty $Process 'ProcessName' '')
    if ($name.Length -gt 15) { $name.Substring(0, 15) } else { $name }
}

function Get-ProcParentId {
    # Not Process.Parent: in PowerShell 7 that runs a per-process Win32_Process CIM
    # query, which takes ~5 s to fail on every process a non-elevated user can't open.
    param([System.Diagnostics.Process]$Process)
    [math]::Max(0, [ProcFs.Native]::GetParentProcessId($Process.Id))
}

function Get-ProcCommandLine {
    # Not Process.CommandLine, for the same ~5 s-per-process CIM reason as above.
    param([System.Diagnostics.Process]$Process)
    [ProcFs.Native]::GetCommandLine($Process.Id)
}

function Split-ProcCommandLine {
    param([string]$CommandLine)
    if ([string]::IsNullOrWhiteSpace($CommandLine)) { return @() }
    [ProcFs.Native]::SplitCommandLine($CommandLine)
}
#endregion

#region Root Directory
# Not cached: the root holds the live PID directories. With UseCache = $true, processes
# started after the first listing stayed invisible (and exited ones lingered) until
# 'ls -Force'. Rebuilding the static entries each time is cheap.
[SHiPSProvider(UseCache = $false)]
class ProcRoot : SHiPSDirectory {
    ProcRoot([string]$name) : base($name) {}
    
    [object[]] GetChildItem() {
        $items = @(
            [ProcCpuInfo]::new('cpuinfo')
            [ProcMemInfo]::new('meminfo')
            [ProcVersion]::new('version')
            [ProcUptime]::new('uptime')
            [ProcLoadAvg]::new('loadavg')
            [ProcStat]::new('stat')
            [ProcMounts]::new('mounts')
            [ProcNetDirectory]::new('net')
            [ProcSysDirectory]::new('sys')
            [ProcCmdline]::new('cmdline')
            [ProcDevicesDirectory]::new('devices')
            [ProcFilesystems]::new('filesystems')
            [ProcSwaps]::new('swaps')
            [ProcPartitions]::new('partitions')
            [ProcModules]::new('modules')
            [ProcSelfDirectory]::new('self')
        )
        
        # Add process directories (PIDs)
        foreach ($proc in Get-Process) {
            $items += [ProcProcessDirectory]::new($proc.Id.ToString())
        }
        
        return $items
    }
}
#endregion

#region CPU Info
class ProcCpuInfo : SHiPSLeaf {
    ProcCpuInfo([string]$name) : base($name) {}
    
    [string] GetContent() {
        $sb = [System.Text.StringBuilder]::new()
        $processors = Get-CimInstance -ClassName Win32_Processor
        
        $processorNum = 0
        foreach ($cpu in $processors) {
            $cores = $cpu.NumberOfCores
            $logicalProcessors = $cpu.NumberOfLogicalProcessors
            
            for ($i = 0; $i -lt $logicalProcessors; $i++) {
                [void]$sb.AppendLine("processor`t: $processorNum")
                [void]$sb.AppendLine("vendor_id`t: $($cpu.Manufacturer)")
                [void]$sb.AppendLine("cpu family`t: $($cpu.Family)")
                [void]$sb.AppendLine("model`t`t: $($cpu.Model)")
                [void]$sb.AppendLine("model name`t: $($cpu.Name)")
                [void]$sb.AppendLine("stepping`t: $($cpu.Stepping)")
                [void]$sb.AppendLine("cpu MHz`t`t: $($cpu.CurrentClockSpeed)")
                [void]$sb.AppendLine("cache size`t: $($cpu.L3CacheSize) KB")
                [void]$sb.AppendLine("physical id`t: $($cpu.DeviceID)")
                [void]$sb.AppendLine("siblings`t: $logicalProcessors")
                [void]$sb.AppendLine("core id`t`t: $([Math]::Floor($i / ($logicalProcessors / $cores)))")
                [void]$sb.AppendLine("cpu cores`t: $cores")
                [void]$sb.AppendLine("flags`t`t: $($cpu.Architecture)")
                [void]$sb.AppendLine()
                $processorNum++
            }
        }
        
        return $sb.ToString()
    }
}
#endregion

#region Memory Info
class ProcMemInfo : SHiPSLeaf {
    ProcMemInfo([string]$name) : base($name) {}
    
    [string] GetContent() {
        $os = Get-CimInstance -ClassName Win32_OperatingSystem
        $cs = Get-CimInstance -ClassName Win32_ComputerSystem
        
        $totalMem = [math]::Round($cs.TotalPhysicalMemory / 1KB)
        $freeMem = [math]::Round($os.FreePhysicalMemory)
        $availableMem = [math]::Round($os.FreePhysicalMemory)
        $usedMem = $totalMem - $freeMem
        
        $totalSwap = [math]::Round($os.TotalVirtualMemorySize)
        $freeSwap = [math]::Round($os.FreeVirtualMemory)
        
        $sb = [System.Text.StringBuilder]::new()
        [void]$sb.AppendLine("MemTotal:       $totalMem kB")
        [void]$sb.AppendLine("MemFree:        $freeMem kB")
        [void]$sb.AppendLine("MemAvailable:   $availableMem kB")
        [void]$sb.AppendLine("Buffers:        0 kB")
        [void]$sb.AppendLine("Cached:         0 kB")
        [void]$sb.AppendLine("SwapTotal:      $totalSwap kB")
        [void]$sb.AppendLine("SwapFree:       $freeSwap kB")
        [void]$sb.AppendLine("Dirty:          0 kB")
        [void]$sb.AppendLine("Writeback:      0 kB")
        [void]$sb.AppendLine("Mapped:         0 kB")
        [void]$sb.AppendLine("Shmem:          0 kB")
        [void]$sb.AppendLine("CommitLimit:    $totalSwap kB")
        [void]$sb.AppendLine("Committed_AS:   $usedMem kB")
        
        return $sb.ToString()
    }
}
#endregion

#region Version
class ProcVersion : SHiPSLeaf {
    ProcVersion([string]$name) : base($name) {}
    
    [string] GetContent() {
        $os = Get-CimInstance -ClassName Win32_OperatingSystem
        return "$($os.Caption) (build $($os.BuildNumber)) $($os.OSArchitecture) $($os.Version)"
    }
}
#endregion

#region Uptime
class ProcUptime : SHiPSLeaf {
    ProcUptime([string]$name) : base($name) {}
    
    [string] GetContent() {
        $os = Get-CimInstance -ClassName Win32_OperatingSystem
        $uptime = (Get-Date) - $os.LastBootUpTime
        $uptimeSeconds = [math]::Round($uptime.TotalSeconds, 2)
        
        # Idle time is harder to calculate accurately on Windows
        # Using a placeholder based on CPU idle percentage
        $cpu = Get-CimInstance -ClassName Win32_Processor | Select-Object -First 1
        $idlePercent = 100 - ($cpu.LoadPercentage)
        $idleSeconds = [math]::Round($uptimeSeconds * ($idlePercent / 100), 2)
        
        return "$uptimeSeconds $idleSeconds"
    }
}
#endregion

#region Load Average
class ProcLoadAvg : SHiPSLeaf {
    ProcLoadAvg([string]$name) : base($name) {}
    
    [string] GetContent() {
        # Windows doesn't have direct load average, simulate with CPU usage
        $cpu = Get-CimInstance -ClassName Win32_Processor
        $avgLoad = ($cpu | Measure-Object -Property LoadPercentage -Average).Average / 100
        
        $processes = (Get-Process).Count
        $threads = (Get-Process | Measure-Object -Property Threads -Sum).Sum
        
        # Format: load1 load5 load15 running/total lastPID
        return "$($avgLoad.ToString('F2')) $($avgLoad.ToString('F2')) $($avgLoad.ToString('F2')) 1/$processes $threads"
    }
}
#endregion

#region Stat
class ProcStat : SHiPSLeaf {
    ProcStat([string]$name) : base($name) {}
    
    [string] GetContent() {
        $sb = [System.Text.StringBuilder]::new()
        
        # CPU stats
        $cpuTimes = Get-CimInstance -ClassName Win32_PerfFormattedData_PerfOS_Processor | 
            Where-Object { $_.Name -eq '_Total' }
        
        $user = [math]::Round($cpuTimes.PercentUserTime * 100)
        $system = [math]::Round($cpuTimes.PercentPrivilegedTime * 100)
        $idle = [math]::Round($cpuTimes.PercentIdleTime * 100)
        
        [void]$sb.AppendLine("cpu  $user 0 $system $idle 0 0 0 0 0 0")
        
        # Per-CPU stats
        $cpuStats = Get-CimInstance -ClassName Win32_PerfFormattedData_PerfOS_Processor | 
            Where-Object { $_.Name -ne '_Total' }
        
        $cpuNum = 0
        foreach ($cpu in $cpuStats) {
            $u = [math]::Round($cpu.PercentUserTime * 100)
            $s = [math]::Round($cpu.PercentPrivilegedTime * 100)
            $i = [math]::Round($cpu.PercentIdleTime * 100)
            [void]$sb.AppendLine("cpu$cpuNum $u 0 $s $i 0 0 0 0 0 0")
            $cpuNum++
        }
        
        # System stats
        $os = Get-CimInstance -ClassName Win32_OperatingSystem
        $bootTime = [DateTimeOffset]$os.LastBootUpTime
        
        [void]$sb.AppendLine("intr 0")
        [void]$sb.AppendLine("ctxt 0")
        [void]$sb.AppendLine("btime $($bootTime.ToUnixTimeSeconds())")
        [void]$sb.AppendLine("processes $(Get-Process | Measure-Object | Select-Object -ExpandProperty Count)")
        [void]$sb.AppendLine("procs_running 1")
        [void]$sb.AppendLine("procs_blocked 0")
        
        return $sb.ToString()
    }
}
#endregion

#region Mounts
class ProcMounts : SHiPSLeaf {
    ProcMounts([string]$name) : base($name) {}
    
    [string] GetContent() {
        $sb = [System.Text.StringBuilder]::new()
        
        Get-PSDrive -PSProvider FileSystem | ForEach-Object {
            $drive = $_
            $fsType = "ntfs"
            $options = "rw"
            
            [void]$sb.AppendLine("$($drive.Name): $($drive.Root) $fsType $options 0 0")
        }
        
        return $sb.ToString()
    }
}
#endregion

#region Cmdline
class ProcCmdline : SHiPSLeaf {
    ProcCmdline([string]$name) : base($name) {}
    
    [string] GetContent() {
        # Return the command line of the current PowerShell process
        $currentProc = Get-Process -Id $global:PID
        return $currentProc.Path
    }
}
#endregion

#region Filesystems
class ProcFilesystems : SHiPSLeaf {
    ProcFilesystems([string]$name) : base($name) {}
    
    [string] GetContent() {
        $sb = [System.Text.StringBuilder]::new()
        [void]$sb.AppendLine("nodev`tsysfs")
        [void]$sb.AppendLine("nodev`ttmpfs")
        [void]$sb.AppendLine("nodev`tdevtmpfs")
        [void]$sb.AppendLine("`tntfs")
        [void]$sb.AppendLine("`tfat32")
        [void]$sb.AppendLine("`texfat")
        return $sb.ToString()
    }
}
#endregion

#region Swaps
class ProcSwaps : SHiPSLeaf {
    ProcSwaps([string]$name) : base($name) {}
    
    [string] GetContent() {
        $sb = [System.Text.StringBuilder]::new()
        [void]$sb.AppendLine("Filename`t`t`t`tType`t`tSize`tUsed`tPriority")
        
        $os = Get-CimInstance -ClassName Win32_OperatingSystem
        $pageFiles = Get-CimInstance -ClassName Win32_PageFileUsage
        
        foreach ($pf in $pageFiles) {
            $size = $pf.AllocatedBaseSize * 1024
            $used = $pf.CurrentUsage * 1024
            [void]$sb.AppendLine("$($pf.Name)`t`tfile`t`t$size`t$used`t-2")
        }
        
        return $sb.ToString()
    }
}
#endregion

#region Partitions
class ProcPartitions : SHiPSLeaf {
    ProcPartitions([string]$name) : base($name) {}
    
    [string] GetContent() {
        $sb = [System.Text.StringBuilder]::new()
        [void]$sb.AppendLine("major minor  #blocks  name")
        
        $disks = Get-CimInstance -ClassName Win32_DiskPartition
        foreach ($disk in $disks) {
            $blocks = [math]::Round($disk.Size / 1024)
            [void]$sb.AppendLine("8     0    $blocks    $($disk.DeviceID)")
        }
        
        return $sb.ToString()
    }
}
#endregion

#region Modules
class ProcModules : SHiPSLeaf {
    ProcModules([string]$name) : base($name) {}
    
    [string] GetContent() {
        $sb = [System.Text.StringBuilder]::new()
        
        # List loaded kernel modules (drivers on Windows)
        $drivers = Get-CimInstance -ClassName Win32_SystemDriver | Where-Object { $_.State -eq 'Running' }
        
        foreach ($driver in $drivers) {
            $size = if ($driver.Size) { $driver.Size } else { 0 }
            [void]$sb.AppendLine("$($driver.Name) $size 0 - Live 0x0000000000000000")
        }
        
        return $sb.ToString()
    }
}
#endregion

#region Net Directory
[SHiPSProvider(UseCache = $true)]
class ProcNetDirectory : SHiPSDirectory {
    ProcNetDirectory([string]$name) : base($name) {}
    
    [object[]] GetChildItem() {
        return @(
            [ProcNetDev]::new('dev')
            [ProcNetRoute]::new('route')
            [ProcNetArp]::new('arp')
            [ProcNetTcp]::new('tcp')
            [ProcNetUdp]::new('udp')
        )
    }
}

class ProcNetDev : SHiPSLeaf {
    ProcNetDev([string]$name) : base($name) {}
    
    [string] GetContent() {
        $sb = [System.Text.StringBuilder]::new()
        [void]$sb.AppendLine("Inter-|   Receive                                                |  Transmit")
        [void]$sb.AppendLine(" face |bytes    packets errs drop fifo frame compressed multicast|bytes    packets errs drop fifo colls carrier compressed")
        
        $adapters = Get-NetAdapterStatistics
        foreach ($adapter in $adapters) {
            $name = $adapter.Name.PadRight(6).Substring(0, 6)
            $rxBytes = $adapter.ReceivedBytes
            $rxPackets = $adapter.ReceivedUnicastPackets
            $txBytes = $adapter.SentBytes
            $txPackets = $adapter.SentUnicastPackets
            
            [void]$sb.AppendLine("$name`: $rxBytes $rxPackets 0 0 0 0 0 0 $txBytes $txPackets 0 0 0 0 0 0")
        }
        
        return $sb.ToString()
    }
}

class ProcNetRoute : SHiPSLeaf {
    ProcNetRoute([string]$name) : base($name) {}
    
    [string] GetContent() {
        $sb = [System.Text.StringBuilder]::new()
        [void]$sb.AppendLine("Iface`tDestination`tGateway `tFlags`tRefCnt`tUse`tMetric`tMask`t`tMTU`tWindow`tIRTT")
        
        $routes = Get-NetRoute -AddressFamily IPv4
        foreach ($route in $routes) {
            $iface = $route.InterfaceAlias
            $dest = $route.DestinationPrefix.Split('/')[0]
            $gateway = if ($route.NextHop -eq '0.0.0.0') { '0.0.0.0' } else { $route.NextHop }
            $metric = $route.RouteMetric
            
            [void]$sb.AppendLine("$iface`t$dest`t$gateway`t0003`t0`t0`t$metric`t0.0.0.0`t0`t0`t0")
        }
        
        return $sb.ToString()
    }
}

class ProcNetArp : SHiPSLeaf {
    ProcNetArp([string]$name) : base($name) {}
    
    [string] GetContent() {
        $sb = [System.Text.StringBuilder]::new()
        [void]$sb.AppendLine("IP address       HW type     Flags       HW address            Mask     Device")
        
        $neighbors = Get-NetNeighbor -AddressFamily IPv4
        foreach ($neighbor in $neighbors) {
            $ip = $neighbor.IPAddress.PadRight(16)
            $mac = $neighbor.LinkLayerAddress
            $iface = $neighbor.InterfaceAlias
            
            [void]$sb.AppendLine("$ip 0x1         0x2         $mac     *        $iface")
        }
        
        return $sb.ToString()
    }
}

class ProcNetTcp : SHiPSLeaf {
    ProcNetTcp([string]$name) : base($name) {}
    
    [string] GetContent() {
        $sb = [System.Text.StringBuilder]::new()
        [void]$sb.AppendLine("  sl  local_address rem_address   st tx_queue rx_queue tr tm->when retrnsmt   uid  timeout inode")
        
        $connections = Get-NetTCPConnection
        $index = 0
        foreach ($conn in $connections) {
            $localAddr = "$($conn.LocalAddress):$($conn.LocalPort)"
            $remoteAddr = "$($conn.RemoteAddress):$($conn.RemotePort)"
            $state = switch ($conn.State) {
                'Listen' { '0A' }
                'Established' { '01' }
                'TimeWait' { '06' }
                default { '00' }
            }
            
            [void]$sb.AppendLine("  $($index.ToString().PadLeft(2)): $localAddr $remoteAddr $state 00000000:00000000 00:00000000 00000000     0        0 0")
            $index++
        }
        
        return $sb.ToString()
    }
}

class ProcNetUdp : SHiPSLeaf {
    ProcNetUdp([string]$name) : base($name) {}
    
    [string] GetContent() {
        $sb = [System.Text.StringBuilder]::new()
        [void]$sb.AppendLine("  sl  local_address rem_address   st tx_queue rx_queue tr tm->when retrnsmt   uid  timeout inode")
        
        $connections = Get-NetUDPEndpoint
        $index = 0
        foreach ($conn in $connections) {
            $localAddr = "$($conn.LocalAddress):$($conn.LocalPort)"
            
            [void]$sb.AppendLine("  $($index.ToString().PadLeft(2)): $localAddr 0.0.0.0:0 07 00000000:00000000 00:00000000 00000000     0        0 0")
            $index++
        }
        
        return $sb.ToString()
    }
}
#endregion

#region Sys Directory
[SHiPSProvider(UseCache = $true)]
class ProcSysDirectory : SHiPSDirectory {
    ProcSysDirectory([string]$name) : base($name) {}
    
    [object[]] GetChildItem() {
        return @(
            [ProcSysKernelDirectory]::new('kernel')
        )
    }
}

class ProcSysKernelDirectory : SHiPSDirectory {
    ProcSysKernelDirectory([string]$name) : base($name) {}
    
    [object[]] GetChildItem() {
        return @(
            [ProcSysKernelHostname]::new('hostname')
            [ProcSysKernelOstype]::new('ostype')
            [ProcSysKernelOsrelease]::new('osrelease')
            [ProcSysKernelVersion]::new('version')
        )
    }
}

class ProcSysKernelHostname : SHiPSLeaf {
    ProcSysKernelHostname([string]$name) : base($name) {}
    
    [string] GetContent() {
        return $env:COMPUTERNAME
    }
}

class ProcSysKernelOstype : SHiPSLeaf {
    ProcSysKernelOstype([string]$name) : base($name) {}
    
    [string] GetContent() {
        return "Windows_NT"
    }
}

class ProcSysKernelOsrelease : SHiPSLeaf {
    ProcSysKernelOsrelease([string]$name) : base($name) {}
    
    [string] GetContent() {
        $os = Get-CimInstance -ClassName Win32_OperatingSystem
        return $os.Version
    }
}

class ProcSysKernelVersion : SHiPSLeaf {
    ProcSysKernelVersion([string]$name) : base($name) {}
    
    [string] GetContent() {
        $os = Get-CimInstance -ClassName Win32_OperatingSystem
        return "$($os.Caption) Build $($os.BuildNumber)"
    }
}
#endregion

#region Devices Directory
[SHiPSProvider(UseCache = $true)]
class ProcDevicesDirectory : SHiPSDirectory {
    ProcDevicesDirectory([string]$name) : base($name) {}
    
    [object[]] GetChildItem() {
        return @(
            [ProcDevicesBlock]::new('block')
            [ProcDevicesChar]::new('character')
        )
    }
}

class ProcDevicesBlock : SHiPSLeaf {
    ProcDevicesBlock([string]$name) : base($name) {}
    
    [string] GetContent() {
        $sb = [System.Text.StringBuilder]::new()
        [void]$sb.AppendLine("Block devices:")
        [void]$sb.AppendLine("  8 sd")
        [void]$sb.AppendLine(" 65 sd")
        [void]$sb.AppendLine("259 blkext")
        return $sb.ToString()
    }
}

class ProcDevicesChar : SHiPSLeaf {
    ProcDevicesChar([string]$name) : base($name) {}
    
    [string] GetContent() {
        $sb = [System.Text.StringBuilder]::new()
        [void]$sb.AppendLine("Character devices:")
        [void]$sb.AppendLine("  1 mem")
        [void]$sb.AppendLine("  4 tty")
        [void]$sb.AppendLine("  5 console")
        [void]$sb.AppendLine("136 pts")
        return $sb.ToString()
    }
}
#endregion

#region Process Directories
[SHiPSProvider(UseCache = $false)]
class ProcProcessDirectory : SHiPSDirectory {
    hidden [int]$ProcessId

    ProcProcessDirectory([string]$name) : base($name) {
        $this.ProcessId = [int]$name
    }

    ProcProcessDirectory([string]$name, [int]$procid) : base($name) {
        $this.ProcessId = $procid
    }

    [object[]] GetChildItem() {
        if (-not (Get-Process -Id $this.ProcessId -ErrorAction SilentlyContinue)) {
            return @()
        }

        return @(
            [ProcProcessCmdline]::new('cmdline', $this.ProcessId)
            [ProcProcessStatus]::new('status', $this.ProcessId)
            [ProcProcessStat]::new('stat', $this.ProcessId)
            [ProcProcessEnviron]::new('environ', $this.ProcessId)
            [ProcProcessMaps]::new('maps', $this.ProcessId)
        )
    }
}

# /proc/self: the same entries as /proc/<PID> for the current PowerShell process.
[SHiPSProvider(UseCache = $false)]
class ProcSelfDirectory : ProcProcessDirectory {
    ProcSelfDirectory([string]$name) : base($name, $global:PID) {}
}

class ProcProcessCmdline : SHiPSLeaf {
    hidden [int]$ProcessId

    ProcProcessCmdline([string]$name, [int]$procid) : base($name) {
        $this.ProcessId = $procid
    }

    # Linux format: argv joined by NUL with a trailing NUL. The Windows command line is
    # split with CommandLineToArgvW, so quoted arguments containing spaces stay intact.
    # Processes whose command line can't be read (protected, Idle, System) are empty,
    # like Linux kernel threads.
    [string] GetContent() {
        $process = Get-Process -Id $this.ProcessId -ErrorAction SilentlyContinue
        if (-not $process) { return '' }
        $argv = Split-ProcCommandLine (Get-ProcCommandLine $process)
        if ($argv.Count -eq 0) { return '' }
        return ($argv -join "`0") + "`0"
    }
}

class ProcProcessStatus : SHiPSLeaf {
    hidden [int]$ProcessId

    ProcProcessStatus([string]$name, [int]$procid) : base($name) {
        $this.ProcessId = $procid
    }

    [string] GetContent() {
        $process = Get-Process -Id $this.ProcessId -ErrorAction SilentlyContinue
        if (-not $process) { return '' }
        $kB = { param($bytes) "$([math]::Round([double]$bytes / 1KB)) kB" }
        $threads = Get-ProcProperty $process 'Threads'
        $sb = [System.Text.StringBuilder]::new()
        [void]$sb.AppendLine("Name:`t$(Get-ProcComm $process)")
        [void]$sb.AppendLine("State:`t$(Get-ProcState $process)")
        [void]$sb.AppendLine("Tgid:`t$($process.Id)")
        [void]$sb.AppendLine("Pid:`t$($process.Id)")
        [void]$sb.AppendLine("PPid:`t$(Get-ProcParentId $process)")
        [void]$sb.AppendLine("VmPeak:`t$(& $kB (Get-ProcProperty $process 'PeakVirtualMemorySize64' 0))")
        [void]$sb.AppendLine("VmSize:`t$(& $kB (Get-ProcProperty $process 'VirtualMemorySize64' 0))")
        [void]$sb.AppendLine("VmHWM:`t$(& $kB (Get-ProcProperty $process 'PeakWorkingSet64' 0))")
        [void]$sb.AppendLine("VmRSS:`t$(& $kB (Get-ProcProperty $process 'WorkingSet64' 0))")
        [void]$sb.AppendLine("VmData:`t$(& $kB (Get-ProcProperty $process 'PrivateMemorySize64' 0))")
        [void]$sb.AppendLine("Threads:`t$(if ($threads) { $threads.Count } else { 0 })")
        return $sb.ToString()
    }
}

class ProcProcessStat : SHiPSLeaf {
    hidden [int]$ProcessId

    ProcProcessStat([string]$name, [int]$procid) : base($name) {
        $this.ProcessId = $procid
    }

    # All 52 fields of Linux /proc/<pid>/stat, in order (see proc(5)). Fields Windows has
    # no equivalent for are 0. Mappings: session = Windows session id, priority = 20+nice
    # (from the priority class), starttime = clock ticks since boot, rss = 4 KiB pages.
    [string] GetContent() {
        $process = Get-Process -Id $this.ProcessId -ErrorAction SilentlyContinue
        if (-not $process) { return '' }

        $start = Get-ProcProperty $process 'StartTime'
        $startTicks = if ($start) { [long][math]::Max(0, ($start - (Get-ProcBootTime)).TotalSeconds * 100) } else { 0 }
        $nice = Get-ProcNice $process
        $threads = Get-ProcProperty $process 'Threads'

        $fields = [System.Collections.Generic.List[object]]::new()
        $fields.AddRange([object[]]@(
            $process.Id                                                      # 1  pid
            "($(Get-ProcComm $process))"                                     # 2  comm
            (Get-ProcState $process).Substring(0, 1)                         # 3  state
            (Get-ProcParentId $process)                                      # 4  ppid
            $process.Id                                                      # 5  pgrp
            (Get-ProcProperty $process 'SessionId' 0)                        # 6  session
            0, -1, 0                                                         # 7  tty_nr, 8 tpgid, 9 flags
            0, 0, 0, 0                                                       # 10-13 minflt cminflt majflt cmajflt
            (Get-ProcTicks (Get-ProcProperty $process 'UserProcessorTime' ([TimeSpan]::Zero)))        # 14 utime
            (Get-ProcTicks (Get-ProcProperty $process 'PrivilegedProcessorTime' ([TimeSpan]::Zero)))  # 15 stime
            0, 0                                                             # 16 cutime, 17 cstime
            (20 + $nice), $nice                                              # 18 priority, 19 nice
            $(if ($threads) { $threads.Count } else { 0 })                   # 20 num_threads
            0                                                                # 21 itrealvalue
            $startTicks                                                      # 22 starttime
            (Get-ProcProperty $process 'VirtualMemorySize64' 0)              # 23 vsize (bytes)
            [long]((Get-ProcProperty $process 'WorkingSet64' 0) / 4096)      # 24 rss (pages)
            '18446744073709551615'                                           # 25 rsslim (unlimited)
        ))
        while ($fields.Count -lt 52) { $fields.Add(0) }                      # 26-52
        return $fields -join ' '
    }
}

class ProcProcessEnviron : SHiPSLeaf {
    hidden [int]$ProcessId

    ProcProcessEnviron([string]$name, [int]$procid) : base($name) {
        $this.ProcessId = $procid
    }

    [string] GetContent() {
        # Only our own environment is readable. Like Linux reading another user's
        # environ, anything else is an access error rather than fake content.
        if ($this.ProcessId -ne $global:PID) {
            throw [System.UnauthorizedAccessException]::new("Reading the environment of process $($this.ProcessId) is not supported; only /proc/self/environ is readable.")
        }
        $sb = [System.Text.StringBuilder]::new()
        foreach ($var in Get-ChildItem Env:) {
            [void]$sb.Append("$($var.Name)=$($var.Value)`0")
        }
        return $sb.ToString()
    }
}

class ProcProcessMaps : SHiPSLeaf {
    hidden [int]$ProcessId

    ProcProcessMaps([string]$name, [int]$procid) : base($name) {
        $this.ProcessId = $procid
    }

    # One line per loaded module, in Linux format: "start-end perms offset dev inode path"
    # with bare lowercase hex addresses. Windows only exposes module images, not every
    # mapping, so heaps and stacks are absent.
    [string] GetContent() {
        $process = Get-Process -Id $this.ProcessId -ErrorAction SilentlyContinue
        if (-not $process) { return '' }
        try {
            $modules = $process.Modules
        } catch {
            throw [System.UnauthorizedAccessException]::new("Cannot read the modules of process $($this.ProcessId): $($_.Exception.InnerException.Message)")
        }
        $sb = [System.Text.StringBuilder]::new()
        foreach ($module in $modules) {
            $base = $module.BaseAddress.ToInt64()
            [void]$sb.AppendLine(('{0:x}-{1:x} r-xp 00000000 00:00 0                          {2}' -f $base, ($base + $module.ModuleMemorySize), $module.FileName))
        }
        return $sb.ToString()
    }
}
#endregion

#region Drive helpers
function Mount-ProcDrive {
    <#
    .SYNOPSIS
        Creates the proc: drive in the global scope (idempotent).
    .DESCRIPTION
        New-PSDrive defaults to the caller's local scope, so a drive created inside a
        script or function disappears when it returns. This always creates it globally.
    #>
    [CmdletBinding()]
    param(
        [string]$Name = 'proc',
        [switch]$PassThru
    )
    $drive = Get-PSDrive -Name $Name -Scope Global -ErrorAction SilentlyContinue
    if ($drive) {
        Write-Verbose "Drive '$($Name):' already exists"
    } else {
        $drive = New-PSDrive -Name $Name -PSProvider SHiPS -Root 'ProcFileSystem#ProcRoot' -Scope Global -ErrorAction Stop
    }
    if ($PassThru) { $drive }
}

function Dismount-ProcDrive {
    <#
    .SYNOPSIS
        Removes the proc: drive from the global scope, if present.
    #>
    [CmdletBinding()]
    param([string]$Name = 'proc')
    if (Get-PSDrive -Name $Name -Scope Global -ErrorAction SilentlyContinue) {
        Remove-PSDrive -Name $Name -Scope Global -Force
    }
}

Export-ModuleMember -Function Mount-ProcDrive, Dismount-ProcDrive
#endregion
