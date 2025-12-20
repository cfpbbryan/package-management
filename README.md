# Package Management Utilities

These are the helper scripts that we're currently using. Only basic info is
provided here.

Do not start here. The full documentation is in MS Word files in SharePoint.
Ask someone from Office of Research or Bryan Harris where that's at.

## Script and file reference

| Script / File Name                | What it does                                                          |
| --------------------------------- | --------------------------------------------------------------------- |
| utilities/add-git-pull.reg        | Adds a Windows Explorer context-menu entry for “Git Pull Here”        |
| utilities/install-ps1-modules.ps1 | Installs PSReadLine and posh-git modules and imports them via profile |
| logging-utils.psm1                | Shared PowerShell logging utilities used by other scripts             |
| integrity-check.ps1               | Generates and validates integrity metadata for a local package mirror |
| pip-client-lockdown.ps1           | Enforces pip client configuration and restrictions                    |
| lockdown-check.ps1                | Verifies pip client lockdown settings and event log reporting         |
| pip-download-packages.ps1         | Downloads Python packages into a controlled mirror                    |
| pip-install-build-tools.ps1       | Installs Python build dependencies required for packaging             |
| pip-print-csv.ps1                 | Exports installed Python package metadata to CSV                      |
| r-build-mirror.R                  | Builds a local mirror of R packages                                   |
| r-install-baseline.R              | Installs a baseline set of approved R packages                        |
| r-print-csv.R                     | Exports installed R package metadata to CSV                           |
| r-print-csv.ps1                   | PowerShell wrapper for R CSV export                                   |
| stata-install-baseline.do         | Installs a baseline set of Stata packages                             |
| stata-print-csv.ps1               | PowerShell wrapper for Stata CSV export                               |
| anaconda-print-csv.ps1            | Exports Anaconda/conda package metadata to CSV                        |
| controls-mapping.csv              | Control-mapping table for compliance reporting (NIST / FedRAMP style) |
| controls-mapping.yaml             | YAML version of the same control-mapping data for automation          |

Legacy and experimental scripts live under the `archive/` directory; see `archive/README.md` for details.

## Compliance control references

- [NIST SP 800-53 Rev. 5 Controls (Excel)](https://csrc.nist.gov/pubs/sp/800/53/r5/upd1/final/docs/sp800-53r5-controls.xlsx)
- [FedRAMP Moderate Baseline Security Controls (Excel)](https://www.fedramp.gov/resources/documents/FedRAMP_Moderate_Security_Controls.xlsx)

## Command usage table

| Command | Purpose |
| --- | --- |
| `.\integrity-check.ps1 -Mode baseline -MirrorRoot "C:\admin\pip_mirror"` | Create a baseline integrity manifest for a mirror. |
| `.\integrity-check.ps1 -Mode verify -MirrorRoot "C:\admin\pip_mirror"` | Verify a mirror against a previously captured baseline. |
| `.\lockdown-check.ps1` | Validate the default pip lockdown configuration. |
| `.\lockdown-check.ps1 -PythonLauncher "C:\Python311\python.exe"` | Validate lockdown settings for a specific Python interpreter. |

## Usage examples

| Scenario | Example |
| --- | --- |
| Create a baseline manifest for one mirror. | ```powershell
& {
  .\integrity-check.ps1 -Mode baseline `
    -MirrorRoot "C:\admin\pip_mirror"
}
``` |
| Verify a mirror against an existing baseline. | ```powershell
& {
  .\integrity-check.ps1 -Mode verify `
    -MirrorRoot "C:\admin\pip_mirror"
}
``` |
| Validate that pip is locked down to the default mirror settings applied by `pip-client-lockdown.ps1`. | ```powershell
& {
  .\lockdown-check.ps1
}
``` |
| Validate pip lockdown using an explicit Python interpreter. | ```powershell
& {
  .\lockdown-check.ps1 -PythonLauncher "C:\Python311\python.exe"
}
``` |

## Splunk search examples

Use these sample SPL queries to locate events written by
`integrity-check.ps1` on a specific Windows host (replace
`my-mirror-host` with your hostname).

| Description | SPL query |
| --- | --- |
| Recent informational events emitted by the script’s Windows event log source, including a zero-results branch you can use to drive an email alert when the scheduled task fails to run. | ```spl
index=windows host="my-mirror-host" source="WinEventLog:Application"
  SourceName="MirrorIntegrityCheck" earliest=-24h latest=now
| stats count BY EventCode, Message
| appendpipe [| stats count | where count=0 | eval Message="No MirrorIntegrityCheck events in the past 24h — verify the scheduled task and notify via email."]
``` |
| Errors from mirror verification runs (helps highlight hash mismatches or missing files). | ```spl
index=windows host="my-mirror-host" source="WinEventLog:Application"
  SourceName="MirrorIntegrityCheck" EventCode=1001
``` |
| Combined view showing both information and error events for a given time window. | ```spl
index=windows host="my-mirror-host" source="WinEventLog:Application"
  SourceName="MirrorIntegrityCheck"
  (EventCode=1000 OR EventCode=1001)
| stats count BY EventCode, Message
``` |
| Successful pip lockdown validation events from `lockdown-check.ps1`. | ```spl
index=windows host="my-mirror-host" source="WinEventLog:Application"
  SourceName="PipClientLockdownCheck" EventCode=1000 earliest=-24h latest=now
``` |
| Pip lockdown validation failures (missing find-links/no-index settings). | ```spl
index=windows host="my-mirror-host" source="WinEventLog:Application"
  SourceName="PipClientLockdownCheck" EventCode=1001 earliest=-24h latest=now
``` |
| Alert when the `PipClientLockdownCheck` source shows no successful runs in the past 24 hours (returns a zero-row result you can wire to an email alert). | ```spl
index=windows host="my-mirror-host" source="WinEventLog:Application"
  SourceName="PipClientLockdownCheck"
  earliest=-24h latest=now
| stats
    count as total_events
    sum(eval(EventCode=1000)) as success_events
    sum(eval(EventCode=1001)) as error_events
| eval
    ran_ok = if(total_events >= 1 AND success_events >= 1, 1, 0)
| where ran_ok=0
``` |
| Cleanup summary events emitted by `pip-cleanup-versions.ps1` when wheel or source distribution files are removed. | ```spl
index=windows host="my-mirror-host" source="WinEventLog:Application"
  SourceName="PipCleanupVersions" EventCode=1000 earliest=-24h latest=now
``` |
| Warning events from `pip-cleanup-versions.ps1` (filter by EventCode to isolate only the warning entries). | ```spl
index=windows host="my-mirror-host" source="WinEventLog:Application"
  SourceName="PipCleanupVersions" EventCode=1001 earliest=-24h latest=now
``` |
| Recent download summary events from `pip-download-packages.ps1` (the message includes the Python version used and reminds you to re-run the `integrity-check` baseline). | ```spl
index=windows host="my-mirror-host" source="WinEventLog:Application"
  SourceName="pip-download-packages" EventCode=1000 earliest=-24h latest=now
``` |
| Filtered download summary events for a specific host and 2-hour window to isolate a particular run. | ```spl
index=windows host="my-mirror-host" source="WinEventLog:Application"
  SourceName="pip-download-packages" EventCode=1000
  earliest=-2h latest=now
| table _time, host, Message
``` |
| Clipboard report events emitted by `r-print-csv.ps1` (the message includes the Rscript and `clip.exe` exit codes). | ```spl
index=windows host="my-mirror-host" source="WinEventLog:Application"
  SourceName="RPrintCsvReport" (EventCode=1000 OR EventCode=1001)
  earliest=-24h latest=now
| table _time, host, EventCode, Message
``` |
| Clipboard summary for `stata-print-csv.ps1` runs (EventCode 1001 indicates the clipboard copy failed or no packages were found). | ```spl
index=windows host="my-mirror-host" source="WinEventLog:Application"
  SourceName="StataPrintCsvReport" (EventCode=1000 OR EventCode=1001)
  earliest=-24h latest=now
| table _time, host, EventCode, Message
``` |

## Local Windows event log search examples

Use PowerShell to retrieve the same `integrity-check.ps1` and
`lockdown-check.ps1` events from your Windows 11 machine without Splunk.

| Description | PowerShell |
| --- | --- |
| Recent informational events from the script source (mirrors the first SPL example). | ```powershell
& {
  Get-WinEvent -FilterHashtable @{
      LogName   = 'Application'
      ProviderName = 'MirrorIntegrityCheck'
      Id        = 1000
      StartTime = (Get-Date).AddDays(-1)
  } | Format-List -Property TimeCreated, Id, ProviderName, Message
}
``` |
| Recent error events (similar to the second SPL example). | ```powershell
& {
  Get-WinEvent -FilterHashtable @{
      LogName   = 'Application'
      ProviderName = 'MirrorIntegrityCheck'
      Id        = 1001
      StartTime = (Get-Date).AddDays(-1)
  } | Format-List -Property TimeCreated, Id, ProviderName, Message
}
``` |
| Combined informational and error events with counts by event ID (parallel to the third SPL example). | ```powershell
& {
  Get-WinEvent -FilterHashtable @{
      LogName   = 'Application'
      ProviderName = 'MirrorIntegrityCheck'
      Id        = @(1000,1001)
      StartTime = (Get-Date).AddDays(-1)
  } | Group-Object Id | Select-Object Count, Name
}
``` |
| Successful pip lockdown validation events from `lockdown-check.ps1` (shows enforcement status for the requested interpreter). | ```powershell
& {
  Get-WinEvent -FilterHashtable @{
      LogName      = 'Application'
      ProviderName = 'PipClientLockdownCheck'
      Id           = 1000
      StartTime    = (Get-Date).AddHours(-24)
      EndTime      = Get-Date
  } | Format-List -Property TimeCreated, Id, ProviderName, Message
}
``` |
| Lockdown validation failures from `lockdown-check.ps1` (missing find-links or no-index settings). | ```powershell
& {
  Get-WinEvent -FilterHashtable @{
      LogName      = 'Application'
      ProviderName = 'PipClientLockdownCheck'
      Id           = 1001
      StartTime    = (Get-Date).AddHours(-24)
      EndTime      = Get-Date
  } | Format-List -Property TimeCreated, Id, ProviderName, Message
}
``` |
| Cleanup summary events recorded by `pip-cleanup-versions.ps1` (highlights how many wheel and source distribution files were deleted). | ```powershell
& {
  Get-WinEvent -FilterHashtable @{
      LogName      = 'Application'
      ProviderName = 'PipCleanupVersions'
      Id           = 1000
      StartTime    = (Get-Date).AddHours(-24)
      EndTime      = Get-Date
  } | Format-List -Property TimeCreated, Id, ProviderName, Message
}
``` |
| Warnings produced by `pip-cleanup-versions.ps1` (the script emits warning events with the same provider name but a different ID). | ```powershell
& {
  Get-WinEvent -FilterHashtable @{
      LogName      = 'Application'
      ProviderName = 'PipCleanupVersions'
      Id           = 1001
      StartTime    = (Get-Date).AddHours(-24)
      EndTime      = Get-Date
  } | Format-List -Property TimeCreated, Id, ProviderName, Message
}
``` |
| Combined informational and warning events with counts by event ID (mirrors the combined `MirrorIntegrityCheck` example above). | ```powershell
& {
  Get-WinEvent -FilterHashtable @{
      LogName      = 'Application'
      ProviderName = 'PipCleanupVersions'
      Id           = @(1000,1001)
      StartTime    = (Get-Date).AddHours(-24)
      EndTime      = Get-Date
  } | Group-Object Id | Select-Object Count, Name
}
``` |
| Download summary events written by `pip-download-packages.ps1` (the message includes the Python version used and the reminder to re-run `integrity-check.ps1` baseline). | ```powershell
& {
  Get-WinEvent -FilterHashtable @{
      LogName   = 'Application'
      ProviderName = 'pip-download-packages'
      Id        = 1000
      StartTime = (Get-Date).AddHours(-24)
      EndTime   = Get-Date
  } | Format-List -Property TimeCreated, Id, ProviderName, Message
}
``` |
| Lockdown summary events written by `pip-client-lockdown.ps1` (shows where the script wrote `pip.ini` and whether an existing file was restored). | ```powershell
& {
  Get-WinEvent -FilterHashtable @{
      LogName      = 'Application'
      ProviderName = 'PipClientLockdown'
      Id           = 1000
      StartTime    = (Get-Date).AddHours(-24)
      EndTime      = Get-Date
  } | Format-List -Property TimeCreated, Id, ProviderName, Message
}
``` |
| Download summary events scoped to the past 2 hours on a specific host. | ```powershell
& {
  Get-WinEvent -FilterHashtable @{
      LogName   = 'Application'
      ProviderName = 'pip-download-packages'
      Id        = 1000
      StartTime = (Get-Date).AddHours(-2)
      EndTime   = Get-Date
  } |
    Where-Object { $_.MachineName -eq 'my-mirror-host' } |
    Format-List -Property TimeCreated, MachineName, Message
}
``` |
| Clipboard copy status from `r-print-csv.ps1` (surface both successful and error events). | ```powershell
& {
  Get-WinEvent -FilterHashtable @{
      LogName      = 'Application'
      ProviderName = 'RPrintCsvReport'
      Id           = @(1000,1001)
      StartTime    = (Get-Date).AddHours(-24)
      EndTime      = Get-Date
  } | Format-List -Property TimeCreated, Id, ProviderName, Message
}
``` |
| Clipboard copy status from `stata-print-csv.ps1` (EventCode 1001 captures clipboard failures or empty reports). | ```powershell
& {
  Get-WinEvent -FilterHashtable @{
      LogName      = 'Application'
      ProviderName = 'StataPrintCsvReport'
      Id           = @(1000,1001)
      StartTime    = (Get-Date).AddHours(-24)
      EndTime      = Get-Date
  } | Format-List -Property TimeCreated, Id, ProviderName, Message
}
``` |

## PowerShell 5.1 multi-line command entry

Enable PowerShell 5.1 to treat multi-line commands and braced (`{ }`) blocks
as single entries in the command history by loading `PSReadLine` from your
user profile:

| Step | Command |
| --- | --- |
| Install PSReadLine. | ```powershell
Install-Module PSReadLine -Scope CurrentUser -Force
``` |
| Define the profile path. | ```powershell
$profilePath = $PROFILE.CurrentUserCurrentHost
``` |
| Ensure the profile file exists. | ```powershell
if (-not (Test-Path $profilePath)) {
    New-Item -ItemType File -Path $profilePath -Force | Out-Null
}
``` |
| Add PSReadLine to the profile and import it. | ```powershell
Add-Content -Path $profilePath -Value 'Import-Module PSReadLine'

Import-Module PSReadLine
``` |
