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

function Get-ScriptRoot {
  if ($PSScriptRoot) {
    return $PSScriptRoot
  }

  return Split-Path -Parent $MyInvocation.MyCommand.Path
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
    Stop-Job $job -Force
    Remove-Job $job -Force
    return [pscustomobject]@{
      TimedOut = $true
      Raw = @()
      ExitCode = $null
      Result = $null
      JsonLine = $null
    }
  }

  $jobRaw = Receive-Job $job
  Remove-Job $job -Force
  $payload = ($jobRaw | Out-String).Trim() | ConvertFrom-Json
  $raw = @($payload.Raw)
  $jsonLine = $raw | Where-Object { $_ -match "^\s*\{" } | Select-Object -Last 1

  if (-not $jsonLine) {
    return [pscustomobject]@{
      TimedOut = $false
      Raw = $raw
      ExitCode = $payload.ExitCode
      Result = $null
      JsonLine = $null
    }
  }

  return [pscustomobject]@{
    TimedOut = $false
    Raw = $raw
    ExitCode = $payload.ExitCode
    Result = ($jsonLine | ConvertFrom-Json)
    JsonLine = $jsonLine
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

if ([string]::IsNullOrWhiteSpace($Task)) {
  if ($MyInvocation.ExpectingInput) {
    $Task = ($input | Out-String)
  }
}

if ([string]::IsNullOrWhiteSpace($Task)) {
  throw "Task text is empty. Pass a positional task string or pipe text into the script."
}

if ($TimeoutSeconds -lt 30) {
  throw "TimeoutSeconds must be at least 30."
}

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
  foreach ($item in $File) {
    $resolved = Resolve-ContextPath -WorkspaceRoot $workspaceRoot -Path $item
    $status = if (Test-Path -LiteralPath $resolved) { "exists" } else { "missing" }
    $prompt += "`n- $resolved ($status)"
  }
}

if (-not $Output) {
  $timestamp = (Get-Date).ToUniversalTime().ToString("yyyyMMdd-HHmmss")
  $runtimeDir = Join-Path (Split-Path -Parent (Get-ScriptRoot)) ".runtime"
  New-Item -ItemType Directory -Force -Path $runtimeDir | Out-Null
  $Output = Join-Path $runtimeDir "$timestamp.md"
}
else {
  $outputParent = Split-Path -Parent ([System.IO.Path]::GetFullPath($Output))
  if ($outputParent) {
    New-Item -ItemType Directory -Force -Path $outputParent | Out-Null
  }
}

Write-OutputMarkdown `
  -Path $Output `
  -SessionId "" `
  -ModelName $Model `
  -EffortLevel $Effort `
  -Permission "" `
  -IsReadOnly $ReadOnly.IsPresent `
  -Body "Claude Code invocation is still running. If this file remains unchanged, the parent process was interrupted before completion." `
  -ModelUsage $null `
  -Status "RUNNING"

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
    -Path $Output `
    -SessionId "" `
    -ModelName $Model `
    -EffortLevel $Effort `
    -Permission $effectivePermissionMode `
    -IsReadOnly $ReadOnly.IsPresent `
    -Body "Claude Code timed out after $TimeoutSeconds seconds. Increase -TimeoutSeconds or reduce the request scope." `
    -ModelUsage $null `
    -Status "TIMEOUT"

  Write-Output "output_path=$([System.IO.Path]::GetFullPath($Output))"
  throw "Claude Code timed out after $TimeoutSeconds seconds. Output was written to $Output"
}

if (-not $invoke.JsonLine) {
  $rawBody = ($invoke.Raw -join "`n")
  Write-OutputMarkdown `
    -Path $Output `
    -SessionId "" `
    -ModelName $Model `
    -EffortLevel $Effort `
    -Permission $effectivePermissionMode `
    -IsReadOnly $ReadOnly.IsPresent `
    -Body "Claude Code did not return JSON.`n`nRaw output:`n`n``````text`n$rawBody`n``````" `
    -ModelUsage $null `
    -Status "NO_JSON"

  Write-Output "output_path=$([System.IO.Path]::GetFullPath($Output))"
  throw "Claude Code did not return JSON. Raw output was written to $Output"
}

$result = $invoke.Result

Write-OutputMarkdown `
  -Path $Output `
  -SessionId $result.session_id `
  -ModelName $Model `
  -EffortLevel $Effort `
  -Permission $effectivePermissionMode `
  -IsReadOnly $ReadOnly.IsPresent `
  -Body "$($result.result)" `
  -ModelUsage $result.modelUsage `
  -Status $(if ($result.is_error) { "ERROR" } else { "OK" })

if ($invoke.ExitCode -ne 0 -and -not $result.session_id) {
  Write-Output "output_path=$([System.IO.Path]::GetFullPath($Output))"
  throw "Claude Code exited with code $($invoke.ExitCode). Output was written to $Output"
}

if ($result.session_id) {
  Write-Output "session_id=$($result.session_id)"
}
Write-Output "output_path=$([System.IO.Path]::GetFullPath($Output))"
