<#
Runs the current Test-CPU.ps1 three times in separate powershell.exe processes.
No RAM, Storage, launcher, JSON, CSV, or HTML benchmark files are created.
#>
[CmdletBinding()]
param(
    [int]$Runs = 3,
    [int]$PauseSeconds = 10
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$projectRoot = Split-Path -Parent $PSScriptRoot
$cpuScript = Join-Path $PSScriptRoot 'Test-CPU.ps1'
$tempRoot = Join-Path $projectRoot ('temp\cpu_validation_' + [guid]::NewGuid().Guid)
$powershellCommand = Get-Command -Name 'powershell.exe' -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
$powershellExe = if ($null -ne $powershellCommand) { $powershellCommand.Source } else { Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe' }

if (-not (Test-Path -LiteralPath $cpuScript -PathType Leaf)) {
    throw "Test-CPU.ps1 not found: $cpuScript"
}
if (-not (Test-Path -LiteralPath $powershellExe -PathType Leaf)) {
    throw "powershell.exe not found: $powershellExe"
}

New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null
$results = [System.Collections.Generic.List[object]]::new()

try {
    for ($run = 1; $run -le $Runs; $run++) {
        $outputPath = Join-Path $tempRoot ("run_{0}.json" -f $run)
        $runnerPath = Join-Path $tempRoot ("runner_{0}.ps1" -f $run)

        $escapedCpu = $cpuScript.Replace("'", "''")
        $escapedOutput = $outputPath.Replace("'", "''")

        $runner = @"
`$result = & '$escapedCpu'
[IO.File]::WriteAllText(
    '$escapedOutput',
    (`$result | ConvertTo-Json -Depth 10),
    [Text.UTF8Encoding]::new(`$false)
)
if (-not `$result.completed) { exit 1 }
"@

        [IO.File]::WriteAllText(
            $runnerPath,
            $runner,
            [Text.UTF8Encoding]::new($true)
        )

        $process = Start-Process `
            -FilePath $powershellExe `
            -ArgumentList @(
                '-NoProfile',
                '-ExecutionPolicy', 'Bypass',
                '-File', ('"{0}"' -f $runnerPath)
            ) `
            -Wait `
            -PassThru `
            -WindowStyle Hidden

        if (-not (Test-Path -LiteralPath $outputPath -PathType Leaf)) {
            throw "Run $run did not create a result file. Exit code: $($process.ExitCode)"
        }

        $result = Get-Content -LiteralPath $outputPath -Raw | ConvertFrom-Json
        $results.Add([pscustomobject]@{
            run              = $run
            completed        = [bool]$result.completed
            engine_version   = [string]$result.engine_version
            score            = [double]$result.score
            pass_scores      = @($result.pass_scores)
            duration_seconds = [double]$result.duration_seconds
            errors           = @($result.errors)
            exit_code        = $process.ExitCode
        })

        if ($run -lt $Runs) {
            Start-Sleep -Seconds $PauseSeconds
        }
    }

    $scores = @($results | ForEach-Object { [double]$_.score })
    $minimum = ($scores | Measure-Object -Minimum).Minimum
    $maximum = ($scores | Measure-Object -Maximum).Maximum
    $average = ($scores | Measure-Object -Average).Average
    $rangePercent = if ($average -gt 0) {
        (($maximum - $minimum) / $average) * 100.0
    }
    else {
        $null
    }

    $results | Format-Table run, completed, score, duration_seconds, exit_code -AutoSize
    Write-Host ''
    Write-Host ('Min: {0:N2}' -f $minimum)
    Write-Host ('Max: {0:N2}' -f $maximum)
    Write-Host ('Average: {0:N2}' -f $average)
    Write-Host ('Range/Average: {0:N2} %' -f $rangePercent)

    [pscustomobject]@{
        runs                  = @($results)
        score_min             = [math]::Round($minimum, 2)
        score_max             = [math]::Round($maximum, 2)
        score_average         = [math]::Round($average, 2)
        range_average_percent = [math]::Round($rangePercent, 2)
        completed             = (@($results | Where-Object { -not $_.completed }).Count -eq 0)
    }
}
finally {
    if (Test-Path -LiteralPath $tempRoot) {
        Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}
