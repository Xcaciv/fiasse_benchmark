#Requires -Version 5.1
<#
.SYNOPSIS
    Automates GitHub Copilot CLI to generate a project from a PRD in 3 languages,
    each with a "rawdog" (plain) and "securable" (FIASSE plugin) variant.

.DESCRIPTION
    Mirrors the structure produced by run-codegen-claude.ps1, and uses the
    same plugin - securable-claude-plugin - for both tools. Copilot CLI's skill
    discovery path includes <project>/.claude/skills/, so the plugin's layout is
    natively compatible with both Claude Code and Copilot CLI.

    Produces the following folder structure:
        <OutputDir>/
            aspnet/
                rawdog/     <- Plain Copilot generation
                securable/  <- Generation with securable-claude-plugin active
            jsp/
                rawdog/
                securable/
            node/
                rawdog/
                securable/

    Plugin activation mechanism (securable mode):
        The script clones securable-claude-plugin once, then copies CLAUDE.md,
        .claude/, skills/, and data/ into each securable target directory.
        Copilot CLI auto-discovers .claude/skills/ and reads CLAUDE.md as project
        context. The /secure-generate command definition is also embedded inline
        in the prompt for reliability in headless (--yes) mode.

    Copilot CLI invocation:
        copilot agent run --prompt-file <file> --yes
        (--yes suppresses interactive confirmations; the agent writes files
        directly into the current working directory)

.PARAMETER PrdFile
    Path to your PRD markdown or text file. Required.

.PARAMETER OutputDir
    Root folder for all generated output. Defaults to .\copilot-codegen-output

.PARAMETER PluginRepo
    URL of the securable-claude-plugin repo. Defaults to the canonical repo.
    Copilot CLI honours .claude/skills/ from the project directory (same
    discovery path as Claude Code), so the claude plugin works for both tools.

.PARAMETER DryRun
    Print the commands that would run without executing Copilot CLI.

.PARAMETER Resume
    Resume a previous run without wiping existing target directories.
    Useful when token windows or rate limits interrupt generation.

.EXAMPLE
    .\run-codegen-copilot-claude-plugin.ps1 -PrdFile .\my-prd.md
    .\run-codegen-copilot-claude-plugin.ps1 -PrdFile .\my-prd.md -OutputDir D:\tests\copilot -DryRun
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateScript({ Test-Path $_ -PathType Leaf })]
    [string]$PrdFile,

    [string]$OutputDir = ".\copilot-codegen-output",

    [string]$PluginRepo = "https://github.com/Xcaciv/securable-claude-plugin.git",

    [switch]$DryRun,

    [switch]$Resume
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

$FinishedFlagFileName = ".codegen-finished"

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
        throw "Required tool '$Name' not found on PATH. Please install it and try again."
    }
    Write-Host "  [OK] $Name found: $((Get-Command $Name).Source)" -ForegroundColor DarkGreen
}

function Set-CopilotWritePermissions {
    param(
        [string]$TargetDir,
        [string[]]$AllowedDirs
    )

    $claudeDir = Join-Path $TargetDir ".claude"
    $claudeJsonPath = Join-Path $claudeDir "claude.json"

    New-Item -ItemType Directory -Force -Path $claudeDir | Out-Null

    $resolvedAllowedDirs = @()
    foreach ($dir in $AllowedDirs) {
        $resolvedAllowedDirs += (Resolve-Path $dir | Select-Object -ExpandProperty Path)
    }

    $config = @{
        allowed_write_directories = $resolvedAllowedDirs
    }

    $config | ConvertTo-Json -Depth 5 | Set-Content -Path $claudeJsonPath -Encoding UTF8
}

# ---------------------------------------------------------------------------
# Helper: Run Copilot CLI agent non-interactively in a given directory.
#
#   GitHub Copilot CLI non-interactive invocation:
#     copilot -p "..." --allow-all
#
#   --allow-all suppresses all interactive confirmations. The agent writes files
#   directly into the working directory, so we Push-Location into the
#   target folder first.
#
#   Copilot CLI discovers .claude/skills/ automatically from the current
#   working directory - no extra flags needed.
#
#   If your version of copilot CLI uses a different flag for supplying the
#   prompt, update the copilot invocation line in this function.
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

    Push-Location $WorkingDir
    try {
        # Persist prompt to a temp file and pass the file path via -p.
        $promptFile = Join-Path $env:TEMP "copilot_prompt_$([System.IO.Path]::GetRandomFileName()).txt"
        Write-Host "  Running in $WorkingDir using temp prompt file: $promptFile" -ForegroundColor DarkGray
        try {
            Set-Content -Path $promptFile -Value $Prompt -Encoding UTF8

            $copilotArgs = @("--allow-all-tools", "--add-dir", $WorkingDir, "--allow-all-urls", "--no-alt-screen")
            if ($Resume) {
                $copilotArgs += "--resume"
            }
            $copilotArgs += @("-p", $promptFile)

            $previousErrorActionPreference = $ErrorActionPreference
            $ErrorActionPreference = "Continue"
            try {
                & copilot @copilotArgs 2>&1 |
                    Tee-Object -FilePath $logFile
            }
            finally {
                $ErrorActionPreference = $previousErrorActionPreference
            }

            if ($LASTEXITCODE -ne 0) {
                Write-Warning "copilot -p exited with code $LASTEXITCODE for $Label - check $logFile"
            }
        }
        finally {
            if (Test-Path $promptFile) { Remove-Item -Force $promptFile }
        }
    }
    finally {
        Pop-Location
    }
}

# ---------------------------------------------------------------------------
# Helper: Install the securable-claude-plugin into a target directory.
#   automatically by Copilot CLI too.
#
#   Copied assets:
#     .claude/   - commands and settings (slash-command definitions)
#     CLAUDE.md  - plugin entry point; Copilot CLI reads this as project context
#     skills/    - SSEM skill definitions (auto-discovered by both CLIs)
#     data/      - FIASSE RFC reference sections used by skills
# ---------------------------------------------------------------------------
function Install-SecurableCopilotPlugin {
    param(
        [string]$PluginSource,   # path to the cloned plugin repo
        [string]$TargetDir       # project directory to install into
    )

    $assets = @(
        @{ Src = ".claude";   Dst = ".claude"   }
        @{ Src = "skills";    Dst = "skills"    }
        @{ Src = "data";      Dst = "data"      }
        @{ Src = "CLAUDE.md"; Dst = "CLAUDE.md" }
    )

    foreach ($asset in $assets) {
        $srcPath = Join-Path $PluginSource $asset.Src
        $dstPath = Join-Path $TargetDir   $asset.Dst
        if (Test-Path $srcPath) {
            Copy-Item -Recurse -Force $srcPath $dstPath
            Write-Host "  Installed $($asset.Src) -> $dstPath" -ForegroundColor DarkGray
        }
    }
}

# ---------------------------------------------------------------------------
# Helper: Read plugin instructions from the securable-claude-plugin layout.
#
#   Primary source : CLAUDE.md
#   Slash command  : .claude/commands/secure-generate.md
#                    Embedded verbatim so Copilot CLI gets the full intent
#                    even in headless mode where slash commands are not
#                    dispatched interactively.
# ---------------------------------------------------------------------------
function Get-SecurableInstructions([string]$PluginSource) {
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

    # Fallback if repo layout differs
    return @(
        "Apply FIASSE/SSEM securability engineering principles as hard constraints.",
        "Satisfy all nine SSEM attributes:",
        "  Maintainability: Analyzability, Modifiability, Testability",
        "  Trustworthiness: Confidentiality, Accountability, Authenticity",
        "  Reliability:     Availability, Integrity, Resilience",
        "Apply canonical input handling (Canonicalize -> Sanitize -> Validate) at all",
        "trust boundaries. Enforce the Derived Integrity Principle for business-critical",
        "values. Produce structured audit logging for all accountable actions.",
        "Use the /secure-generate approach from the securable-claude-plugin."
    ) -join "`n"
}

# ===========================================================================
# MAIN
# ===========================================================================

$PrdFile   = Resolve-Path $PrdFile | Select-Object -ExpandProperty Path
$OutputDir = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutputDir)

Write-Step "Starting Copilot CLI codegen run (securable-claude-plugin)" "Magenta"
Write-Host "  PRD file   : $PrdFile"
Write-Host "  Output dir : $OutputDir"
Write-Host "  Dry run    : $DryRun"
Write-Host "  Resume     : $Resume"

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
$PluginTemp = Join-Path $OutputDir "_securable_claude_plugin_temp"

if (Test-Path $PluginTemp) {
    Write-Step "Plugin already cloned at $PluginTemp - skipping clone" "Yellow"
} else {
    Write-Step "Cloning securable-claude-plugin ..."
    if ($DryRun) {
        Write-Host "  [DRY-RUN] git clone $PluginRepo $PluginTemp" -ForegroundColor Yellow
        # Stub structure for dry-run
        New-Item -ItemType Directory -Force -Path (Join-Path $PluginTemp ".claude\commands") | Out-Null
        New-Item -ItemType Directory -Force -Path (Join-Path $PluginTemp "skills") | Out-Null
        New-Item -ItemType Directory -Force -Path (Join-Path $PluginTemp "data")   | Out-Null
        Set-Content (Join-Path $PluginTemp "CLAUDE.md")                            "# securable-claude-plugin stub (dry-run)"
        Set-Content (Join-Path $PluginTemp ".claude\commands\secure-generate.md") "# secure-generate stub (dry-run)"
    } else {
        git clone $PluginRepo $PluginTemp
        if ($LASTEXITCODE -ne 0) { throw "git clone failed" }
    }
}

$SecurableInstructions = Get-SecurableInstructions $PluginTemp

$AllTargetDirs = @()
foreach ($lang in $Languages.Keys) {
    foreach ($m in @("rawdog", "securable")) {
        $AllTargetDirs += (Join-Path $OutputDir "$lang\$m")
    }
}

# ---------------------------------------------------------------------------
# Step 2: Loop over languages x modes
# ---------------------------------------------------------------------------
foreach ($langKey in $Languages.Keys) {
    $langLabel = $Languages[$langKey]

    foreach ($mode in @("rawdog", "securable")) {

        $targetDir = Join-Path $OutputDir "$langKey\$mode"
        $finishedFlagPath = Join-Path $targetDir $FinishedFlagFileName

        if (Test-Path $finishedFlagPath) {
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
        # fence. Both Claude Code and Copilot CLI stop their upward directory walk
        # when they find a CLAUDE.md, preventing plugin files in parent directories
        # from bleeding into the plain baseline run.
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
            # Install plugin files first so Copilot CLI auto-loads them
            Install-SecurableCopilotPlugin -PluginSource $PluginTemp -TargetDir $targetDir

            $prompt = @(
                "You are operating with the securable-claude-plugin active (CLAUDE.md and",
                ".claude/commands/ are present in this directory).",
                "",
                "The following securability engineering instructions are your primary",
                "constraints - treat them as non-negotiable design requirements.",
                "",
                "=== SECURABLE-CLAUDE-PLUGIN INSTRUCTIONS ===",
                $SecurableInstructions,
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

        if (-not $DryRun) {
            Set-CopilotWritePermissions -TargetDir $targetDir -AllowedDirs $AllTargetDirs
        }

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
Write-Host "NOTE: This script targets newer Copilot CLI versions using 'copilot -p'." -ForegroundColor DarkYellow
Write-Host "      If your CLI differs, check 'copilot --help' and adjust" -ForegroundColor DarkYellow
Write-Host "      the Invoke-CopilotAgent function in this script accordingly." -ForegroundColor DarkYellow

if ($DryRun) {
    Write-Host "`n[DRY-RUN MODE] No Copilot calls were made." -ForegroundColor Yellow
    Write-Host "Remove -DryRun to execute for real." -ForegroundColor Yellow
}
