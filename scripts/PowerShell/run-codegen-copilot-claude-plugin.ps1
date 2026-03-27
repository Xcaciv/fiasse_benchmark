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
        context from files in the working directory.

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

.PARAMETER Modes
    One or more generation modes to run.
        Defaults to both: rawdog,securable
    The script validates all provided modes and fails early if any are unsupported.
        Supported modes:
            - rawdog   : plain generation
            - securable: generation with securable-claude-plugin constraints
            - fiassed  : securable generation plus PRD enhancement via the
                                     prd-fiasse-asvs-enhancement play before prompting

.PARAMETER Clean
    Remove the cached plugin clone and .codegen-finished flags from
    the output directory, then exit.  No generation is performed.
    -PrdFile is not required when -Clean is specified.

.EXAMPLE
    .\run-codegen-copilot-claude-plugin.ps1 -PrdFile .\my-prd.md
    .\run-codegen-copilot-claude-plugin.ps1 -PrdFile .\my-prd.md -OutputDir D:\tests\copilot -DryRun
    .\run-codegen-copilot-claude-plugin.ps1 -PrdFile .\my-prd.md -Modes rawdog
    .\run-codegen-copilot-claude-plugin.ps1 -PrdFile .\my-prd.md -Modes fiassed
    .\run-codegen-copilot-claude-plugin.ps1 -OutputDir D:\tests\copilot -Clean
#>
[CmdletBinding(DefaultParameterSetName = 'Run')]
param(
    [Parameter(Mandatory = $true, ParameterSetName = 'Run')]
    [ValidateScript({ Test-Path $_ -PathType Leaf })]
    [string]$PrdFile,

    [string]$OutputDir = ".\copilot-codegen-output",

    [string]$PluginRepo = "https://github.com/Xcaciv/securable-claude-plugin.git",

    [switch]$DryRun,

    [switch]$Resume,

    [ValidateCount(1, 32)]
    [string[]]$Modes = @("rawdog", "securable", "fiassed"),

    [Parameter(ParameterSetName = 'Clean')]
    [switch]$Clean
)

Import-Module (Join-Path $PSScriptRoot "ExternalAgentTools\ExternalAgentTools.psm1")
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

$ModeDefinitions = [ordered]@{
    "rawdog" = @{
        IsSecurable  = $false
        IsFiassed    = $false
        SummaryLabel = "plain Copilot generation"
    }
    "securable" = @{
        IsSecurable  = $true
        IsFiassed    = $false
        SummaryLabel = "FIASSE/SSEM secured generation"
    }
    "fiassed" = @{
        IsSecurable  = $true
        IsFiassed    = $true
        SummaryLabel = "FIASSE/SSEM secured generation with PRD play enhancement"
    }
}

$SupportedModes = @($ModeDefinitions.Keys)
$NormalizedModes = [System.Collections.Generic.List[string]]::new()
foreach ($modeArg in $Modes) {
    foreach ($candidate in ($modeArg -split ",")) {
        $normalized = $candidate.Trim().ToLowerInvariant()
        if (-not [string]::IsNullOrWhiteSpace($normalized)) {
            $NormalizedModes.Add($normalized)
        }
    }
}

$Modes = @($NormalizedModes | Select-Object -Unique)
if ($Modes.Count -eq 0) {
    throw "At least one mode must be provided via -Modes. Available modes: $($SupportedModes -join ', ')"
}

$InvalidModes = @($Modes | Where-Object { $_ -notin $SupportedModes })
if ($InvalidModes.Count -gt 0) {
    throw "Unsupported mode(s): $($InvalidModes -join ', '). Available modes: $($SupportedModes -join ', ')"
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
        $resolvedAllowedDirs += $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($dir)
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
        Write-Host "  Running in $WorkingDir"
        Write-Host "  using temp prompt file: $promptFile" -ForegroundColor DarkGray
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
                & cmd /c "copilot " @copilotArgs |
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
# Helper: Enhance PRD content using the FIASSE+ASVS play before generation.
#
#   Uses plugin play:
#     plays/requirements-analysis/prd-fiasse-asvs-enhancement.md
#
#   Returns enhanced PRD markdown content. If in -DryRun mode, returns the
#   original PRD unchanged.
# ---------------------------------------------------------------------------
function Get-FiassedPrdContent {
    param(
        [string]$WorkingDir,
        [string]$PluginSource,
        [string]$OriginalPrdContent,
        [string]$Label
    )

    if ($DryRun) {
        Write-Host "  [DRY-RUN] Would enhance PRD via fiassed play for: $Label" -ForegroundColor Yellow
        return $OriginalPrdContent
    }

    $playCandidates = @(
        (Join-Path $PluginSource "plays\requirements-analysis\prd-fiasse-asvs-enhancement.md"),
        (Join-Path $PluginSource "plays\requirements-analysis\prd-fiasse-asvs-enhansement.md")
    )

    $playPath = $playCandidates | Where-Object { Test-Path $_ } | Select-Object -First 1
    if (-not $playPath) {
        throw "fiassed mode requires play file 'prd-fiasse-asvs-enhancement.md'. Expected under plays/requirements-analysis in plugin repo."
    }

    $playContent = Get-Content $playPath -Raw
    $enhancePrompt = @(
        "Run the following play exactly to enhance the provided PRD.",
        "",
        "Output requirements:",
        "- Return ONLY the enhanced PRD markdown",
        "- Do not wrap in code fences",
        "- Do not add explanations before or after",
        "",
        "=== PLAY: prd-fiasse-asvs-enhancement ===",
        $playContent,
        "=== END PLAY ===",
        "",
        "=== INPUT PRD ===",
        $OriginalPrdContent,
        "=== END INPUT PRD ==="
    ) -join "`n"

    $promptFile = Join-Path $env:TEMP "copilot_prd_enhance_$([System.IO.Path]::GetRandomFileName()).txt"
    $enhancedPrdFile = Join-Path $WorkingDir "enhanced-prd.md"
    $enhanceLogFile = Join-Path $WorkingDir "copilot-prd-enhancement.log"

    Write-Step "Enhancing PRD via fiassed play for: $Label" "Green"
    try {
        Set-Content -Path $promptFile -Value $enhancePrompt -Encoding UTF8

        $copilotArgs = @("--allow-all-tools", "--add-dir", $WorkingDir, "--allow-all-urls", "--no-alt-screen", "-p", $promptFile)
        if ($Resume) {
            $copilotArgs += "--resume"
        }

        $previousErrorActionPreference = $ErrorActionPreference
        $ErrorActionPreference = "Continue"
        try {
            $enhanceOutput = & cmd /c "copilot " @copilotArgs 2>&1 |
                Tee-Object -FilePath $enhanceLogFile
        }
        finally {
            $ErrorActionPreference = $previousErrorActionPreference
        }

        if ($LASTEXITCODE -ne 0) {
            throw "Copilot PRD enhancement failed with exit code $LASTEXITCODE for $Label - check $enhanceLogFile"
        }

        $enhancedContent = (($enhanceOutput | Out-String).Trim())
        if ([string]::IsNullOrWhiteSpace($enhancedContent)) {
            throw "Copilot PRD enhancement produced empty output for $Label - check $enhanceLogFile"
        }

        Set-Content -Path $enhancedPrdFile -Value $enhancedContent -Encoding UTF8
        Write-Host "  Enhanced PRD written: $enhancedPrdFile" -ForegroundColor DarkGray
        return $enhancedContent
    }
    finally {
        if (Test-Path $promptFile) { Remove-Item -Force $promptFile }
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

    # Copilot CLI discovers skills at <project>/.claude/skills/ — merge the
    # plugin's top-level skills/ directory into that path so the CLI finds them.
    $skillsSrc = Join-Path $PluginSource "skills"
    if (Test-Path $skillsSrc) {
           $skillsDst = Join-Path (Join-Path $TargetDir ".claude") "skills"
        New-Item -ItemType Directory -Force -Path $skillsDst | Out-Null
        Copy-Item -Recurse -Force (Join-Path $skillsSrc "*") $skillsDst
        Write-Host "  Installed skills/ -> $skillsDst" -ForegroundColor DarkGray
    }
}

# ===========================================================================
# MAIN
# ===========================================================================

$OutputDir = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutputDir)

# ---------------------------------------------------------------------------
# -Clean: remove cached plugin clone and finished flags, then exit
# ---------------------------------------------------------------------------
if ($Clean) {
    Write-Step "Cleaning cache files from $OutputDir" "Magenta"

    $PluginTemp = Join-Path $OutputDir "_securable_claude_plugin_temp"
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

Write-Step "Starting Copilot CLI codegen run (securable-claude-plugin)" "Magenta"
Write-Host "  PRD file   : $PrdFile"
Write-Host "  Output dir : $OutputDir"
Write-Host "  Dry run    : $DryRun"
Write-Host "  Resume     : $Resume"
Write-Host "  Modes      : $($Modes -join ', ')"

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

$AllTargetDirs = @()
foreach ($lang in $Languages.Keys) {
    foreach ($m in $Modes) {
        $AllTargetDirs += (Join-Path $OutputDir "$lang\$m")
    }
}

# ---------------------------------------------------------------------------
# Step 2: Loop over languages x modes
# ---------------------------------------------------------------------------
foreach ($langKey in $Languages.Keys) {
    $langLabel = $Languages[$langKey]

    foreach ($mode in $Modes) {

        $modeConfig = $ModeDefinitions[$mode]

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
        # fence. Both Claude Code and Copilot CLI stop their upward directory walk
        # when they find a CLAUDE.md, preventing plugin files in parent directories
        # from bleeding into the plain baseline run.
        if (-not $modeConfig.IsSecurable) {
            $fenceContent = @(
                "# codegen-test: rawdog baseline",
                "# This file exists only to prevent context from parent directories",
                "# being loaded into this isolated test run.  Do not add instructions here."
            ) -join "`n"
            Set-Content (Join-Path $targetDir "CLAUDE.md") $fenceContent
        }

        $effectivePrdContent = $PrdContent

        # ---- Build the prompt ----
        if (-not $modeConfig.IsSecurable) {
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
                $effectivePrdContent,
                "---"
            ) -join "`n"
        } else {
            # Install plugin files first so Copilot CLI auto-loads them
            Install-SecurableCopilotPlugin -PluginSource $PluginTemp -TargetDir $targetDir

            if ($modeConfig.IsFiassed) {
                # fiassed mode: run the PRD enhancement play after plugin install
                # and before constructing the generation prompt.
                $effectivePrdContent = Get-FiassedPrdContent -WorkingDir $targetDir -PluginSource $PluginTemp -OriginalPrdContent $PrdContent -Label "$langKey / $mode"
            }

            $prompt = @(
                "You are operating inside a project with the securable-claude-plugin installed.",
                "Use the plugin files already present in this working directory as your source of",
                "securability constraints while generating the project.",
                "",
                "Generate a complete, working $langLabel project based on the following PRD,",
                "applying the active plugin's FIASSE/SSEM constraints throughout the generated code.",
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
                $effectivePrdContent,
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
    foreach ($mode in $Modes) {
        $summaryLabel = $ModeDefinitions[$mode].SummaryLabel
        Write-Host "    $mode\  <- $summaryLabel" -ForegroundColor Gray
    }
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
