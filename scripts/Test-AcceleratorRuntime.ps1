#requires -Version 5.1
<#
.SYNOPSIS
    AI PC Bench - Accelerator Runtime Detection

.DESCRIPTION
    Detects installed AI/compute runtimes and tools.
    No packages are installed and no benchmark workload is executed.

    Checks:
      - NVIDIA driver / nvidia-smi
      - CUDA toolkit
      - Python
      - ONNX Runtime
      - ONNX Runtime execution providers
      - OpenVINO
      - OpenVINO available devices (CPU/GPU/NPU)
      - DirectML package/runtime indicators

.NOTES
    Project : AI PC Bench
    Module  : Runtime Detection
#>

[CmdletBinding()]
param(
    [switch]$AsJson
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Continue'

$checks = @()


function Add-Check {
    param(
        [string]$Component,
        [string]$Target,
        [string]$Status,
        [string]$Version = '',
        [string]$Details = ''
    )

    $script:checks += [pscustomobject][ordered]@{
        Component = $Component
        Target    = $Target
        Status    = $Status
        Version   = $Version
        Details   = $Details
    }
}


function Find-CommandPath {
    param([string]$Name)

    $cmd = Get-Command $Name -ErrorAction SilentlyContinue |
        Select-Object -First 1

    if ($null -eq $cmd) {
        return $null
    }

    if ($cmd.Source) {
        return $cmd.Source
    }

    return $cmd.Path
}


function Invoke-ExternalText {
    param(
        [string]$Exe,
        [string[]]$Arguments
    )

    try {
        $output = & $Exe @Arguments 2>&1
        return (($output | Out-String).Trim())
    }
    catch {
        return $null
    }
}


# ---------------------------------------------------------------------------
# Hardware discovery
# ---------------------------------------------------------------------------

$discoveryScript = Join-Path $PSScriptRoot 'Get-AcceleratorInfo.ps1'

if (Test-Path -LiteralPath $discoveryScript) {
    try {
        $hardware = & $discoveryScript -Quiet

        Add-Check `
            -Component 'Hardware Discovery' `
            -Target 'Accelerators' `
            -Status 'AVAILABLE' `
            -Details (
                'CPU={0}; GPU={1}; dGPU={2}; iGPU={3}; NPU={4}' -f `
                $hardware.Summary.CPUCount,
                $hardware.Summary.GPUCount,
                $hardware.Summary.DiscreteGPUCount,
                $hardware.Summary.IntegratedGPUCount,
                $hardware.Summary.NPUCount
            )
    }
    catch {
        Add-Check `
            -Component 'Hardware Discovery' `
            -Target 'Accelerators' `
            -Status 'ERROR' `
            -Details $_.Exception.Message
    }
}
else {
    Add-Check `
        -Component 'Hardware Discovery' `
        -Target 'Accelerators' `
        -Status 'NOT INSTALLED' `
        -Details 'Get-AcceleratorInfo.ps1 not found'
}


# ---------------------------------------------------------------------------
# NVIDIA / nvidia-smi
# ---------------------------------------------------------------------------

$nvidiaSmi = Find-CommandPath 'nvidia-smi.exe'

if ($nvidiaSmi) {

    $driver = Invoke-ExternalText `
        -Exe $nvidiaSmi `
        -Arguments @(
            '--query-gpu=driver_version'
            '--format=csv,noheader'
        )

    $gpuName = Invoke-ExternalText `
        -Exe $nvidiaSmi `
        -Arguments @(
            '--query-gpu=name'
            '--format=csv,noheader'
        )

    Add-Check `
        -Component 'NVIDIA Driver' `
        -Target 'NVIDIA GPU' `
        -Status 'AVAILABLE' `
        -Version $driver `
        -Details $gpuName
}
else {
    Add-Check `
        -Component 'NVIDIA Driver' `
        -Target 'NVIDIA GPU' `
        -Status 'NOT INSTALLED' `
        -Details 'nvidia-smi.exe not found'
}


# ---------------------------------------------------------------------------
# CUDA Toolkit
# ---------------------------------------------------------------------------

$nvcc = Find-CommandPath 'nvcc.exe'

if ($nvcc) {

    $nvccText = Invoke-ExternalText `
        -Exe $nvcc `
        -Arguments @('--version')

    $cudaVersion = ''

    if ($nvccText -match 'release\s+([0-9.]+)') {
        $cudaVersion = $Matches[1]
    }

    Add-Check `
        -Component 'CUDA Toolkit' `
        -Target 'NVIDIA GPU' `
        -Status 'AVAILABLE' `
        -Version $cudaVersion `
        -Details $nvcc
}
else {

    $cudaPath = $env:CUDA_PATH

    if ($cudaPath -and (Test-Path -LiteralPath $cudaPath)) {
        Add-Check `
            -Component 'CUDA Toolkit' `
            -Target 'NVIDIA GPU' `
            -Status 'PARTIAL' `
            -Details "CUDA_PATH=$cudaPath; nvcc.exe not found in PATH"
    }
    else {
        Add-Check `
            -Component 'CUDA Toolkit' `
            -Target 'NVIDIA GPU' `
            -Status 'NOT INSTALLED' `
            -Details 'CUDA Toolkit compiler not detected'
    }
}


# ---------------------------------------------------------------------------
# Python
# ---------------------------------------------------------------------------

$python = Find-CommandPath 'python.exe'

if (-not $python) {
    $python = Find-CommandPath 'python'
}

if ($python) {

    $pythonVersion = Invoke-ExternalText `
        -Exe $python `
        -Arguments @('--version')

    Add-Check `
        -Component 'Python' `
        -Target 'Runtime Host' `
        -Status 'AVAILABLE' `
        -Version $pythonVersion `
        -Details $python
}
else {
    Add-Check `
        -Component 'Python' `
        -Target 'Runtime Host' `
        -Status 'NOT INSTALLED' `
        -Details 'python.exe not found in PATH'
}


# ---------------------------------------------------------------------------
# Python-based runtime checks
# ---------------------------------------------------------------------------

if ($python) {

    # ONNX Runtime
    $ortCode = @'
import json
try:
    import onnxruntime as ort
    print(json.dumps({
        "ok": True,
        "version": ort.__version__,
        "providers": ort.get_available_providers()
    }))
except Exception as e:
    print(json.dumps({
        "ok": False,
        "error": str(e)
    }))
'@

    try {
        $ortRaw = $ortCode | & $python - 2>$null
        $ortText = (($ortRaw | Out-String).Trim())

        if ($ortText) {
            $ort = $ortText | ConvertFrom-Json

            if ($ort.ok) {

                $providers = @($ort.providers)

                Add-Check `
                    -Component 'ONNX Runtime' `
                    -Target 'Runtime' `
                    -Status 'AVAILABLE' `
                    -Version ([string]$ort.version) `
                    -Details ($providers -join ', ')

                $providerTests = @(
                    @{
                        Name   = 'CPUExecutionProvider'
                        Target = 'CPU'
                    },
                    @{
                        Name   = 'CUDAExecutionProvider'
                        Target = 'NVIDIA GPU'
                    },
                    @{
                        Name   = 'DmlExecutionProvider'
                        Target = 'GPU / DirectML'
                    },
                    @{
                        Name   = 'OpenVINOExecutionProvider'
                        Target = 'Intel CPU/GPU/NPU'
                    }
                )

                foreach ($test in $providerTests) {

                    if ($providers -contains $test.Name) {
                        Add-Check `
                            -Component 'ONNX Provider' `
                            -Target $test.Target `
                            -Status 'AVAILABLE' `
                            -Details $test.Name
                    }
                    else {
                        Add-Check `
                            -Component 'ONNX Provider' `
                            -Target $test.Target `
                            -Status 'NOT INSTALLED' `
                            -Details $test.Name
                    }
                }
            }
            else {
                Add-Check `
                    -Component 'ONNX Runtime' `
                    -Target 'Runtime' `
                    -Status 'NOT INSTALLED' `
                    -Details ([string]$ort.error)
            }
        }
    }
    catch {
        Add-Check `
            -Component 'ONNX Runtime' `
            -Target 'Runtime' `
            -Status 'ERROR' `
            -Details $_.Exception.Message
    }


    # OpenVINO
    $openvinoCode = @'
import json
try:
    import openvino as ov

    version = getattr(ov, "__version__", "")

    try:
        core = ov.Core()
        devices = list(core.available_devices)
    except Exception as device_error:
        devices = []
        device_error_text = str(device_error)
    else:
        device_error_text = ""

    print(json.dumps({
        "ok": True,
        "version": version,
        "devices": devices,
        "device_error": device_error_text
    }))

except Exception as e:
    print(json.dumps({
        "ok": False,
        "error": str(e)
    }))
'@

    try {
        $ovRaw = $openvinoCode | & $python - 2>$null
        $ovText = (($ovRaw | Out-String).Trim())

        if ($ovText) {

            $ov = $ovText | ConvertFrom-Json

            if ($ov.ok) {

                $ovDevices = @($ov.devices)

                Add-Check `
                    -Component 'OpenVINO' `
                    -Target 'Runtime' `
                    -Status 'AVAILABLE' `
                    -Version ([string]$ov.version) `
                    -Details ($ovDevices -join ', ')

                foreach ($deviceName in @('CPU', 'GPU', 'NPU')) {

                    $found = $false

                    foreach ($availableDevice in $ovDevices) {
                        if (
                            ([string]$availableDevice) -match (
                                '^{0}(\.|$)' -f [regex]::Escape($deviceName)
                            )
                        ) {
                            $found = $true
                            break
                        }
                    }

                    if ($found) {
                        Add-Check `
                            -Component 'OpenVINO Device' `
                            -Target $deviceName `
                            -Status 'AVAILABLE' `
                            -Details (
                                $ovDevices |
                                Where-Object {
                                    ([string]$_) -match (
                                        '^{0}(\.|$)' -f [regex]::Escape($deviceName)
                                    )
                                } |
                                Out-String
                            ).Trim()
                    }
                    else {
                        Add-Check `
                            -Component 'OpenVINO Device' `
                            -Target $deviceName `
                            -Status 'DEVICE NOT EXPOSED' `
                            -Details 'Runtime did not expose this device'
                    }
                }
            }
            else {
                Add-Check `
                    -Component 'OpenVINO' `
                    -Target 'Runtime' `
                    -Status 'NOT INSTALLED' `
                    -Details ([string]$ov.error)
            }
        }
    }
    catch {
        Add-Check `
            -Component 'OpenVINO' `
            -Target 'Runtime' `
            -Status 'ERROR' `
            -Details $_.Exception.Message
    }


    # DirectML / ONNX DirectML package indicators
    $dmlCode = @'
import json
import importlib.util

modules = {
    "onnxruntime": importlib.util.find_spec("onnxruntime") is not None,
    "onnxruntime_directml": importlib.util.find_spec("onnxruntime_directml") is not None
}

print(json.dumps(modules))
'@

    try {
        $dmlRaw = $dmlCode | & $python - 2>$null
        $dmlText = (($dmlRaw | Out-String).Trim())

        if ($dmlText) {
            $dml = $dmlText | ConvertFrom-Json

            if ($dml.onnxruntime_directml) {
                Add-Check `
                    -Component 'DirectML' `
                    -Target 'Windows GPU' `
                    -Status 'AVAILABLE' `
                    -Details 'onnxruntime-directml Python package detected'
            }
            else {
                Add-Check `
                    -Component 'DirectML' `
                    -Target 'Windows GPU' `
                    -Status 'NOT INSTALLED' `
                    -Details 'onnxruntime-directml Python package not detected'
            }
        }
    }
    catch {
        Add-Check `
            -Component 'DirectML' `
            -Target 'Windows GPU' `
            -Status 'ERROR' `
            -Details $_.Exception.Message
    }
}


# ---------------------------------------------------------------------------
# Result
# ---------------------------------------------------------------------------

$result = [pscustomobject][ordered]@{
    SchemaVersion = '1.0'
    GeneratedAt   = (Get-Date).ToString('yyyy-MM-ddTHH:mm:ssK')
    ComputerName  = $env:COMPUTERNAME
    Checks        = @($checks)
}


if ($AsJson) {
    $result | ConvertTo-Json -Depth 6
    return
}


Write-Host ''
Write-Host 'AI PC Bench - Runtime / Backend Detection' -ForegroundColor Cyan
Write-Host '=========================================' -ForegroundColor DarkGray
Write-Host ''

foreach ($check in $checks) {

    $color = switch ($check.Status) {
        'AVAILABLE'          { 'Green' }
        'PARTIAL'            { 'Yellow' }
        'NOT INSTALLED'      { 'DarkYellow' }
        'DEVICE NOT EXPOSED' { 'DarkYellow' }
        'ERROR'              { 'Red' }
        default              { 'Gray' }
    }

    Write-Host (
        '{0,-20} {1,-18} {2,-20} {3}' -f `
        $check.Component,
        $check.Target,
        $check.Status,
        $check.Version
    ) -ForegroundColor $color

    if ($check.Details) {
        Write-Host "  -> $($check.Details)" -ForegroundColor DarkGray
    }
}

Write-Host ''

$result