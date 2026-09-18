<# EXPC AI Benchmark Portable - portable stage 3 launcher. #>
[CmdletBinding()]
param()
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Continue'
$ProjectRoot = Split-Path -Parent $PSScriptRoot
$MarkerPath = Join-Path $ProjectRoot '.expc-benchmark-root'; $TempPath = Join-Path $ProjectRoot 'temp'; $LogsPath = Join-Path $ProjectRoot 'logs'; $ResultsPath = Join-Path $ProjectRoot 'results'; $ReportsPath = Join-Path $ProjectRoot 'reports'; $BackupsPath = Join-Path $ProjectRoot 'backups'; $ConfigPath = Join-Path $ProjectRoot 'config\benchmark_config.json'; $VersionPath = Join-Path $ProjectRoot 'VERSION.txt'
$CollectorPath = Join-Path $PSScriptRoot 'Collect-SystemInfo.ps1'; $NpuPath = Join-Path $PSScriptRoot 'Get-NPUInfo.ps1'; $TestNpuPath = Join-Path $PSScriptRoot 'Test-NPU.ps1'; $NpuCatalogPath = Join-Path $ProjectRoot 'config\npu_catalog.json'; $CpuPath = Join-Path $PSScriptRoot 'Test-CPU.ps1'; $MemoryPath = Join-Path $PSScriptRoot 'Test-Memory.ps1'; $StoragePath = Join-Path $PSScriptRoot 'Test-Storage.ps1'; $BuildReportPath = Join-Path $PSScriptRoot 'Build-Report.ps1'; $BuildReportV2Path = Join-Path $PSScriptRoot 'Build-ReportV2.ps1'

function Test-ProjectEnvironment {
    $warnings = [System.Collections.Generic.List[string]]::new(); $errors = [System.Collections.Generic.List[string]]::new(); $storageAllowed = $false; $driveType = $null; $driveName = $null
    if (-not (Test-Path -LiteralPath $MarkerPath -PathType Leaf)) { $errors.Add("Protective root marker is missing: $MarkerPath") }
    foreach ($folder in @('scripts','assets','config')) { if (-not (Test-Path -LiteralPath (Join-Path $ProjectRoot $folder) -PathType Container)) { $errors.Add("Required project folder is missing: $folder") } }
    $isUnc = $ProjectRoot.StartsWith('\\'); if ($isUnc) { $warnings.Add('Project is on a UNC path; Storage benchmark is disabled.') }
    if ($errors.Count -eq 0) { $probe = Join-Path $TempPath ('EXPC_writecheck_' + [guid]::NewGuid().Guid + '.tmp'); try { [IO.File]::WriteAllText($probe, 'EXPC write check', [Text.UTF8Encoding]::new($false)); if ([IO.File]::ReadAllText($probe) -ne 'EXPC write check') { throw 'read/write mismatch' } } catch { $errors.Add("Project write check failed: $($_.Exception.Message)") } finally { if (Test-Path -LiteralPath $probe) { Remove-Item -LiteralPath $probe -Force -ErrorAction SilentlyContinue } } }
    if (-not $isUnc) { try { $driveName = [IO.Path]::GetPathRoot([IO.Path]::GetFullPath($ProjectRoot)).TrimEnd([char[]]@(58,92)); $disk = Get-CimInstance -ClassName Win32_LogicalDisk -Filter "DeviceID='$driveName`:'" -ErrorAction Stop | Select-Object -First 1; $driveType = $disk.DriveType; if ($driveType -eq 3) { $storageAllowed = $true } else { $warnings.Add("Project drive type is $driveType, not Fixed Disk (3); Storage benchmark is disabled.") } } catch { $warnings.Add('Project drive type could not be determined; Storage benchmark is disabled.') } }
    [pscustomobject]@{ warnings = @($warnings); errors = @($errors); storage_allowed = $storageAllowed; drive_name = $driveName; drive_type = $driveType; write_check_passed = @($errors | Where-Object { $_ -like 'Project write check failed:*' }).Count -eq 0 }
}
function Get-ConfigInt([object]$Config, [string]$Name, [int]$Default, [int]$Minimum, [int]$Maximum, [System.Collections.Generic.List[string]]$Warnings) {
    $property = $Config.PSObject.Properties[$Name]
    if ($null -eq $property) { $Warnings.Add("Config key '$Name' is missing; safe default $Default was used."); return $Default }
    try { $value = [int]$property.Value } catch { $Warnings.Add("Config key '$Name' is invalid; safe default $Default was used."); return $Default }
    if ($value -lt $Minimum -or $value -gt $Maximum) { $Warnings.Add("Config key '$Name' is outside safe limits; safe default $Default was used."); return $Default }
    return $value
}
function Get-PreflightCpuLoad([int]$SampleCount, [int]$WarningThreshold, [System.Collections.Generic.List[string]]$Warnings) {
    $samples = [System.Collections.Generic.List[double]]::new(); $method = 'Win32_PerfFormattedData_PerfOS_Processor'
    for ($sample = 1; $sample -le $SampleCount; $sample++) {
        $value = $null
        try { $item = Get-CimInstance -ClassName Win32_PerfFormattedData_PerfOS_Processor -Filter "Name='_Total'" -ErrorAction Stop | Select-Object -First 1; if ($null -ne $item -and $null -ne $item.PercentProcessorTime -and [double]$item.PercentProcessorTime -ge 0 -and [double]$item.PercentProcessorTime -le 100) { $value = [double]$item.PercentProcessorTime } } catch { }
        if ($null -eq $value) { $method = 'Win32_Processor fallback'; try { $value = [double](Get-CimInstance -ClassName Win32_Processor -ErrorAction Stop | Measure-Object -Property LoadPercentage -Average | Select-Object -ExpandProperty Average) } catch { } }
        if ($null -ne $value) { $samples.Add($value) }
        if ($sample -lt $SampleCount) { Start-Sleep -Seconds 1 }
    }
    if ($method -eq 'Win32_Processor fallback') { $Warnings.Add('Загрузка CPU измерена резервным методом Win32_Processor; результат может быть менее точным') }
    $ordered = @($samples | Sort-Object); $median = $null; if ($ordered.Count) { $middle = [int][math]::Floor($ordered.Count / 2); $median = if ($ordered.Count % 2) { $ordered[$middle] } else { ($ordered[$middle - 1] + $ordered[$middle]) / 2 } }
    $average = if ($ordered.Count) { [math]::Round((($ordered | Measure-Object -Average).Average), 2) } else { $null }
    [pscustomobject]@{ cpu_load_percent = $median; cpu_load_method = $method; cpu_load_samples = @($samples); cpu_load_min_percent = if ($ordered.Count) { $ordered[0] } else { $null }; cpu_load_max_percent = if ($ordered.Count) { $ordered[-1] } else { $null }; cpu_load_average_percent = $average; cpu_load_median_percent = $median; cpu_warning_threshold_percent = $WarningThreshold; cpu_warning_triggered = ($null -ne $median -and $median -gt $WarningThreshold) }
}

# Runtime directories are intentionally recreated on every launch because ZIP archives omit empty folders.
foreach ($path in @($TempPath,$ResultsPath,$ReportsPath,$LogsPath,$BackupsPath)) {
    New-Item -ItemType Directory -Path $path -Force | Out-Null
}

$runId = [guid]::NewGuid().Guid; $dateTag = Get-Date -Format 'yyyyMMdd_HHmmss'; $logPath = Join-Path $LogsPath "EXPC_Benchmark_${dateTag}_${runId}.log"
function Write-Log([string]$Message) { $line = "$(Get-Date -Format 'o') $Message"; Write-Host $line; [IO.File]::AppendAllText($logPath, "$line`r`n", [Text.UTF8Encoding]::new($false)) }

$environment = @(Test-ProjectEnvironment) | Select-Object -Last 1
foreach ($warning in @($environment.warnings)) { Write-Log "WARNING: $warning" }
if (@($environment.errors).Count -gt 0) { foreach ($errorText in @($environment.errors)) { Write-Log "ERROR: $errorText" }; throw 'Portable project environment validation failed.' }
    foreach ($file in @($CollectorPath,$NpuPath,$TestNpuPath,$NpuCatalogPath,$CpuPath,$MemoryPath,$StoragePath,$BuildReportPath)) { if (-not (Test-Path -LiteralPath $file -PathType Leaf)) { throw "Required script is missing: $file" } }
$configurationWarnings = [System.Collections.Generic.List[string]]::new()
try { $benchmarkVersion = (Get-Content -LiteralPath $VersionPath -Raw -ErrorAction Stop).Trim() } catch { $benchmarkVersion = '0.1.0'; $configurationWarnings.Add('VERSION.txt could not be read; 0.1.0 was used.') }
try { $config = Get-Content -LiteralPath $ConfigPath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop; if (-not [string]::IsNullOrWhiteSpace($config.benchmark_version)) { $benchmarkVersion = $config.benchmark_version } } catch { $config = [pscustomobject]@{}; $configurationWarnings.Add('benchmark_config.json could not be read; safe defaults were used.') }
$cpuSeconds = Get-ConfigInt $config 'cpu_test_seconds' 10 1 60 $configurationWarnings; $memoryMb = Get-ConfigInt $config 'memory_max_test_mb' 512 128 512 $configurationWarnings; $storageMb = Get-ConfigInt $config 'storage_test_size_mb' 512 64 2048 $configurationWarnings
$idleSeconds = Get-ConfigInt $config 'preflight_idle_check_seconds' 5 1 30 $configurationWarnings; $cpuWarnPercent = Get-ConfigInt $config 'preflight_cpu_warning_percent' 15 1 100 $configurationWarnings

try {
    Write-Log "Stage 3 started. Root: $ProjectRoot; Run ID: $runId"
    $systemInfo = @(& $CollectorPath -RunId $runId -BenchmarkVersion $benchmarkVersion) | Select-Object -Last 1
    if ($null -eq $systemInfo -or $null -eq $systemInfo.computer) { throw 'Base system information could not be collected.' }
    $npuResult = @(& $NpuPath -CpuName $systemInfo.cpu.name -CatalogPath $NpuCatalogPath) | Select-Object -Last 1; $npuRuntime = @(& $TestNpuPath) | Select-Object -Last 1; if ($null -eq $npuResult) { throw 'NPU detection returned no result.' }; $npuResult.runtime_benchmark_status=$npuRuntime.runtime_benchmark_status; $npuResult.runtime_score_raw=$npuRuntime.runtime_score_raw; $npuResult.runtime_index=$npuRuntime.runtime_index; $npuResult.execution_provider=$npuRuntime.execution_provider; Write-Log "NPU detection status: $($npuResult.status)"
    $preflight = Get-PreflightCpuLoad -SampleCount $idleSeconds -WarningThreshold $cpuWarnPercent -Warnings $configurationWarnings; if ($preflight.cpu_warning_triggered) { $configurationWarnings.Add("Предварительная загрузка CPU составила $($preflight.cpu_load_percent)%, что выше рекомендуемого порога $cpuWarnPercent%. Это может повлиять на результат CPU-теста") }; Write-Log "Preflight CPU load: $($preflight.cpu_load_percent)% via $($preflight.cpu_load_method)"
    $cpuResult = @(& $CpuPath -DurationSeconds $cpuSeconds) | Select-Object -Last 1; if ($null -eq $cpuResult) { throw 'CPU test returned no result.' }; Write-Log "CPU test completed: $($cpuResult.completed)"
    Start-Sleep -Seconds 3
    $memoryResult = @(& $MemoryPath -MemoryMaxTestMb $memoryMb) | Select-Object -Last 1; if ($null -eq $memoryResult) { throw 'Memory test returned no result.' }; Write-Log "Memory test completed: $($memoryResult.completed)"
    Start-Sleep -Seconds 3
    $storageResult = @(& $StoragePath -StorageTestSizeMb $storageMb -RunId $runId) | Select-Object -Last 1; if ($null -eq $storageResult) { throw 'Storage test returned no result.' }; Write-Log "Storage test completed: $($storageResult.completed)"
    $warnings = @($configurationWarnings) + @($environment.warnings) + @($systemInfo.warnings) + @($cpuResult.warnings) + @($memoryResult.warnings) + @($storageResult.warnings)
    $errors = @($systemInfo.errors) + @($cpuResult.errors) + @($memoryResult.errors) + @($storageResult.errors)
    $status = if ($cpuResult.completed -and $memoryResult.completed -and $storageResult.completed) { 'success' } else { 'partial' }
    $showSerials = $false; $serialProperty = $config.PSObject.Properties['show_serial_numbers']; if ($null -ne $serialProperty) { $showSerials = [bool]$serialProperty.Value }
    $cpuRaw = [double]$cpuResult.score; $display = [pscustomobject]@{ cpu_index=[math]::Round($cpuRaw / 10000); cpu_score_millions=[math]::Round($cpuRaw / 1000000,2); ram_mbps=[math]::Round([double]$memoryResult.effective_mbps); storage_write_mbps=[math]::Round([double]$storageResult.sequential_write_mbps); storage_read_mbps=[math]::Round([double]$storageResult.sequential_read_mbps) }
    $result = [pscustomobject]@{ schema_version = '1.1'; benchmark_version = $benchmarkVersion; run_id = $runId; timestamp = (Get-Date).ToString('o'); computer = $systemInfo.computer; operating_system = $systemInfo.operating_system; cpu = $systemInfo.cpu; motherboard = $systemInfo.motherboard; bios = $systemInfo.bios; memory = $systemInfo.memory; gpus = $systemInfo.gpus; nvidia_gpus = $systemInfo.nvidia_gpus; physical_disks = $systemInfo.physical_disks; logical_disks = $systemInfo.logical_disks; power_plan = $systemInfo.power_plan; preflight = $preflight; privacy = [pscustomobject]@{ serial_numbers_visible_in_report = $showSerials }; display=$display; npu=$npuResult; gpu=[pscustomobject]@{compute_benchmark_status='not_run'}; benchmarks = [pscustomobject]@{ cpu = $cpuResult; memory = $memoryResult; storage = $storageResult }; status = $status; warnings = @($warnings); errors = @($errors) }
    $computerName = $result.computer.computer_name; if ([string]::IsNullOrWhiteSpace($computerName)) { $computerName = 'UNKNOWN' }; $safeName = $computerName -replace '[^A-Za-z0-9_-]', '_'; $jsonPath = Join-Path $ResultsPath "EXPC_Benchmark_Stage3_${safeName}_${dateTag}_${runId}.json"
    [IO.File]::WriteAllText($jsonPath, ($result | ConvertTo-Json -Depth 12), [Text.UTF8Encoding]::new($false)); $null = Get-Content -LiteralPath $jsonPath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
    Write-Log "Benchmark JSON saved: $jsonPath"
    Write-Log 'Starting report creation with Build-ReportV2.ps1.'
    $reportResult = $null; $v2Succeeded = $false; $fallbackUsed = $false
    if (Test-Path -LiteralPath $BuildReportV2Path -PathType Leaf) {
        try {
            $parseTokens = $null; $parseErrors = $null
            [System.Management.Automation.Language.Parser]::ParseFile($BuildReportV2Path, [ref]$parseTokens, [ref]$parseErrors) | Out-Null
            if (@($parseErrors).Count -ne 0) { throw "Build-ReportV2.ps1 Parser errors: $(@($parseErrors).Count)" }
            $v2Prefix = "Stage3_$safeName"
            $reportResult = @(& $BuildReportV2Path -BenchmarkData $result -ProjectRoot $ProjectRoot -OutputPrefix $v2Prefix) | Select-Object -Last 1
            if ($null -eq $reportResult -or -not $reportResult.completed -or -not (Test-Path -LiteralPath $reportResult.csv_path -PathType Leaf) -or -not (Test-Path -LiteralPath $reportResult.html_path -PathType Leaf)) { throw 'Build-ReportV2.ps1 returned an incomplete result.' }
            $v2Succeeded = $true; Write-Log "V2 report created: CSV $($reportResult.csv_path); HTML $($reportResult.html_path)"
        }
        catch { Write-Log "WARNING: V2 report creation failed: $($_.Exception.Message)" }
    }
    else { Write-Log 'WARNING: Build-ReportV2.ps1 is missing; stable fallback will be used.' }
    if (-not $v2Succeeded) {
        $fallbackUsed = $true; Write-Log 'Starting stable Build-Report.ps1 fallback.'
        $reportResult = @(& $BuildReportPath -Benchmark $result -ProjectRoot $ProjectRoot -JsonPath $jsonPath -RunId $runId) | Select-Object -Last 1
        Write-Log 'Stable Build-Report.ps1 fallback completed.'
    }
    if ($null -eq $reportResult -or -not $reportResult.completed) {
        $reportErrors = if ($null -eq $reportResult) { @('Build-Report.ps1 returned no result.') } else { @($reportResult.errors) }
        $errors = @($errors) + $reportErrors; $status = 'partial'; Write-Log "ERROR: Report creation failed: $($reportErrors -join ' | ')"
    }
    else {
        Write-Log "CSV created: $($reportResult.csv_path); V2 used: $v2Succeeded; fallback used: $fallbackUsed"
        $csvCheck = @(Import-Csv -LiteralPath $reportResult.csv_path -Delimiter ';')
        if ($csvCheck.Count -ne 1) { $errors = @($errors) + @('CSV validation failed in launcher.'); $status = 'partial'; Write-Log 'ERROR: CSV validation failed in launcher.' } else { Write-Log 'CSV Import-Csv validation passed.' }
        Write-Log "HTML created: $($reportResult.html_path); size $((Get-Item -LiteralPath $reportResult.html_path).Length) bytes"
        $htmlCheck = Get-Content -LiteralPath $reportResult.html_path -Raw -ErrorAction Stop
        if ($htmlCheck.Length -eq 0 -or $htmlCheck -notmatch '<!DOCTYPE html>' -or $htmlCheck -notmatch 'EXPC WORKSTATION BENCHMARK REPORT' -or $htmlCheck -notmatch '<style>' -or $htmlCheck -match 'https?://') { $errors = @($errors) + @('HTML autonomous validation failed in launcher.'); $status = 'partial'; Write-Log 'ERROR: HTML autonomous validation failed in launcher.' } else { Write-Log 'HTML autonomous validation passed.' }
    }
    $result.warnings = @($warnings); $result.errors = @($errors); $result.status = $status
    [IO.File]::WriteAllText($jsonPath, ($result | ConvertTo-Json -Depth 12), [Text.UTF8Encoding]::new($false)); $null = Get-Content -LiteralPath $jsonPath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
    $openReport = $false; $openProperty = $config.PSObject.Properties['open_report_after_finish']; if ($null -ne $openProperty) { try { $openReport = [bool]$openProperty.Value } catch { $warnings += 'open_report_after_finish was invalid; report was not opened.' } }
    if ($openReport -and $null -ne $reportResult -and $reportResult.html_created) { try { Write-Log 'Attempting to open HTML report in the default browser.'; Start-Process -FilePath $reportResult.html_path -ErrorAction Stop; Write-Host 'Report opened in default browser.' } catch { $warnings += "Report could not be opened: $($_.Exception.Message)"; $result.warnings = @($warnings); [IO.File]::WriteAllText($jsonPath, ($result | ConvertTo-Json -Depth 12), [Text.UTF8Encoding]::new($false)); Write-Log "WARNING: Report opening failed ($($_.Exception.Message))" } }
    Write-Host ''; Write-Host "EXPC AI Benchmark Portable v$benchmarkVersion" -ForegroundColor Cyan; Write-Host "`nSYSTEM"; Write-Host "Computer: $($result.computer.computer_name)"; Write-Host "CPU: $($result.cpu.name)"; Write-Host "Motherboard: $($result.motherboard.manufacturer) $($result.motherboard.product)"; Write-Host "RAM: $($result.memory.total_gb) GB"; Write-Host "GPU: $((@($result.gpus | ForEach-Object { $_.name }) -join '; '))"; Write-Host "Storage target: $($storageResult.test_path)"; Write-Host "Power plan: $($result.power_plan.name)"
    Write-Host "`nCPU BENCHMARK"; Write-Host "Threads: $($cpuResult.logical_threads_used)"; Write-Host "Duration: $($cpuResult.duration_seconds) s"; Write-Host "Operations/sec: $($cpuResult.operations_per_second)"; Write-Host "Score: $($cpuResult.score)"
    Write-Host "`nMEMORY BENCHMARK"; Write-Host "Test size: $($memoryResult.test_size_mb) MB"; Write-Host "Write: $($memoryResult.write_mbps) MB/s"; Write-Host "Copy: $($memoryResult.copy_mbps) MB/s"; Write-Host "Read: $($memoryResult.read_mbps) MB/s"; Write-Host "Effective: $($memoryResult.effective_mbps) MB/s"
    Write-Host "`nSTORAGE BENCHMARK"; Write-Host "Drive: $($storageResult.drive)"; Write-Host "Disk: $($storageResult.disk_model)"; Write-Host "Test size: $($storageResult.test_size_mb) MB"; Write-Host "Write: $($storageResult.sequential_write_mbps) MB/s"; Write-Host "Read: $($storageResult.sequential_read_mbps) MB/s"; Write-Host "Test file deleted: $($storageResult.test_file_deleted)"
    Write-Host "`nFILES"; Write-Host "JSON: $jsonPath"; Write-Host "CSV: $($reportResult.csv_path)"; Write-Host "HTML: $($reportResult.html_path)"; Write-Host "Log: $logPath"
    Write-Host "`nSTATUS"; Write-Host "Status: $status"; Write-Host "Warnings: $(@($warnings).Count)"; Write-Host "Errors: $(@($errors).Count)"; Write-Host "Result JSON: $jsonPath" -ForegroundColor Green; Write-Log "Stage 4 completed with status: $status"
}
catch { Write-Log "ERROR: $($_.Exception.Message)"; throw }
