<#
    EXPC AI Benchmark Portable - System configuration collector (stage 2)
    Collects local data only and returns one PSCustomObject.
#>
[CmdletBinding()]
param(
    [string]$RunId,
    [string]$BenchmarkVersion
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Continue'
$ProjectRoot = Split-Path -Parent $PSScriptRoot
$warnings = [System.Collections.Generic.List[string]]::new()
$errors = [System.Collections.Generic.List[string]]::new()

function Add-CollectorWarning([string]$Message) {
    [void]$warnings.Add($Message)
}

function Get-Value($Object, [string]$Name) {
    if ($null -eq $Object) { return $null }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) { return $null }
    return $property.Value
}

function Get-CimData([string]$ClassName, [string]$Section, [string]$Filter) {
    try {
        if ([string]::IsNullOrWhiteSpace($Filter)) {
            return @(Get-CimInstance -ClassName $ClassName -ErrorAction Stop)
        }
        return @(Get-CimInstance -ClassName $ClassName -Filter $Filter -ErrorAction Stop)
    }
    catch {
        Add-CollectorWarning "${Section}: CIM class $ClassName is unavailable ($($_.Exception.Message))"
        return @()
    }
}

function Convert-BytesToGb($Bytes) {
    if ($null -eq $Bytes) { return $null }
    return [math]::Round(([double]$Bytes / 1GB), 2)
}

function Convert-DateValue($Value) {
    if ($null -eq $Value) { return $null }
    try { return ([datetime]$Value).ToString('o') } catch { return [string]$Value }
}

function Get-BootMode {
    try {
        $firmware = Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop | Select-Object -First 1
        $result = Get-Value $firmware 'BootupState'
        if ($result -match 'UEFI') { return 'UEFI' }
    }
    catch { }
    try {
        $firmwareType = [Environment]::GetEnvironmentVariable('firmware_type')
        if ($firmwareType -match 'UEFI') { return 'UEFI' }
        if ($firmwareType -match 'BIOS|Legacy') { return 'Legacy' }
    }
    catch { }
    return 'Unknown'
}

function Get-NvidiaData {
    $command = Get-Command 'nvidia-smi.exe' -ErrorAction SilentlyContinue
    if ($null -eq $command) { $command = Get-Command 'nvidia-smi' -ErrorAction SilentlyContinue }
    if ($null -eq $command) {
        Add-CollectorWarning 'NVIDIA: nvidia-smi was not found; NVIDIA telemetry was skipped.'
        return @()
    }
    try {
        $lines = & $command.Source '--query-gpu=name,driver_version,memory.total,temperature.gpu,power.limit,pci.bus_id' '--format=csv,noheader,nounits' 2>$null
        if ($LASTEXITCODE -ne 0) { throw "nvidia-smi exited with code $LASTEXITCODE" }
        $items = @()
        foreach ($line in @($lines)) {
            $fields = @($line -split ',' | ForEach-Object { $_.Trim() })
            if ($fields.Count -ge 6) {
                $items += [pscustomobject]@{
                    name = $fields[0]; driver_version = $fields[1]; memory_total_mb = $fields[2]
                    temperature_gpu_c = $fields[3]; power_limit_w = $fields[4]; pci_bus_id = $fields[5]
                }
            }
        }
        return $items
    }
    catch {
        Add-CollectorWarning "NVIDIA: nvidia-smi query failed ($($_.Exception.Message))"
        return @()
    }
}

if ([string]::IsNullOrWhiteSpace($RunId)) { $RunId = [guid]::NewGuid().Guid }
if ([string]::IsNullOrWhiteSpace($BenchmarkVersion)) {
    $versionFile = Join-Path $ProjectRoot 'VERSION.txt'
    try { $BenchmarkVersion = (Get-Content -LiteralPath $versionFile -Raw -ErrorAction Stop).Trim() } catch { $BenchmarkVersion = '0.1.0' }
}

$computerSystem = (Get-CimData 'Win32_ComputerSystem' 'computer' $null | Select-Object -First 1)
$operatingSystem = (Get-CimData 'Win32_OperatingSystem' 'operating_system' $null | Select-Object -First 1)
$processor = (Get-CimData 'Win32_Processor' 'cpu' $null | Select-Object -First 1)
$baseboard = (Get-CimData 'Win32_BaseBoard' 'motherboard' $null | Select-Object -First 1)
$biosData = (Get-CimData 'Win32_BIOS' 'bios' $null | Select-Object -First 1)
$memoryModules = Get-CimData 'Win32_PhysicalMemory' 'memory' $null
$videoControllers = Get-CimData 'Win32_VideoController' 'gpus' $null

$edition = $null
try {
    $edition = (Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -ErrorAction Stop).EditionID
}
catch { Add-CollectorWarning 'operating_system: Windows edition is unavailable.' }

$uptime = $null
try {
    $boot = [datetime](Get-Value $operatingSystem 'LastBootUpTime')
    $uptime = [math]::Floor(((Get-Date) - $boot).TotalSeconds)
}
catch { Add-CollectorWarning 'operating_system: uptime could not be calculated.' }

$modules = @($memoryModules | ForEach-Object {
    $capacity = Get-Value $_ 'Capacity'
    $manufacturerRaw = Get-Value $_ 'Manufacturer'
    $manufacturerText = (([string]$manufacturerRaw).Trim())
    if ($manufacturerText -match '^(?:0x[0-9a-fA-F]+|\d+)$') { $manufacturerText = 'Unknown' }
    [pscustomobject]@{
        manufacturer = $manufacturerText; manufacturer_raw = $manufacturerRaw; part_number = ((Get-Value $_ 'PartNumber') -as [string]).Trim()
        serial_number = Get-Value $_ 'SerialNumber'; capacity_bytes = $capacity; capacity_gb = Convert-BytesToGb $capacity
        speed_mts = Get-Value $_ 'Speed'; configured_speed_mts = Get-Value $_ 'ConfiguredClockSpeed'
        bank_label = Get-Value $_ 'BankLabel'; device_locator = Get-Value $_ 'DeviceLocator'
        form_factor = Get-Value $_ 'FormFactor'; memory_type = Get-Value $_ 'SMBIOSMemoryType'
    }
})
$configuredSpeeds = @($modules | Where-Object { $null -ne $_.configured_speed_mts } | Select-Object -ExpandProperty configured_speed_mts -Unique)
$configuredSpeed = if ($configuredSpeeds.Count -eq 1) { $configuredSpeeds[0] } else { $null }

$gpus = @($videoControllers | ForEach-Object {
    $ram = Get-Value $_ 'AdapterRAM'
    # Some drivers expose invalid 32-bit adapter RAM values; keep only plausible values.
    if ($null -ne $ram -and ([uint64]$ram -lt 64MB -or [uint64]$ram -gt 512GB)) { $ram = $null }
    $name = Get-Value $_ 'Name'
    $isVirtual = ([string]$name -match 'Virtual|Remote|USB Mobile Monitor|Basic Display|Indirect Display|Mirror|RDP')
    [pscustomobject]@{
        name = $name; is_virtual_adapter = $isVirtual; adapter_ram_bytes = $ram; driver_version = Get-Value $_ 'DriverVersion'
        driver_date = Convert-DateValue (Get-Value $_ 'DriverDate'); video_processor = Get-Value $_ 'VideoProcessor'
        pnp_device_id = Get-Value $_ 'PNPDeviceID'
    }
})

$physicalDisks = @()
try {
    $physicalCommand = Get-Command Get-PhysicalDisk -ErrorAction Stop
    $physicalDisks = @(& $physicalCommand.Source -ErrorAction Stop | ForEach-Object {
        $size = Get-Value $_ 'Size'
        [pscustomobject]@{
            friendly_name = Get-Value $_ 'FriendlyName'; model = Get-Value $_ 'Model'; serial_number = Get-Value $_ 'SerialNumber'
            media_type = Get-Value $_ 'MediaType'; bus_type = Get-Value $_ 'BusType'; size_bytes = $size; size_gb = Convert-BytesToGb $size
            health_status = Get-Value $_ 'HealthStatus'; operational_status = Get-Value $_ 'OperationalStatus'; firmware_version = Get-Value $_ 'FirmwareVersion'
        }
    })
}
catch {
    Add-CollectorWarning 'physical_disks: Get-PhysicalDisk is unavailable; using CIM fallback.'
    $physicalDisks = @(Get-CimData 'Win32_DiskDrive' 'physical_disks' $null | ForEach-Object {
        $size = Get-Value $_ 'Size'
        [pscustomobject]@{
            friendly_name = Get-Value $_ 'Caption'; model = Get-Value $_ 'Model'; serial_number = ((Get-Value $_ 'SerialNumber') -as [string]).Trim()
            media_type = Get-Value $_ 'MediaType'; bus_type = Get-Value $_ 'InterfaceType'; size_bytes = $size; size_gb = Convert-BytesToGb $size
            health_status = $null; operational_status = Get-Value $_ 'Status'; firmware_version = Get-Value $_ 'FirmwareRevision'
        }
    })
}

$logicalDisks = @(Get-CimData 'Win32_LogicalDisk' 'logical_disks' 'DriveType = 3' | ForEach-Object {
    $size = Get-Value $_ 'Size'; $free = Get-Value $_ 'FreeSpace'
    $freePercent = if ($null -ne $size -and [uint64]$size -gt 0 -and $null -ne $free) { [math]::Round((100.0 * [double]$free / [double]$size), 2) } else { $null }
    [pscustomobject]@{
        device_id = Get-Value $_ 'DeviceID'; volume_name = Get-Value $_ 'VolumeName'; file_system = Get-Value $_ 'FileSystem'
        size_bytes = $size; size_gb = Convert-BytesToGb $size; free_bytes = $free; free_gb = Convert-BytesToGb $free
        free_percent = $freePercent; drive_type = Get-Value $_ 'DriveType'
    }
})

$powerRaw = $null; $powerGuid = $null; $powerName = $null
try {
    $powerRaw = ((& powercfg /getactivescheme 2>$null) -join ' ').Trim()
    if ($LASTEXITCODE -ne 0) { throw "powercfg exited with code $LASTEXITCODE" }
    if ($powerRaw -match '([0-9a-fA-F]{8}(?:-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12})') { $powerGuid = $matches[1] }
    if ($powerRaw -match '\((.+)\)') { $powerName = $matches[1] }
}
catch { Add-CollectorWarning "power_plan: active plan could not be read ($($_.Exception.Message))" }

[pscustomobject]@{
    computer = [pscustomobject]@{
        computer_name = Get-Value $computerSystem 'Name'; manufacturer = Get-Value $computerSystem 'Manufacturer'
        model = Get-Value $computerSystem 'Model'; system_type = Get-Value $computerSystem 'SystemType'
        total_physical_memory_bytes = Get-Value $computerSystem 'TotalPhysicalMemory'
    }
    operating_system = [pscustomobject]@{
        caption = Get-Value $operatingSystem 'Caption'; edition = $edition; version = Get-Value $operatingSystem 'Version'
        build_number = Get-Value $operatingSystem 'BuildNumber'; architecture = Get-Value $operatingSystem 'OSArchitecture'
        install_date = Convert-DateValue (Get-Value $operatingSystem 'InstallDate'); last_boot_time = Convert-DateValue (Get-Value $operatingSystem 'LastBootUpTime'); uptime_seconds = $uptime
    }
    cpu = [pscustomobject]@{
        manufacturer = Get-Value $processor 'Manufacturer'; name = Get-Value $processor 'Name'; socket = Get-Value $processor 'SocketDesignation'
        physical_cores = Get-Value $processor 'NumberOfCores'; logical_processors = Get-Value $processor 'NumberOfLogicalProcessors'
        max_clock_mhz = Get-Value $processor 'MaxClockSpeed'; current_clock_mhz = Get-Value $processor 'CurrentClockSpeed'
        l2_cache_kb = Get-Value $processor 'L2CacheSize'; l3_cache_kb = Get-Value $processor 'L3CacheSize'
        virtualization_firmware_enabled = Get-Value $processor 'VirtualizationFirmwareEnabled'
    }
    motherboard = [pscustomobject]@{ manufacturer = Get-Value $baseboard 'Manufacturer'; product = Get-Value $baseboard 'Product'; version = Get-Value $baseboard 'Version'; serial_number = Get-Value $baseboard 'SerialNumber' }
    bios = [pscustomobject]@{ manufacturer = Get-Value $biosData 'Manufacturer'; smbios_version = Get-Value $biosData 'SMBIOSBIOSVersion'; release_date = Convert-DateValue (Get-Value $biosData 'ReleaseDate'); serial_number = Get-Value $biosData 'SerialNumber'; boot_mode = Get-BootMode }
    memory = [pscustomobject]@{ total_bytes = Get-Value $computerSystem 'TotalPhysicalMemory'; total_gb = Convert-BytesToGb (Get-Value $computerSystem 'TotalPhysicalMemory'); configured_speed_mts = $configuredSpeed; modules = $modules }
    gpus = $gpus
    nvidia_gpus = Get-NvidiaData
    physical_disks = $physicalDisks
    logical_disks = $logicalDisks
    power_plan = [pscustomobject]@{ guid = $powerGuid; name = $powerName; raw = $powerRaw }
    benchmark = [pscustomobject]@{ benchmark_version = $BenchmarkVersion; schema_version = '1.0'; timestamp = (Get-Date).ToString('o'); run_id = $RunId; collector_version = '0.1.0' }
    warnings = @($warnings)
    errors = @($errors)
}
