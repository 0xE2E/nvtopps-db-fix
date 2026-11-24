<#
.SYNOPSIS
  Show which files NVDisplay.Container.exe actually writes to, using only built-in Windows
  tracing (ETW Microsoft-Windows-Kernel-File via logman). Needs an Administrator PowerShell.

.EXAMPLE
  .\Trace-NvWrites.ps1                 # 120 s trace
  .\Trace-NvWrites.ps1 -Seconds 300 -Csv .\trace.csv

.NOTES
  File names are matched by FileKey first (stable), then by the most recent Create on the
  same FileObject. A few rows can still carry a stale name; trust rows whose size matches a
  real file. "Create" events also include failed open attempts, so a path that does not
  exist on disk can show up in the raw trace. That is normal.
#>
param([int]$Seconds = 120, [string]$Csv, [switch]$AllProcesses)

if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)) { throw 'Run this from an Administrator PowerShell.' }

$session = 'NvWriteTrace'
$etl     = Join-Path $env:TEMP ("nvtrace_{0:yyyyMMdd_HHmmss}.etl" -f (Get-Date))
$nvPids  = @((Get-CimInstance Win32_Process -Filter "Name='NVDisplay.Container.exe'").ProcessId)
Write-Host "NVDisplay.Container PIDs: $($nvPids -join ', ')"

# Kernel-File keywords: FILENAME 0x10 | CREATE 0x80 | WRITE 0x200
logman stop $session -ets 2>$null | Out-Null
logman start $session -p Microsoft-Windows-Kernel-File 0x290 0x4 -o $etl -ets -bs 1024 -nb 64 512 | Out-Null
Write-Host "Tracing for $Seconds s (leave the PC idle)..."
Start-Sleep $Seconds
logman stop $session -ets | Out-Null

Write-Host 'Parsing (can take a minute or two)...'
$keyName = @{}; $objName = @{}
$writes  = [System.Collections.Generic.List[object]]::new()
Get-WinEvent -Path $etl -Oldest -ErrorAction SilentlyContinue | ForEach-Object {
    $ev = $_; $p = $ev.Properties
    if ($ev.Id -eq 10 -or $ev.Id -eq 11) {                 # NameCreate / NameDelete: FileKey, FileName
        $keyName["$($p[0].Value)"] = $p[1].Value
    } elseif ($ev.Id -eq 12) {                             # Create
        $fo = if ($ev.Version -ge 1) { $p[1].Value } else { $p[2].Value }
        $objName["$($ev.ProcessId)|$fo"] = $p[6].Value     # same-process only, avoids stale cross-process names
    } elseif ($ev.Id -eq 16) {                             # Write
        if ($ev.Version -ge 1) { $fo = $p[2].Value; $fk = $p[3].Value } else { $fo = $p[3].Value; $fk = $p[4].Value }
        if ($AllProcesses -or $ev.ProcessId -in $nvPids) {
            # name as of this moment (keys and objects get reused); end-of-trace name only as fallback
            $writes.Add([pscustomobject]@{ P = $ev.ProcessId; K = "$fk"; KN = $keyName["$fk"]; ON = $objName["$($ev.ProcessId)|$fo"]; S = [int64]$p[5].Value })
        }
    }
}
Remove-Item $etl -ErrorAction SilentlyContinue

$agg = @{}
foreach ($w in $writes) {
    $f = $w.KN; if (-not $f) { $f = $w.ON }; if (-not $f) { $f = $keyName[$w.K] }; if (-not $f) { $f = "<unresolved FileKey $($w.K)>" }
    $k = "$($w.P)|$f"
    if (-not $agg.ContainsKey($k)) { $agg[$k] = [pscustomobject]@{ PID = $w.P; MB = 0.0; Writes = 0; File = $f } }
    $agg[$k].MB += $w.S / 1MB; $agg[$k].Writes++
}
$rows = $agg.Values | Sort-Object MB -Descending | Select-Object PID, @{n='MB';e={[math]::Round($_.MB,2)}}, Writes, File
$total = ($rows | Measure-Object MB -Sum).Sum
Write-Host ("Total written by traced processes: {0:N1} MB in {1} s (~{2:N1} GB/hour)" -f $total, $Seconds, ($total * 3600 / $Seconds / 1024))
$rows | Select-Object -First 15 | Format-Table -AutoSize | Out-String -Width 250 | Write-Host
if ($Csv) { $rows | Export-Csv $Csv -NoTypeInformation -Encoding utf8; Write-Host "Saved $Csv" }
