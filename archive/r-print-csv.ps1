# Invoke the R report script and copy its tab-separated output to the clipboard.
# Windows-only expectations; ensures the R script's exit code is preserved.

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$rScriptPath = Join-Path $scriptDir "r-print-csv.R"

$rExitCode = 0

# Run the R script and capture its exit code while piping output to clip.exe
& {
    & Rscript $rScriptPath
    $script:rExitCode = $LASTEXITCODE
} | clip.exe
$clipExitCode = $LASTEXITCODE
$rExitCode = $script:rExitCode

$summaryMessage = "R package report: Rscript exit code $rExitCode; clip.exe exit code $clipExitCode."
$summaryType = if (($rExitCode -ne 0) -or ($clipExitCode -ne 0)) { 'Error' } else { 'Information' }

if ($clipExitCode -ne 0) {
    Write-Host "clip.exe returned exit code $clipExitCode while copying the report" -ForegroundColor Yellow
}

if ($summaryType -eq 'Information') {
    Write-Host "Copied R package report to clipboard" -ForegroundColor Yellow
}
else {
    Write-Host "R package report encountered issues while copying to clipboard" -ForegroundColor Yellow
}

exit $rExitCode
