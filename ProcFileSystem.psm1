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

[DllImport("kernel32.dll", SetLastError = true)]
static extern bool GetSystemTimes(out long idleTime, out long kernelTime, out long userTime);
[DllImport("kernel32.dll")]
public static extern bool IsProcessorFeaturePresent(uint feature);

// Idle, kernel (which includes idle) and user time summed over all CPUs, in 100 ns units.
public static long[] SystemTimes() {
    long idle, kernel, user;
    if (!GetSystemTimes(out idle, out kernel, out user)) throw new System.ComponentModel.Win32Exception();
    return new long[] { idle, kernel, user };
}

// Load average. Windows keeps no run-queue average, so sample CPU demand (busy fraction
// x CPU count, i.e. "CPUs' worth of work") every 5 s and apply the same exponential
// decay Linux uses for its 1/5/15-minute averages. The first sample seeds all three.
static System.Threading.Timer loadTimer;
static readonly object loadLock = new object();
static readonly double[] loadAvg = new double[3];
static readonly double[] loadDecay = { Math.Exp(-5.0 / 60), Math.Exp(-5.0 / 300), Math.Exp(-5.0 / 900) };
static long lastIdle, lastBusy;
static bool loadSeeded;

public static void StartLoadSampler() {
    lock (loadLock) {
        if (loadTimer != null) return;
        long idle, kernel, user;
        GetSystemTimes(out idle, out kernel, out user);
        lastIdle = idle; lastBusy = (kernel - idle) + user;
        loadTimer = new System.Threading.Timer(_ => SampleLoad(), null, 1000, 5000);
    }
}

static void SampleLoad() {
    long idle, kernel, user;
    if (!GetSystemTimes(out idle, out kernel, out user)) return;
    long busy = (kernel - idle) + user;
    lock (loadLock) {
        double dBusy = busy - lastBusy, dTotal = dBusy + (idle - lastIdle);
        lastIdle = idle; lastBusy = busy;
        if (dTotal <= 0) return;
        double demand = Environment.ProcessorCount * dBusy / dTotal;
        for (int i = 0; i < 3; i++)
            loadAvg[i] = loadSeeded ? loadAvg[i] * loadDecay[i] + demand * (1 - loadDecay[i]) : demand;
        loadSeeded = true;
    }
}

public static double[] LoadAverage() { lock (loadLock) { return (double[])loadAvg.Clone(); } }
'@
}
[ProcFs.Native]::StartLoadSampler()

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

function Get-ProcSystemTimes { [ProcFs.Native]::SystemTimes() }
function Get-ProcLoadAverage { [ProcFs.Native]::LoadAverage() }

function Get-ProcCpuFlags {
    # Linux /proc/cpuinfo flag names for the features Windows reports through
    # IsProcessorFeaturePresent (PF_* constants from winnt.h).
    # (A list of pairs, not [ordered]@{}: an int indexer on an ordered dictionary is
    # positional, so $map[3] would return the fourth entry rather than key 3.)
    $map = @(@(3, 'mmx'), @(6, 'sse'), @(8, 'tsc'), @(9, 'pae'), @(10, 'sse2'), @(12, 'nx'), @(13, 'pni'),
             @(14, 'cx16'), @(17, 'xsave'), @(28, 'rdrand'), @(32, 'rdtscp'), @(36, 'ssse3'),
             @(37, 'sse4_1'), @(38, 'sse4_2'), @(39, 'avx'), @(40, 'avx2'), @(41, 'avx512f'))
    $flags = foreach ($pair in $map) { if ([ProcFs.Native]::IsProcessorFeaturePresent($pair[0])) { $pair[1] } }
    if ([Environment]::Is64BitOperatingSystem) { $flags = @('fpu') + $flags + 'lm' }
    $flags -join ' '
}

function Get-ProcRunnable {
    # Approximates Linux's procs_running (running + runnable): threads waiting in the
    # ready queue plus the number of CPUs' worth of work currently executing.
    $queue = (Get-CimInstance -ClassName Win32_PerfRawData_PerfOS_System).ProcessorQueueLength
    $busy = (Get-CimInstance -ClassName Win32_PerfFormattedData_PerfOS_Processor -Filter "Name = '_Total'").PercentProcessorTime
    [int]$queue + [int][math]::Round([Environment]::ProcessorCount * $busy / 100)
}

function ConvertTo-ProcMountPath {
    # /proc/mounts escapes whitespace as octal so lines can be split on spaces. Linux also
    # escapes backslash (\134), but every Windows path is full of them, so they are left
    # as-is to keep the file readable.
    param([string]$Path)
    $Path -replace ' ', '\040' -replace "`t", '\011' -replace "`n", '\012'
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
        $flags = Get-ProcCpuFlags
        $processorNum = 0
        $socket = 0
        foreach ($cpu in Get-CimInstance -ClassName Win32_Processor) {
            # Win32_Processor.Family is a WMI enum code (e.g. 107) and there is no Model
            # property; the real CPUID values are in Description:
            # "AMD64 Family 25 Model 80 Stepping 0".
            $family = $model = $stepping = 0
            if ($cpu.Description -match 'Family (\d+) Model (\d+) Stepping (\d+)') {
                $family, $model, $stepping = $Matches[1], $Matches[2], $Matches[3]
            }
            $cores = [int]$cpu.NumberOfCores
            $logical = [int]$cpu.NumberOfLogicalProcessors
            $threadsPerCore = [math]::Max(1, $logical / [math]::Max(1, $cores))
            for ($i = 0; $i -lt $logical; $i++) {
                [void]$sb.AppendLine("processor`t: $processorNum")
                [void]$sb.AppendLine("vendor_id`t: $($cpu.Manufacturer)")
                [void]$sb.AppendLine("cpu family`t: $family")
                [void]$sb.AppendLine("model`t`t: $model")
                [void]$sb.AppendLine("model name`t: $($cpu.Name.Trim())")
                [void]$sb.AppendLine("stepping`t: $stepping")
                [void]$sb.AppendLine("cpu MHz`t`t: $($cpu.CurrentClockSpeed).000")
                [void]$sb.AppendLine("cache size`t: $($cpu.L3CacheSize) KB")
                [void]$sb.AppendLine("physical id`t: $socket")
                [void]$sb.AppendLine("siblings`t: $logical")
                [void]$sb.AppendLine("core id`t`t: $([math]::Floor($i / $threadsPerCore))")
                [void]$sb.AppendLine("cpu cores`t: $cores")
                [void]$sb.AppendLine("flags`t`t: $flags")
                [void]$sb.AppendLine()
                $processorNum++
            }
            $socket++
        }
        return $sb.ToString()
    }
}
#endregion

#region Memory Info
class ProcMemInfo : SHiPSLeaf {
    ProcMemInfo([string]$name) : base($name) {}

    # Windows -> Linux mapping:
    #   MemFree      free + zeroed page lists (truly unused pages)
    #   MemAvailable Available Bytes (free + standby: what can be handed out without paging)
    #   Cached       the standby lists, Windows' equivalent of the page cache
    #   Dirty        the modified page list (written-to pages not yet flushed)
    #   Slab         kernel pools; SReclaimable = paged pool, SUnreclaim = non-paged pool
    #   Swap*        page files only (TotalVirtualMemorySize is RAM + page file)
    #   CommitLimit / Committed_AS   commit limit and committed bytes
    [string] GetContent() {
        $mem = Get-CimInstance -ClassName Win32_PerfRawData_PerfOS_Memory
        $total = (Get-CimInstance -ClassName Win32_ComputerSystem).TotalPhysicalMemory
        $swapTotal = $swapUsed = 0
        foreach ($pf in Get-CimInstance -ClassName Win32_PageFileUsage) {
            $swapTotal += [long]$pf.AllocatedBaseSize * 1MB
            $swapUsed += [long]$pf.CurrentUsage * 1MB
        }
        $standby = [long]$mem.StandbyCacheCoreBytes + [long]$mem.StandbyCacheNormalPriorityBytes + [long]$mem.StandbyCacheReserveBytes
        $rows = [ordered]@{
            MemTotal     = $total
            MemFree      = $mem.FreeAndZeroPageListBytes
            MemAvailable = $mem.AvailableBytes
            Buffers      = 0
            Cached       = $standby
            SwapCached   = 0
            SwapTotal    = $swapTotal
            SwapFree     = $swapTotal - $swapUsed
            Dirty        = $mem.ModifiedPageListBytes
            Shmem        = 0
            Slab         = [long]$mem.PoolPagedBytes + [long]$mem.PoolNonpagedBytes
            SReclaimable = $mem.PoolPagedBytes
            SUnreclaim   = $mem.PoolNonpagedBytes
            CommitLimit  = $mem.CommitLimit
            Committed_AS = $mem.CommittedBytes
        }
        $sb = [System.Text.StringBuilder]::new()
        foreach ($key in $rows.Keys) {
            [void]$sb.AppendLine(('{0,-15} {1,8} kB' -f "$($key):", [long]([double]$rows[$key] / 1KB)))
        }
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

    # "<seconds since boot> <idle seconds summed over all CPUs>", as on Linux.
    [string] GetContent() {
        $uptime = [Environment]::TickCount64 / 1000.0
        $idle = (Get-ProcSystemTimes)[0] / 1e7
        return [string]::Format([cultureinfo]::InvariantCulture, '{0:F2} {1:F2}', $uptime, $idle)
    }
}
#endregion

#region Load Average
class ProcLoadAvg : SHiPSLeaf {
    ProcLoadAvg([string]$name) : base($name) {}

    # "<1m> <5m> <15m> <runnable>/<total threads> <newest pid>". The averages are of CPU
    # demand, sampled every 5 s from module load (see StartLoadSampler); Windows has no
    # run-queue average. Windows PIDs are not sequential, so the last field is the PID of
    # the most recently started process rather than the highest one.
    [string] GetContent() {
        $avg = Get-ProcLoadAverage
        $processes = Get-Process
        $threads = 0
        $newest = $null
        foreach ($p in $processes) {
            $t = Get-ProcProperty $p 'Threads'
            if ($t) { $threads += $t.Count }
            $start = Get-ProcProperty $p 'StartTime'
            if ($start -and (-not $newest -or $start -gt $newest.Start)) { $newest = @{ Id = $p.Id; Start = $start } }
        }
        $inv = [cultureinfo]::InvariantCulture
        return [string]::Format($inv, '{0:F2} {1:F2} {2:F2} {3}/{4} {5}', $avg[0], $avg[1], $avg[2],
            (Get-ProcRunnable), $threads, $(if ($newest) { $newest.Id } else { 0 }))
    }
}
#endregion

#region Stat
class ProcStat : SHiPSLeaf {
    ProcStat([string]$name) : base($name) {}

    # Cumulative counters since boot, as on Linux, so tools can diff two reads.
    # CPU columns are clock ticks (USER_HZ = 100) from the raw processor counters
    # (100 ns units). Windows' privileged time includes interrupt and DPC time, so
    # system = privileged - interrupt - DPC; irq = interrupt, softirq = DPC.
    [string] GetContent() {
        # Instances are "N", or "group,N" on systems with more than 64 logical CPUs (which
        # also have per-group "_Total" instances); order them by group, then number.
        $cpus = Get-CimInstance -ClassName Win32_PerfRawData_PerfOS_Processor |
            Where-Object Name -notlike '*_Total' |
            Sort-Object { [int](($_.Name -split ',')[0]) }, { [int](($_.Name -split ',')[-1]) }
        $lines = [System.Collections.Generic.List[string]]::new()
        $sum = [long[]]::new(7)
        $intr = 0L
        foreach ($cpu in $cpus) {
            $user = [long]($cpu.PercentUserTime / 1e5)
            $irq = [long]($cpu.PercentInterruptTime / 1e5)
            $soft = [long]($cpu.PercentDPCTime / 1e5)
            $system = [math]::Max(0, [long]($cpu.PercentPrivilegedTime / 1e5) - $irq - $soft)
            $idle = [long]($cpu.PercentIdleTime / 1e5)
            $vals = [long[]]@($user, 0, $system, $idle, 0, $irq, $soft)
            for ($i = 0; $i -lt 7; $i++) { $sum[$i] += $vals[$i] }
            $intr += [long]$cpu.InterruptsPersec
            $lines.Add("cpu$($lines.Count) $($vals -join ' ') 0 0 0")
        }
        $sys = Get-CimInstance -ClassName Win32_PerfRawData_PerfOS_System
        $btime = [DateTimeOffset]::new((Get-ProcBootTime)).ToUnixTimeSeconds()

        $sb = [System.Text.StringBuilder]::new()
        [void]$sb.AppendLine("cpu  $($sum -join ' ') 0 0 0")
        foreach ($l in $lines) { [void]$sb.AppendLine($l) }
        [void]$sb.AppendLine("intr $intr")
        [void]$sb.AppendLine("ctxt $($sys.ContextSwitchesPersec)")
        [void]$sb.AppendLine("btime $btime")
        # Linux counts forks since boot; Windows has no such counter, so this is the
        # current process count.
        [void]$sb.AppendLine("processes $($sys.Processes)")
        [void]$sb.AppendLine("procs_running $(Get-ProcRunnable)")
        [void]$sb.AppendLine("procs_blocked 0")
        return $sb.ToString()
    }
}
#endregion

#region Mounts
class ProcMounts : SHiPSLeaf {
    ProcMounts([string]$name) : base($name) {}

    # "<device> <mount point> <fstype> <options> 0 0". Local volumes use their volume
    # GUID path as the device; mapped network drives use the UNC share and type cifs.
    [string] GetContent() {
        $volumes = @{}
        foreach ($v in Get-CimInstance -ClassName Win32_Volume) {
            if ($v.DriveLetter) { $volumes[$v.DriveLetter] = $v.DeviceID.TrimEnd('\') }
        }
        $sb = [System.Text.StringBuilder]::new()
        foreach ($disk in Get-CimInstance -ClassName Win32_LogicalDisk) {
            if (-not $disk.FileSystem) { continue }   # empty card reader / optical drive
            if ($disk.DriveType -eq 4) {
                $device = $disk.ProviderName; $type = 'cifs'
            } else {
                $device = if ($volumes[$disk.DeviceID]) { $volumes[$disk.DeviceID] } else { $disk.DeviceID }
                $type = $disk.FileSystem.ToLowerInvariant()
            }
            $options = if ($disk.Access -eq 1) { 'ro' } else { 'rw' }
            [void]$sb.AppendLine("$(ConvertTo-ProcMountPath $device) $(ConvertTo-ProcMountPath "$($disk.DeviceID)\") $type $options 0 0")
        }
        return $sb.ToString()
    }
}
#endregion

#region Cmdline
class ProcCmdline : SHiPSLeaf {
    ProcCmdline([string]$name) : base($name) {}

    # Linux /proc/cmdline is the kernel boot command line. The Windows equivalent is the
    # boot loader options, which the kernel records in SystemStartOptions.
    [string] GetContent() {
        $options = (Get-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control' -Name SystemStartOptions -ErrorAction SilentlyContinue).SystemStartOptions
        return (([string]$options).Trim() -replace '\s+', ' ') + "`n"
    }
}
#endregion

#region Filesystems
class ProcFilesystems : SHiPSLeaf {
    ProcFilesystems([string]$name) : base($name) {}

    # Filesystem drivers currently loaded in the kernel, with Linux names where one exists.
    # "nodev" marks filesystems that are not backed by a block device.
    [string] GetContent() {
        $known = [ordered]@{
            'Ntfs' = "`tntfs"; 'ReFS' = "`trefs"; 'fastfat' = "`tvfat"; 'exfat' = "`texfat"
            'udfs' = "`tudf"; 'cdfs' = "`tiso9660"; 'Npfs' = "nodev`tnpfs"; 'Msfs' = "nodev`tmsfs"
            'rdbss' = "nodev`tcifs"; 'MRxDAV' = "nodev`twebdav"; 'P9Rdr' = "nodev`t9p"
        }
        $running = @{}
        foreach ($d in Get-CimInstance -ClassName Win32_SystemDriver -Filter "State = 'Running'") { $running[$d.Name] = $true }
        $sb = [System.Text.StringBuilder]::new()
        foreach ($name in $known.Keys) {
            if ($running[$name]) { [void]$sb.AppendLine($known[$name]) }
        }
        return $sb.ToString()
    }
}
#endregion

#region Swaps
class ProcSwaps : SHiPSLeaf {
    ProcSwaps([string]$name) : base($name) {}

    [string] GetContent() {
        $sb = [System.Text.StringBuilder]::new()
        [void]$sb.AppendLine("Filename`t`t`t`tType`t`tSize`t`tUsed`t`tPriority")
        foreach ($pf in Get-CimInstance -ClassName Win32_PageFileUsage) {
            $size = [long]$pf.AllocatedBaseSize * 1024   # MB -> kB
            $used = [long]$pf.CurrentUsage * 1024
            [void]$sb.AppendLine("$($pf.Name)`t`t`t`tfile`t`t$size`t`t$used`t`t-2")
        }
        return $sb.ToString()
    }
}
#endregion

#region Partitions
class ProcPartitions : SHiPSLeaf {
    ProcPartitions([string]$name) : base($name) {}

    # Linux layout: one row per disk, then one per partition, sizes in 1 KiB blocks.
    # Names follow the sd convention numerically: disk0, disk0p1, ... (major 8,
    # minor = 16 * disk + partition).
    [string] GetContent() {
        $sb = [System.Text.StringBuilder]::new()
        [void]$sb.AppendLine('major minor  #blocks  name')
        [void]$sb.AppendLine()
        $parts = Get-CimInstance -ClassName Win32_DiskPartition
        foreach ($disk in Get-CimInstance -ClassName Win32_DiskDrive | Sort-Object Index) {
            [void]$sb.AppendLine(('{0,4} {1,7} {2,10} {3}' -f 8, (16 * $disk.Index), [long]($disk.Size / 1KB), "disk$($disk.Index)"))
            foreach ($part in $parts | Where-Object DiskIndex -eq $disk.Index | Sort-Object Index) {
                $n = $part.Index + 1
                [void]$sb.AppendLine(('{0,4} {1,7} {2,10} {3}' -f 8, (16 * $disk.Index + $n), [long]($part.Size / 1KB), "disk$($disk.Index)p$n"))
            }
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
