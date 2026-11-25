#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
<#
    Pester tests for the proc: drive. Windows only.

        Invoke-Pester ./Tests                      # everything except installer tests
        Invoke-Pester ./Tests -TagFilter Installer # installer round trip (touches your
                                                   # module path and profile; see below)
#>

BeforeDiscovery {
    $script:IsWin = $IsWindows
}

BeforeAll {
    $repo = Split-Path $PSScriptRoot -Parent
    Import-Module (Join-Path $repo 'ProcFileSystem.psd1') -Force -WarningAction SilentlyContinue
    Mount-ProcDrive

    function Get-ProcLines([string]$Path) {
        (Get-Content $Path) -split "`r?`n" | Where-Object { $_ -ne '' }
    }
    function ConvertFrom-ProcHex4([string]$Hex) {
        $b = for ($i = 6; $i -ge 0; $i -= 2) { [Convert]::ToByte($Hex.Substring($i, 2), 16) }
        ([ipaddress][byte[]]$b).ToString()
    }
}

AfterAll {
    Dismount-ProcDrive
}

Describe 'Module' -Skip:(-not $IsWin) {
    It 'has a valid manifest that requires SHiPS' {
        $m = Test-ModuleManifest (Join-Path (Split-Path $PSScriptRoot -Parent) 'ProcFileSystem.psd1')
        $m.RequiredModules.Name | Should -Contain 'SHiPS'
    }

    It 'exports only the drive helpers' {
        (Get-Module ProcFileSystem).ExportedFunctions.Keys | Sort-Object | Should -Be @('Dismount-ProcDrive', 'Mount-ProcDrive')
    }

    It 'mounts globally even when called from a nested scope, and is idempotent' {
        Dismount-ProcDrive
        & { & { Mount-ProcDrive } }
        { Mount-ProcDrive } | Should -Not -Throw
        Get-PSDrive -Name proc -Scope Global -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
    }
}

Describe 'Root directory' -Skip:(-not $IsWin) {
    It 'lists the static entries' {
        $names = (Get-ChildItem proc:\).Name
        foreach ($n in 'cpuinfo', 'meminfo', 'stat', 'loadavg', 'uptime', 'version', 'cmdline', 'mounts',
                       'filesystems', 'swaps', 'partitions', 'modules', 'net', 'sys', 'devices', 'self') {
            $names | Should -Contain $n
        }
    }

    It 'shows a new process without -Force, and drops it once it exits' {
        $null = Get-ChildItem proc:\
        $p = Start-Process -FilePath ping -ArgumentList '-n', '30', '127.0.0.1' -PassThru -WindowStyle Hidden
        try {
            Start-Sleep -Milliseconds 500
            (Get-ChildItem proc:\).Name | Should -Contain "$($p.Id)"
        } finally {
            $p | Stop-Process -Force
        }
        $p.WaitForExit(5000) | Out-Null
        (Get-ChildItem proc:\).Name | Should -Not -Contain "$($p.Id)"
    }
}

Describe 'System files' -Skip:(-not $IsWin) {
    It '<_> is readable and non-empty' -ForEach @('cpuinfo', 'meminfo', 'stat', 'loadavg', 'uptime', 'version',
                                                  'mounts', 'filesystems', 'swaps', 'partitions', 'modules',
                                                  'sys\kernel\hostname', 'sys\kernel\ostype', 'sys\kernel\osrelease',
                                                  'sys\kernel\version', 'devices\block', 'devices\character') {
        Get-Content "proc:\$_" -ErrorAction Stop | Should -Not -BeNullOrEmpty
    }

    Context 'meminfo' {
        BeforeAll {
            $mem = @{}
            foreach ($l in Get-ProcLines proc:\meminfo) {
                if ($l -match '^(\w+):\s+(\d+) kB$') { $mem[$Matches[1]] = [long]$Matches[2] }
            }
        }
        It 'has every expected field' {
            foreach ($k in 'MemTotal', 'MemFree', 'MemAvailable', 'Buffers', 'Cached', 'SwapTotal', 'SwapFree',
                           'Dirty', 'Slab', 'SReclaimable', 'SUnreclaim', 'CommitLimit', 'Committed_AS') {
                $mem.Keys | Should -Contain $k
            }
        }
        It 'reports MemAvailable >= MemFree (it was a copy of MemFree)' {
            $mem.MemAvailable | Should -BeGreaterOrEqual $mem.MemFree
        }
        It 'reports SwapTotal as page files only (it was RAM + page file)' {
            $pf = (Get-CimInstance Win32_PageFileUsage | Measure-Object AllocatedBaseSize -Sum).Sum * 1024
            $mem.SwapTotal | Should -Be ([long]$pf)
        }
        It 'keeps Slab = SReclaimable + SUnreclaim' {
            $mem.Slab | Should -BeIn @(($mem.SReclaimable + $mem.SUnreclaim - 1)..($mem.SReclaimable + $mem.SUnreclaim + 1))
        }
    }

    Context 'stat' {
        It 'has one cpuN line per logical processor' {
            @(Get-ProcLines proc:\stat | Where-Object { $_ -match '^cpu\d+ ' }).Count | Should -Be ([Environment]::ProcessorCount)
        }
        It 'reports cumulative counters that grow between reads' {
            $a = ((Get-ProcLines proc:\stat)[0] -split '\s+')[1..7] | ForEach-Object { [long]$_ }
            Start-Sleep -Seconds 1
            $b = ((Get-ProcLines proc:\stat)[0] -split '\s+')[1..7] | ForEach-Object { [long]$_ }
            for ($i = 0; $i -lt 7; $i++) { $b[$i] | Should -BeGreaterOrEqual $a[$i] }
            # ~1 s x 100 ticks x CPUs elapsed; allow for read overhead
            (($b | Measure-Object -Sum).Sum - ($a | Measure-Object -Sum).Sum) | Should -BeGreaterThan (50 * [Environment]::ProcessorCount)
        }
        It 'reports btime within a minute of the CIM boot time' {
            $btime = [long](((Get-ProcLines proc:\stat) | Where-Object { $_ -like 'btime *' }) -split ' ')[1]
            $cim = [DateTimeOffset]::new((Get-CimInstance Win32_OperatingSystem).LastBootUpTime).ToUnixTimeSeconds()
            [math]::Abs($btime - $cim) | Should -BeLessThan 60
        }
    }

    It 'uptime matches the system tick count' {
        $up, $idle = (Get-Content proc:\uptime).Trim() -split ' '
        [math]::Abs([double]$up - [Environment]::TickCount64 / 1000) | Should -BeLessThan 5
        [double]$idle | Should -BeLessOrEqual ([double]$up * [Environment]::ProcessorCount)
    }

    It 'loadavg has the Linux layout' {
        (Get-Content proc:\loadavg).Trim() | Should -Match '^\d+\.\d\d \d+\.\d\d \d+\.\d\d \d+/\d+ \d+$'
    }

    It 'cpuinfo has one block per logical processor with real CPUID values' {
        $lines = Get-ProcLines proc:\cpuinfo
        @($lines | Where-Object { $_ -match '^processor\s*:' }).Count | Should -Be ([Environment]::ProcessorCount)
        ($lines | Where-Object { $_ -match '^model\s*:' } | Select-Object -First 1) | Should -Match ':\s*\d+$'
        if ([Environment]::Is64BitOperatingSystem) {
            ($lines | Where-Object { $_ -match '^flags' } | Select-Object -First 1) | Should -Match '\bsse2\b'
        }
    }

    It 'cmdline is the boot loader options' {
        $expected = ((Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control').SystemStartOptions.Trim() -replace '\s+', ' ')
        (Get-Content proc:\cmdline).Trim() | Should -Be $expected
    }

    It 'mounts lists the system drive with a real filesystem type' {
        $sys = $env:SystemDrive
        Get-ProcLines proc:\mounts | Where-Object { ($_ -split ' ')[1] -eq "$sys\" } | Should -Match ' (ntfs|refs) r[ow] 0 0$'
    }
}

Describe 'Process files' -Skip:(-not $IsWin) {
    It 'self has the same entries as a PID directory' {
        (Get-ChildItem proc:\self).Name | Should -Be (Get-ChildItem "proc:\$PID").Name
    }

    Context 'stat' {
        BeforeAll {
            $f = (Get-Content proc:\self\stat).Trim() -split ' '
            $cim = Get-CimInstance Win32_Process -Filter "ProcessId = $PID"
        }
        It 'has all 52 proc(5) fields' { $f.Count | Should -Be 52 }
        It 'has pid, comm and ppid in fields 1, 2 and 4' {
            $f[0] | Should -Be "$PID"
            $f[1] | Should -Be "(pwsh)"
            $f[3] | Should -Be "$($cim.ParentProcessId)"
        }
        It 'has num_threads in field 20' {
            [int]$f[19] | Should -BeGreaterThan 0
            [math]::Abs([int]$f[19] - (Get-Process -Id $PID).Threads.Count) | Should -BeLessThan 10
        }
        It 'has starttime as clock ticks since boot in field 22' {
            [long]$f[21] | Should -BeGreaterThan 0
            [long]$f[21] | Should -BeLessOrEqual ([long]([Environment]::TickCount64 / 10))
        }
        It 'has utime/stime in fields 14/15 (they were always 0)' {
            ([long]$f[13] + [long]$f[14]) | Should -BeGreaterThan 0
        }
    }

    It 'status reports virtual size separately from RSS' {
        $s = @{}; foreach ($l in Get-ProcLines proc:\self\status) { $k, $v = $l -split ":\s*", 2; $s[$k] = $v }
        $s.Pid | Should -Be "$PID"
        [long]($s.VmSize -replace ' kB') | Should -BeGreaterThan ([long]($s.VmRSS -replace ' kB'))
    }

    It 'cmdline keeps a quoted argument with a space as one NUL-separated argument' {
        $p = Start-Process -FilePath $env:ComSpec -ArgumentList '/c ping -n 30 127.0.0.1 >nul & rem "has space"' -PassThru -WindowStyle Hidden
        try {
            Start-Sleep -Milliseconds 500
            $raw = Get-Content "proc:\$($p.Id)\cmdline"
            $raw | Should -Match "`0$"
            $argv = $raw.TrimEnd("`0") -split "`0"
            $argv[-1] | Should -Be 'has space'
            $argv | Should -Contain 'ping'
        } finally {
            $p | Stop-Process -Force
        }
    }

    It '<_> stat and status do not throw for Idle (0) and System (4)' -ForEach 0, 4 {
        { Get-Content "proc:\$_\stat" -ErrorAction Stop } | Should -Not -Throw
        { Get-Content "proc:\$_\status" -ErrorAction Stop } | Should -Not -Throw
        ((Get-Content "proc:\$_\stat").Trim() -split ' ').Count | Should -Be 52
    }

    It 'environ is readable for self and an error for other processes' {
        (Get-Content proc:\self\environ) -split "`0" | Should -Contain "PATH=$env:PATH"
        { Get-Content proc:\4\environ -ErrorAction Stop } | Should -Throw
    }

    It 'maps uses the Linux address format' {
        (Get-ProcLines proc:\self\maps)[0] | Should -Match '^[0-9a-f]+-[0-9a-f]+ r-xp 00000000 00:00 0 +\S'
    }
}

Describe 'Network files' -Skip:(-not $IsWin) {
    It 'net has dev, route, arp, tcp, tcp6, udp and udp6' {
        (Get-ChildItem proc:\net).Name | Sort-Object | Should -Be @('arp', 'dev', 'route', 'tcp', 'tcp6', 'udp', 'udp6')
    }

    It 'dev lists every adapter by its full name' {
        $dev = Get-Content proc:\net\dev
        foreach ($a in Get-NetAdapterStatistics) { $dev | Should -Match ([regex]::Escape("$($a.Name):")) }
    }

    It 'tcp rows are Linux hex format and decode to live connections' {
        $rows = Get-ProcLines proc:\net\tcp | Select-Object -Skip 1
        $rows | ForEach-Object { $_ | Should -Match '^\s*\d+: [0-9A-F]{8}:[0-9A-F]{4} [0-9A-F]{8}:[0-9A-F]{4} [0-9A-F]{2} ' }
        $live = Get-NetTCPConnection | Where-Object { -not $_.LocalAddress.Contains(':') } |
            ForEach-Object { "$($_.LocalAddress):$($_.LocalPort)" }
        $decoded = foreach ($r in $rows) {
            $a, $p = (($r.Trim() -split '\s+')[1]) -split ':'
            "$(ConvertFrom-ProcHex4 $a):$([Convert]::ToInt32($p, 16))"
        }
        $found = @($decoded | Where-Object { $_ -in $live }).Count
        $found / [math]::Max(1, $decoded.Count) | Should -BeGreaterThan 0.9   # connections churn between reads
    }

    It 'tcp6 and udp6 hold only IPv6 sockets' {
        Get-ProcLines proc:\net\tcp6 | Select-Object -Skip 1 | ForEach-Object { $_ | Should -Match '^\s*\d+: [0-9A-F]{32}:[0-9A-F]{4} ' }
        Get-ProcLines proc:\net\udp | Select-Object -Skip 1 | ForEach-Object { $_ | Should -Match '^\s*\d+: [0-9A-F]{8}:[0-9A-F]{4} ' }
    }

    It 'route has 11 tab-separated columns and the real default gateway' {
        $rows = Get-ProcLines proc:\net\route | Select-Object -Skip 1
        $rows | ForEach-Object { ($_ -split "`t").Count | Should -Be 11 }
        $default = Get-NetRoute -DestinationPrefix '0.0.0.0/0' -PolicyStore ActiveStore -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($default) {
            $gateways = $rows | Where-Object { ($_ -split "`t")[1] -eq '00000000' } | ForEach-Object { ConvertFrom-ProcHex4 (($_ -split "`t")[2]) }
            $gateways | Should -Contain $default.NextHop
        }
    }

    It 'arp uses colon-separated lowercase MACs' {
        Get-ProcLines proc:\net\arp | Select-Object -Skip 1 | ForEach-Object { $_ | Should -Match ' 0x1 +0x[026] +([0-9a-f]{2}:){5}[0-9a-f]{2} ' }
    }
}

Describe 'Encoding helpers' -Skip:(-not $IsWin) {
    It 'encodes <Address> as <Hex>' -ForEach @(
        @{ Address = '127.0.0.1'; Hex = '0100007F' }
        @{ Address = '192.168.1.10'; Hex = '0A01A8C0' }
        @{ Address = '::1'; Hex = '00000000000000000000000001000000' }
    ) {
        InModuleScope ProcFileSystem -Parameters $_ { ConvertTo-ProcHexAddress $Address } | Should -Be $Hex
    }

    It 'encodes a /<Prefix> netmask as <Hex>' -ForEach @(
        @{ Prefix = 0; Hex = '00000000' }
        @{ Prefix = 24; Hex = '00FFFFFF' }
        @{ Prefix = 32; Hex = 'FFFFFFFF' }
    ) {
        InModuleScope ProcFileSystem -Parameters $_ { ConvertTo-ProcHexMask $Prefix } | Should -Be $Hex
    }

    It 'maps TCP state <State> to <Code>' -ForEach @(
        @{ State = 'Established'; Code = '01' }; @{ State = 'Listen'; Code = '0A' }
        @{ State = 'TimeWait'; Code = '06' }; @{ State = 'Bound'; Code = '07' }
    ) {
        InModuleScope ProcFileSystem -Parameters $_ { Get-ProcTcpState $State } | Should -Be $Code
    }

    It 'splits command lines like the C runtime' {
        InModuleScope ProcFileSystem { Split-ProcCommandLine 'app.exe "a b" c\"d' } | Should -Be @('app.exe', 'a b', 'c"d')
    }
}

# Opt-in: installs to the real CurrentUser module path and edits the real profile, then
# removes both. Skipped if ProcFileSystem is already installed there, so it never deletes
# a copy you installed yourself.
Describe 'Installer' -Tag Installer -Skip:(-not $IsWin) {
    BeforeAll {
        $installer = Join-Path (Split-Path $PSScriptRoot -Parent) 'Install-ProcDrive.ps1'
        $installed = Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'PowerShell\Modules\ProcFileSystem'
        $preexisting = Test-Path $installed
    }

    It 'leaves proc: mounted after the script returns, and uninstalls cleanly' {
        if ($preexisting) { Set-ItResult -Skipped -Because "ProcFileSystem is already installed at $installed"; return }
        $result = pwsh -NoProfile -Command "& '$installer' -Install *> `$null; [bool](Get-PSDrive proc -ErrorAction SilentlyContinue); & '$installer' -Uninstall -RemoveFiles *> `$null; [bool](Get-PSDrive proc -ErrorAction SilentlyContinue)"
        $result | Should -Be @('True', 'False')
        Test-Path $installed | Should -BeFalse
    }

    It 'mounts proc: in new sessions with -AddToProfile, and -RemoveFiles undoes it' {
        if ($preexisting) { Set-ItResult -Skipped -Because "ProcFileSystem is already installed at $installed"; return }
        $profileFile = $PROFILE.CurrentUserAllHosts
        $before = if (Test-Path $profileFile) { Get-Content $profileFile -Raw } else { $null }
        try {
            pwsh -NoProfile -Command "& '$installer' -Install -AddToProfile *> `$null"
            pwsh -Command '[bool](Get-PSDrive proc -ErrorAction SilentlyContinue)' | Should -Be 'True'
            pwsh -NoProfile -Command "& '$installer' -Uninstall -RemoveFiles *> `$null"
            $after = if (Test-Path $profileFile) { Get-Content $profileFile -Raw } else { $null }
            "$after" | Should -Not -Match 'ProcFileSystem'
        } finally {
            if ($null -ne $before) { Set-Content -Path $profileFile -Value $before -NoNewline }
        }
    }
}
