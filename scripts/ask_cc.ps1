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

  [switch]$ReadOnly,

  [switch]$Bare
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

if ([string]::IsNullOrWhiteSpace($Task)) {
  if ($MyInvocation.ExpectingInput) {
    $Task = ($input | Out-String)
  }
}

if ([string]::IsNullOrWhiteSpace($Task)) {
  throw "Task text is empty. Pass a positional task string or pipe text into the script."
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

$claudeArgs = @(
  "-p",
  "--output-format", "json",
  "--model", $Model,
  "--effort", $Effort
)

if ($Bare) {
  $claudeArgs += "--bare"
}

if ($ReadOnly) {
  $claudeArgs += @("--permission-mode", "plan")
}

if ($Session) {
  $claudeArgs += @("--resume", $Session)
}

$claudeArgs += $prompt

Push-Location $workspaceRoot
try {
  $raw = & claude @claudeArgs 2>&1
  $exitCode = $LASTEXITCODE
}
finally {
  Pop-Location
}

$jsonLine = $raw | Where-Object { $_ -match "^\s*\{" } | Select-Object -Last 1
if (-not $jsonLine) {
  $raw | Set-Content -Encoding UTF8 -LiteralPath $Output
  throw "Claude Code did not return JSON. Raw output was written to $Output"
}

$result = $jsonLine | ConvertFrom-Json

$markdown = @()
$markdown += "# Claude Code Response"
$markdown += ""
$markdown += "**Session**: $($result.session_id)"
$markdown += "**Model**: $Model"
$markdown += "**Effort**: $Effort"
$markdown += "**Read Only**: $($ReadOnly.IsPresent)"
$markdown += ""
$markdown += "## Response"
$markdown += ""
$markdown += "$($result.result)"

if ($result.is_error) {
  $markdown += ""
  $markdown += "## Error"
  $markdown += ""
  $markdown += "Claude Code returned `is_error=true`."
}

$markdown -join "`n" | Set-Content -Encoding UTF8 -LiteralPath $Output

if ($exitCode -ne 0 -and -not $result.session_id) {
  throw "Claude Code exited with code $exitCode. Output was written to $Output"
}

if ($result.session_id) {
  Write-Output "session_id=$($result.session_id)"
}
Write-Output "output_path=$([System.IO.Path]::GetFullPath($Output))"
