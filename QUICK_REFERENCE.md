# proc: Quick Reference

See [README.md](README.md) for formats and details.

## Setup

```powershell
.\Install-ProcDrive.ps1 -Install -AddToProfile    # install, mount now and in new sessions
.\Install-ProcDrive.ps1 -Uninstall -RemoveFiles   # remove everything
Mount-ProcDrive / Dismount-ProcDrive              # after Import-Module ProcFileSystem
```

## Files

```text
cpuinfo  meminfo  stat  loadavg  uptime  version  cmdline
mounts   filesystems  swaps  partitions  modules
net\dev  net\route  net\arp  net\tcp  net\tcp6  net\udp  net\udp6
sys\kernel\hostname  sys\kernel\ostype  sys\kernel\osrelease  sys\kernel\version
devices\block  devices\character
<PID>\cmdline  <PID>\status  <PID>\stat  <PID>\environ  <PID>\maps   (also self\)
```

## The one rule

Each file comes back as **one string**; `-Raw` isn't supported. Split it to get lines:

```powershell
$lines = (cat proc:\meminfo) -split "`r?`n"
```

## One-liners

```powershell
# Available memory, GB
[long](((cat proc:\meminfo) -split "`r?`n" | Select-String '^MemAvailable').Line -replace '\D') / 1MB

# Logical CPUs
@((cat proc:\cpuinfo) -split "`r?`n" | Select-String '^processor').Count

# CPU model
(((cat proc:\cpuinfo) -split "`r?`n" | Select-String '^model name' | Select-Object -First 1).Line -split ':\s*', 2)[1]

# Uptime, hours
[math]::Round([double]((cat proc:\uptime).Split()[0]) / 3600, 1)

# Load averages
(cat proc:\loadavg).Split()[0..2]

# Process IDs
(ls proc:\ | ? Name -match '^\d+$').Name

# stat fields after comm. comm can contain spaces ("(Creative Cloud)"), so split after
# the last ')': field N is $rest[N-3]
$s = cat proc:\self\stat; $rest = $s.Substring($s.LastIndexOf(')') + 2) -split ' '

# Parent (field 4) and RSS (field 24)
"ppid $($rest[1]), rss $([long]$rest[21] * 4) kB"

# argv of a process
(cat proc:\self\cmdline).TrimEnd("`0") -split "`0"

# Established IPv4 TCP connections (state 01)
@((cat proc:\net\tcp) -split "`r?`n" | ? { ($_.Trim() -split '\s+')[3] -eq '01' }).Count

# Interface names
(cat proc:\net\dev) -split "`r?`n" | Select-Object -Skip 2 | ? { $_ } | % { $_.Split(':')[0].Trim() }
```

## Decoding net\tcp addresses

```powershell
function ConvertFrom-ProcHex4($hex) {   # 0100007F -> 127.0.0.1
    ([ipaddress][byte[]](6, 4, 2, 0 | % { [Convert]::ToByte($hex.Substring($_, 2), 16) })).ToString()
}
$f = (((cat proc:\net\tcp) -split "`r?`n")[1].Trim() -split '\s+')[1].Split(':')
"$(ConvertFrom-ProcHex4 $f[0]):$([Convert]::ToInt32($f[1], 16))"
```

TCP states: `01` established, `02` syn-sent, `03` syn-recv, `04`/`05` fin-wait, `06`
time-wait, `07` close, `08` close-wait, `09` last-ack, `0A` listen, `0B` closing.

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| `proc:` gone after running a script | Use `Mount-ProcDrive` (global), not `New-PSDrive` |
| `A parameter cannot be found that matches parameter name 'Raw'` | Drop `-Raw`; content is already one string |
| `Unable to find type [SHiPSDirectory]` | SHiPS isn't installed: `Install-Module SHiPS -Scope CurrentUser` |
| Reading `<PID>\environ` fails | Only `self\environ` is readable |
| Slow `cpuinfo` | `Win32_Processor` takes about a second; expected |
