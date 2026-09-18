[CmdletBinding()]
param([string]$JsonPath)
Set-StrictMode -Version Latest
$ProjectRoot = Split-Path -Parent $PSScriptRoot
$ResultsPath = Join-Path $ProjectRoot 'results'
if ([string]::IsNullOrWhiteSpace($JsonPath)) {
    $file = Get-ChildItem -LiteralPath $ResultsPath -Filter 'EXPC_Benchmark_Stage3_*.json' -File | Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if ($null -eq $file) { throw 'No benchmark JSON was found.' }
    $JsonPath = $file.FullName
}
$JsonPath = [IO.Path]::GetFullPath($JsonPath)
$data = Get-Content -LiteralPath $JsonPath -Raw -Encoding UTF8 | ConvertFrom-Json
if ($data.schema_version -ne '1.0') { Write-Warning "Unexpected schema version: $($data.schema_version)" }
if ($data.status -ne 'success') { Write-Warning "Source JSON status: $($data.status)" }
$builder = Join-Path $PSScriptRoot 'Build-Report.ps1'
$result = & $builder -Benchmark $data -ProjectRoot $ProjectRoot -JsonPath $JsonPath -Preview
if (-not $result.completed) { throw 'Preview report creation failed.' }
$csv = Import-Csv -LiteralPath $result.csv_path -Delimiter ';'
if (@($csv).Count -ne 1) { throw 'Preview CSV validation failed.' }
$html = Get-Content -LiteralPath $result.html_path -Raw -Encoding UTF8
if ($html -notmatch '<!DOCTYPE html>' -or $html -match 'https?://') { throw 'Preview HTML autonomous validation failed.' }
Write-Host "Source JSON: $JsonPath"
Write-Host "Preview CSV: $($result.csv_path)"
Write-Host "Preview HTML: $($result.html_path)"
if ($true -eq (Get-Content (Join-Path $ProjectRoot 'config\benchmark_config.json') -Raw | ConvertFrom-Json).open_report_after_finish) { Start-Process -FilePath $result.html_path }
