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

.PARAMETER PrdFile
    Path to your PRD markdown or text file. Required.

.PARAMETER OutputDir
    Root folder for all generated output. Defaults to .\copilot-codegen-output

.PARAMETER PluginRepo
    URL of the securable-copilot repo. Defaults to the canonical repo.

.PARAMETER DryRun
    Print the commands that would run without executing Copilot CLI.

.PARAMETER Resume
    Resume a previous run without wiping existing target directories.
    Useful when token windows or rate limits interrupt generation.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateScript({ Test-Path $_ -PathType Leaf })]
    [string]$PrdFile,

    [string]$OutputDir = ".\copilot-codegen-output",

    [string]$PluginRepo = "https://github.com/Xcaciv/securable-copilot.git",

    [switch]$DryRun,

    [switch]$Resume
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$Languages = [ordered]@{
    "aspnet" = "ASP.NET Core (C#) Web API / MVC application"
    "jsp"    = "Java web application using JSP (Java Server Pages) and servlets"
    "node"   = "Node.js web application using Express.js"
}

$FinishedFlagFileName = ".codegen-finished"

function Write-Step([string]$Message, [string]$Color = "Cyan") {
    Write-Host "`n>>> $Message" -ForegroundColor $Color
}

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
        try {
            Set-Content -Path $promptFile -Value $Prompt -Encoding UTF8

            $copilotArgs = @("--allow-tool=write", "--add-dir", $WorkingDir, "--allow-all-urls", "--no-alt-screen")
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

function Install-SecurableCopilotPlugin {
    param(
        [string]$PluginSource,
        [string]$TargetDir
    )

    $srcGithub = Join-Path $PluginSource ".github"
    $dstGithub = Join-Path $TargetDir ".github"

    if (Test-Path $srcGithub) {
        Copy-Item -Recurse -Force $srcGithub $dstGithub
        Write-Host "  Installed .github/ plugin files into: $dstGithub" -ForegroundColor DarkGray
    } else {
        Write-Warning "Plugin .github/ directory not found at $srcGithub - securable mode may not be active."
    }
}

function Get-SecurableInstructions([string]$PluginSource) {
    $parts = [System.Collections.Generic.List[string]]::new()

    $instrFile = Join-Path $PluginSource ".github\copilot-instructions.md"
    if (Test-Path $instrFile) {
        $parts.Add((Get-Content $instrFile -Raw))
    }

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

    return @(
        "Apply FIASSE/SSEM securability engineering principles throughout.",
        "Satisfy all nine SSEM attributes:",
        "  Maintainability: Analyzability, Modifiability, Testability",
        "  Trustworthiness: Confidentiality, Accountability, Authenticity",
        "  Reliability:     Availability, Integrity, Resilience",
        "Apply canonical input handling (Canonicalize -> Sanitize -> Validate) at all",
        "trust boundaries. Enforce the Derived Integrity Principle for business-critical",
        "values. Produce structured audit logging for all accountable actions."
    ) -join "`n"
}

$PrdFile = Resolve-Path $PrdFile | Select-Object -ExpandProperty Path
$OutputDir = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutputDir)

Write-Step "Starting Copilot CLI codegen run" "Magenta"
Write-Host "  PRD file   : $PrdFile"
Write-Host "  Output dir : $OutputDir"
Write-Host "  Dry run    : $DryRun"
Write-Host "  Resume     : $Resume"

Write-Step "Checking prerequisites ..."
if (-not $DryRun) {
    Assert-Tool "copilot"
    Assert-Tool "git"
} else {
    Write-Host "  [DRY-RUN] Skipping tool checks" -ForegroundColor Yellow
}

$PrdContent = Get-Content $PrdFile -Raw
New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null

$PluginTemp = Join-Path $OutputDir "_securable_copilot_temp"
if (Test-Path $PluginTemp) {
    Write-Step "Plugin already cloned at $PluginTemp - skipping clone" "Yellow"
} else {
    Write-Step "Cloning securable-copilot plugin ..."
    if ($DryRun) {
        Write-Host "  [DRY-RUN] git clone $PluginRepo $PluginTemp" -ForegroundColor Yellow
        New-Item -ItemType Directory -Force -Path (Join-Path $PluginTemp ".github\prompts") | Out-Null
        New-Item -ItemType Directory -Force -Path (Join-Path $PluginTemp ".github\agents") | Out-Null
        Set-Content (Join-Path $PluginTemp ".github\copilot-instructions.md") "# securable-copilot stub (dry-run)"
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
            Install-SecurableCopilotPlugin -PluginSource $PluginTemp -TargetDir $targetDir

            $prompt = @(
                "You are operating with the securable-copilot FIASSE plugin active.",
                "The following securability engineering instructions and prompts are your",
                "primary constraints - treat them as non-negotiable design requirements,",
                "not optional guidelines.",
                "",
                "=== SECURABLE-COPILOT PLUGIN INSTRUCTIONS ===",
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

Write-Step "All done!" "Magenta"
Write-Host ""
Write-Host "Generated folder structure:" -ForegroundColor White
foreach ($langKey in $Languages.Keys) {
    Write-Host "  $OutputDir\" -NoNewline -ForegroundColor Gray
    Write-Host "$langKey\" -ForegroundColor Cyan
    Write-Host "    rawdog\     - plain Copilot generation" -ForegroundColor Gray
    Write-Host "    securable\  - FIASSE/SSEM secured generation" -ForegroundColor Gray
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
