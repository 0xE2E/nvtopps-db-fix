<#
.SYNOPSIS
  Diagnose and fix NVDisplay.Container.exe SSD write bursts caused by a bloated NvTopps
  database (nvtopps.db3), still seen on GeForce hotfix driver 621.35.

.DESCRIPTION
  -Check    (default, no admin needed) Shows driver version, nvtopps.db3 size and free pages,
            and measures how much NVDisplay.Container writes in 2 minutes.
  -Fix      (admin) Stops the NVIDIA Display Container LS service, backs up nvtopps.db3,
            compacts it with SQLite VACUUM, restarts the service and measures again.
  -Restore  (admin) Puts the backup made by -Fix back.

  Uses only winsqlite3.dll, which ships with Windows 10/11. Nothing is downloaded or
  installed, and no NVIDIA plugin or feature is disabled.

.EXAMPLE
  .\Fix-NvToppsDb.ps1            # check only
  .\Fix-NvToppsDb.ps1 -Fix       # from an Administrator PowerShell
  .\Fix-NvToppsDb.ps1 -Restore
#>
[CmdletBinding(DefaultParameterSetName = 'Check')]
param(
    [Parameter(ParameterSetName = 'Fix')]     [switch]$Fix,
    [Parameter(ParameterSetName = 'Restore')] [switch]$Restore,
    [int]$MeasureSeconds = 120,
    [Parameter(ParameterSetName = 'Check')] [string]$DbPath   # check another copy of the DB (testing)
)

$ErrorActionPreference = 'Stop'
$Svc  = 'NVDisplay.ContainerLocalSystem'
$Dir  = Join-Path $env:ProgramData 'NVIDIA Corporation\nvtopps'
$Db   = Join-Path $Dir 'nvtopps.db3'
$Bak  = "$Db.before_vacuum.bak"
$Nvlg = Join-Path $Dir 'nct\nvlog.nvlgstg'
if ($DbPath) { $Db = $DbPath }

# ---------- helpers ----------
function Test-Admin {
    ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
}

if (-not ('NvFix.Sqlite' -as [type])) {
    Add-Type -Namespace NvFix -Name Sqlite -MemberDefinition @'
[DllImport("winsqlite3.dll", CharSet=CharSet.Unicode, EntryPoint="sqlite3_open16")] public static extern int Open(string f, out IntPtr db);
[DllImport("winsqlite3.dll", EntryPoint="sqlite3_close")] public static extern int Close(IntPtr db);
[DllImport("winsqlite3.dll", EntryPoint="sqlite3_exec")] public static extern int Exec(IntPtr db, byte[] sql, IntPtr cb, IntPtr arg, out IntPtr err);
[DllImport("winsqlite3.dll", EntryPoint="sqlite3_prepare_v2")] public static extern int Prepare(IntPtr db, byte[] sql, int n, out IntPtr st, IntPtr tail);
[DllImport("winsqlite3.dll", EntryPoint="sqlite3_step")] public static extern int Step(IntPtr st);
[DllImport("winsqlite3.dll", EntryPoint="sqlite3_column_text16")] public static extern IntPtr ColText(IntPtr st, int i);
[DllImport("winsqlite3.dll", EntryPoint="sqlite3_finalize")] public static extern int Fin(IntPtr st);
'@
}
function ConvertTo-Utf8Z([string]$s) { [Text.Encoding]::UTF8.GetBytes($s + [char]0) }
function Invoke-SqlScalar([IntPtr]$h, [string]$sql) {
    $st = [IntPtr]::Zero
    if ([NvFix.Sqlite]::Prepare($h, (ConvertTo-Utf8Z $sql), -1, [ref]$st, [IntPtr]::Zero) -ne 0) { throw "prepare failed: $sql" }
    try { if ([NvFix.Sqlite]::Step($st) -eq 100) { [Runtime.InteropServices.Marshal]::PtrToStringUni([NvFix.Sqlite]::ColText($st, 0)) } }
    finally { [void][NvFix.Sqlite]::Fin($st) }
}
function Get-DbStats([string]$path) {
    $h = [IntPtr]::Zero
    if ([NvFix.Sqlite]::Open($path, [ref]$h) -ne 0) { throw "cannot open $path" }
    try {
        [pscustomobject]@{
            SizeMB    = [math]::Round((Get-Item $path).Length / 1MB, 2)
            Pages     = [int](Invoke-SqlScalar $h 'pragma page_count')
            FreePages = [int](Invoke-SqlScalar $h 'pragma freelist_count')
            Integrity = Invoke-SqlScalar $h 'pragma integrity_check'
        }
    } finally { [void][NvFix.Sqlite]::Close($h) }
}
function Invoke-Vacuum([string]$path) {
    $h = [IntPtr]::Zero
    if ([NvFix.Sqlite]::Open($path, [ref]$h) -ne 0) { throw "cannot open $path" }
    try {
        $ok = Invoke-SqlScalar $h 'pragma integrity_check'
        if ($ok -ne 'ok') { throw "integrity_check says '$ok' - not touching this DB" }
        $err = [IntPtr]::Zero
        $rc = [NvFix.Sqlite]::Exec($h, (ConvertTo-Utf8Z 'VACUUM'), [IntPtr]::Zero, [IntPtr]::Zero, [ref]$err)
        if ($rc -ne 0) { throw "VACUUM failed (sqlite rc $rc)" }
    } finally { [void][NvFix.Sqlite]::Close($h) }
}
function Get-ContainerWriteBytes {
    $id = (Get-CimInstance Win32_Service -Filter "Name='$Svc'").ProcessId
    if (-not $id) { return $null }
    (Get-CimInstance Win32_Process -Filter "ProcessId=$id").WriteTransferCount
}
function Measure-Writes([int]$sec) {
    $a = Get-ContainerWriteBytes; $n0 = if (Test-Path $Nvlg) { (Get-Item $Nvlg -Force).LastWriteTimeUtc } else { $null }
    Write-Host "Measuring NVDisplay.Container writes for $sec s (leave the PC idle)..."
    Start-Sleep $sec
    $b = Get-ContainerWriteBytes; $n1 = if (Test-Path $Nvlg) { (Get-Item $Nvlg -Force).LastWriteTimeUtc } else { $null }
    if ($null -eq $a -or $null -eq $b) { Write-Warning 'Service not running, cannot measure.'; return $null }
    $mb = ($b - $a) / 1MB
    [pscustomobject]@{ MB = [math]::Round($mb, 2); GBperHour = [math]::Round($mb * 3600 / $sec / 1024, 2); NvlogTouched = ($n0 -ne $n1) }
}
function Stop-NvContainer {
    Stop-Service $Svc -Force
    for ($i = 0; $i -lt 30 -and (Get-Process NVDisplay.Container -ErrorAction SilentlyContinue); $i++) { Start-Sleep 1 }
    if (Get-Process NVDisplay.Container -ErrorAction SilentlyContinue) { throw 'NVDisplay.Container is still running; try again in a minute.' }
}
function Show-NvToppsState {
    $log = Join-Path $Dir 'nvtopps.log'
    if (-not (Test-Path $log)) { return }
    $tail = Get-Content $log -Tail 300
    $i = ($tail | Select-String 'nvtopps initialize\.\.\.' | Select-Object -Last 1).LineNumber
    if (-not $i) { return }
    $after = $tail[($i - 1)..($tail.Count - 1)]
    if ($after -match 'database is locked|Database was invalid') { Write-Warning 'NvTopps reported a DB problem at its last start. Restart the service once more, or run -Restore.' }
    elseif ($after -match 'JpacWorker start completed|DB populated') { Write-Host 'NvTopps started normally.' -ForegroundColor Green }
}

# ---------- main ----------
if (-not (Test-Path $Db)) { throw "Not found: $Db  (is this an NVIDIA GPU system with the display container?)" }
$drv = try { (& nvidia-smi --query-gpu=name,driver_version --format=csv,noheader) -join '; ' } catch { 'nvidia-smi not available' }
Write-Host "GPU / driver: $drv"

if ($PSCmdlet.ParameterSetName -eq 'Check') {
    $tmp = Join-Path $env:TEMP "nvtopps_check_$PID.db3"
    Copy-Item $Db $tmp -Force          # read a copy so the live DB is never locked by us
    $s = Get-DbStats $tmp; Remove-Item $tmp -Force
    $pct = if ($s.Pages) { [math]::Round(100 * $s.FreePages / $s.Pages, 1) } else { 0 }
    Write-Host ("nvtopps.db3: {0} MB, {1} pages, {2} free ({3}%), integrity {4}" -f $s.SizeMB, $s.Pages, $s.FreePages, $pct, $s.Integrity)
    $m = Measure-Writes $MeasureSeconds
    if ($m) { Write-Host ("NVDisplay.Container wrote {0} MB in {1} s  (~{2} GB/hour)" -f $m.MB, $MeasureSeconds, $m.GBperHour) }
    Write-Host ''
    if ($s.SizeMB -ge 5 -and $pct -ge 50) {
        Write-Host 'Bloated NvTopps DB found. Running -Fix from an Administrator PowerShell should cut these writes.' -ForegroundColor Yellow
    } elseif ($m -and $m.GBperHour -ge 1 -and $m.NvlogTouched) {
        Write-Host 'Writes look like the nvlog.nvlgstg bug (drivers 621.14/621.24). Install hotfix 621.35 or newer first.' -ForegroundColor Yellow
    } elseif ($m -and $m.GBperHour -ge 1) {
        Write-Host 'High writes but the DB is not bloated: this fix probably will not help. See README > Tracing.' -ForegroundColor Yellow
    } else {
        Write-Host 'Looks fine. Bursts can be minutes apart, so re-run later or with -MeasureSeconds 600 to be sure.' -ForegroundColor Green
    }
    return
}

if (-not (Test-Admin)) { throw 'Run this from an Administrator PowerShell.' }

if ($Restore) {
    if (-not (Test-Path $Bak)) { throw "No backup found at $Bak" }
    Stop-NvContainer
    Copy-Item $Bak $Db -Force
    Remove-Item "$Db-journal" -Force -ErrorAction SilentlyContinue
    Start-Service $Svc
    Write-Host 'Original nvtopps.db3 restored and service restarted.'
    return
}

# -Fix
Stop-NvContainer
$before = Get-DbStats $Db
Write-Host ("Before: {0} MB, {1} pages, {2} free" -f $before.SizeMB, $before.Pages, $before.FreePages)
Copy-Item $Db $Bak -Force
Write-Host "Backup: $Bak"
try { Invoke-Vacuum $Db }
catch { Write-Warning "$_ - restoring backup"; Copy-Item $Bak $Db -Force; Start-Service $Svc; throw }
$after = Get-DbStats $Db
Write-Host ("After:  {0} MB, {1} pages, {2} free, integrity {3}" -f $after.SizeMB, $after.Pages, $after.FreePages, $after.Integrity) -ForegroundColor Green
Start-Service $Svc
Start-Sleep 20
Show-NvToppsState
$m = Measure-Writes $MeasureSeconds
if ($m) { Write-Host ("NVDisplay.Container wrote {0} MB in {1} s  (~{2} GB/hour)" -f $m.MB, $MeasureSeconds, $m.GBperHour) }
Write-Host 'If the DB grows past a few MB again later, just run -Fix again. Undo with -Restore.'
