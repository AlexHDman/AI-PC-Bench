<#
EXPC AI Benchmark Portable
Native CPU benchmark engine without PowerShell runspaces.

The benchmark compiles a small in-process C# helper into memory and uses
native .NET threads with a synchronized start time. Compilation and worker
initialization are excluded from measured passes.
#>
[CmdletBinding()]
param(
    [int]$DurationSeconds = 10,
    [int]$Threads = 0
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$warnings = [System.Collections.Generic.List[string]]::new()
$errors = [System.Collections.Generic.List[string]]::new()
$testStart = Get-Date
$testEnd = $null
$logicalAvailable = [Environment]::ProcessorCount
$projectRoot = Split-Path -Parent $PSScriptRoot
$compileTemp = Join-Path $projectRoot 'temp\cpu_native_compile'
$oldTemp = $env:TEMP
$oldTmp = $env:TMP

if ($DurationSeconds -lt 5) {
    $warnings.Add('cpu_test_seconds was below 5; 5 seconds per measured pass were used.')
    $DurationSeconds = 5
}
if ($DurationSeconds -gt 30) {
    $warnings.Add('cpu_test_seconds was capped at 30 seconds per measured pass.')
    $DurationSeconds = 30
}
if ($Threads -le 0) {
    $Threads = $logicalAvailable
}
if ($Threads -gt $logicalAvailable) {
    $warnings.Add('Requested thread count was capped to logical processor count.')
    $Threads = $logicalAvailable
}
if ($Threads -lt 1) {
    $Threads = 1
}

$csharp = @'
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Threading;

namespace EXPC.NativeCpu
{
    public sealed class NativePassResult
    {
        public long TotalIterations;
        public double DurationSeconds;
        public double Score;
        public int WorkerCount;
        public int WorkerFailures;
        public string[] Errors;
    }

    public sealed class NativeBenchmarkResult
    {
        public bool Completed;
        public int Threads;
        public int WarmupSeconds;
        public int PassSeconds;
        public int PassCount;
        public long TotalIterations;
        public double[] PassScores;
        public double[] PassDurations;
        public double ScoreMin;
        public double ScoreMax;
        public double ScoreAverage;
        public double ScoreMedian;
        public int WorkerFailures;
        public string[] Errors;
    }

    internal sealed class WorkerState
    {
        public CountdownEvent Ready;
        public ManualResetEventSlim StartGate;
        public long StartTicks;
        public long EndTicks;
        public long Iterations;
        public long Checksum;
        public string Error;
    }

    public static class EngineV2
    {
        private static long WorkUnit(long seed, double[] buffer)
        {
            unchecked
            {
                long x = seed;

                for (int i = 0; i < 768; i++)
                {
                    x = (x * 6364136223846793005L) + 1442695040888963407L;
                    x ^= (x >> 17);
                    x ^= (x << 13);
                }

                int primeCount = 0;
                for (int candidate = 2; candidate <= 251; candidate++)
                {
                    bool isPrime = true;
                    for (int divisor = 2; divisor * divisor <= candidate; divisor++)
                    {
                        if ((candidate % divisor) == 0)
                        {
                            isPrime = false;
                            break;
                        }
                    }
                    if (isPrime)
                    {
                        primeCount++;
                    }
                }

                double sum = 0.0;
                for (int i = 0; i < buffer.Length; i++)
                {
                    double v = buffer[i];
                    double mix = (double)((x >> (i & 31)) & 255L) * 0.00001;
                    v = (v + mix + 1.0) * 1.0000001192092896;
                    if (v > 1000.0)
                    {
                        v *= 0.001;
                    }
                    buffer[i] = v;
                    sum += Math.Sqrt(v + (double)(i & 7));
                }

                if (primeCount != 54 || Double.IsNaN(sum) || Double.IsInfinity(sum))
                {
                    throw new InvalidOperationException("Native CPU work validation failed.");
                }

                return x ^ BitConverter.DoubleToInt64Bits(sum) ^ (long)primeCount;
            }
        }

        private static void WorkerMain(object value)
        {
            WorkerState state = (WorkerState)value;
            bool readySignaled = false;

            try
            {
                double[] buffer = new double[256];
                for (int i = 0; i < buffer.Length; i++)
                {
                    buffer[i] = (double)(i + 1) / 257.0;
                }

                long checksum = 1L;

                // Per-thread initialization and JIT warm-up are completed before Ready.
                for (int i = 0; i < 16; i++)
                {
                    checksum = WorkUnit(checksum + i + 1L, buffer);
                }

                state.Ready.Signal();
                readySignaled = true;
                state.StartGate.Wait();

                while (Stopwatch.GetTimestamp() < state.StartTicks)
                {
                    Thread.SpinWait(64);
                }

                long iterations = 0L;
                while (Stopwatch.GetTimestamp() < state.EndTicks)
                {
                    checksum = WorkUnit(checksum + iterations + 1L, buffer);
                    iterations++;
                }

                state.Iterations = iterations;
                state.Checksum = checksum;
            }
            catch (Exception ex)
            {
                state.Error = ex.GetType().Name + ": " + ex.Message;
            }
            finally
            {
                if (!readySignaled)
                {
                    try { state.Ready.Signal(); } catch { }
                }
            }
        }

        private static NativePassResult RunPass(int threads, int durationSeconds)
        {
            CountdownEvent ready = new CountdownEvent(threads);
            ManualResetEventSlim startGate = new ManualResetEventSlim(false);
            Thread[] workers = new Thread[threads];
            WorkerState[] states = new WorkerState[threads];
            List<string> errors = new List<string>();

            try
            {
                for (int i = 0; i < threads; i++)
                {
                    WorkerState state = new WorkerState();
                    state.Ready = ready;
                    state.StartGate = startGate;
                    states[i] = state;

                    Thread thread = new Thread(WorkerMain);
                    thread.IsBackground = true;
                    thread.Name = "EXPC-CPU-" + i.ToString();
                    workers[i] = thread;
                    thread.Start(state);
                }

                if (!ready.Wait(TimeSpan.FromSeconds(30)))
                {
                    // Never run a partial pass: release every worker so it can exit,
                    // then report the barrier failure to the PowerShell wrapper.
                    errors.Add("Workers did not reach the ready barrier within 30 seconds.");
                    long abortTicks = Stopwatch.GetTimestamp();
                    for (int i = 0; i < states.Length; i++)
                    {
                        states[i].StartTicks = abortTicks;
                        states[i].EndTicks = abortTicks;
                    }
                    startGate.Set();
                    for (int i = 0; i < workers.Length; i++)
                    {
                        workers[i].Join(30000);
                    }

                    NativePassResult failed = new NativePassResult();
                    failed.TotalIterations = 0L;
                    failed.DurationSeconds = 0.0;
                    failed.Score = 0.0;
                    failed.WorkerCount = threads;
                    failed.WorkerFailures = threads;
                    failed.Errors = errors.ToArray();
                    return failed;
                }

                long frequency = Stopwatch.Frequency;
                long leadTicks = Math.Max(1L, frequency / 20L); // 50 ms lead.
                long startTicks = Stopwatch.GetTimestamp() + leadTicks;
                long endTicks = startTicks + ((long)durationSeconds * frequency);

                for (int i = 0; i < states.Length; i++)
                {
                    states[i].StartTicks = startTicks;
                    states[i].EndTicks = endTicks;
                }

                startGate.Set();

                int joinTimeoutMs = checked((durationSeconds + 30) * 1000);
                for (int i = 0; i < workers.Length; i++)
                {
                    if (!workers[i].Join(joinTimeoutMs))
                    {
                        errors.Add("Worker " + i.ToString() + " did not finish within the timeout.");
                    }
                }

                long totalIterations = 0L;
                int failures = 0;

                for (int i = 0; i < states.Length; i++)
                {
                    if (!String.IsNullOrEmpty(states[i].Error))
                    {
                        failures++;
                        errors.Add("Worker " + i.ToString() + ": " + states[i].Error);
                    }

                    if (states[i].Iterations <= 0L)
                    {
                        failures++;
                        errors.Add("Worker " + i.ToString() + " returned no iterations.");
                    }
                    else
                    {
                        totalIterations += states[i].Iterations;
                    }
                }

                double actualDuration = (double)(endTicks - startTicks) / (double)frequency;
                double score = actualDuration > 0.0
                    ? (double)totalIterations / actualDuration
                    : 0.0;

                NativePassResult result = new NativePassResult();
                result.TotalIterations = totalIterations;
                result.DurationSeconds = actualDuration;
                result.Score = score;
                result.WorkerCount = threads;
                result.WorkerFailures = failures;
                result.Errors = errors.ToArray();
                return result;
            }
            finally
            {
                startGate.Dispose();
                ready.Dispose();
            }
        }

        private static double Median(double[] values)
        {
            double[] copy = (double[])values.Clone();
            Array.Sort(copy);
            int middle = copy.Length / 2;
            if ((copy.Length % 2) == 1)
            {
                return copy[middle];
            }
            return (copy[middle - 1] + copy[middle]) / 2.0;
        }

        public static NativeBenchmarkResult Run(int threads, int warmupSeconds, int passSeconds, int passCount)
        {
            List<string> errors = new List<string>();
            int workerFailures = 0;

            NativePassResult warmup = RunPass(threads, warmupSeconds);
            workerFailures += warmup.WorkerFailures;
            if (warmup.Errors != null)
            {
                errors.AddRange(warmup.Errors);
            }

            double[] passScores = new double[passCount];
            double[] passDurations = new double[passCount];
            long totalIterations = 0L;

            for (int pass = 0; pass < passCount; pass++)
            {
                if (pass > 0)
                {
                    Thread.Sleep(2000);
                }

                NativePassResult measured = RunPass(threads, passSeconds);
                passScores[pass] = measured.Score;
                passDurations[pass] = measured.DurationSeconds;
                totalIterations += measured.TotalIterations;
                workerFailures += measured.WorkerFailures;

                if (measured.Errors != null)
                {
                    errors.AddRange(measured.Errors);
                }
            }

            double min = Double.MaxValue;
            double max = Double.MinValue;
            double sum = 0.0;

            for (int i = 0; i < passScores.Length; i++)
            {
                if (passScores[i] < min) min = passScores[i];
                if (passScores[i] > max) max = passScores[i];
                sum += passScores[i];
            }

            NativeBenchmarkResult result = new NativeBenchmarkResult();
            result.Completed = errors.Count == 0 && workerFailures == 0;
            result.Threads = threads;
            result.WarmupSeconds = warmupSeconds;
            result.PassSeconds = passSeconds;
            result.PassCount = passCount;
            result.TotalIterations = totalIterations;
            result.PassScores = passScores;
            result.PassDurations = passDurations;
            result.ScoreMin = min;
            result.ScoreMax = max;
            result.ScoreAverage = sum / (double)passScores.Length;
            result.ScoreMedian = Median(passScores);
            result.WorkerFailures = workerFailures;
            result.Errors = errors.ToArray();
            return result;
        }
    }
}
'@

try {
    New-Item -ItemType Directory -Path $compileTemp -Force | Out-Null
    $env:TEMP = $compileTemp
    $env:TMP = $compileTemp

    if (-not ('EXPC.NativeCpu.EngineV2' -as [type])) {
        Add-Type -TypeDefinition $csharp -Language CSharp -ErrorAction Stop
    }

    $warmupSeconds = 2
    $measuredPasses = 3

    $native = [EXPC.NativeCpu.EngineV2]::Run(
        $Threads,
        $warmupSeconds,
        $DurationSeconds,
        $measuredPasses
    )

    foreach ($nativeError in @($native.Errors)) {
        if (-not [string]::IsNullOrWhiteSpace([string]$nativeError)) {
            $errors.Add([string]$nativeError)
        }
    }

    $testEnd = Get-Date
    $passScores = @($native.PassScores | ForEach-Object { [math]::Round([double]$_, 2) })
    $passDurations = @($native.PassDurations | ForEach-Object { [math]::Round([double]$_, 3) })
    $measuredDuration = [math]::Round(
        (($native.PassDurations | Measure-Object -Sum).Sum),
        3
    )
    $score = [math]::Round([double]$native.ScoreMedian, 2)

    [pscustomobject]@{
        start_time                = $testStart.ToString('o')
        end_time                  = $testEnd.ToString('o')
        engine_version            = 'native-thread-v2'
        score_unit                = 'work_units_per_second'
        warmup_seconds            = $warmupSeconds
        warmup_completed          = ($native.WorkerFailures -eq 0)
        warmup_duration_seconds   = [double]$warmupSeconds
        duration_seconds          = $measuredDuration
        total_elapsed_seconds     = [math]::Round(($testEnd - $testStart).TotalSeconds, 3)
        logical_threads_available = $logicalAvailable
        logical_threads_used      = $Threads
        measured_passes           = $measuredPasses
        total_iterations          = [Int64]$native.TotalIterations
        pass_scores               = $passScores
        pass_durations            = $passDurations
        score_min                 = [math]::Round([double]$native.ScoreMin, 2)
        score_max                 = [math]::Round([double]$native.ScoreMax, 2)
        score_average             = [math]::Round([double]$native.ScoreAverage, 2)
        score_median              = $score
        worker_failures           = [int]$native.WorkerFailures
        operations_per_second     = $score
        score                     = $score
        completed                 = [bool]$native.Completed
        warnings                  = @($warnings)
        errors                    = @($errors)
    }
}
catch {
    $errors.Add($_.Exception.GetType().Name + ': ' + $_.Exception.Message)
    $testEnd = Get-Date

    [pscustomobject]@{
        start_time                = $testStart.ToString('o')
        end_time                  = $testEnd.ToString('o')
        engine_version            = 'native-thread-v2'
        score_unit                = 'work_units_per_second'
        warmup_seconds            = 2
        warmup_completed          = $false
        warmup_duration_seconds   = $null
        duration_seconds          = [math]::Round(($testEnd - $testStart).TotalSeconds, 3)
        total_elapsed_seconds     = [math]::Round(($testEnd - $testStart).TotalSeconds, 3)
        logical_threads_available = $logicalAvailable
        logical_threads_used      = $Threads
        measured_passes           = 0
        total_iterations          = $null
        pass_scores               = @()
        pass_durations            = @()
        score_min                 = $null
        score_max                 = $null
        score_average             = $null
        score_median              = $null
        worker_failures           = $null
        operations_per_second     = $null
        score                     = $null
        completed                 = $false
        warnings                  = @($warnings)
        errors                    = @($errors)
    }
}
finally {
    $env:TEMP = $oldTemp
    $env:TMP = $oldTmp

    if (Test-Path -LiteralPath $compileTemp) {
        Remove-Item -LiteralPath $compileTemp -Recurse -Force -ErrorAction SilentlyContinue
    }
}
