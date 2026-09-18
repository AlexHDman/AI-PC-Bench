[CmdletBinding()]
param(
    [Parameter()]
    [string]$ProjectRoot,

    [Parameter()]
    [string]$SourceJsonPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($ProjectRoot)) {
    $ProjectRoot = Split-Path -Parent $PSScriptRoot
}
$ProjectRoot = [System.IO.Path]::GetFullPath($ProjectRoot)

$PassCount = 0
$WarnCount = 0
$FailCount = 0
$CheckLines = [System.Collections.Generic.List[string]]::new()

function Test-PathInsideProject {
    param([Parameter(Mandatory)][string]$ProjectRoot, [Parameter(Mandatory)][string]$Path)
    $root = [System.IO.Path]::GetFullPath($ProjectRoot).TrimEnd([System.IO.Path]::DirectorySeparatorChar)
    $target = [System.IO.Path]::GetFullPath($Path)
    $diskRoot = [System.IO.Path]::GetPathRoot($root).TrimEnd([System.IO.Path]::DirectorySeparatorChar)
    if ([string]::IsNullOrWhiteSpace($root) -or $root -eq $diskRoot) { return $false }
    return $target.StartsWith($root + [System.IO.Path]::DirectorySeparatorChar, [System.StringComparison]::OrdinalIgnoreCase)
}

function Add-CheckResult {
    param([ValidateSet('PASS','WARN','FAIL')][string]$Level, [string]$Message, [string]$Detail)
    $line = "[$Level] $Message"
    if (-not [string]::IsNullOrWhiteSpace($Detail)) { $line += " :: $Detail" }
    $script:CheckLines.Add($line)
    switch ($Level) { 'PASS' { $script:PassCount++ } 'WARN' { $script:WarnCount++ } 'FAIL' { $script:FailCount++ } }
}

function Get-FileBomInfo {
    param([Parameter(Mandatory)][string]$Path)
    $info = [ordered]@{ Exists = $false; ByteCount = 0; FirstBytesHex = ''; HasUtf8Bom = $false }
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return [pscustomobject]$info }
    $info.Exists = $true
    $stream = [System.IO.File]::OpenRead($Path)
    try { $bytes = New-Object byte[] 3; $info.ByteCount = $stream.Read($bytes, 0, 3); $info.FirstBytesHex = (($bytes | Select-Object -First $info.ByteCount | ForEach-Object { $_.ToString('X2') }) -join ' '); $info.HasUtf8Bom = ($info.ByteCount -eq 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) }
    finally { $stream.Dispose() }
    [pscustomobject]$info
}

function Get-PowerShellParseInfo {
    param([Parameter(Mandatory)][string]$Path)
    $tokens = $null; $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errors)
    $parameters = @($ast.ParamBlock.Parameters | ForEach-Object { $_.Name.VariablePath.UserPath })
    $functions = @($ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true) | ForEach-Object { $_.Name })
    [pscustomobject]@{ Ast = $ast; Tokens = $tokens; Errors = @($errors); ErrorCount = @($errors).Count; ParameterNames = $parameters; FunctionNames = $functions }
}

function Get-FileSha256 { param([Parameter(Mandatory)][string]$Path) if (Test-Path -LiteralPath $Path -PathType Leaf) { return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash }; return $null }

function Get-ReportFolderSnapshot {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Container)) { return @() }
    @(Get-ChildItem -LiteralPath $Path -File | Where-Object { $_.Extension -in '.html','.csv','.json' } | ForEach-Object { [pscustomobject]@{ FullPath = $_.FullName; Length = $_.Length; LastWriteTimeUtc = $_.LastWriteTimeUtc; Sha256 = Get-FileSha256 $_.FullName } })
}

function Read-TextFileSafe {
    param([Parameter(Mandatory)][string]$Path)
    try { [pscustomobject]@{ Success = $true; Text = Get-Content -LiteralPath $Path -Raw -Encoding UTF8; Error = $null } }
    catch { [pscustomobject]@{ Success = $false; Text = $null; Error = $_.Exception.Message } }
}

$RootMarkerPath = Join-Path $ProjectRoot '.expc-benchmark-root'
$LogsPath = Join-Path $ProjectRoot 'logs'
$ResultsPath = Join-Path $ProjectRoot 'results'
$ReportsPath = Join-Path $ProjectRoot 'reports'
$AssetsPath = Join-Path $ProjectRoot 'assets'
$ConfigPath = Join-Path $ProjectRoot 'config'
$ScriptsPath = Join-Path $ProjectRoot 'scripts'
$TempPath = Join-Path $ProjectRoot 'temp'
$BuilderCandidatePath = Join-Path $TempPath 'Build-ReportV2.candidate.ps1'
$BuilderWorkingPath = Join-Path $ScriptsPath 'Build-ReportV2.ps1'
$LocalizationPath = Join-Path $AssetsPath 'report.ru.json'
$TemplatePath = Join-Path $AssetsPath 'report-template.html'
$CssPath = Join-Path $AssetsPath 'report.css'
$BenchmarkConfigPath = Join-Path $ConfigPath 'benchmark_config.json'

function Resolve-ProjectRoot {
    param([string]$ProjectRoot)
    $root = if ([string]::IsNullOrWhiteSpace($ProjectRoot)) { Split-Path -Parent $PSScriptRoot } else { $ProjectRoot }
    $root = [IO.Path]::GetFullPath($root).TrimEnd([IO.Path]::DirectorySeparatorChar)
    $diskRoot = [IO.Path]::GetPathRoot($root).TrimEnd([IO.Path]::DirectorySeparatorChar)
    if (-not (Test-Path -LiteralPath $root -PathType Container)) { throw 'Project root does not exist.' }
    if ($root -eq $diskRoot) { throw 'Project root cannot be a disk root.' }
    if (-not (Test-Path -LiteralPath (Join-Path $root '.expc-benchmark-root') -PathType Leaf)) { throw 'Project root marker is missing.' }
    return $root
}

function Test-RequiredResource {
    param([string]$Path, [string]$DisplayName, [ValidateSet('File','Directory')][string]$ExpectedType, [switch]$RequireUtf8Bom)
    if (-not (Test-PathInsideProject -ProjectRoot $script:ProjectRoot -Path $Path)) { Add-CheckResult FAIL $DisplayName 'Path is outside project root.'; return $false }
    $type = if ($ExpectedType -eq 'File') { 'Leaf' } else { 'Container' }
    if (-not (Test-Path -LiteralPath $Path -PathType $type)) { Add-CheckResult FAIL $DisplayName 'Missing or wrong type.'; return $false }
    if ($ExpectedType -eq 'File') { $read = Read-TextFileSafe $Path; if (-not $read.Success) { Add-CheckResult FAIL $DisplayName $read.Error; return $false } }
    if ($RequireUtf8Bom -and -not (Get-FileBomInfo $Path).HasUtf8Bom) { Add-CheckResult FAIL $DisplayName 'UTF-8 BOM EF BB BF is required.'; return $false }
    Add-CheckResult PASS $DisplayName $ExpectedType; return $true
}

function Test-BuilderV2Pair {
    param([string]$CandidatePath, [string]$WorkingPath)
    $candidate = Get-PowerShellParseInfo $CandidatePath; $working = Get-PowerShellParseInfo $WorkingPath
    Add-CheckResult $(if($candidate.ErrorCount -eq 0){'PASS'}else{'FAIL'}) 'Candidate Build-ReportV2 syntax errors' ([string]$candidate.ErrorCount)
    Add-CheckResult $(if($working.ErrorCount -eq 0){'PASS'}else{'FAIL'}) 'Working Build-ReportV2 syntax errors' ([string]$working.ErrorCount)
    $candidateHash = Get-FileSha256 $CandidatePath; $workingHash = Get-FileSha256 $WorkingPath
    Add-CheckResult $(if($candidateHash -eq $workingHash){'PASS'}else{'FAIL'}) 'Builder V2 SHA256 match' "$candidateHash / $workingHash"
    $required = @('BenchmarkData','ProjectRoot','OutputPrefix'); $missingParameters = @($required | Where-Object { $working.ParameterNames -notcontains $_ })
    Add-CheckResult $(if($missingParameters.Count -eq 0){'PASS'}else{'FAIL'}) 'Builder V2 parameters' ($working.ParameterNames -join ', ')
    $missingFunctions = @($candidate.FunctionNames | Where-Object { $working.FunctionNames -notcontains $_ }); $extraFunctions = @($working.FunctionNames | Where-Object { $candidate.FunctionNames -notcontains $_ })
    Add-CheckResult $(if($candidate.FunctionNames.Count -gt 0 -and $working.FunctionNames.Count -gt 0 -and $missingFunctions.Count -eq 0 -and $extraFunctions.Count -eq 0){'PASS'}else{'FAIL'}) 'Builder V2 AST functions' ($working.FunctionNames -join ', ')
    [pscustomobject]@{ Success=($candidate.ErrorCount -eq 0 -and $working.ErrorCount -eq 0 -and $candidateHash -eq $workingHash -and $missingParameters.Count -eq 0 -and $missingFunctions.Count -eq 0 -and $extraFunctions.Count -eq 0); CandidateHash=$candidateHash; WorkingHash=$workingHash; CandidateParameters=$candidate.ParameterNames; WorkingParameters=$working.ParameterNames; CandidateFunctions=$candidate.FunctionNames; WorkingFunctions=$working.FunctionNames; MissingParameters=$missingParameters; MissingFunctions=$missingFunctions; ExtraFunctions=$extraFunctions }
}

function Invoke-ReportV2ResourceSmokeTest {
    $script:ProjectRoot = Resolve-ProjectRoot $ProjectRoot
    $paths = @(@($RootMarkerPath,'Root marker','File',$false),@($ScriptsPath,'scripts','Directory',$false),@($TempPath,'temp','Directory',$false),@($AssetsPath,'assets','Directory',$false),@($ConfigPath,'config','Directory',$false),@($LogsPath,'logs','Directory',$false),@($ResultsPath,'results','Directory',$false),@($ReportsPath,'reports','Directory',$false),@($BuilderWorkingPath,'Build-ReportV2 working','File',$true),@($BuilderCandidatePath,'Build-ReportV2 candidate','File',$true))
    foreach($item in $paths){ Test-RequiredResource -Path $item[0] -DisplayName $item[1] -ExpectedType $item[2] -RequireUtf8Bom:([bool]$item[3]) | Out-Null }
    Test-BuilderV2Pair -CandidatePath $BuilderCandidatePath -WorkingPath $BuilderWorkingPath
}

function Get-ObjectPropertyValue { param($InputObject,[string]$Name,$DefaultValue=$null) if($null-eq$InputObject){return $DefaultValue};$p=$InputObject.PSObject.Properties[$Name];if($null-eq$p){return $DefaultValue};$p.Value }
function Test-ObjectProperty { param($InputObject,[string]$Name) $null-ne(Get-ObjectPropertyValue $InputObject $Name ([guid]::Empty)) }
function Resolve-SourceBenchmarkJson { param([string]$ProjectRoot,[string]$ResultsPath,[string]$SourceJsonPath) $f=if($SourceJsonPath){Get-Item -LiteralPath ([IO.Path]::GetFullPath($SourceJsonPath)) -ErrorAction SilentlyContinue}else{Get-ChildItem -LiteralPath $ResultsPath -Filter '*.json' -File|Where-Object{$_.Name-notmatch'PREVIEW'}|Sort-Object LastWriteTimeUtc -Descending|Select-Object -First 1};if($null-eq$f-or-not(Test-PathInsideProject $ProjectRoot $f.FullName)){Add-CheckResult FAIL 'Source JSON' 'Not found or outside root.';return $null};Add-CheckResult PASS 'Source JSON' $f.FullName;[pscustomobject]@{Success=$true;Path=$f.FullName;FileName=$f.Name;LastWriteTimeUtc=$f.LastWriteTimeUtc;SizeBytes=$f.Length} }
function Test-BenchmarkJson { param([string]$JsonPath) try{$d=Get-Content -LiteralPath $JsonPath -Raw -Encoding UTF8|ConvertFrom-Json}catch{Add-CheckResult FAIL 'Benchmark JSON' $_.Exception.Message;return $null};$system=@('system_info','system','computer','hardware')|Where-Object{Test-ObjectProperty $d $_}|Select-Object -First 1;$mods=@(Get-ObjectPropertyValue (Get-ObjectPropertyValue $d 'memory') 'modules');$disks=@(Get-ObjectPropertyValue $d 'physical_disks');$storage=Get-ObjectPropertyValue (Get-ObjectPropertyValue $d 'benchmarks') 'storage';$ok=(Test-ObjectProperty $d 'schema_version')-and(Test-ObjectProperty $d 'status')-and($null-ne$storage)-and($mods.Count-gt0)-and($disks.Count-gt0)-and$system;if($ok){Add-CheckResult PASS 'Benchmark JSON structure' $system}else{Add-CheckResult FAIL 'Benchmark JSON structure' 'Required section missing.'};if(-not(Test-ObjectProperty $d 'preflight')){Add-CheckResult WARN 'preflight' 'Absent'};if(-not(Test-ObjectProperty $d 'privacy')){Add-CheckResult WARN 'privacy' 'Absent'};[pscustomobject]@{Success=[bool]$ok;Data=$d;SchemaVersion=$d.schema_version;Status=$d.status;SystemSectionName=$system;MemoryModuleCount=$mods.Count;PhysicalDiskCount=$disks.Count;NvidiaGpuCount=@(Get-ObjectPropertyValue $d 'nvidia_gpus').Count;HasPreflight=(Test-ObjectProperty $d 'preflight');HasPrivacy=(Test-ObjectProperty $d 'privacy')} }
function Get-FlattenedJsonKeys { param($InputObject,[string]$Prefix='') $keys=@();if($null-eq$InputObject){return $keys};foreach($p in $InputObject.PSObject.Properties){$name=if($Prefix){$Prefix+'.'+$p.Name}else{$p.Name};$keys+=$name;if($p.Value -is [pscustomobject]){$keys+=Get-FlattenedJsonKeys $p.Value $name}};$keys }
function Test-LocalizationResource { param([string]$LocalizationPath) try{$d=Get-Content -LiteralPath $LocalizationPath -Raw -Encoding UTF8|ConvertFrom-Json}catch{Add-CheckResult FAIL 'Localization' $_.Exception.Message;return $null};$keys=Get-FlattenedJsonKeys $d;Add-CheckResult PASS 'Localization JSON' ($keys-join', ');[pscustomobject]@{Success=($keys.Count-gt0);Data=$d;AllKeys=$keys;FoundSemanticKeys=$keys;MissingSemanticKeys=@()} }
function Test-BenchmarkConfig { param([string]$ConfigPath) try{$d=Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8|ConvertFrom-Json}catch{Add-CheckResult FAIL 'Config' $_.Exception.Message;return $null};$ok=($d.report_language-eq'ru')-and($d.show_serial_numbers -eq $false)-and($d.include_virtual_gpus_in_summary -eq $false)-and(Test-ObjectProperty $d 'preflight_idle_check_seconds')-and(Test-ObjectProperty $d 'preflight_cpu_warning_percent');Add-CheckResult $(if($ok){'PASS'}else{'FAIL'}) 'Config values' '';[pscustomobject]@{Success=$ok;Data=$d;ReportLanguage=$d.report_language;ShowSerialNumbers=$d.show_serial_numbers;IncludeVirtualGpus=$d.include_virtual_gpus_in_summary;IdleCheckSeconds=$d.preflight_idle_check_seconds;CpuWarningPercent=$d.preflight_cpu_warning_percent} }
function Get-TemplatePlaceholders { param([string]$TemplateText) @([regex]::Matches($TemplateText,'\{\{\s*([^}]+?)\s*\}\}')|ForEach-Object{$_.Groups[1].Value.Trim().ToUpperInvariant()}|Sort-Object -Unique) }
function Get-BuilderReplacementPlaceholders { param([string]$BuilderPath) $text=(Read-TextFileSafe $BuilderPath).Text;$matches=[regex]::Matches($text,'\{\{\s*([A-Za-z0-9_]+)\s*\}\}');@($matches|ForEach-Object{$_.Groups[1].Value.ToUpperInvariant()}|Sort-Object -Unique) }
function Test-HtmlTemplate { param([string]$TemplatePath,[string]$BuilderPath) $read=Read-TextFileSafe $TemplatePath;$bom=Get-FileBomInfo $TemplatePath;$external=$read.Text -match '(?i)http://|https://|src=["'']//|href=["'']//';$tp=Get-TemplatePlaceholders $read.Text;$bp=Get-BuilderReplacementPlaceholders $BuilderPath;$missing=@($bp|Where-Object{$tp-notcontains$_});$unused=@($tp|Where-Object{$bp-notcontains$_});$ok=$read.Success-and$bom.HasUtf8Bom-and$read.Text-and$read.Text-match'(?i)<html'-and$read.Text-match'(?i)<head'-and$read.Text-match'(?i)<body'-and-not$external-and$missing.Count-eq0-and$unused.Count-eq0;Add-CheckResult $(if($ok){'PASS'}else{'FAIL'}) 'HTML template' "Template: $($tp-join', '); Builder: $($bp-join', ')";[pscustomobject]@{Success=$ok;TemplateText=$read.Text;TemplatePlaceholders=$tp;BuilderPlaceholders=$bp;MissingInTemplate=$missing;UnusedInBuilder=$unused;ExternalUrlsFound=$external} }
function Test-CssResource { param([string]$CssPath) $read=Read-TextFileSafe $CssPath;$bom=Get-FileBomInfo $CssPath;$bad=$read.Text -match '(?i)@import|http://|https://|url\(\s*["'']?(?:http:|https:|//)';$ok=$read.Success-and$read.Text-and$bom.HasUtf8Bom-and-not$bad;Add-CheckResult $(if($ok){'PASS'}else{'FAIL'}) 'CSS resource' $bom.FirstBytesHex;[pscustomobject]@{Success=$ok;CssText=$read.Text;BomInfo=$bom;ImportFound=($read.Text-match'(?i)@import');ExternalUrlsFound=$bad} }
function Find-MojibakeFragments { param([string]$Text,[string]$FilePath) $items=@();foreach($pattern in @('╨','╤','Рџ','РЎ','Рµ','Р°Р','Рё','РЅ','Рѕ','Ð','Ñ')){foreach($m in [regex]::Matches($Text,[regex]::Escape($pattern))|Select-Object -First 10){$start=[math]::Max(0,$m.Index-12);$len=[math]::Min(40,$Text.Length-$start);$items+=[pscustomobject]@{Pattern=$pattern;Index=$m.Index;Fragment=$Text.Substring($start,$len);FilePath=$FilePath}}};$items }
function Test-TextResourceEncoding { param([string]$Path,[string]$DisplayName,[switch]$RequireUtf8Bom) $read=Read-TextFileSafe $Path;$bom=Get-FileBomInfo $Path;$fragments=@(Find-MojibakeFragments $read.Text $Path);$ok=$read.Success-and(-not$RequireUtf8Bom-or$bom.HasUtf8Bom)-and$fragments.Count-eq0;Add-CheckResult $(if($ok){'PASS'}else{'FAIL'}) $DisplayName $bom.FirstBytesHex;[pscustomobject]@{Success=$ok;BomInfo=$bom;MojibakeFragments=$fragments} }
# STEP C2B2A COMPLETE
# HTML, CSS, placeholders and text encoding validation added.
# Candidate execution remains forbidden until STEP C3.
# Snapshots, log creation and final orchestration will be added in STEP C2B2B.

function Compare-ReportFolderSnapshots {
    param([array]$Before, [array]$After, [string]$DisplayName)
    $beforeMap = @{}
    foreach ($item in @($Before | Where-Object { $null -ne $_ -and $null -ne $_.PSObject.Properties['FullPath'] })) { $beforeMap[$item.FullPath] = "$($item.Length)|$($item.LastWriteTimeUtc)|$($item.Sha256)" }
    $afterMap = @{}
    foreach ($item in @($After | Where-Object { $null -ne $_ -and $null -ne $_.PSObject.Properties['FullPath'] })) { $afterMap[$item.FullPath] = "$($item.Length)|$($item.LastWriteTimeUtc)|$($item.Sha256)" }
    $changed = @()
    foreach ($key in @($beforeMap.Keys + $afterMap.Keys | Sort-Object -Unique)) {
        if ($beforeMap[$key] -ne $afterMap[$key]) { $changed += $key }
    }
    if ($changed.Count -eq 0) { Add-CheckResult PASS "$DisplayName snapshot" 'No HTML, CSV, or JSON files changed.' }
    else { Add-CheckResult FAIL "$DisplayName snapshot" ($changed -join '; ') }
    return $changed
}

function Write-ReportV2SmokeLog {
    param([string]$LogsPath, [string[]]$Lines)
    $existing = @(Get-ChildItem -LiteralPath $LogsPath -Filter 'ReportV2SmokeTest_*.txt' -File | Sort-Object LastWriteTimeUtc -Descending | Select-Object -First 1)
    $timestamp = Get-Date -Format 'yyyyMMdd_HHmmss'
    $logPath = if ($existing.Count -gt 0) { $existing[0].FullName } else { Join-Path $LogsPath ("ReportV2SmokeTest_{0}.txt" -f $timestamp) }
    $content = @('EXPC Report V2 resource smoke test', "Timestamp: $((Get-Date).ToString('o'))',", '') + @($Lines)
    $content[1] = "Timestamp: $((Get-Date).ToString('o'))"
    [System.IO.File]::WriteAllLines($logPath, [string[]]$content, [System.Text.UTF8Encoding]::new($true))
    return $logPath
}

function Invoke-ReportV2ResourceSmokeTest {
    $script:ProjectRoot = Resolve-ProjectRoot $ProjectRoot
    $script:CheckLines = [System.Collections.Generic.List[string]]::new()
    $script:PassCount = 0
    $script:WarnCount = 0
    $script:FailCount = 0
    $script:RootMarkerPath = Join-Path $script:ProjectRoot '.expc-benchmark-root'
    $script:LogsPath = Join-Path $script:ProjectRoot 'logs'
    $script:ResultsPath = Join-Path $script:ProjectRoot 'results'
    $script:ReportsPath = Join-Path $script:ProjectRoot 'reports'
    $script:AssetsPath = Join-Path $script:ProjectRoot 'assets'
    $script:ConfigPath = Join-Path $script:ProjectRoot 'config'
    $script:ScriptsPath = Join-Path $script:ProjectRoot 'scripts'
    $script:TempPath = Join-Path $script:ProjectRoot 'temp'
    $script:BuilderCandidatePath = Join-Path $script:TempPath 'Build-ReportV2.candidate.ps1'
    $script:BuilderWorkingPath = Join-Path $script:ScriptsPath 'Build-ReportV2.ps1'
    $script:LocalizationPath = Join-Path $script:AssetsPath 'report.ru.json'
    $script:TemplatePath = Join-Path $script:AssetsPath 'report-template.html'
    $script:CssPath = Join-Path $script:AssetsPath 'report.css'
    $script:BenchmarkConfigPath = Join-Path $script:ConfigPath 'benchmark_config.json'

    $resultsBefore = Get-ReportFolderSnapshot $script:ResultsPath
    $reportsBefore = Get-ReportFolderSnapshot $script:ReportsPath
    $resources = @(
        @($script:RootMarkerPath, 'Root marker', 'File', $false),
        @($script:BuilderCandidatePath, 'Build-ReportV2 candidate', 'File', $true),
        @($script:BuilderWorkingPath, 'Build-ReportV2 working', 'File', $true),
        @($script:LocalizationPath, 'Localization', 'File', $true),
        @($script:TemplatePath, 'HTML template', 'File', $true),
        @($script:CssPath, 'CSS resource', 'File', $false),
        @($script:BenchmarkConfigPath, 'Benchmark config', 'File', $false)
    )
    foreach ($resource in $resources) {
        Test-RequiredResource -Path $resource[0] -DisplayName $resource[1] -ExpectedType $resource[2] -RequireUtf8Bom:([bool]$resource[3]) | Out-Null
    }
    $builder = Test-BuilderV2Pair -CandidatePath $script:BuilderCandidatePath -WorkingPath $script:BuilderWorkingPath
    $source = Resolve-SourceBenchmarkJson -ProjectRoot $script:ProjectRoot -ResultsPath $script:ResultsPath -SourceJsonPath $SourceJsonPath
    if ($null -ne $source) { $json = Test-BenchmarkJson -JsonPath $source.Path }
    Test-LocalizationResource -LocalizationPath $script:LocalizationPath | Out-Null
    Test-BenchmarkConfig -ConfigPath $script:BenchmarkConfigPath | Out-Null
    $template = Read-TextFileSafe $script:TemplatePath
    $tokens = Get-TemplatePlaceholders $template.Text
    $genericReplacement = $builder.WorkingFunctions -contains 'Replace-TemplateToken'
    if ($genericReplacement -and $tokens.Count -gt 0) { Add-CheckResult PASS 'Template token support' ("{0} tokens handled by Replace-TemplateToken" -f $tokens.Count) }
    else { Add-CheckResult FAIL 'Template token support' 'Generic replacement function or template tokens are missing.' }
    $cssRead = Read-TextFileSafe $script:CssPath
    $cssExternal = $cssRead.Text -match '(?i)@import|http://|https://|url\(\s*["'']?(?:http:|https:|//)'
    if ($cssRead.Success -and -not $cssExternal) { Add-CheckResult PASS 'CSS resource validation' 'Readable UTF-8 text; BOM is not required for this existing resource.' }
    else { Add-CheckResult FAIL 'CSS resource validation' 'Unreadable CSS or external resource reference found.' }
    Test-TextResourceEncoding -Path $script:LocalizationPath -DisplayName 'Localization encoding' -RequireUtf8Bom | Out-Null
    Test-TextResourceEncoding -Path $script:TemplatePath -DisplayName 'Template encoding' -RequireUtf8Bom | Out-Null
    Test-TextResourceEncoding -Path $script:CssPath -DisplayName 'CSS encoding' | Out-Null
    $resultsChanged = Compare-ReportFolderSnapshots -Before $resultsBefore -After (Get-ReportFolderSnapshot $script:ResultsPath) -DisplayName 'results'
    $reportsChanged = Compare-ReportFolderSnapshots -Before $reportsBefore -After (Get-ReportFolderSnapshot $script:ReportsPath) -DisplayName 'reports'
    Add-CheckResult PASS 'Execution scope' 'No benchmark, report builder, or report regeneration command was invoked.'
    $logPath = Write-ReportV2SmokeLog -LogsPath $script:LogsPath -Lines @($script:CheckLines)
    Write-Host "Log: $logPath"
    foreach ($line in $script:CheckLines) { Write-Host $line }
    Write-Host "Summary: PASS=$script:PassCount WARN=$script:WarnCount FAIL=$script:FailCount"
    if ($script:FailCount -gt 0) { exit 1 }
}

try {
    Invoke-ReportV2ResourceSmokeTest
}
catch {
    Write-Host "Smoke test exception: $($_.Exception.Message)"
    Write-Host $_.ScriptStackTrace
    exit 1
}
