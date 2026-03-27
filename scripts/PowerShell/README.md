# PRD Codegen Automation Scripts

PowerShell automation for iterative prompt testing — generates a project from a PRD specification using three different AI coding tools and two security plugin configurations, producing a consistent folder tree for side-by-side comparison.

## Overview

Each script takes a single PRD file as input and runs AI-assisted code generation across three target languages and two modes:

| Mode | Description |
|------|-------------|
| `rawdog` | Plain generation — no security plugin active |
| `securable` | Generation with a FIASSE/SSEM security plugin applied |

Each script produces output under six folders:

```
<OutputDir>/
├── aspnet/
│   ├── rawdog/       ← ASP.NET Core (C#), plain generation
│   └── securable/    ← ASP.NET Core (C#), plugin-constrained generation
├── jsp/
│   ├── rawdog/       ← Java JSP/Servlets, plain generation
│   └── securable/    ← Java JSP/Servlets, plugin-constrained generation
└── node/
    ├── rawdog/       ← Node.js / Express, plain generation
    └── securable/    ← Node.js / Express, plugin-constrained generation
```

Every folder also contains a log file (`claude-output.log` or `copilot-output.log`) with the full CLI output for that run.

---

## The Three Scripts

### 1. `run-codegen-claude.ps1`

**Tool:** Claude Code CLI (`claude --print`)  
**Plugin:** [`securable-claude-plugin`](https://github.com/Xcaciv/securable-claude-plugin)

Drives Anthropic's Claude Code in non-interactive (`--print`) mode. The PRD prompt is piped via stdin for each language and mode combination.

For `securable` runs, the plugin is activated by copying its `CLAUDE.md`, `.claude/`, `skills/`, and `data/` directories into each target folder. Claude Code then reads the installed plugin files directly from the working directory during the run.

**Default output directory:** `.\codegen-output`

---

### 2. `run-codegen-copilot.ps1`

**Tool:** GitHub Copilot CLI (`copilot agent run`)  
**Plugin:** [`securable-copilot`](https://github.com/Xcaciv/securable-copilot)

Drives GitHub Copilot CLI in non-interactive (`--yes`) mode. Uses Copilot's native plugin mechanism: when `.github/copilot-instructions.md` is present in the working directory, Copilot automatically applies those instructions to every interaction.

For `securable` runs, the script copies the plugin's `.github/` directory (containing `copilot-instructions.md`, `prompts/`, and `agents/`) into each target folder before invoking the CLI. The instructions are also embedded inline in the prompt as a fallback for headless mode.

**Default output directory:** `.\copilot-codegen-output`

---

### 3. `run-codegen-copilot-claude-plugin.ps1`

**Tool:** GitHub Copilot CLI (`copilot agent run`)  
**Plugin:** [`securable-claude-plugin`](https://github.com/Xcaciv/securable-claude-plugin)

Same Copilot CLI invocation as script 2, but uses the Claude Code plugin instead of the Copilot-native one. This is valid because Copilot CLI's skill discovery order explicitly includes `<project>/.claude/skills/` as a recognized path, making the plugin's layout compatible with both tools without modification.

This script is most useful for **direct apples-to-apples comparison** between Claude Code and Copilot CLI: both tools receive identical plugin constraints, so any differences in the generated output are attributable to the AI tool rather than the plugin.

**Default output directory:** `.\copilot-codegen-output`

---

## Prerequisites

### All scripts
- **PowerShell 5.1+** (included in Windows 10/11; verify with `$PSVersionTable.PSVersion`)
- **Git** on `PATH` (for cloning the plugin repos)
- A PRD file (`.md` or `.txt`) describing the project to generate

### `run-codegen-claude.ps1`
- **Claude Code CLI** installed and authenticated
  ```
  npm install -g @anthropic-ai/claude-code
  claude auth login
  ```

### `run-codegen-copilot.ps1` and `run-codegen-copilot-claude-plugin.ps1`
- **GitHub Copilot CLI** installed and authenticated
  ```
  npm install -g @githubnext/copilot-cli
  copilot auth login
  ```
- An active GitHub Copilot subscription

### PowerShell execution policy (first-time setup)
If scripts are blocked, run once in an elevated terminal:
```powershell
Set-ExecutionPolicy -Scope CurrentUser RemoteSigned
```

---

## Usage

All three scripts share the same parameter interface.

### Parameters

| Parameter | Required | Default | Description |
|-----------|----------|---------|-------------|
| `-PrdFile` | Yes | — | Path to your PRD file |
| `-OutputDir` | No | Script-specific (see above) | Root folder for all generated output |
| `-PluginRepo` | No | Canonical repo URL | Override the plugin git URL (e.g. a fork) |
| `-DryRun` | No | `$false` | Print what would run without calling the AI CLI |

### Quick start

Always run with `-DryRun` first to verify paths and review the prompts before spending tokens:

```powershell
# Verify setup
.\run-codegen-claude.ps1               -PrdFile .\my-prd.md -DryRun
.\run-codegen-copilot.ps1              -PrdFile .\my-prd.md -DryRun
.\run-codegen-copilot-claude-plugin.ps1 -PrdFile .\my-prd.md -DryRun

# Run for real
.\run-codegen-claude.ps1               -PrdFile .\my-prd.md
.\run-codegen-copilot.ps1              -PrdFile .\my-prd.md
.\run-codegen-copilot-claude-plugin.ps1 -PrdFile .\my-prd.md
```

### Custom output directory

```powershell
.\run-codegen-claude.ps1 -PrdFile .\my-prd.md -OutputDir C:\Projects\codegen-test
```

### Using a plugin fork

```powershell
.\run-codegen-claude.ps1 -PrdFile .\my-prd.md -PluginRepo https://github.com/yourorg/securable-claude-plugin.git
```

---

## How Plugin Activation Works

Understanding how each script activates its plugin explains what the generated output reflects.

### Claude Code — `securable-claude-plugin`

Claude Code reads `CLAUDE.md` from the working directory automatically on startup. The script copies the full plugin tree into each `securable/` target directory before invoking `claude --print`, so the active plugin constraints come from the installed files rather than duplicated inline prompt content.

```
securable/
├── CLAUDE.md                   ← auto-read by Claude Code
├── .claude/
│   └── commands/
│       └── secure-generate.md
├── skills/                     ← SSEM skill definitions
└── data/                       ← FIASSE RFC reference material
```

### Copilot CLI — `securable-copilot`

Copilot CLI reads `.github/copilot-instructions.md` from the working directory automatically. The script copies the plugin's `.github/` folder into each `securable/` target directory. The instructions are also embedded inline in the prompt as a belt-and-suspenders fallback.

```
securable/
└── .github/
    ├── copilot-instructions.md  ← auto-read by Copilot CLI
    ├── prompts/                 ← reusable skill prompts
    └── agents/                  ← Securable Engineer / AppSec Partner personas
```

### Copilot CLI — `securable-claude-plugin`

Copilot CLI's skill discovery path includes `<project>/.claude/skills/` (position 3 in its resolution order). The script copies the Claude plugin's layout unchanged — no adapter needed. `CLAUDE.md` is included as additional project context, and the `/secure-generate` definition is embedded in the prompt.

```
securable/
├── CLAUDE.md                   ← included as project context
├── .claude/
│   └── commands/
│       └── secure-generate.md  ← embedded inline in the prompt
├── skills/                     ← auto-discovered by Copilot CLI
└── data/                       ← FIASSE reference material
```

---

## Comparing Results

The folder structure is intentionally uniform across all three scripts so outputs can be diffed directly.

| Comparison | Scripts to run | What it isolates |
|---|---|---|
| Claude Code vs Copilot CLI (same plugin) | `run-codegen-claude.ps1` + `run-codegen-copilot-claude-plugin.ps1` | AI tool differences |
| Copilot native plugin vs Claude plugin | `run-codegen-copilot.ps1` + `run-codegen-copilot-claude-plugin.ps1` | Plugin/instruction differences |
| Baseline vs secured (any tool) | `rawdog/` vs `securable/` within any script's output | Plugin impact on code quality |
| All three tools, same language | All three scripts, same language subfolder | Full matrix comparison |

A useful starting point is to diff the `README.md` files generated inside each `securable/` folder — scripts that are working correctly will ask the AI to include an SSEM attribute coverage summary there, giving a quick qualitative signal before diving into the code itself.

---

## Troubleshooting

**`copilot agent run --prompt-file` is not recognized**  
The `--prompt-file` flag name has changed across Copilot CLI versions. Check your version with `copilot --version` and look up the equivalent flag (`--message`, `--input`, or piped stdin). Update the `Invoke-CopilotAgent` function in the script accordingly.

**`claude` is not recognized as a command**  
Ensure Claude Code is installed globally: `npm install -g @anthropic-ai/claude-code`. If using a local install, add the `node_modules/.bin` directory to your `PATH`.

**`git clone` fails**  
Ensure `git` is on your `PATH` and you have network access to GitHub. If you're behind a proxy, configure it with `git config --global http.proxy`.

**Script is blocked by execution policy**  
Run `Set-ExecutionPolicy -Scope CurrentUser RemoteSigned` in an elevated PowerShell window.

**Plugin files not found after clone**  
The plugin repos may have been restructured. Run with `-DryRun` first to confirm the clone path resolves correctly, then inspect `_plugin_temp/` manually to verify the expected file layout is present.

---

## References

- [securable-claude-plugin](https://github.com/Xcaciv/securable-claude-plugin) — FIASSE/SSEM plugin for Claude Code (and Copilot CLI)
- [securable-copilot](https://github.com/Xcaciv/securable-copilot) — FIASSE/SSEM plugin for GitHub Copilot
- [FIASSE RFC](https://github.com/Xcaciv/securable_software_engineering/blob/main/docs/FIASSE-RFC.md) — Framework for Integrating Application Security into Software Engineering
- [Claude Code documentation](https://docs.anthropic.com/en/docs/claude-code)
- [GitHub Copilot CLI documentation](https://docs.github.com/en/copilot/reference/copilot-cli-reference)
