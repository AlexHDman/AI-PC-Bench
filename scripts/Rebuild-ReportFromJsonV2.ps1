[CmdletBinding()]
param(
    [Parameter()][string]$ProjectRoot,
    [Parameter()][string]$SourceJsonPath,
    [Parameter()][string]$OutputPrefix = 'PREVIEW_V2'
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Test-InsideRoot([string]$Root, [string]$Path) {
    $fullRoot = [IO.Path]::GetFullPath($Root).TrimEnd([IO.Path]::DirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
    $fullPath = [IO.Path]::GetFullPath($Path)
    return $fullPath.StartsWith($fullRoot, [StringComparison]::OrdinalIgnoreCase)
}
function Read-BenchmarkJson([string]$Path) {
    try { $data = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json } catch { throw "Invalid source JSON: $($_.Exception.Message)" }
    foreach ($name in @('schema_version','status','benchmarks','computer','memory','physical_disks')) { if ($null -eq $data.PSObject.Properties[$name]) { throw "Required JSON section is missing: $name" } }
    foreach ($name in @('cpu','memory','storage')) { if ($null -eq $data.benchmarks.PSObject.Properties[$name]) { throw "Required benchmark section is missing: benchmarks.$name" } }
    return $data
}

$root = if ([string]::IsNullOrWhiteSpace($ProjectRoot)) { Split-Path -Parent $PSScriptRoot } else { $ProjectRoot }
$root = [IO.Path]::GetFullPath($root).TrimEnd([IO.Path]::DirectorySeparatorChar)
if (-not (Test-Path -LiteralPath $root -PathType Container)) { throw 'ProjectRoot does not exist.' }
if (-not (Test-Path -LiteralPath (Join-Path $root '.expc-benchmark-root') -PathType Leaf)) { throw 'Project root marker is missing.' }
$results = Join-Path $root 'results'; $reports = Join-Path $root 'reports'; $builder = Join-Path $root 'scripts\Build-ReportV2.ps1'
foreach ($path in @($results,$reports,$builder)) { if (-not (Test-Path -LiteralPath $path)) { throw "Required path is missing: $path" }; if (-not (Test-InsideRoot $root $path)) { throw "Path is outside ProjectRoot: $path" } }
if ([string]::IsNullOrWhiteSpace($SourceJsonPath)) {
    $candidate = Get-ChildItem -LiteralPath $results -Filter '*.json' -File | Where-Object { $_.Name -notmatch 'PREVIEW' } | Sort-Object LastWriteTimeUtc -Descending | ForEach-Object { try { [pscustomobject]@{ File=$_; Data=(Read-BenchmarkJson $_.FullName) } } catch { $null } } | Select-Object -First 1
    if ($null -eq $candidate) { throw 'No suitable benchmark JSON was found.' }
    $source = $candidate.File.FullName; $data = $candidate.Data
} else {
    $source = [IO.Path]::GetFullPath($SourceJsonPath)
    if (-not (Test-Path -LiteralPath $source -PathType Leaf) -or -not (Test-InsideRoot $root $source)) { throw 'SourceJsonPath must be an existing file inside ProjectRoot.' }
    $data = Read-BenchmarkJson $source
}
$sourceHashBefore = (Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash
$result = & $builder -BenchmarkData $data -ProjectRoot $root -OutputPrefix $OutputPrefix
if ($null -eq $result -or -not $result.completed -or -not (Test-Path -LiteralPath $result.csv_path) -or -not (Test-Path -LiteralPath $result.html_path)) { throw 'Build-ReportV2 did not return valid preview paths.' }
foreach ($path in @($result.csv_path,$result.html_path)) { if (-not (Test-InsideRoot $root $path)) { throw 'Builder returned a path outside ProjectRoot.' } }
if ($result.csv_path -eq $source -or $result.html_path -eq $source) { throw 'Preview output path matches the source JSON.' }
$sourceHashAfter = (Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash
if ($sourceHashBefore -ne $sourceHashAfter) { throw 'Source JSON changed during rebuild.' }
[pscustomobject]@{ completed=$true; source_json_path=$source; source_json_sha256_before=$sourceHashBefore; source_json_sha256_after=$sourceHashAfter; csv_path=$result.csv_path; html_path=$result.html_path; primary_gpu=$result.primary_gpu }
