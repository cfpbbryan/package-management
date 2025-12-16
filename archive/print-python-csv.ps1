$requirementsPath = Join-Path $PSScriptRoot 'python_requirements.txt'

Get-Content $requirementsPath | ForEach-Object {
    if ($_ -notmatch "([^=]+)==(.+)") { return }

    $info = py -m pip show $Matches[1] 2>$null
    if (-not $info) { return }

    $metadata = $info
        | ForEach-Object { $_ -replace '^([^:]+):\s*(.*)$', '$1=$2' }
        | ConvertFrom-StringData

    "$($metadata.Name)`t$($metadata.Version)`tPyPi`tReviewer`tInstaller`t$($metadata.Summary)`t$($metadata.'Home-page')`t$($metadata.Location)"
}
