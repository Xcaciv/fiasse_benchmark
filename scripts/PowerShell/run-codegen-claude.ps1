#Requires -Version 5.1
<#
.SYNOPSIS
    Automates Claude Code to generate a project from a PRD in 3 languages,
    each with a "rawdog" (plain) and "securable" (FIASSE plugin) variant.

.DESCRIPTION
    Produces the following folder structure:
        <OutputDir>/
            aspnet/
                rawdog/     <- Plain Claude Code generation
                securable/  <- Generation with securable-claude-plugin
            jsp/
                rawdog/
                securable/
            node/
                rawdog/
                securable/

.PARAMETER PrdFile
    Path to your PRD markdown or text file. Required.

.PARAMETER OutputDir
    Root folder for all generated output. Defaults to .\codegen-output

.PARAMETER PluginRepo
    URL of the securable-claude-plugin. Defaults to the canonical repo.

.PARAMETER DryRun
    Print the commands that would run without actually executing Claude Code.
    Useful for verifying setup before spending tokens.

.EXAMPLE
    .\run-codegen.ps1 -PrdFile .\my-prd.md
    .\run-codegen.ps1 -PrdFile .\my-prd.md -OutputDir C:\Projects\codegen -DryRun
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateScript({ Test-Path $_ -PathType Leaf })]
    [string]$PrdFile,

    [string]$OutputDir = ".\codegen-output",

    [string]$PluginRepo = "https://github.com/Xcaciv/securable-claude-plugin.git",

    [switch]$DryRun
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# ---------------------------------------------------------------------------
# Language definitions
# Name -> human-readable label used inside prompts
# ---------------------------------------------------------------------------
$Languages = [ordered]@{
    "aspnet" = "ASP.NET Core (C#) Web API / MVC application"
    "jsp"    = "Java web application using JSP (Java Server Pages) and servlets"
    "node"   = "Node.js web application using Express.js"
}

# ---------------------------------------------------------------------------
# Helper: Write a coloured status line
# ---------------------------------------------------------------------------
function Write-Step([string]$Message, [string]$Color = "Cyan") {
    Write-Host "`n>>> $Message" -ForegroundColor $Color
}

# ---------------------------------------------------------------------------
# Helper: Run claude non-interactively in a given directory
#   Claude Code CLI: claude --print  (alias: claude -p)
#   The prompt is passed via stdin so we avoid command-line quoting hell.
# ---------------------------------------------------------------------------
function Invoke-Claude {
    param(
        [string]$WorkingDir,
        [string]$Prompt,
        [string]$Label
    )

    $logFile = Join-Path $WorkingDir "claude-output.log"

    if ($DryRun) {
        Write-Host "  [DRY-RUN] Would run in: $WorkingDir" -ForegroundColor Yellow
        Write-Host "  [DRY-RUN] Prompt starts: $($Prompt.Substring(0, [Math]::Min(120, $Prompt.Length)))..." -ForegroundColor Yellow
        return
    }

    Write-Step "Running Claude Code for: $Label" "Green"
    Write-Host "  Output dir : $WorkingDir"
    Write-Host "  Log file   : $logFile"

    Push-Location $WorkingDir
    try {
        # Pipe the prompt via stdin; --print keeps Claude non-interactive
        $Prompt | claude --print 2>&1 | Tee-Object -FilePath $logFile
        if ($LASTEXITCODE -ne 0) {
            Write-Warning "Claude exited with code $LASTEXITCODE for $Label — check $logFile"
        }
    }
    finally {
        Pop-Location
    }
}

# ---------------------------------------------------------------------------
# Helper: Install the securable plugin into a target directory
#   Copies .claude/ dir and CLAUDE.md from the cloned plugin repo.
# ---------------------------------------------------------------------------
function Install-SecurablePlugin {
    param(
        [string]$PluginSource,   # path to the cloned plugin repo
        [string]$TargetDir       # project directory to install into
    )

    $claudeDir   = Join-Path $PluginSource ".claude"
    $claudeMd    = Join-Path $PluginSource "CLAUDE.md"
    $skillsDir   = Join-Path $PluginSource "skills"
    $dataDir     = Join-Path $PluginSource "data"

    if (Test-Path $claudeDir) {
        Copy-Item -Recurse -Force $claudeDir  (Join-Path $TargetDir ".claude")
    }
    if (Test-Path $claudeMd) {
        Copy-Item -Force $claudeMd (Join-Path $TargetDir "CLAUDE.md")
    }
    # skills/ and data/ are referenced by the plugin's commands
    if (Test-Path $skillsDir) {
        Copy-Item -Recurse -Force $skillsDir  (Join-Path $TargetDir "skills")
    }
    if (Test-Path $dataDir) {
        Copy-Item -Recurse -Force $dataDir    (Join-Path $TargetDir "data")
    }
}

# ---------------------------------------------------------------------------
# Helper: Read the /secure-generate command definition so we can embed it
#   directly in the prompt — this makes it work reliably in --print mode
#   where slash commands may not be dispatched automatically.
# ---------------------------------------------------------------------------
function Get-SecureGenerateInstructions([string]$PluginSource) {
    $cmdFile = Join-Path $PluginSource ".claude\commands\secure-generate.md"
    if (Test-Path $cmdFile) {
        return Get-Content $cmdFile -Raw
    }
    # Fallback if file not found
    return @"
Apply FIASSE/SSEM securability engineering principles as hard constraints
while generating the code. Ensure the output scores well across the nine
SSEM attributes: Analyzability, Modifiability, Testability, Confidentiality,
Accountability, Authenticity, Availability, Integrity, and Resilience.
Use the /secure-generate approach from the securable-claude-plugin.
"@
}

# ===========================================================================
# MAIN
# ===========================================================================

# Resolve absolute paths early to avoid Push-Location surprises
$PrdFile   = Resolve-Path $PrdFile | Select-Object -ExpandProperty Path
$OutputDir = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutputDir)

Write-Step "Starting codegen run" "Magenta"
Write-Host "  PRD file   : $PrdFile"
Write-Host "  Output dir : $OutputDir"
Write-Host "  Dry run    : $DryRun"

# Read PRD
$PrdContent = Get-Content $PrdFile -Raw

# Create root output dir
New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null

# ---------------------------------------------------------------------------
# Step 1: Clone the plugin once into a temp subfolder
# ---------------------------------------------------------------------------
$PluginTemp = Join-Path $OutputDir "_plugin_temp"

if (Test-Path $PluginTemp) {
    Write-Step "Plugin already cloned at $PluginTemp — skipping clone" "Yellow"
} else {
    Write-Step "Cloning securable-claude-plugin ..."
    if ($DryRun) {
        Write-Host "  [DRY-RUN] git clone $PluginRepo $PluginTemp" -ForegroundColor Yellow
        # Create a stub so the rest of the script can continue in dry-run mode
        New-Item -ItemType Directory -Force -Path (Join-Path $PluginTemp ".claude\commands") | Out-Null
        New-Item -ItemType Directory -Force -Path (Join-Path $PluginTemp "skills") | Out-Null
        New-Item -ItemType Directory -Force -Path (Join-Path $PluginTemp "data") | Out-Null
        Set-Content (Join-Path $PluginTemp "CLAUDE.md") "# Securable Plugin (dry-run stub)"
        Set-Content (Join-Path $PluginTemp ".claude\commands\secure-generate.md") "# secure-generate stub"
    } else {
        git clone $PluginRepo $PluginTemp
        if ($LASTEXITCODE -ne 0) { throw "git clone failed" }
    }
}

$SecureInstructions = Get-SecureGenerateInstructions $PluginTemp

# ---------------------------------------------------------------------------
# Step 2: Loop over languages x modes
# ---------------------------------------------------------------------------
foreach ($langKey in $Languages.Keys) {
    $langLabel = $Languages[$langKey]

    foreach ($mode in @("rawdog", "securable")) {

        $targetDir = Join-Path $OutputDir "$langKey\$mode"
        New-Item -ItemType Directory -Force -Path $targetDir | Out-Null

        # ---- Build the prompt ----
        if ($mode -eq "rawdog") {
            $prompt = @"
Generate a complete, working $langLabel project based on the following PRD.

Create all necessary files, configuration, and folder structure.
Include a README.md with setup and run instructions.

PRD:
---
$PrdContent
---
"@
        } else {
            # securable: install plugin files then invoke /secure-generate
            Install-SecurablePlugin -PluginSource $PluginTemp -TargetDir $targetDir

            $prompt = @"
You are operating with the securable-claude-plugin active (CLAUDE.md and
.claude/commands/ are present in this directory).

Apply the following /secure-generate instructions as your primary constraints:

$SecureInstructions

Now generate a complete, working $langLabel project based on the following PRD,
ensuring all FIASSE/SSEM securability attributes are applied throughout.

Create all necessary files, configuration, and folder structure.
Include a README.md with setup, run instructions, and a brief SSEM score summary.

PRD:
---
$PrdContent
---
"@
        }

        $label = "$langKey / $mode"
        Invoke-Claude -WorkingDir $targetDir -Prompt $prompt -Label $label
    }
}

# ---------------------------------------------------------------------------
# Step 3: Summary
# ---------------------------------------------------------------------------
Write-Step "All done!" "Magenta"
Write-Host ""
Write-Host "Generated folder structure:" -ForegroundColor White
foreach ($langKey in $Languages.Keys) {
    Write-Host "  $OutputDir\" -NoNewline -ForegroundColor Gray
    Write-Host "$langKey\" -ForegroundColor Cyan
    Write-Host "    rawdog\     <- plain generation" -ForegroundColor Gray
    Write-Host "    securable\  <- FIASSE/SSEM secured generation" -ForegroundColor Gray
}
Write-Host ""
Write-Host "Each folder contains a claude-output.log with the full Claude response." -ForegroundColor DarkGray

if ($DryRun) {
    Write-Host "`n[DRY-RUN MODE] No Claude calls were made." -ForegroundColor Yellow
    Write-Host "Remove -DryRun to execute for real." -ForegroundColor Yellow
}
