<# Placeholder for v0.2.0. It intentionally performs no inference and never returns a fabricated score. #>
[CmdletBinding()]
param()
Set-StrictMode -Version Latest
[pscustomobject]@{ runtime_benchmark_status='not_implemented'; runtime_score_raw=$null; runtime_index=$null; execution_provider=$null; errors=@(); warnings=@('Real NPU inference benchmark is planned for v0.2.0 and is not implemented in v0.1.2.') }
