[CmdletBinding()]
param([string]$JsonPath)

Set-StrictMode -Version Latest
$ProjectRoot = Split-Path -Parent $PSScriptRoot
$ResultsPath = Join-Path $ProjectRoot 'results'
$LogsPath = Join-Path $ProjectRoot 'logs'

function Mask-Serial([string]$Value) {
    if ([string]::IsNullOrWhiteSpace($Value)) { return '' }
    if ($Value.Length -le 4) { return ('*' * $Value.Length) }
    return $Value.Substring(0, 2) + ('*' * ($Value.Length - 4)) + $Value.Substring($Value.Length - 2)
}

function Format-ExampleValue($Value, [string]$PropertyName) {
    if ($null -eq $Value) { return '<null>' }
    $text = [string]$Value
    if ($PropertyName -match 'serial') { return Mask-Serial $text }
    if ($text.Length -gt 120) { return $text.Substring(0, 117) + '...' }
    return $text
}

function Get-SafeProperty($Object, [string]$Name) {
    if ($null -eq $Object) { return $null }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) { return $null }
    return $property.Value
}

function Show-ObjectSchema {
    param([string]$Name, $Object)

    Write-Output "[$Name]"
    if ($null -eq $Object) { Write-Output '  Status: <null>'; return }

    $items = @($Object)
    $isArray = $Object -is [System.Array] -or $Object -is [System.Collections.IEnumerable] -and $Object -isnot [string] -and $Object.PSObject.Properties['Count']
    if ($isArray) {
        Write-Output "  Array count: $($items.Count)"
        if ($items.Count -eq 0) { return }
        $sample = $items[0]
        Write-Output "  First item type: $($sample.GetType().FullName)"
    }
    else { $sample = $Object }

    $properties = @($sample.PSObject.Properties)
    if ($properties.Count -eq 0) { Write-Output "  Example: $(Format-ExampleValue $sample '')"; return }
    Write-Output "  Properties: $($properties.Name -join ', ')"
    foreach ($property in $properties) {
        $example = Format-ExampleValue $property.Value $property.Name
        Write-Output "  - $($property.Name): $example"
    }
}

if ([string]::IsNullOrWhiteSpace($JsonPath)) {
    $latest = Get-ChildItem -LiteralPath $ResultsPath -Filter 'EXPC_Benchmark_Stage3_*.json' -File |
        Sort-Object LastWriteTime -Descending |
        Select-Object -First 1
    if ($null -eq $latest) { throw 'No EXPC_Benchmark_Stage3 JSON files were found.' }
    $JsonPath = $latest.FullName
}

$JsonPath = [IO.Path]::GetFullPath($JsonPath)
if (-not (Test-Path -LiteralPath $JsonPath -PathType Leaf)) { throw "JSON file was not found: $JsonPath" }
$data = Get-Content -LiteralPath $JsonPath -Raw -Encoding UTF8 | ConvertFrom-Json

$timestamp = Get-Date -Format 'yyyyMMdd_HHmmss'
$logPath = Join-Path $LogsPath "JsonSchema_${timestamp}.txt"
$lines = [System.Collections.Generic.List[string]]::new()
function Add-SchemaOutput([string]$Text) { $lines.Add($Text); Write-Host $Text }

Add-SchemaOutput "JSON schema inspection"
Add-SchemaOutput "JSON path: $JsonPath"
Add-SchemaOutput "schema_version: $($data.schema_version)"
Add-SchemaOutput "status: $($data.status)"
if ($data.schema_version -ne '1.0') { Add-SchemaOutput 'WARNING: schema_version is not 1.0.' }
if ($data.status -ne 'success') { Add-SchemaOutput 'WARNING: status is not success.' }

$sections = @(
    @{ Name = 'root'; Object = $data }, @{ Name = 'computer'; Object = $data.computer }, @{ Name = 'operating_system'; Object = $data.operating_system },
    @{ Name = 'cpu'; Object = $data.cpu }, @{ Name = 'motherboard'; Object = $data.motherboard }, @{ Name = 'bios'; Object = $data.bios },
    @{ Name = 'memory'; Object = $data.memory }, @{ Name = 'memory.modules'; Object = $data.memory.modules }, @{ Name = 'gpus'; Object = $data.gpus },
    @{ Name = 'nvidia_gpus'; Object = $data.nvidia_gpus }, @{ Name = 'physical_disks'; Object = $data.physical_disks }, @{ Name = 'logical_disks'; Object = $data.logical_disks },
    @{ Name = 'power_plan'; Object = $data.power_plan }, @{ Name = 'benchmarks'; Object = $data.benchmarks }, @{ Name = 'benchmarks.cpu'; Object = $data.benchmarks.cpu },
    @{ Name = 'benchmarks.memory'; Object = $data.benchmarks.memory }, @{ Name = 'benchmarks.storage'; Object = $data.benchmarks.storage },
    @{ Name = 'preflight'; Object = (Get-SafeProperty $data 'preflight') }, @{ Name = 'privacy'; Object = (Get-SafeProperty $data 'privacy') }, @{ Name = 'warnings'; Object = $data.warnings }, @{ Name = 'errors'; Object = $data.errors }
)

foreach ($section in $sections) {
    $capture = @(Show-ObjectSchema -Name $section.Name -Object $section.Object)
    foreach ($line in $capture) { Add-SchemaOutput $line }
}

foreach ($name in @('cpu', 'memory', 'storage')) {
    if ($null -eq (Get-SafeProperty $data.benchmarks $name)) { Add-SchemaOutput "WARNING: benchmarks.$name is missing." }
}

[IO.File]::WriteAllLines($logPath, $lines, [Text.UTF8Encoding]::new($false))
Write-Host "Schema log: $logPath"
