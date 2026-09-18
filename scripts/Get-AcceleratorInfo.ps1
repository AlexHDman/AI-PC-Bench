#requires -Version 5.1
<#
.SYNOPSIS
    AI PC Bench - Accelerator Discovery

.DESCRIPTION
    Discovers CPU, physical GPU adapters and NPU devices.

    This script performs discovery only.
    It does NOT run performance benchmarks.

    Output model:
      CPU
      GPU / dGPU / iGPU
      NPU

    Virtual, remote and Microsoft basic display adapters are excluded
    from accelerator benchmarking candidates.

.NOTES
    Project : AI PC Bench
    Module  : Accelerator Discovery
#>

[CmdletBinding()]
param(
    [switch]$AsJson,
    [switch]$Quiet
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

function Get-SafeProperty {
    param(
        [Parameter(Mandatory)]
        $Object,

        [Parameter(Mandatory)]
        [string]$Name,

        $Default = $null
    )

    if ($null -eq $Object) {
        return $Default
    }

    $property = $Object.PSObject.Properties[$Name]

    if ($null -eq $property) {
        return $Default
    }

    if ($null -eq $property.Value) {
        return $Default
    }

    return $property.Value
}


function Get-VendorFromName {
    param(
        [string]$Name,
        [string]$PNPDeviceID
    )

    $text = "$Name $PNPDeviceID"

    if ($text -match '(?i)NVIDIA|VEN_10DE') {
        return 'NVIDIA'
    }

    if ($text -match '(?i)AMD|Advanced Micro Devices|Radeon|VEN_1002') {
        return 'AMD'
    }

    if ($text -match '(?i)Intel|VEN_8086') {
        return 'Intel'
    }

    if ($text -match '(?i)Qualcomm|VEN_17CB') {
        return 'Qualcomm'
    }

    if ($text -match '(?i)Microsoft') {
        return 'Microsoft'
    }

    return 'Unknown'
}


function Test-VirtualAdapter {
    param(
        [string]$Name,
        [string]$PNPDeviceID
    )

    $text = "$Name $PNPDeviceID"

    $patterns = @(
        'Microsoft Basic Display',
        'Remote Display',
        'RemoteFX',
        'RDP',
        'VirtualBox',
        'VMware',
        'Hyper-V',
        'Parallels',
        'Citrix',
        'Indirect Display',
        'IDD',
        'Virtual Display',
        'Parsec Virtual',
        'Dummy Display'
    )

    foreach ($pattern in $patterns) {
        if ($text -match [regex]::Escape($pattern)) {
            return $true
        }
    }

    return $false
}


function Get-GpuType {
    param(
        [string]$Vendor,
        [string]$Name,
        [UInt64]$AdapterRAM,
        [string]$PNPDeviceID
    )

    # Do not guess when classification is uncertain.
    #
    # NVIDIA GeForce / RTX / GTX workstation adapters are normally discrete.
    if ($Vendor -eq 'NVIDIA') {
        if ($Name -match '(?i)GeForce|RTX|GTX|Quadro|Tesla|TITAN|NVIDIA RTX') {
            return 'dGPU'
        }

        return 'GPU'
    }

    # Intel naming gives us some reliable cases.
   if ($Vendor -eq 'Intel') {

    # Generic "Intel(R) Graphics" is the integrated GPU naming
    # used by current Intel Core Ultra desktop platforms.
    if ($Name -match '(?i)^Intel\(R\) Graphics$') {
        return 'iGPU'
    }

    if ($Name -match '(?i)UHD Graphics|Iris|HD Graphics') {
        return 'iGPU'
    }

    # Intel Arc may be integrated or discrete depending on platform.
    # Do not guess without stronger hardware evidence.
    return 'GPU'
	}

    # AMD naming alone is not always sufficient to distinguish
    # integrated Radeon graphics from discrete Radeon adapters.
    if ($Vendor -eq 'AMD') {
        if ($Name -match '(?i)Radeon RX|Radeon PRO W|FirePro') {
            return 'dGPU'
        }

        return 'GPU'
    }

    return 'GPU'
}


function Get-BackendCandidates {
    param(
        [string]$Vendor,
        [string]$Type
    )

    switch ($Type) {
        'CPU' {
            return @(
                'CPU'
                'ONNX Runtime CPU'
                'OpenVINO CPU'
            )
        }

        'NPU' {
            switch ($Vendor) {
                'Intel' {
                    return @(
                        'OpenVINO NPU'
                        'ONNX Runtime'
                    )
                }

                'AMD' {
                    return @(
                        'Vendor Runtime'
                        'ONNX Runtime'
                    )
                }

                'Qualcomm' {
                    return @(
                        'Vendor Runtime'
                        'ONNX Runtime'
                    )
                }

                default {
                    return @('Unknown')
                }
            }
        }

        default {
            switch ($Vendor) {
                'NVIDIA' {
                    return @(
                        'CUDA'
                        'DirectML'
                        'ONNX Runtime'
                    )
                }

                'AMD' {
                    return @(
                        'DirectML'
                        'ONNX Runtime'
                    )
                }

                'Intel' {
                    return @(
                        'OpenVINO GPU'
                        'DirectML'
                        'ONNX Runtime'
                    )
                }

                default {
                    return @('DirectML')
                }
            }
        }
    }
}


function Convert-BytesToGB {
    param(
        [UInt64]$Bytes
    )

    if ($Bytes -le 0) {
        return $null
    }

    return [math]::Round(($Bytes / 1GB), 2)
}


# ---------------------------------------------------------------------------
# Result container
# ---------------------------------------------------------------------------

$devices = New-Object System.Collections.Generic.List[object]


# ---------------------------------------------------------------------------
# CPU discovery
# ---------------------------------------------------------------------------

try {
    $cpuList = @(Get-CimInstance Win32_Processor)

    $cpuIndex = 0

    foreach ($cpu in $cpuList) {
        $cpuIndex++

        $name = ([string](Get-SafeProperty $cpu 'Name' '')).Trim()
        $manufacturer = [string](Get-SafeProperty $cpu 'Manufacturer' '')
        $vendor = Get-VendorFromName -Name "$manufacturer $name" -PNPDeviceID ''

        $cores = [int](Get-SafeProperty $cpu 'NumberOfCores' 0)
        $threads = [int](Get-SafeProperty $cpu 'NumberOfLogicalProcessors' 0)
        $maxClock = [int](Get-SafeProperty $cpu 'MaxClockSpeed' 0)

        $devices.Add([pscustomobject][ordered]@{
            Id                  = "CPU-$cpuIndex"
            Device              = 'CPU'
            Vendor              = $vendor
            Type                = 'CPU'
            Name                = $name
            Driver              = $null
            VRAM_GB             = $null
            PhysicalCores       = $cores
            LogicalProcessors   = $threads
            MaxClockMHz         = $maxClock
            PNPDeviceID         = $null
            BackendCandidates   = @(Get-BackendCandidates -Vendor $vendor -Type 'CPU')
            Available           = $true
            BenchmarkStatus     = 'not_run'
            Score               = $null
            LatencyMs           = $null
            Throughput          = $null
            Errors              = @()
        })
    }
}
catch {
    if (-not $Quiet) {
        Write-Warning "CPU discovery failed: $($_.Exception.Message)"
    }
}


# ---------------------------------------------------------------------------
# GPU discovery
# ---------------------------------------------------------------------------

$gpuIndex = 0

try {
    $videoControllers = @(Get-CimInstance Win32_VideoController)

    foreach ($gpu in $videoControllers) {

        $name = ([string](Get-SafeProperty $gpu 'Name' '')).Trim()
        $pnpId = [string](Get-SafeProperty $gpu 'PNPDeviceID' '')

        if ([string]::IsNullOrWhiteSpace($name)) {
            continue
        }

        if (Test-VirtualAdapter -Name $name -PNPDeviceID $pnpId) {
            continue
        }

        $gpuIndex++

        $vendor = Get-VendorFromName -Name $name -PNPDeviceID $pnpId

        $adapterRamRaw = Get-SafeProperty $gpu 'AdapterRAM' 0

        try {
            $adapterRam = [UInt64]$adapterRamRaw
        }
        catch {
            $adapterRam = 0
        }

        $gpuType = Get-GpuType `
            -Vendor $vendor `
            -Name $name `
            -AdapterRAM $adapterRam `
            -PNPDeviceID $pnpId

        $driver = [string](Get-SafeProperty $gpu 'DriverVersion' '')
        $vramGB = Convert-BytesToGB -Bytes $adapterRam

        $devices.Add([pscustomobject][ordered]@{
            Id                  = "GPU-$gpuIndex"
            Device              = 'GPU'
            Vendor              = $vendor
            Type                = $gpuType
            Name                = $name
            Driver              = $driver
            VRAM_GB             = $vramGB
            PhysicalCores       = $null
            LogicalProcessors   = $null
            MaxClockMHz         = $null
            PNPDeviceID         = $pnpId
            BackendCandidates   = @(Get-BackendCandidates -Vendor $vendor -Type $gpuType)
            Available           = $true
            BenchmarkStatus     = 'not_run'
            Score               = $null
            LatencyMs           = $null
            Throughput          = $null
            Errors              = @()
        })
    }
}
catch {
    if (-not $Quiet) {
        Write-Warning "GPU discovery failed: $($_.Exception.Message)"
    }
}


# ---------------------------------------------------------------------------
# NVIDIA refinement using nvidia-smi
# ---------------------------------------------------------------------------

try {
    $nvidiaSmi = Get-Command 'nvidia-smi.exe' -ErrorAction SilentlyContinue

    if ($null -ne $nvidiaSmi) {

        $rows = @(
            & $nvidiaSmi.Source `
                '--query-gpu=name,memory.total,driver_version' `
                '--format=csv,noheader,nounits' 2>$null
        )

        $nvidiaDevices = @(
            $devices | Where-Object {
                $_.Device -eq 'GPU' -and $_.Vendor -eq 'NVIDIA'
            }
        )

        for ($i = 0; $i -lt $rows.Count; $i++) {

            if ($i -ge $nvidiaDevices.Count) {
                break
            }

            $parts = @($rows[$i] -split ',')

            if ($parts.Count -lt 3) {
                continue
            }

            $smiName = $parts[0].Trim()
            $memoryMBText = $parts[1].Trim()
            $driverVersion = $parts[2].Trim()

            [double]$memoryMB = 0

            if ([double]::TryParse(
                $memoryMBText,
                [Globalization.NumberStyles]::Any,
                [Globalization.CultureInfo]::InvariantCulture,
                [ref]$memoryMB
            )) {
                $nvidiaDevices[$i].VRAM_GB = [math]::Round(($memoryMB / 1024), 2)
            }

            if (-not [string]::IsNullOrWhiteSpace($driverVersion)) {
                $nvidiaDevices[$i].Driver = $driverVersion
            }

            if (-not [string]::IsNullOrWhiteSpace($smiName)) {
                $nvidiaDevices[$i].Name = $smiName
            }

            $nvidiaDevices[$i].Type = 'dGPU'
        }
    }
}
catch {
    if (-not $Quiet) {
        Write-Warning "NVIDIA refinement skipped: $($_.Exception.Message)"
    }
}


# ---------------------------------------------------------------------------
# NPU discovery
# ---------------------------------------------------------------------------

$npuCandidates = New-Object System.Collections.Generic.List[object]

try {
    $pnpDevices = @(
        Get-CimInstance Win32_PnPEntity |
        Where-Object {
            $name = [string](Get-SafeProperty $_ 'Name' '')
            $desc = [string](Get-SafeProperty $_ 'Description' '')
            $text = "$name $desc"

            $text -match '(?i)\bNPU\b' -or
            $text -match '(?i)Neural Processing' -or
            $text -match '(?i)AI Boost' -or
            $text -match '(?i)Ryzen AI' -or
            $text -match '(?i)Neural Processor' -or
            $text -match '(?i)Qualcomm.*AI' -or
            $text -match '(?i)Intel.*IPU'
        }
    )

    foreach ($npu in $pnpDevices) {

        $name = ([string](Get-SafeProperty $npu 'Name' '')).Trim()
        $pnpId = [string](Get-SafeProperty $npu 'PNPDeviceID' '')
        $status = [string](Get-SafeProperty $npu 'Status' '')

        if ([string]::IsNullOrWhiteSpace($name)) {
            continue
        }

        $alreadyExists = $false

        foreach ($existing in $npuCandidates) {
            if (
                (-not [string]::IsNullOrWhiteSpace($pnpId)) -and
                ($existing.PNPDeviceID -eq $pnpId)
            ) {
                $alreadyExists = $true
                break
            }

            if ($existing.Name -eq $name) {
                $alreadyExists = $true
                break
            }
        }

        if ($alreadyExists) {
            continue
        }

        $vendor = Get-VendorFromName -Name $name -PNPDeviceID $pnpId

        $npuCandidates.Add([pscustomobject][ordered]@{
            Name        = $name
            Vendor      = $vendor
            PNPDeviceID = $pnpId
            Status      = $status
        })
    }
}
catch {
    if (-not $Quiet) {
        Write-Warning "PnP NPU discovery failed: $($_.Exception.Message)"
    }
}


# ---------------------------------------------------------------------------
# Reuse existing AI PC Bench NPU discovery if available
# ---------------------------------------------------------------------------

$legacyNpuScript = Join-Path $PSScriptRoot 'Get-NPUInfo.ps1'

if (Test-Path -LiteralPath $legacyNpuScript) {

    try {
        $legacyOutput = & $legacyNpuScript 2>$null

        foreach ($item in @($legacyOutput)) {

            if ($null -eq $item) {
                continue
            }

            # Existing script may return objects with different property names.
            $candidateName = $null

            foreach ($propertyName in @(
                'Name',
                'DeviceName',
                'FriendlyName',
                'NPUName'
            )) {
                $value = Get-SafeProperty $item $propertyName $null

                if (-not [string]::IsNullOrWhiteSpace([string]$value)) {
                    $candidateName = ([string]$value).Trim()
                    break
                }
            }

            if ([string]::IsNullOrWhiteSpace($candidateName)) {
                continue
            }

            $candidatePnp = [string](Get-SafeProperty $item 'PNPDeviceID' '')
            $vendor = Get-VendorFromName `
                -Name $candidateName `
                -PNPDeviceID $candidatePnp

            $alreadyExists = $false

            foreach ($existing in $npuCandidates) {

                if (
                    (-not [string]::IsNullOrWhiteSpace($candidatePnp)) -and
                    ($existing.PNPDeviceID -eq $candidatePnp)
                ) {
                    $alreadyExists = $true
                    break
                }

                if ($existing.Name -eq $candidateName) {
                    $alreadyExists = $true
                    break
                }
            }

            if (-not $alreadyExists) {
                $npuCandidates.Add([pscustomobject][ordered]@{
                    Name        = $candidateName
                    Vendor      = $vendor
                    PNPDeviceID = $candidatePnp
                    Status      = 'Detected'
                })
            }
        }
    }
    catch {
        if (-not $Quiet) {
            Write-Warning "Existing Get-NPUInfo.ps1 could not be merged: $($_.Exception.Message)"
        }
    }
}


# ---------------------------------------------------------------------------
# Add NPU devices to common device model
# ---------------------------------------------------------------------------

$npuIndex = 0

foreach ($npu in $npuCandidates) {

    $npuIndex++

    $available = $true

    if (
        -not [string]::IsNullOrWhiteSpace($npu.Status) -and
        $npu.Status -match '(?i)Error|Degraded|Unknown'
    ) {
        $available = $false
    }

    $devices.Add([pscustomobject][ordered]@{
        Id                  = "NPU-$npuIndex"
        Device              = 'NPU'
        Vendor              = $npu.Vendor
        Type                = 'NPU'
        Name                = $npu.Name
        Driver              = $null
        VRAM_GB             = $null
        PhysicalCores       = $null
        LogicalProcessors   = $null
        MaxClockMHz         = $null
        PNPDeviceID         = $npu.PNPDeviceID
        BackendCandidates   = @(Get-BackendCandidates -Vendor $npu.Vendor -Type 'NPU')
        Available           = $available
        BenchmarkStatus     = 'not_run'
        Score               = $null
        LatencyMs           = $null
        Throughput          = $null
        Errors              = @()
    })
}


# ---------------------------------------------------------------------------
# Final result
# ---------------------------------------------------------------------------

$result = [pscustomobject][ordered]@{
    SchemaVersion = '1.0'
    GeneratedAt   = (Get-Date).ToString('yyyy-MM-ddTHH:mm:ssK')
    ComputerName  = $env:COMPUTERNAME

    Summary = [pscustomobject][ordered]@{
        CPUCount         = @($devices | Where-Object Device -eq 'CPU').Count
        GPUCount         = @($devices | Where-Object Device -eq 'GPU').Count
        DiscreteGPUCount = @($devices | Where-Object Type -eq 'dGPU').Count
        IntegratedGPUCount = @($devices | Where-Object Type -eq 'iGPU').Count
        NPUCount         = @($devices | Where-Object Device -eq 'NPU').Count
    }

    Devices = $devices.ToArray()
}


# ---------------------------------------------------------------------------
# Output
# ---------------------------------------------------------------------------

if ($AsJson) {
    $result | ConvertTo-Json -Depth 8
    return
}


if (-not $Quiet) {

    Write-Host ''
    Write-Host 'AI PC Bench - Accelerator Discovery' -ForegroundColor Cyan
    Write-Host '===================================' -ForegroundColor DarkGray
    Write-Host ''

    foreach ($device in $devices) {

        $typeText = $device.Type

        switch ($device.Device) {
            'CPU' {
                Write-Host (
                    '[CPU]  {0} | {1}C/{2}T' -f `
                    $device.Name,
                    $device.PhysicalCores,
                    $device.LogicalProcessors
                ) -ForegroundColor White
            }

            'GPU' {
                $vramText = ''

                if ($null -ne $device.VRAM_GB) {
                    $vramText = " | $($device.VRAM_GB) GB"
                }

                Write-Host (
                    '[{0}] {1} | {2}{3}' -f `
                    $typeText,
                    $device.Name,
                    $device.Vendor,
                    $vramText
                ) -ForegroundColor Yellow
            }

            'NPU' {
                Write-Host (
                    '[NPU]  {0} | {1}' -f `
                    $device.Name,
                    $device.Vendor
                ) -ForegroundColor Green
            }
        }
    }

    Write-Host ''
    Write-Host (
        'Detected: CPU={0} GPU={1} dGPU={2} iGPU={3} NPU={4}' -f `
        $result.Summary.CPUCount,
        $result.Summary.GPUCount,
        $result.Summary.DiscreteGPUCount,
        $result.Summary.IntegratedGPUCount,
        $result.Summary.NPUCount
    ) -ForegroundColor Cyan

    Write-Host ''
}


$result