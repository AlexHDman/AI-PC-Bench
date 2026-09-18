<# Safe sequential managed-memory benchmark. #>
[CmdletBinding()]
param([int]$MemoryMaxTestMb = 512)
Set-StrictMode -Version Latest
$warnings = [System.Collections.Generic.List[string]]::new(); $errors = [System.Collections.Generic.List[string]]::new()
$start = Get-Date; $source = $null; $destination = $null
function Get-Median([double[]]$Values) { $values = @($Values | Sort-Object); if ($values.Count -eq 0) { return $null }; if (($values.Count % 2) -eq 1) { return $values[[int]($values.Count / 2)] }; [math]::Round(($values[$values.Count / 2 - 1] + $values[$values.Count / 2]) / 2, 2) }
function Invoke-MemoryPass([byte[]]$Source, [byte[]]$Destination, [int]$SizeMb) {
    $pattern = [byte[]](0..255); $timer = [Diagnostics.Stopwatch]::StartNew()
    [array]::Copy($pattern, $Source, $pattern.Length); $filled = $pattern.Length
    while ($filled -lt $Source.Length) { $length = [math]::Min($filled, $Source.Length - $filled); [Buffer]::BlockCopy($Source, 0, $Source, $filled, $length); $filled += $length }
    $timer.Stop(); $write = $SizeMb / $timer.Elapsed.TotalSeconds
    $timer.Restart(); [Buffer]::BlockCopy($Source, 0, $Destination, 0, $Source.Length); $timer.Stop(); $copy = $SizeMb / $timer.Elapsed.TotalSeconds
    $timer.Restart(); $sha = [Security.Cryptography.SHA256]::Create(); try { $sourceHash = [Convert]::ToBase64String($sha.ComputeHash($Source)); $destinationHash = [Convert]::ToBase64String($sha.ComputeHash($Destination)) } finally { $sha.Dispose() }; $timer.Stop()
    [pscustomobject]@{ write = [math]::Round($write, 2); copy = [math]::Round($copy, 2); read = [math]::Round($SizeMb / $timer.Elapsed.TotalSeconds, 2); valid = ($sourceHash -eq $destinationHash) }
}
try {
    $os = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop
    $availableMb = [math]::Floor([double]$os.FreePhysicalMemory / 1024)
    $requested = if ($MemoryMaxTestMb -gt 0) { $MemoryMaxTestMb } else { 512 }
    $safeMb = [math]::Min([math]::Min($requested, 512), [math]::Floor($availableMb * 0.1))
    if ($safeMb -lt 128) { throw "Available RAM ($availableMb MB) is insufficient for the minimum safe 128 MB test." }
    if ($safeMb -lt $requested) { $warnings.Add("Memory test size was reduced to $safeMb MB to keep both arrays within 20% of available RAM.") }
    [int]$testMb = $safeMb; [int]$byteCount = $testMb * 1MB
    $source = [byte[]]::new($byteCount); $destination = [byte[]]::new($byteCount)
    $warmup = Invoke-MemoryPass $source $destination $testMb
    if (-not $warmup.valid) { throw 'Memory checksum validation failed during warm-up.' }
    $writes = [System.Collections.Generic.List[double]]::new(); $copies = [System.Collections.Generic.List[double]]::new(); $reads = [System.Collections.Generic.List[double]]::new()
    for ($pass = 1; $pass -le 3; $pass++) { $passResult = Invoke-MemoryPass $source $destination $testMb; if (-not $passResult.valid) { throw "Memory checksum validation failed during measured pass $pass." }; $writes.Add($passResult.write); $copies.Add($passResult.copy); $reads.Add($passResult.read) }
    $write = Get-Median ($writes.ToArray()); $copy = Get-Median ($copies.ToArray()); $read = Get-Median ($reads.ToArray()); $end = Get-Date
    [pscustomobject]@{ test_size_mb = $testMb; warmup_passes = 1; measured_passes = 3; write_mbps = $write; copy_mbps = $copy; read_mbps = $read; effective_mbps = [math]::Round(($write + $copy + $read) / 3, 2); checksum_valid = $true; duration_seconds = [math]::Round(($end - $start).TotalSeconds, 3); completed = $true; warnings = @($warnings); errors = @($errors) }
}
catch { $errors.Add($_.Exception.Message); $end = Get-Date; [pscustomobject]@{ test_size_mb = $null; warmup_passes = 0; measured_passes = 0; write_mbps = $null; copy_mbps = $null; read_mbps = $null; effective_mbps = $null; checksum_valid = $false; duration_seconds = [math]::Round(($end - $start).TotalSeconds, 3); completed = $false; warnings = @($warnings); errors = @($errors) } }
finally { $source = $null; $destination = $null; [GC]::Collect(); [GC]::WaitForPendingFinalizers(); [GC]::Collect() }
