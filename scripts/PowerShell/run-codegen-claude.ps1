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

.PARAMETER Resume
    Resume a previous run without wiping existing target directories.
    Useful when Claude rate limits or token windows interrupt generation.

.PARAMETER Clean
    Remove the cached plugin clone and .codegen-finished flags from
    the output directory, then exit.  No generation is performed.
    -PrdFile is not required when -Clean is specified.

.EXAMPLE
    .\run-codegen-claude.ps1 -PrdFile .\my-prd.md
    .\run-codegen-claude.ps1 -PrdFile .\my-prd.md -OutputDir C:\Projects\codegen -DryRun
    .\run-codegen-claude.ps1 -PrdFile .\my-prd.md -Resume
    .\run-codegen-claude.ps1 -OutputDir C:\Projects\codegen -Clean
#>

[CmdletBinding(DefaultParameterSetName = 'Run')]
param(
    [Parameter(Mandatory = $true, ParameterSetName = 'Run')]
    [ValidateScript({ Test-Path $_ -PathType Leaf })]
    [string]$PrdFile,

    [string]$OutputDir = ".\codegen-output",

    [string]$PluginRepo = "https://github.com/Xcaciv/securable-claude-plugin.git",

    [switch]$DryRun,

    [switch]$Resume,

    [Parameter(ParameterSetName = 'Clean')]
    [switch]$Clean
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

$FinishedFlagFileName = ".codegen-finished"

# ---------------------------------------------------------------------------
# Helper: Write a coloured status line
# ---------------------------------------------------------------------------
function Write-Step([string]$Message, [string]$Color = "Cyan") {
    Write-Host "`n>>> $Message" -ForegroundColor $Color
}

# ---------------------------------------------------------------------------
# Helper: Verify required tools are present
# ---------------------------------------------------------------------------
function Assert-Tool([string]$Name) {
    if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) {
        throw "Required tool '$Name' not found on PATH. Please install it and try again."
    }
    Write-Host "  [OK] $Name found: $((Get-Command $Name).Source)" -ForegroundColor DarkGreen
}

# ---------------------------------------------------------------------------
# Helper: Run claude non-interactively in a given directory.
#   Claude Code CLI: claude --print  (alias: claude -p)
#   The prompt is passed via stdin to avoid command-line quoting issues.
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
        # Pipe the prompt via stdin; --print keeps Claude non-interactive.
        # bypassPermissions prevents interactive write approval prompts.
        $Prompt | claude --print --permission-mode bypassPermissions 2>&1 | Tee-Object -FilePath $logFile
        if ($LASTEXITCODE -ne 0) {
            Write-Warning "Claude exited with code $LASTEXITCODE for $Label - check $logFile"
        }
    }
    finally {
        Pop-Location
    }
}

# ---------------------------------------------------------------------------
# Helper: Configure Claude's allowed write directories for a target directory.
#   Ensures the .claude/claude.json exists and allows writes to the target.
# ---------------------------------------------------------------------------
function Set-ClaudeWritePermissions {
    param(
        [string]$TargetDir
    )

    $claudeConfigDir = Join-Path $TargetDir ".claude"
    $claudeJsonPath = Join-Path $claudeConfigDir "claude.json"

    # Ensure .claude directory exists
    New-Item -ItemType Directory -Force -Path $claudeConfigDir | Out-Null

    # Create or update claude.json with allowed_write_directories
    # Using absolute path for target directory to allow Claude to write there
    $claudeConfig = @{
        "allowed_write_directories" = @(
            (Resolve-Path $TargetDir | Select-Object -ExpandProperty Path)
        )
    }

    $claudeConfig | ConvertTo-Json | Set-Content -Path $claudeJsonPath -Encoding UTF8
}

# ---------------------------------------------------------------------------
# Helper: Install the securable plugin into a target directory.
#   Copies .claude/, CLAUDE.md, skills/, and data/ from the cloned plugin repo.
# ---------------------------------------------------------------------------
function Install-SecurablePlugin {
    param(
        [string]$PluginSource,   # path to the cloned plugin repo
        [string]$TargetDir       # project directory to install into
    )

    $claudeDir = Join-Path $PluginSource ".claude"
    $claudeMd  = Join-Path $PluginSource "CLAUDE.md"
    $skillsDir = Join-Path $PluginSource "skills"
    $dataDir   = Join-Path $PluginSource "data"

    if (Test-Path $claudeDir) {
        Copy-Item -Recurse -Force $claudeDir (Join-Path $TargetDir ".claude")
    }
    if (Test-Path $claudeMd) {
        Copy-Item -Force $claudeMd (Join-Path $TargetDir "CLAUDE.md")
    }
    if (Test-Path $skillsDir) {
        Copy-Item -Recurse -Force $skillsDir (Join-Path $TargetDir "skills")
    }
    if (Test-Path $dataDir) {
        Copy-Item -Recurse -Force $dataDir (Join-Path $TargetDir "data")
    }
}

# ---------------------------------------------------------------------------
# Helper: Read the /secure-generate command definition so we can embed it
#   directly in the prompt. This makes it work reliably in --print mode
#   where slash commands may not be dispatched automatically.
# ---------------------------------------------------------------------------
function Get-SecureGenerateInstructions([string]$PluginSource) {
    $parts = [System.Collections.Generic.List[string]]::new()

    $claudeMd  = Join-Path $PluginSource "CLAUDE.md"
    $secGenCmd = Join-Path $PluginSource ".claude\commands\secure-generate.md"

    if (Test-Path $claudeMd) {
        $parts.Add((Get-Content $claudeMd -Raw))
    }
    if (Test-Path $secGenCmd) {
        $parts.Add("---`n# /secure-generate command definition`n" + (Get-Content $secGenCmd -Raw))
    }

    if ($parts.Count -gt 0) {
        return $parts -join "`n`n"
    }

    # Fallback if plugin files not found
    return @(
        "Apply FIASSE/SSEM securability engineering principles as hard constraints.",
        "Satisfy all nine SSEM attributes:",
        "  Maintainability: Analyzability, Modifiability, Testability",
        "  Trustworthiness: Confidentiality, Accountability, Authenticity",
        "  Reliability:     Availability, Integrity, Resilience",
        "Apply canonical input handling (Canonicalize -> Sanitize -> Validate) at all",
        "trust boundaries. Enforce the Derived Integrity Principle for business-critical",
        "values. Produce structured audit logging for all accountable actions."
    ) -join "`n"
}

# ===========================================================================
# MAIN
# ===========================================================================

# Resolve absolute paths early to avoid Push-Location surprises
$OutputDir = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutputDir)

# ---------------------------------------------------------------------------
# -Clean: remove cached plugin clone and finished flags, then exit
# ---------------------------------------------------------------------------
if ($Clean) {
    Write-Step "Cleaning cache files from $OutputDir" "Magenta"

    $PluginTemp = Join-Path $OutputDir "_plugin_temp"
    if (Test-Path $PluginTemp) {
        Write-Host "  Removing plugin cache: $PluginTemp" -ForegroundColor Yellow
        Remove-Item -Recurse -Force $PluginTemp
    } else {
        Write-Host "  Plugin cache not found (already clean)" -ForegroundColor DarkGray
    }

    $flagsRemoved = 0
    if (Test-Path $OutputDir) {
        Get-ChildItem -Path $OutputDir -Filter $FinishedFlagFileName -Recurse -Force | ForEach-Object {
            Write-Host "  Removing finished flag: $($_.FullName)" -ForegroundColor Yellow
            Remove-Item -Force $_.FullName
            $flagsRemoved++
        }
    }
    Write-Host "  Removed $flagsRemoved finished flag(s)." -ForegroundColor DarkGray

    Write-Step "Clean complete." "Magenta"
    return
}

$PrdFile   = Resolve-Path $PrdFile | Select-Object -ExpandProperty Path

Write-Step "Starting codegen run" "Magenta"
Write-Host "  PRD file   : $PrdFile"
Write-Host "  Output dir : $OutputDir"
Write-Host "  Dry run    : $DryRun"
Write-Host "  Resume     : $Resume"

# ---------------------------------------------------------------------------
# Prerequisite check
# ---------------------------------------------------------------------------
Write-Step "Checking prerequisites ..."
if (-not $DryRun) {
    Assert-Tool "claude"
    Assert-Tool "git"
} else {
    Write-Host "  [DRY-RUN] Skipping tool checks" -ForegroundColor Yellow
}

# Read PRD
$PrdContent = Get-Content $PrdFile -Raw

# Create root output dir
New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null

# ---------------------------------------------------------------------------
# Step 1: Clone the plugin once into a temp subfolder
# ---------------------------------------------------------------------------
$PluginTemp = Join-Path $OutputDir "_plugin_temp"

if (Test-Path $PluginTemp) {
    Write-Step "Plugin already cloned at $PluginTemp - skipping clone" "Yellow"
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
        $finishedFlagPath = Join-Path $targetDir $FinishedFlagFileName

        if ($Resume -and (Test-Path $finishedFlagPath)) {
            if ($DryRun) {
                Write-Host "  [DRY-RUN] Would skip completed variation: $targetDir" -ForegroundColor Yellow
            } else {
                Write-Host "  Skipping completed variation: $targetDir" -ForegroundColor DarkGreen
            }
            continue
        }

        # By default, wipe prior output so generation starts from a clean slate.
        # In -Resume mode, preserve existing content to continue interrupted runs.
        if (Test-Path $targetDir) {
            if ($Resume) {
                if ($DryRun) {
                    Write-Host "  [DRY-RUN] Would keep existing (resume mode): $targetDir" -ForegroundColor Yellow
                } else {
                    Write-Host "  Resume mode: keeping existing directory: $targetDir" -ForegroundColor DarkGray
                }
            } else {
                if ($DryRun) {
                    Write-Host "  [DRY-RUN] Would wipe existing: $targetDir" -ForegroundColor Yellow
                } else {
                    Write-Host "  Cleaning previous run: $targetDir" -ForegroundColor DarkGray
                    Remove-Item -Recurse -Force $targetDir
                }
            }
        }
        New-Item -ItemType Directory -Force -Path $targetDir | Out-Null

        # Isolation: place a minimal CLAUDE.md in rawdog directories as a context
        # fence. Claude Code stops its upward directory walk when it finds a
        # CLAUDE.md, preventing any plugin files in parent directories from
        # bleeding into the plain baseline run.
        if ($mode -eq "rawdog") {
            $fenceContent = @(
                "# codegen-test: rawdog baseline",
                "# This file exists only to prevent context from parent directories",
                "# being loaded into this isolated test run.  Do not add instructions here."
            ) -join "`n"
            Set-Content (Join-Path $targetDir "CLAUDE.md") $fenceContent
        }

        # ---- Build the prompt ----
        if ($mode -eq "rawdog") {
            $prompt = @(
                "Generate a complete, working $langLabel project based on the following PRD.",
                "",
                "Create all necessary source files, configuration files, and folder structure",
                "inside the current working directory.",
                "",
                "Include a README.md with setup and run instructions.",
                "When the project is fully complete, create a file named $FinishedFlagFileName in the",
                "current working directory. Only create this file after all required project files are done.",
                "",
                "PRD:",
                "---",
                $PrdContent,
                "---"
            ) -join "`n"
        } else {
            # securable: install plugin files then embed /secure-generate instructions
            Install-SecurablePlugin -PluginSource $PluginTemp -TargetDir $targetDir

            $prompt = @(
                "You are operating with the securable-claude-plugin active (CLAUDE.md and",
                ".claude/commands/ are present in this directory).",
                "",
                "The following securability engineering instructions are your primary",
                "constraints - treat them as non-negotiable design requirements.",
                "",
                "=== SECURABLE-CLAUDE-PLUGIN INSTRUCTIONS ===",
                $SecureInstructions,
                "=== END PLUGIN INSTRUCTIONS ===",
                "",
                "Now generate a complete, working $langLabel project based on the following PRD,",
                "applying every FIASSE/SSEM constraint above throughout all generated code.",
                "",
                "Create all necessary source files, configuration files, and folder structure",
                "inside the current working directory.",
                "",
                "Include a README.md with:",
                "  - Setup and run instructions",
                "  - A brief SSEM attribute coverage summary describing how each of the nine",
                "    attributes is addressed in the generated code",
                "When the project is fully complete, create a file named $FinishedFlagFileName in the",
                "current working directory. Only create this file after all required project files are done.",
                "",
                "PRD:",
                "---",
                $PrdContent,
                "---"
            ) -join "`n"
        }

        $label = "$langKey / $mode"
        
        # Ensure Claude has write permissions to the target directory (skip in dry-run)
        if (-not $DryRun) {
            Set-ClaudeWritePermissions -TargetDir $targetDir
        }
        
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
