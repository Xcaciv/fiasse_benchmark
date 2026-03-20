#Requires -Version 5.1
<#
.SYNOPSIS
    Automates GitHub Copilot CLI to generate a project from a PRD in 3 languages,
    each with a "rawdog" (plain) and "securable" (FIASSE plugin) variant.

.DESCRIPTION
    Mirrors the structure produced by run-codegen.ps1 (Claude Code), but drives
    GitHub Copilot CLI instead.

    Produces the following folder structure:
        <OutputDir>/
            aspnet/
                rawdog/     <- Plain Copilot generation
                securable/  <- Generation with securable-copilot plugin active
            jsp/
                rawdog/
                securable/
            node/
                rawdog/
                securable/

    Plugin activation mechanism (securable mode):
        Copilot CLI automatically reads  <workdir>/.github/copilot-instructions.md
        when present.  The script clones the securable-copilot repo once, then
        copies .github/ into each securable target directory before invoking the
        CLI, so the instructions are active for that run only.

    Copilot CLI invocation:
        copilot agent run --prompt "..." --yes
        (--yes suppresses interactive confirmations; the agent writes files
         directly into the current working directory)

.PARAMETER PrdFile
    Path to your PRD markdown or text file.  Required.

.PARAMETER OutputDir
    Root folder for all generated output.  Defaults to .\copilot-codegen-output

.PARAMETER PluginRepo
    URL of the securable-copilot repo.  Defaults to the canonical repo.

.PARAMETER DryRun
    Print the commands that would run without executing Copilot CLI.

.EXAMPLE
    .\run-codegen-copilot.ps1 -PrdFile .\my-prd.md
    .\run-codegen-copilot.ps1 -PrdFile .\my-prd.md -OutputDir D:\tests\copilot -DryRun
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateScript({ Test-Path $_ -PathType Leaf })]
    [string]$PrdFile,

    [string]$OutputDir = ".\copilot-codegen-output",

    [string]$PluginRepo = "https://github.com/Xcaciv/securable-copilot.git",

    [switch]$DryRun
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# ---------------------------------------------------------------------------
# Language definitions
# ---------------------------------------------------------------------------
$Languages = [ordered]@{
    "aspnet" = "ASP.NET Core (C#) Web API / MVC application"
    "jsp"    = "Java web application using JSP (Java Server Pages) and servlets"
    "node"   = "Node.js web application using Express.js"
}

# ---------------------------------------------------------------------------
# Helper: Coloured status line
# ---------------------------------------------------------------------------
function Write-Step([string]$Message, [string]$Color = "Cyan") {
    Write-Host "`n>>> $Message" -ForegroundColor $Color
}

# ---------------------------------------------------------------------------
# Helper: Verify required tools are present
# ---------------------------------------------------------------------------
function Assert-Tool([string]$Name) {
    if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) {
        throw "Required tool '$Name' not found on PATH.  Please install it and try again."
    }
    Write-Host "  [OK] $Name found: $((Get-Command $Name).Source)" -ForegroundColor DarkGreen
}

# ---------------------------------------------------------------------------
# Helper: Run Copilot CLI agent non-interactively in a given directory.
#
#   GitHub Copilot CLI non-interactive invocation:
#     copilot agent run --prompt "..." --yes
#
#   --yes       suppress all interactive confirmations
#   The agent writes generated files directly into the working directory,
#   so we Push-Location into the target folder first.
#
#   Copilot CLI discovers .github/copilot-instructions.md automatically
#   from the current working directory — no extra flags needed.
# ---------------------------------------------------------------------------
function Invoke-CopilotAgent {
    param(
        [string]$WorkingDir,
        [string]$Prompt,
        [string]$Label
    )

    $logFile = Join-Path $WorkingDir "copilot-output.log"

    if ($DryRun) {
        Write-Host "  [DRY-RUN] Would run in: $WorkingDir" -ForegroundColor Yellow
        Write-Host "  [DRY-RUN] Prompt starts: $($Prompt.Substring(0, [Math]::Min(120, $Prompt.Length)))..." -ForegroundColor Yellow
        return
    }

    Write-Step "Running Copilot CLI for: $Label" "Green"
    Write-Host "  Output dir : $WorkingDir"
    Write-Host "  Log file   : $logFile"

    # Write the prompt to a temp file to avoid any shell quoting issues
    # with multi-line strings on Windows.
    $promptFile = Join-Path $env:TEMP "copilot_prompt_$([System.IO.Path]::GetRandomFileName()).txt"
    try {
        Set-Content -Path $promptFile -Value $Prompt -Encoding UTF8

        Push-Location $WorkingDir
        try {
            # copilot agent run reads the prompt from a file via --prompt-file,
            # or from stdin.  We use --prompt-file for maximum compatibility.
            # If your version of copilot CLI uses a different flag, adjust here.
            copilot agent run --prompt-file $promptFile --yes 2>&1 |
                Tee-Object -FilePath $logFile

            if ($LASTEXITCODE -ne 0) {
                Write-Warning "copilot agent run exited with code $LASTEXITCODE for $Label — check $logFile"
            }
        }
        finally {
            Pop-Location
        }
    }
    finally {
        if (Test-Path $promptFile) { Remove-Item $promptFile -Force }
    }
}

# ---------------------------------------------------------------------------
# Helper: Install the securable-copilot plugin into a target directory.
#
#   The securable-copilot plugin works through two automatic mechanisms:
#     1. .github/copilot-instructions.md  — loaded automatically by every
#        Copilot interaction when present in the working directory.
#     2. .github/prompts/*.prompt.md      — reusable skills/prompts that
#        Copilot CLI makes available as named context.
#
#   We also copy .github/agents/ so the Securable Engineer persona is
#   available if Copilot picks up agent definitions from the project.
# ---------------------------------------------------------------------------
function Install-SecurableCopilotPlugin {
    param(
        [string]$PluginSource,   # path to the cloned plugin repo
        [string]$TargetDir       # project directory to install into
    )

    $srcGithub = Join-Path $PluginSource ".github"
    $dstGithub = Join-Path $TargetDir   ".github"

    if (Test-Path $srcGithub) {
        Copy-Item -Recurse -Force $srcGithub $dstGithub
        Write-Host "  Installed .github/ plugin files into: $dstGithub" -ForegroundColor DarkGray
    } else {
        Write-Warning "Plugin .github/ directory not found at $srcGithub — securable mode may not be active."
    }
}

# ---------------------------------------------------------------------------
# Helper: Read copilot-instructions.md and any relevant prompt files from
#   the cloned plugin, so we can embed them directly in the Copilot prompt.
#   This is belt-and-suspenders: even if Copilot CLI doesn't auto-load the
#   instructions in headless mode, the content is part of the request.
# ---------------------------------------------------------------------------
function Get-SecurableInstructions([string]$PluginSource) {
    $parts = [System.Collections.Generic.List[string]]::new()

    # Primary: copilot-instructions.md
    $instrFile = Join-Path $PluginSource ".github\copilot-instructions.md"
    if (Test-Path $instrFile) {
        $parts.Add((Get-Content $instrFile -Raw))
    }

    # Supplementary: the code-generation-relevant prompt files
    $promptFiles = @(
        ".github\prompts\input-handling.prompt.md",
        ".github\prompts\security-requirements.prompt.md"
    )
    foreach ($rel in $promptFiles) {
        $full = Join-Path $PluginSource $rel
        if (Test-Path $full) {
            $parts.Add("---`n# $(Split-Path $rel -Leaf)`n" + (Get-Content $full -Raw))
        }
    }

    if ($parts.Count -gt 0) {
        return $parts -join "`n`n"
    }

    # Fallback if repo layout differs
    return @"
Apply FIASSE/SSEM securability engineering principles throughout.
Satisfy all nine SSEM attributes:
  Maintainability: Analyzability, Modifiability, Testability
  Trustworthiness: Confidentiality, Accountability, Authenticity
  Reliability:     Availability, Integrity, Resilience
Apply canonical input handling (Canonicalize -> Sanitize -> Validate) at all
trust boundaries.  Enforce the Derived Integrity Principle for business-critical
values.  Produce structured audit logging for all accountable actions.
"@
}

# ===========================================================================
# MAIN
# ===========================================================================

$PrdFile   = Resolve-Path $PrdFile | Select-Object -ExpandProperty Path
$OutputDir = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutputDir)

Write-Step "Starting Copilot CLI codegen run" "Magenta"
Write-Host "  PRD file   : $PrdFile"
Write-Host "  Output dir : $OutputDir"
Write-Host "  Dry run    : $DryRun"

# ---------------------------------------------------------------------------
# Prerequisite check
# ---------------------------------------------------------------------------
Write-Step "Checking prerequisites ..."
if (-not $DryRun) {
    Assert-Tool "copilot"
    Assert-Tool "git"
} else {
    Write-Host "  [DRY-RUN] Skipping tool checks" -ForegroundColor Yellow
}

# Read PRD
$PrdContent = Get-Content $PrdFile -Raw

# Create root output dir
New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null

# ---------------------------------------------------------------------------
# Step 1: Clone the plugin once
# ---------------------------------------------------------------------------
$PluginTemp = Join-Path $OutputDir "_securable_copilot_temp"

if (Test-Path $PluginTemp) {
    Write-Step "Plugin already cloned at $PluginTemp — skipping clone" "Yellow"
} else {
    Write-Step "Cloning securable-copilot plugin ..."
    if ($DryRun) {
        Write-Host "  [DRY-RUN] git clone $PluginRepo $PluginTemp" -ForegroundColor Yellow
        # Stub structure for dry-run
        New-Item -ItemType Directory -Force -Path (Join-Path $PluginTemp ".github\prompts") | Out-Null
        New-Item -ItemType Directory -Force -Path (Join-Path $PluginTemp ".github\agents")  | Out-Null
        Set-Content (Join-Path $PluginTemp ".github\copilot-instructions.md") "# securable-copilot stub (dry-run)"
    } else {
        git clone $PluginRepo $PluginTemp
        if ($LASTEXITCODE -ne 0) { throw "git clone failed" }
    }
}

$SecurableInstructions = Get-SecurableInstructions $PluginTemp

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

Create all necessary source files, configuration files, and folder structure
inside the current working directory.

Include a README.md with setup and run instructions.

PRD:
---
$PrdContent
---
"@
        } else {
            # Install plugin files first so Copilot CLI auto-loads them
            Install-SecurableCopilotPlugin -PluginSource $PluginTemp -TargetDir $targetDir

            $prompt = @"
You are operating with the securable-copilot FIASSE plugin active.
The following securability engineering instructions and prompts are your
primary constraints — treat them as non-negotiable design requirements,
not optional guidelines.

=== SECURABLE-COPILOT PLUGIN INSTRUCTIONS ===
$SecurableInstructions
=== END PLUGIN INSTRUCTIONS ===

Now generate a complete, working $langLabel project based on the following PRD,
applying every FIASSE/SSEM constraint above throughout all generated code.

Create all necessary source files, configuration files, and folder structure
inside the current working directory.

Include a README.md with:
  - Setup and run instructions
  - A brief SSEM attribute coverage summary describing how each of the nine
    attributes is addressed in the generated code

PRD:
---
$PrdContent
---
"@
        }

        $label = "$langKey / $mode"
        Invoke-CopilotAgent -WorkingDir $targetDir -Prompt $prompt -Label $label
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
    Write-Host "    rawdog\     <- plain Copilot generation" -ForegroundColor Gray
    Write-Host "    securable\  <- FIASSE/SSEM secured generation" -ForegroundColor Gray
}
Write-Host ""
Write-Host "Each folder contains a copilot-output.log with the full CLI response." -ForegroundColor DarkGray
Write-Host ""
Write-Host "NOTE: If 'copilot agent run --prompt-file' is not available in your" -ForegroundColor DarkYellow
Write-Host "      version of the CLI, see the PROMPT FLAG COMPATIBILITY note in" -ForegroundColor DarkYellow
Write-Host "      the script comments and update Invoke-CopilotAgent accordingly." -ForegroundColor DarkYellow

if ($DryRun) {
    Write-Host "`n[DRY-RUN MODE] No Copilot calls were made." -ForegroundColor Yellow
    Write-Host "Remove -DryRun to execute for real." -ForegroundColor Yellow
}
