# nvtopps-db-fix

Stops the NVIDIA **NVDisplay.Container.exe** SSD write bursts that can continue after GeForce
hotfix driver **621.35**. On the system where this was found, the bursts were caused by a
bloated NvTopps database. Nothing is disabled, and the fix can be undone with one command.

> Community workaround, not affiliated with or endorsed by NVIDIA. Tested on one system so
> far (see [Results](#results)). Use until NVIDIA ships a complete fix.

## Background

- Drivers 621.14 and 621.24 made `NVDisplay.Container.exe` keep rewriting
  `C:\ProgramData\NVIDIA Corporation\nvtopps\nct\nvlog.nvlgstg`. Users measured up to
  ~30 GB/hour. NVIDIA tracks it as bug 7116722.
- Hotfix **621.35** (20 Nov 2026) fixes the `nvlog.nvlgstg` writes, but some users report the
  writes coming back.
- On the test system, 621.35 still wrote **~13 GB/hour**. A kernel file trace showed the writes
  going to a different file: **`nvtopps.db3`**, NvTopps's SQLite database, plus its
  rollback journal `nvtopps.db3-journal`.

## The cause (on the test system)

`nvtopps.db3` was **56 MB**, but **13,757 of its 13,796 pages (99.7%) were empty**. The actual
data was ~160 KB: Dynamic Boost settings, a few GPU error records and system info. Every 30–60 s,
NvTopps saved the database by writing all 56 MB through the journal, roughly 220 MB per burst,
empty pages included.

SQLite's `VACUUM` command rebuilds the file without the empty pages. After that, each save is
tiny.

What bloated the database in the first place is unknown. A likely guess is the earlier log bug
filling tables that were later cleared, which SQLite never shrinks on its own.

## Usage

Download the repo (Code → Download ZIP), extract it, and open PowerShell in that folder.
If Windows blocks the script, run `Unblock-File .\*.ps1` first, or prefix each command with
`powershell -ExecutionPolicy Bypass -File`.

**1. Check (no admin needed, changes nothing):**
```powershell
.\Fix-NvToppsDb.ps1
```
It prints your driver version, the database size and how much of it is empty, then measures the
container's writes for 2 minutes and tells you whether this fix applies to you.

**2. Fix (Administrator PowerShell):**
```powershell
.\Fix-NvToppsDb.ps1 -Fix
```
It stops the *NVIDIA Display Container LS* service and waits until the database is released,
saves a backup as `nvtopps.db3.before_vacuum.bak`, runs an integrity check and `VACUUM`,
restarts the service, and measures again.

**3. Undo (Administrator PowerShell):**
```powershell
.\Fix-NvToppsDb.ps1 -Restore
```

The script uses only `winsqlite3.dll`, which ships with Windows 10/11. Nothing is downloaded or
installed. If the database grows large again later, run `-Fix` again.

## Why not `DisableLoad=1` on `_nvtopps`?

That widely shared workaround stops the plugin that does the writing, but `_nvtopps.dll` is also
NVIDIA's power manager. On laptops it runs **Dynamic Boost** (CPU↔GPU power sharing), Battery
Boost, WhisperMode and a CPU frame limiter. Turning it off can lower the GPU's sustained power.
This fix leaves NvTopps running.

Making `nvlog.nvlgstg` read-only does not help on 621.35 either: the writes go to the database,
not the log.

## Results

Test system: RTX 5080 Laptop GPU, Windows 11, driver 621.35, `C:` on an NVMe SSD.

| | Before | After `-Fix` |
|---|---|---|
| `nvtopps.db3` | 56.5 MB (99.7% empty pages) | 156 KB |
| NVDisplay.Container writes | 108–432 MB per minute, ~13 GB/hour | ~1–2.5 MB per minute, ~0.06–0.14 GB/hour |
| SSD-level check | 104 MB written by the disk per 2 s during a burst | no bursts |
| NvTopps / Dynamic Boost | running | running, full 175 W under load |

Long idle (8 h) result: *pending*.

If you try it, please open an issue with your GPU, driver version, and the `-Check` output from
before and after. Laptop and desktop results are both useful.

## Tracing (find out what is being written on your PC)

```powershell
.\Trace-NvWrites.ps1                  # Administrator PowerShell, 120 s
.\Trace-NvWrites.ps1 -Seconds 300 -Csv .\trace.csv
```
It uses built-in Windows tracing (ETW, `Microsoft-Windows-Kernel-File`) and lists the files
`NVDisplay.Container.exe` wrote, with MB and write counts.

Notes:
- Windows reuses internal file IDs, so a row can occasionally carry the wrong name, usually in
  the first burst of the trace. Trust rows whose size matches a real file.
- Large writes made by the Windows cache on the process's behalf can show up as "unresolved".
- A raw trace also lists failed *open attempts* for files that don't exist. That is normal and
  not a write.

## Reporting to NVIDIA

NVIDIA has asked users who still see the problem on 621.35 to send `nvlog.nvlgstg` and their GPU
model to driverfeedback@nvidia.com. Your `-Check` output and trace results are useful to include.

## License

MIT, see [LICENSE](LICENSE).
