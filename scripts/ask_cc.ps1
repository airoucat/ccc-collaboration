[CmdletBinding()]
param(
  [Parameter(Position = 0)]
  [string]$Task,

  [Alias("w")]
  [string]$Workspace = (Get-Location).Path,

  [Alias("f")]
  [string[]]$File = @(),

  [string]$Session,

  [string]$Model = "opus",

  [ValidateSet("low", "medium", "high", "xhigh", "max")]
  [string]$Effort = "max",

  [Alias("o")]
  [string]$Output,

  [ValidateSet("acceptEdits", "auto", "bypassPermissions", "default", "dontAsk", "plan")]
  [string]$PermissionMode,

  [int]$TimeoutSeconds = 1800,

  [switch]$ReadOnly,

  [switch]$Bare,

  [switch]$NoSettingsEnv
)

$ErrorActionPreference = "Stop"
$script:OutputPath = $null
$script:OutputPathPrinted = $false

function Resolve-WorkspacePath {
  param([string]$Path)

  if ([System.IO.Path]::IsPathRooted($Path)) {
    return [System.IO.Path]::GetFullPath($Path)
  }

  return [System.IO.Path]::GetFullPath((Join-Path (Get-Location).Path $Path))
}

function Resolve-ContextPath {
  param(
    [string]$WorkspaceRoot,
    [string]$Path
  )

  $clean = $Path.Trim()
  if ($clean -match "^(.*)#L\d+$") {
    $clean = $Matches[1]
  }
  elseif ($clean -match "^(.*):\d+(-\d+)?$") {
    $clean = $Matches[1]
  }

  if (-not [System.IO.Path]::IsPathRooted($clean)) {
    $clean = Join-Path $WorkspaceRoot $clean
  }

  return [System.IO.Path]::GetFullPath($clean)
}

function Test-IsPathInside {
  param(
    [string]$ChildPath,
    [string]$ParentPath
  )

  $parentFull = [System.IO.Path]::GetFullPath($ParentPath).TrimEnd([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar)
  $childFull = [System.IO.Path]::GetFullPath($ChildPath)
  if ($childFull.Equals($parentFull, [System.StringComparison]::OrdinalIgnoreCase)) {
    return $true
  }

  $parentPrefix = $parentFull + [System.IO.Path]::DirectorySeparatorChar
  return $childFull.StartsWith($parentPrefix, [System.StringComparison]::OrdinalIgnoreCase)
}

function Copy-ContextFileForClaude {
  param(
    [string]$WorkspaceRoot,
    [string]$ResolvedPath,
    [int]$Index
  )

  if (-not (Test-Path -LiteralPath $ResolvedPath -PathType Leaf)) {
    return [pscustomobject]@{
      Path = $ResolvedPath
      Note = "missing"
    }
  }

  if (Test-IsPathInside -ChildPath $ResolvedPath -ParentPath $WorkspaceRoot) {
    return [pscustomobject]@{
      Path = $ResolvedPath
      Note = "workspace"
    }
  }

  $contextDir = Join-Path $WorkspaceRoot "build\tmp\ccc-collaboration\context"
  New-Item -ItemType Directory -Force -Path $contextDir | Out-Null
  $fileName = [System.IO.Path]::GetFileName($ResolvedPath)
  $safeName = $fileName -replace '[^\w.\-]+', '_'
  if ([string]::IsNullOrWhiteSpace($safeName)) {
    $safeName = "context-file"
  }
  $destination = Join-Path $contextDir ("{0:D2}-{1}" -f $Index, $safeName)
  Copy-Item -LiteralPath $ResolvedPath -Destination $destination -Force

  return [pscustomobject]@{
    Path = [System.IO.Path]::GetFullPath($destination)
    Note = "mirrored from $ResolvedPath"
  }
}

function Get-ScriptRoot {
  if ($PSScriptRoot) {
    return $PSScriptRoot
  }

  return Split-Path -Parent $MyInvocation.MyCommand.Path
}

function Initialize-OutputPath {
  param([string]$RequestedPath)

  if ([string]::IsNullOrWhiteSpace($RequestedPath)) {
    $timestamp = (Get-Date).ToUniversalTime().ToString("yyyyMMdd-HHmmss")
    $runtimeDir = Join-Path (Split-Path -Parent (Get-ScriptRoot)) ".runtime"
    New-Item -ItemType Directory -Force -Path $runtimeDir | Out-Null
    return (Join-Path $runtimeDir "$timestamp.md")
  }

  $fullPath = [System.IO.Path]::GetFullPath($RequestedPath)
  $outputParent = Split-Path -Parent $fullPath
  if ($outputParent) {
    New-Item -ItemType Directory -Force -Path $outputParent | Out-Null
  }

  return $fullPath
}

function Import-ClaudeSettingsEnv {
  $settingsPath = Join-Path $HOME ".claude\settings.json"
  if (-not (Test-Path -LiteralPath $settingsPath -PathType Leaf)) {
    return
  }

  $settings = Get-Content -Raw -LiteralPath $settingsPath | ConvertFrom-Json
  if (-not $settings.env) {
    return
  }

  foreach ($prop in $settings.env.PSObject.Properties) {
    [Environment]::SetEnvironmentVariable($prop.Name, [string]$prop.Value, "Process")
  }

  if ($settings.env.ANTHROPIC_AUTH_TOKEN) {
    Remove-Item Env:ANTHROPIC_API_KEY -ErrorAction SilentlyContinue
  }
}

function Write-OutputPath {
  param([string]$Path)

  if (-not $script:OutputPathPrinted -and -not [string]::IsNullOrWhiteSpace($Path)) {
    Write-Output "output_path=$([System.IO.Path]::GetFullPath($Path))"
    $script:OutputPathPrinted = $true
  }
}

function Write-OutputMarkdown {
  param(
    [string]$Path,
    [string]$SessionId,
    [string]$ModelName,
    [string]$EffortLevel,
    [string]$Permission,
    [bool]$IsReadOnly,
    [string]$Body,
    [object]$ModelUsage,
    [string]$Status = "OK"
  )

  $markdown = @()
  $markdown += "# Claude Code Response"
  $markdown += ""
  $markdown += "**Status**: $Status"
  $markdown += "**Session**: $SessionId"
  $markdown += "**Model**: $ModelName"
  $markdown += "**Effort**: $EffortLevel"
  $markdown += "**Permission Mode**: $Permission"
  $markdown += "**Read Only**: $IsReadOnly"
  $markdown += ""

  if ($ModelUsage) {
    $markdown += "## Model Usage"
    $markdown += ""
    foreach ($usage in $ModelUsage.PSObject.Properties) {
      $markdown += ("- ``{0}``" -f $usage.Name)
    }
    $markdown += ""
  }

  $markdown += "## Response"
  $markdown += ""
  $markdown += $Body

  $markdown -join "`n" | Set-Content -Encoding UTF8 -LiteralPath $Path
}

function Get-OutputStatus {
  param([string]$Path)

  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
    return ""
  }

  $statusLine = Get-Content -LiteralPath $Path -TotalCount 8 |
    Where-Object { $_ -match "^\*\*Status\*\*: " } |
    Select-Object -First 1

  if ($statusLine -match "^\*\*Status\*\*: (.+)$") {
    return $Matches[1].Trim()
  }

  return ""
}

function Remove-InvocationJob {
  param([System.Management.Automation.Job]$Job)

  if (-not $Job) {
    return
  }

  try {
    if ($Job.State -in @("NotStarted", "Running")) {
      Stop-Job -Job $Job -ErrorAction SilentlyContinue
    }
  }
  catch {
    # Cleanup must not mask the real invocation result.
  }

  try {
    Remove-Job -Job $Job -ErrorAction SilentlyContinue
  }
  catch {
    # PowerShell hosts differ in job cleanup parameters; avoid -Force.
  }
}

function Invoke-ClaudeJson {
  param(
    [string]$WorkspaceRoot,
    [string]$ClaudeCommand,
    [string[]]$ClaudeArgs,
    [int]$TimeoutSeconds
  )

  $job = Start-Job -ScriptBlock {
    param($WorkspaceRoot, $ClaudeCommand, $ClaudeArgs)

    Set-Location $WorkspaceRoot
    $raw = & $ClaudeCommand @ClaudeArgs 2>&1
    $exitCode = $LASTEXITCODE

    [pscustomobject]@{
      ExitCode = $exitCode
      Raw = @($raw | ForEach-Object { "$_" })
    } | ConvertTo-Json -Depth 6
  } -ArgumentList $WorkspaceRoot, $ClaudeCommand, $ClaudeArgs

  $completed = Wait-Job $job -Timeout $TimeoutSeconds
  if (-not $completed) {
    Remove-InvocationJob -Job $job
    return [pscustomobject]@{
      TimedOut = $true
      Raw = @()
      ExitCode = $null
      Result = $null
      JsonLine = $null
      WrapperError = $null
    }
  }

  try {
    $jobRaw = Receive-Job $job -ErrorAction Stop
  }
  finally {
    Remove-InvocationJob -Job $job
  }

  try {
    $payload = ($jobRaw | Out-String).Trim() | ConvertFrom-Json
  }
  catch {
    return [pscustomobject]@{
      TimedOut = $false
      Raw = @($jobRaw)
      ExitCode = $null
      Result = $null
      JsonLine = $null
      WrapperError = "$_"
    }
  }

  $raw = @($payload.Raw)
  $jsonLine = $raw | Where-Object { $_ -match "^\s*\{" } | Select-Object -Last 1

  if (-not $jsonLine) {
    return [pscustomobject]@{
      TimedOut = $false
      Raw = $raw
      ExitCode = $payload.ExitCode
      Result = $null
      JsonLine = $null
      WrapperError = $null
    }
  }

  return [pscustomobject]@{
    TimedOut = $false
    Raw = $raw
    ExitCode = $payload.ExitCode
    Result = ($jsonLine | ConvertFrom-Json)
    JsonLine = $jsonLine
    WrapperError = $null
  }
}

function Test-PlanPlaceholderResponse {
  param([object]$Result)

  if (-not $Result -or [string]::IsNullOrWhiteSpace($Result.result)) {
    return $false
  }

  return (
    $Result.result -match "ExitPlanMode" -or
    $Result.result -match "review is ready for your review"
  )
}

try {
  if ([string]::IsNullOrWhiteSpace($Task) -and $MyInvocation.ExpectingInput) {
    $Task = ($input | Out-String)
  }

  if ([string]::IsNullOrWhiteSpace($Task)) {
    throw "Task text is empty. Pass a positional task string or pipe text into the script."
  }

  if ($TimeoutSeconds -lt 30) {
    throw "TimeoutSeconds must be at least 30."
  }

  $script:OutputPath = Initialize-OutputPath -RequestedPath $Output

  Write-OutputMarkdown `
    -Path $script:OutputPath `
    -SessionId "" `
    -ModelName $Model `
    -EffortLevel $Effort `
    -Permission "" `
    -IsReadOnly $ReadOnly.IsPresent `
    -Body "Claude Code invocation is still running. If this file remains unchanged, the parent process was interrupted before completion." `
    -ModelUsage $null `
    -Status "RUNNING"

  if (-not $NoSettingsEnv) {
    Import-ClaudeSettingsEnv
  }

  $workspaceRoot = Resolve-WorkspacePath $Workspace
  if (-not (Test-Path -LiteralPath $workspaceRoot -PathType Container)) {
    throw "Workspace does not exist: $workspaceRoot"
  }

  $prompt = $Task.Trim()

  if ($ReadOnly) {
    $prompt += "`n`nMode constraint: read-only. Do not edit files. Provide analysis, critique, or recommendations only."
  }

  if ($File.Count -gt 0) {
    $prompt += "`n`nPriority files to inspect first:"
    $fileIndex = 0
    foreach ($item in $File) {
      $resolved = Resolve-ContextPath -WorkspaceRoot $workspaceRoot -Path $item
      $fileIndex++
      $accessible = Copy-ContextFileForClaude -WorkspaceRoot $workspaceRoot -ResolvedPath $resolved -Index $fileIndex
      $prompt += "`n- $($accessible.Path) ($($accessible.Note))"
    }
  }

  $claudeCommand = (Get-Command claude -ErrorAction Stop).Source

  $claudeArgs = @(
    "-p",
    "--output-format", "json",
    "--model", $Model,
    "--effort", $Effort
  )

  if ($Bare) {
    $claudeArgs += "--bare"
  }

  $permissionModeExplicit = $PSBoundParameters.ContainsKey("PermissionMode")
  $effectivePermissionMode = $PermissionMode

  if (-not $permissionModeExplicit -and $ReadOnly) {
    $effectivePermissionMode = "default"
  }

  if (-not [string]::IsNullOrWhiteSpace($effectivePermissionMode)) {
    $claudeArgs += @("--permission-mode", $effectivePermissionMode)
  }

  if ($Session) {
    $claudeArgs += @("--resume", $Session)
  }

  $claudeArgs += $prompt

  $invoke = Invoke-ClaudeJson `
    -WorkspaceRoot $workspaceRoot `
    -ClaudeCommand $claudeCommand `
    -ClaudeArgs $claudeArgs `
    -TimeoutSeconds $TimeoutSeconds

  if (
    $ReadOnly -and
    -not $permissionModeExplicit -and
    $effectivePermissionMode -eq "default" -and
    $invoke.Result -and
    (Test-PlanPlaceholderResponse -Result $invoke.Result)
  ) {
    $fallbackArgs = @($claudeArgs)
    $permissionIndex = [Array]::IndexOf($fallbackArgs, "--permission-mode")
    if ($permissionIndex -ge 0 -and ($permissionIndex + 1) -lt $fallbackArgs.Length) {
      $fallbackArgs[$permissionIndex + 1] = "dontAsk"
    }

    $invoke = Invoke-ClaudeJson `
      -WorkspaceRoot $workspaceRoot `
      -ClaudeCommand $claudeCommand `
      -ClaudeArgs $fallbackArgs `
      -TimeoutSeconds $TimeoutSeconds

    $effectivePermissionMode = "dontAsk"
  }

  if ($invoke.TimedOut) {
    Write-OutputMarkdown `
      -Path $script:OutputPath `
      -SessionId "" `
      -ModelName $Model `
      -EffortLevel $Effort `
      -Permission $effectivePermissionMode `
      -IsReadOnly $ReadOnly.IsPresent `
      -Body "Claude Code timed out after $TimeoutSeconds seconds. Increase -TimeoutSeconds or reduce the request scope." `
      -ModelUsage $null `
      -Status "TIMEOUT"

    Write-OutputPath -Path $script:OutputPath
    throw "Claude Code timed out after $TimeoutSeconds seconds. Output was written to $script:OutputPath"
  }

  if (-not $invoke.JsonLine) {
    $rawBody = ($invoke.Raw -join "`n")
    if ($invoke.WrapperError) {
      $rawBody += "`n`nWrapper parse error:`n$($invoke.WrapperError)"
    }

    Write-OutputMarkdown `
      -Path $script:OutputPath `
      -SessionId "" `
      -ModelName $Model `
      -EffortLevel $Effort `
      -Permission $effectivePermissionMode `
      -IsReadOnly $ReadOnly.IsPresent `
      -Body "Claude Code did not return JSON.`n`nRaw output:`n`n``````text`n$rawBody`n``````" `
      -ModelUsage $null `
      -Status "NO_JSON"

    Write-OutputPath -Path $script:OutputPath
    throw "Claude Code did not return JSON. Raw output was written to $script:OutputPath"
  }

  $result = $invoke.Result
  $finalStatus = if ($result.is_error -or $invoke.ExitCode -ne 0) { "ERROR" } else { "OK" }
  $body = "$($result.result)"
  if ($invoke.ExitCode -ne 0) {
    $body += "`n`nClaude Code exited with code $($invoke.ExitCode)."
  }

  Write-OutputMarkdown `
    -Path $script:OutputPath `
    -SessionId $result.session_id `
    -ModelName $Model `
    -EffortLevel $Effort `
    -Permission $effectivePermissionMode `
    -IsReadOnly $ReadOnly.IsPresent `
    -Body $body `
    -ModelUsage $result.modelUsage `
    -Status $finalStatus

  if ($result.session_id) {
    Write-Output "session_id=$($result.session_id)"
  }
  Write-OutputPath -Path $script:OutputPath

  if ($invoke.ExitCode -ne 0) {
    throw "Claude Code exited with code $($invoke.ExitCode). Output was written to $script:OutputPath"
  }
}
catch {
  if (-not [string]::IsNullOrWhiteSpace($script:OutputPath)) {
    $terminalStatus = Get-OutputStatus -Path $script:OutputPath
    if ($terminalStatus -notin @("OK", "ERROR", "TIMEOUT", "NO_JSON")) {
      Write-OutputMarkdown `
        -Path $script:OutputPath `
        -SessionId "" `
        -ModelName $Model `
        -EffortLevel $Effort `
        -Permission "" `
        -IsReadOnly $ReadOnly.IsPresent `
        -Body "Wrapper failed before producing a terminal Claude Code result.`n`nError:`n`n``````text`n$_`n``````" `
        -ModelUsage $null `
        -Status "ERROR"
    }

    Write-OutputPath -Path $script:OutputPath
  }

  throw
}
