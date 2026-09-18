<# Removes only direct contents of the portable project's temp directory. #>
[CmdletBinding()]
param()
Set-StrictMode -Version Latest
$ProjectRoot = Split-Path -Parent $PSScriptRoot
$MarkerPath = Join-Path $ProjectRoot '.expc-benchmark-root'
$TempPath = Join-Path $ProjectRoot 'temp'

if (-not (Test-Path -LiteralPath $MarkerPath -PathType Leaf)) { throw "Refusing cleanup: protective marker is missing at $MarkerPath" }
if (-not (Test-Path -LiteralPath $TempPath -PathType Container)) { throw "Refusing cleanup: temp directory is missing at $TempPath" }
$rootFull = [IO.Path]::GetFullPath($ProjectRoot).TrimEnd([IO.Path]::DirectorySeparatorChar)
$tempFull = [IO.Path]::GetFullPath($TempPath).TrimEnd([IO.Path]::DirectorySeparatorChar)
$userFull = [IO.Path]::GetFullPath($env:USERPROFILE).TrimEnd([IO.Path]::DirectorySeparatorChar)
$driveRoot = [IO.Path]::GetPathRoot($rootFull).TrimEnd([IO.Path]::DirectorySeparatorChar)
if ($tempFull -eq $rootFull -or $tempFull -eq $userFull -or $tempFull -eq $driveRoot) { throw 'Refusing cleanup: temp path resolves to a protected root.' }

$removed = @()
foreach ($item in @(Get-ChildItem -LiteralPath $tempFull -Force)) {
    $itemFull = [IO.Path]::GetFullPath($item.FullName)
    if (-not $itemFull.StartsWith($tempFull + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) { throw "Refusing cleanup outside temp: $itemFull" }
    if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { Write-Warning "Skipped reparse point: $itemFull"; continue }
    Remove-Item -LiteralPath $itemFull -Recurse -Force -ErrorAction Stop
    $removed += $itemFull
}
if ($removed.Count -eq 0) { Write-Host 'temp is already empty.' } else { Write-Host 'Removed objects:'; $removed | ForEach-Object { Write-Host $_ } }
