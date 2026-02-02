<#
.SYNOPSIS
    Test and demonstration script for PowerShell proc: drive
.DESCRIPTION
    Validates functionality and demonstrates various features of the proc: filesystem
#>

[CmdletBinding()]
param(
    [switch]$RunTests,
    [switch]$Demo,
    [switch]$Benchmark
)

function Test-ProcDrive {
    Write-Host "`n=== Testing proc: Drive Functionality ===" -ForegroundColor Cyan
    
    $testsPassed = 0
    $testsFailed = 0
    
    # Test 1: Drive exists
    Write-Host "`nTest 1: Checking if proc: drive exists..." -NoNewline
    if (Test-Path proc:) {
        Write-Host " PASS" -ForegroundColor Green
        $testsPassed++
    } else {
        Write-Host " FAIL" -ForegroundColor Red
        $testsFailed++
        Write-Host "Run Install-ProcDrive.ps1 -Install first" -ForegroundColor Yellow
        return
    }
    
    # Test 2: Root directory listing
    Write-Host "Test 2: Listing root directory..." -NoNewline
    try {
        $items = Get-ChildItem proc:\ -ErrorAction Stop
        if ($items.Count -gt 0) {
            Write-Host " PASS ($($items.Count) items)" -ForegroundColor Green
            $testsPassed++
        } else {
            Write-Host " FAIL (no items)" -ForegroundColor Red
            $testsFailed++
        }
    } catch {
        Write-Host " FAIL ($_)" -ForegroundColor Red
        $testsFailed++
    }
    
    # Test 3: Reading cpuinfo
    Write-Host "Test 3: Reading cpuinfo..." -NoNewline
    try {
        $cpuinfo = Get-Content proc:\cpuinfo -Raw -ErrorAction Stop
        if ($cpuinfo -match 'processor') {
            Write-Host " PASS" -ForegroundColor Green
            $testsPassed++
        } else {
            Write-Host " FAIL (invalid content)" -ForegroundColor Red
            $testsFailed++
        }
    } catch {
        Write-Host " FAIL ($_)" -ForegroundColor Red
        $testsFailed++
    }
    
    # Test 4: Reading meminfo
    Write-Host "Test 4: Reading meminfo..." -NoNewline
    try {
        $meminfo = Get-Content proc:\meminfo -Raw -ErrorAction Stop
        if ($meminfo -match 'MemTotal') {
            Write-Host " PASS" -ForegroundColor Green
            $testsPassed++
        } else {
            Write-Host " FAIL (invalid content)" -ForegroundColor Red
            $testsFailed++
        }
    } catch {
        Write-Host " FAIL ($_)" -ForegroundColor Red
        $testsFailed++
    }
    
    # Test 5: Network directory
    Write-Host "Test 5: Accessing net directory..." -NoNewline
    try {
        $netItems = Get-ChildItem proc:\net -ErrorAction Stop
        if ($netItems.Count -gt 0) {
            Write-Host " PASS ($($netItems.Count) items)" -ForegroundColor Green
            $testsPassed++
        } else {
            Write-Host " FAIL (no items)" -ForegroundColor Red
            $testsFailed++
        }
    } catch {
        Write-Host " FAIL ($_)" -ForegroundColor Red
        $testsFailed++
    }
    
    # Test 6: Process directories
    Write-Host "Test 6: Checking process directories..." -NoNewline
    try {
        $procs = Get-ChildItem proc:\ | Where-Object Name -match '^\d+$'
        if ($procs.Count -gt 0) {
            Write-Host " PASS ($($procs.Count) processes)" -ForegroundColor Green
            $testsPassed++
        } else {
            Write-Host " FAIL (no process directories)" -ForegroundColor Red
            $testsFailed++
        }
    } catch {
        Write-Host " FAIL ($_)" -ForegroundColor Red
        $testsFailed++
    }
    
    # Test 7: Self directory
    Write-Host "Test 7: Reading self/status..." -NoNewline
    try {
        $status = Get-Content proc:\self\status -Raw -ErrorAction Stop
        if ($status -match 'Name:') {
            Write-Host " PASS" -ForegroundColor Green
            $testsPassed++
        } else {
            Write-Host " FAIL (invalid content)" -ForegroundColor Red
            $testsFailed++
        }
    } catch {
        Write-Host " FAIL ($_)" -ForegroundColor Red
        $testsFailed++
    }
    
    # Test 8: Sys/kernel directory
    Write-Host "Test 8: Reading sys/kernel/hostname..." -NoNewline
    try {
        $hostname = Get-Content proc:\sys\kernel\hostname -Raw -ErrorAction Stop
        if ($hostname.Trim().Length -gt 0) {
            Write-Host " PASS ($($hostname.Trim()))" -ForegroundColor Green
            $testsPassed++
        } else {
            Write-Host " FAIL (empty)" -ForegroundColor Red
            $testsFailed++
        }
    } catch {
        Write-Host " FAIL ($_)" -ForegroundColor Red
        $testsFailed++
    }
    
    # Test 9: Network stats
    Write-Host "Test 9: Reading net/dev..." -NoNewline
    try {
        $netdev = Get-Content proc:\net\dev -Raw -ErrorAction Stop
        if ($netdev -match 'Receive') {
            Write-Host " PASS" -ForegroundColor Green
            $testsPassed++
        } else {
            Write-Host " FAIL (invalid content)" -ForegroundColor Red
            $testsFailed++
        }
    } catch {
        Write-Host " FAIL ($_)" -ForegroundColor Red
        $testsFailed++
    }
    
    # Test 10: Version info
    Write-Host "Test 10: Reading version..." -NoNewline
    try {
        $version = Get-Content proc:\version -Raw -ErrorAction Stop
        if ($version.Length -gt 0) {
            Write-Host " PASS" -ForegroundColor Green
            $testsPassed++
        } else {
            Write-Host " FAIL (empty)" -ForegroundColor Red
            $testsFailed++
        }
    } catch {
        Write-Host " FAIL ($_)" -ForegroundColor Red
        $testsFailed++
    }
    
    # Summary
    Write-Host "`n=== Test Summary ===" -ForegroundColor Cyan
    Write-Host "Passed: $testsPassed" -ForegroundColor Green
    Write-Host "Failed: $testsFailed" -ForegroundColor $(if ($testsFailed -eq 0) { 'Green' } else { 'Red' })
    Write-Host "Total:  $($testsPassed + $testsFailed)"
}

function Show-Demo {
    Write-Host "`n=== proc: Drive Interactive Demo ===" -ForegroundColor Cyan
    
    if (-not (Test-Path proc:)) {
        Write-Host "proc: drive not found. Run Install-ProcDrive.ps1 -Install first" -ForegroundColor Red
        return
    }
    
    Write-Host "`n1. System Information" -ForegroundColor Yellow
    Write-Host "   Hostname: " -NoNewline
    Write-Host (Get-Content proc:\sys\kernel\hostname -Raw).Trim() -ForegroundColor White
    
    Write-Host "   OS Version: " -NoNewline
    Write-Host (Get-Content proc:\version -Raw).Trim() -ForegroundColor White
    
    $uptime = (Get-Content proc:\uptime -Raw).Split()[0]
    $uptimeHours = [math]::Round([double]$uptime / 3600, 2)
    Write-Host "   Uptime: " -NoNewline
    Write-Host "$uptimeHours hours" -ForegroundColor White
    
    Write-Host "`n2. CPU Information" -ForegroundColor Yellow
    $cpuinfo = Get-Content proc:\cpuinfo -Raw
    $cpuSections = ($cpuinfo -split "`n`n").Count - 1
    Write-Host "   Logical Processors: " -NoNewline
    Write-Host $cpuSections -ForegroundColor White
    
    $cpuName = ($cpuinfo -split "`n" | Select-String 'model name' | Select-Object -First 1).ToString().Split(':')[1].Trim()
    Write-Host "   CPU Model: " -NoNewline
    Write-Host $cpuName -ForegroundColor White
    
    Write-Host "`n3. Memory Information" -ForegroundColor Yellow
    $meminfo = Get-Content proc:\meminfo -Raw
    $memTotal = ($meminfo -split "`n" | Select-String 'MemTotal').ToString().Split()[1]
    $memFree = ($meminfo -split "`n" | Select-String 'MemFree').ToString().Split()[1]
    $memTotalGB = [math]::Round([int]$memTotal / 1MB, 2)
    $memFreeGB = [math]::Round([int]$memFree / 1MB, 2)
    $memUsedGB = $memTotalGB - $memFreeGB
    
    Write-Host "   Total Memory: " -NoNewline
    Write-Host "$memTotalGB GB" -ForegroundColor White
    Write-Host "   Free Memory: " -NoNewline
    Write-Host "$memFreeGB GB" -ForegroundColor White
    Write-Host "   Used Memory: " -NoNewline
    Write-Host "$memUsedGB GB" -ForegroundColor White
    
    Write-Host "`n4. Network Interfaces" -ForegroundColor Yellow
    $netdev = Get-Content proc:\net\dev -Raw
    $interfaces = ($netdev -split "`n" | Select-Object -Skip 2 | Where-Object { $_.Trim() }).Count
    Write-Host "   Active Interfaces: " -NoNewline
    Write-Host $interfaces -ForegroundColor White
    
    Write-Host "`n5. Network Connections" -ForegroundColor Yellow
    $tcpConns = ((Get-Content proc:\net\tcp -Raw) -split "`n" | Select-Object -Skip 1 | Where-Object { $_.Trim() }).Count
    $udpConns = ((Get-Content proc:\net\udp -Raw) -split "`n" | Select-Object -Skip 1 | Where-Object { $_.Trim() }).Count
    Write-Host "   TCP Connections: " -NoNewline
    Write-Host $tcpConns -ForegroundColor White
    Write-Host "   UDP Endpoints: " -NoNewline
    Write-Host $udpConns -ForegroundColor White
    
    Write-Host "`n6. Process Information" -ForegroundColor Yellow
    $processes = (Get-ChildItem proc:\ | Where-Object Name -match '^\d+$').Count
    Write-Host "   Running Processes: " -NoNewline
    Write-Host $processes -ForegroundColor White
    
    Write-Host "`n7. Current Process (self)" -ForegroundColor Yellow
    Write-Host "   PID: " -NoNewline
    Write-Host $PID -ForegroundColor White
    
    $selfStatus = Get-Content proc:\self\status -Raw
    $selfName = ($selfStatus -split "`n" | Select-String 'Name:').ToString().Split("`t")[1].Trim()
    Write-Host "   Name: " -NoNewline
    Write-Host $selfName -ForegroundColor White
    
    Write-Host "`n8. Storage Information" -ForegroundColor Yellow
    $mounts = (Get-Content proc:\mounts -Raw) -split "`n" | Where-Object { $_.Trim() }
    Write-Host "   Mounted Drives: " -NoNewline
    Write-Host $mounts.Count -ForegroundColor White
    
    Write-Host "`n9. Directory Structure" -ForegroundColor Yellow
    Write-Host "   Root Entries: " -NoNewline
    $rootItems = Get-ChildItem proc:\
    Write-Host $rootItems.Count -ForegroundColor White
    
    Write-Host "`n   Key Directories:" -ForegroundColor Gray
    $rootItems | Where-Object PSIsContainer | Select-Object -First 5 | ForEach-Object {
        Write-Host "     - $($_.Name)" -ForegroundColor DarkGray
    }
    
    Write-Host "`n   Key Files:" -ForegroundColor Gray
    $rootItems | Where-Object { -not $_.PSIsContainer } | Select-Object -First 5 | ForEach-Object {
        Write-Host "     - $($_.Name)" -ForegroundColor DarkGray
    }
}

function Invoke-Benchmark {
    Write-Host "`n=== proc: Drive Performance Benchmark ===" -ForegroundColor Cyan
    
    if (-not (Test-Path proc:)) {
        Write-Host "proc: drive not found. Run Install-ProcDrive.ps1 -Install first" -ForegroundColor Red
        return
    }
    
    # Benchmark 1: Root directory listing
    Write-Host "`nBenchmark 1: Root directory listing..." -NoNewline
    $time = Measure-Command { Get-ChildItem proc:\ | Out-Null }
    Write-Host " $($time.TotalMilliseconds.ToString('F2')) ms" -ForegroundColor Cyan
    
    # Benchmark 2: Reading cpuinfo
    Write-Host "Benchmark 2: Reading cpuinfo..." -NoNewline
    $time = Measure-Command { Get-Content proc:\cpuinfo -Raw | Out-Null }
    Write-Host " $($time.TotalMilliseconds.ToString('F2')) ms" -ForegroundColor Cyan
    
    # Benchmark 3: Reading meminfo
    Write-Host "Benchmark 3: Reading meminfo..." -NoNewline
    $time = Measure-Command { Get-Content proc:\meminfo -Raw | Out-Null }
    Write-Host " $($time.TotalMilliseconds.ToString('F2')) ms" -ForegroundColor Cyan
    
    # Benchmark 4: Network directory
    Write-Host "Benchmark 4: Listing net directory..." -NoNewline
    $time = Measure-Command { Get-ChildItem proc:\net | Out-Null }
    Write-Host " $($time.TotalMilliseconds.ToString('F2')) ms" -ForegroundColor Cyan
    
    # Benchmark 5: Reading network stats
    Write-Host "Benchmark 5: Reading net/dev..." -NoNewline
    $time = Measure-Command { Get-Content proc:\net\dev -Raw | Out-Null }
    Write-Host " $($time.TotalMilliseconds.ToString('F2')) ms" -ForegroundColor Cyan
    
    # Benchmark 6: Process enumeration
    Write-Host "Benchmark 6: Enumerating processes..." -NoNewline
    $time = Measure-Command { 
        Get-ChildItem proc:\ | Where-Object Name -match '^\d+$' | Out-Null
    }
    Write-Host " $($time.TotalMilliseconds.ToString('F2')) ms" -ForegroundColor Cyan
    
    # Benchmark 7: Reading process info
    Write-Host "Benchmark 7: Reading self/status..." -NoNewline
    $time = Measure-Command { Get-Content proc:\self\status -Raw | Out-Null }
    Write-Host " $($time.TotalMilliseconds.ToString('F2')) ms" -ForegroundColor Cyan
    
    # Benchmark 8: Multiple file reads
    Write-Host "Benchmark 8: Reading 10 different files..." -NoNewline
    $time = Measure-Command {
        Get-Content proc:\cpuinfo -Raw | Out-Null
        Get-Content proc:\meminfo -Raw | Out-Null
        Get-Content proc:\version -Raw | Out-Null
        Get-Content proc:\uptime -Raw | Out-Null
        Get-Content proc:\loadavg -Raw | Out-Null
        Get-Content proc:\stat -Raw | Out-Null
        Get-Content proc:\mounts -Raw | Out-Null
        Get-Content proc:\filesystems -Raw | Out-Null
        Get-Content proc:\net\dev -Raw | Out-Null
        Get-Content proc:\net\tcp -Raw | Out-Null
    }
    Write-Host " $($time.TotalMilliseconds.ToString('F2')) ms" -ForegroundColor Cyan
}

# Main execution
if ($RunTests) {
    Test-ProcDrive
} elseif ($Demo) {
    Show-Demo
} elseif ($Benchmark) {
    Invoke-Benchmark
} else {
    Write-Host "proc: Drive Test Suite" -ForegroundColor Cyan
    Write-Host "`nUsage:" -ForegroundColor Yellow
    Write-Host "  .\Test-ProcDrive.ps1 -RunTests     # Run validation tests"
    Write-Host "  .\Test-ProcDrive.ps1 -Demo         # Show interactive demo"
    Write-Host "  .\Test-ProcDrive.ps1 -Benchmark    # Run performance benchmarks"
    Write-Host "`nMake sure to install the proc: drive first using Install-ProcDrive.ps1 -Install"
}
