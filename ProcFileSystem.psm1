#Requires -Modules SHiPS
using namespace Microsoft.PowerShell.SHiPS

<#
.SYNOPSIS
    PowerShell SHiPS provider that mimics Linux /proc filesystem
.DESCRIPTION
    Creates a proc: drive that provides read-only access to system information
    similar to Linux /proc pseudo-filesystem
.NOTES
    Requires: PowerShell 7+ and SHiPS module (Install-Module -Name SHiPS)
#>

#region Root Directory
[SHiPSProvider(UseCache = $true)]
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
[SHiPSProvider(UseCache = $true)]
class ProcCpuInfo : SHiPSLeaf {
    ProcCpuInfo([string]$name) : base($name) {}
    
    static [string] GetContent() {
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
[SHiPSProvider(UseCache = $true)]
class ProcMemInfo : SHiPSLeaf {
    ProcMemInfo([string]$name) : base($name) {}
    
    static [string] GetContent() {
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
[SHiPSProvider(UseCache = $true)]
class ProcVersion : SHiPSLeaf {
    ProcVersion([string]$name) : base($name) {}
    
    static [string] GetContent() {
        $os = Get-CimInstance -ClassName Win32_OperatingSystem
        return "$($os.Caption) (build $($os.BuildNumber)) $($os.OSArchitecture) $($os.Version)"
    }
}
#endregion

#region Uptime
[SHiPSProvider(UseCache = $false)]
class ProcUptime : SHiPSLeaf {
    ProcUptime([string]$name) : base($name) {}
    
    static [string] GetContent() {
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
[SHiPSProvider(UseCache = $false)]
class ProcLoadAvg : SHiPSLeaf {
    ProcLoadAvg([string]$name) : base($name) {}
    
    static [string] GetContent() {
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
[SHiPSProvider(UseCache = $false)]
class ProcStat : SHiPSLeaf {
    ProcStat([string]$name) : base($name) {}
    
    static [string] GetContent() {
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
[SHiPSProvider(UseCache = $true)]
class ProcMounts : SHiPSLeaf {
    ProcMounts([string]$name) : base($name) {}
    
    static [string] GetContent() {
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
[SHiPSProvider(UseCache = $true)]
class ProcCmdline : SHiPSLeaf {
    ProcCmdline([string]$name) : base($name) {}
    
    static [string] GetContent() {
        # Return the command line of the current PowerShell process
        $currentProc = Get-Process -Id $PID
        return $currentProc.Path
    }
}
#endregion

#region Filesystems
[SHiPSProvider(UseCache = $true)]
class ProcFilesystems : SHiPSLeaf {
    ProcFilesystems([string]$name) : base($name) {}
    
    static [string] GetContent() {
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
[SHiPSProvider(UseCache = $true)]
class ProcSwaps : SHiPSLeaf {
    ProcSwaps([string]$name) : base($name) {}
    
    static [string] GetContent() {
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
[SHiPSProvider(UseCache = $true)]
class ProcPartitions : SHiPSLeaf {
    ProcPartitions([string]$name) : base($name) {}
    
    static [string] GetContent() {
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
[SHiPSProvider(UseCache = $true)]
class ProcModules : SHiPSLeaf {
    ProcModules([string]$name) : base($name) {}
    
    static [string] GetContent() {
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
    
    static [string] GetContent() {
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
    
    static [string] GetContent() {
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
    
    static [string] GetContent() {
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
    
    static [string] GetContent() {
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
    
    static [string] GetContent() {
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
    
    static [string] GetContent() {
        return $env:COMPUTERNAME
    }
}

class ProcSysKernelOstype : SHiPSLeaf {
    ProcSysKernelOstype([string]$name) : base($name) {}
    
    static [string] GetContent() {
        return "Windows_NT"
    }
}

class ProcSysKernelOsrelease : SHiPSLeaf {
    ProcSysKernelOsrelease([string]$name) : base($name) {}
    
    static [string] GetContent() {
        $os = Get-CimInstance -ClassName Win32_OperatingSystem
        return $os.Version
    }
}

class ProcSysKernelVersion : SHiPSLeaf {
    ProcSysKernelVersion([string]$name) : base($name) {}
    
    static [string] GetContent() {
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
    
    static [string] GetContent() {
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
    
    static [string] GetContent() {
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

#region Self Directory
[SHiPSProvider(UseCache = $false)]
class ProcSelfDirectory : SHiPSDirectory {
    ProcSelfDirectory([string]$name) : base($name) {}
    
    [object[]] GetChildItem() {
        return @(
            [ProcProcessCmdline]::new('cmdline', $PID)
            [ProcProcessStatus]::new('status', $PID)
            [ProcProcessStat]::new('stat', $PID)
            [ProcProcessEnviron]::new('environ', $PID)
        )
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

class ProcProcessCmdline : SHiPSLeaf {
    hidden [int]$ProcessId
    
    ProcProcessCmdline([string]$name, [int]$procid) : base($name) {
        $this.ProcessId = $procid
    }
    
    [string] GetContent() {
        $process = Get-Process -Id $this.ProcessId -ErrorAction SilentlyContinue
        if ($process) {
            $cmdline = $process.CommandLine
            if ($cmdline) {
                return $cmdline -replace ' ', "`0"
            }
            return $process.Path
        }
        return ""
    }
}

class ProcProcessStatus : SHiPSLeaf {
    hidden [int]$ProcessId
    
    ProcProcessStatus([string]$name, [int]$procid) : base($name) {
        $this.ProcessId = $procid
    }
    
    [string] GetContent() {
        $process = Get-Process -Id $this.ProcessId -ErrorAction SilentlyContinue
        if ($process) {
            $sb = [System.Text.StringBuilder]::new()
            [void]$sb.AppendLine("Name:`t$($process.ProcessName)")
            [void]$sb.AppendLine("State:`tR (running)")
            [void]$sb.AppendLine("Pid:`t$($process.Id)")
            [void]$sb.AppendLine("PPid:`t$($process.Parent.Id)")
            [void]$sb.AppendLine("Threads:`t$($process.Threads.Count)")
            [void]$sb.AppendLine("VmSize:`t$([math]::Round($process.WorkingSet64 / 1KB)) kB")
            [void]$sb.AppendLine("VmRSS:`t$([math]::Round($process.WorkingSet64 / 1KB)) kB")
            return $sb.ToString()
        }
        return ""
    }
}

class ProcProcessStat : SHiPSLeaf {
    hidden [int]$ProcessId
    
    ProcProcessStat([string]$name, [int]$procid) : base($name) {
        $this.ProcessId = $procid
    }
    
    [string] GetContent() {
        $process = Get-Process -Id $this.ProcessId -ErrorAction SilentlyContinue
        if ($process) {
            $state = 'R'
            $ppid = if ($process.Parent) { $process.Parent.Id } else { 0 }
            $priority = $process.BasePriority
            $threads = $process.Threads.Count
            $startTime = [DateTimeOffset]$process.StartTime
            
            return "$($process.Id) ($($process.ProcessName)) $state $ppid 0 0 0 0 0 0 0 0 0 0 $priority 0 $threads 0 $($startTime.ToUnixTimeSeconds())"
        }
        return ""
    }
}

class ProcProcessEnviron : SHiPSLeaf {
    hidden [int]$ProcessId
    
    ProcProcessEnviron([string]$name, [int]$procid) : base($name) {
        $this.ProcessId = $procid
    }
    
    [string] GetContent() {
        # Windows doesn't easily expose other process environments
        # Return current process environment if it's our PID
        if ($this.ProcessId -eq $PID) {
            $sb = [System.Text.StringBuilder]::new()
            foreach ($var in Get-ChildItem Env:) {
                [void]$sb.Append("$($var.Name)=$($var.Value)`0")
            }
            return $sb.ToString()
        }
        return "Access denied"
    }
}

class ProcProcessMaps : SHiPSLeaf {
    hidden [int]$ProcessId
    
    ProcProcessMaps([string]$name, [int]$procid) : base($name) {
        $this.ProcessId = $procid
    }
    
    [string] GetContent() {
        $process = Get-Process -Id $this.ProcessId -ErrorAction SilentlyContinue
        if ($process) {
            $sb = [System.Text.StringBuilder]::new()
            
            foreach ($module in $process.Modules) {
                $baseAddr = "0x{0:x16}" -f $module.BaseAddress.ToInt64()
                $endAddr = "0x{0:x16}" -f ($module.BaseAddress.ToInt64() + $module.ModuleMemorySize)
                [void]$sb.AppendLine("$baseAddr-$endAddr r-xp 00000000 00:00 0    $($module.FileName)")
            }
            
            return $sb.ToString()
        }
        return ""
    }
}
#endregion

# Export the root class
Export-ModuleMember -Function * -Cmdlet *
