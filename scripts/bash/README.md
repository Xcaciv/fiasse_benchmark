# PRD Codegen Automation Scripts — Linux / bash

Bash automation for iterative prompt testing — generates a project from a PRD specification using two AI coding tools and two security plugin configurations, producing a consistent folder tree for side-by-side comparison.

> **Windows users:** See the sibling [`README.md`](../README.md) for the equivalent PowerShell scripts.

## Overview

Each script takes a single PRD file as input and runs AI-assisted code generation across three target languages and two modes:

| Mode | Description |
|------|-------------|
| `rawdog` | Plain generation — no security plugin active |
| `securable` | Generation with FIASSE/SSEM security constraints applied |

Both scripts produce output under the same six-folder structure:

```
<output-dir>/
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

## The Two Scripts

### 1. `run-codegen-claude.sh`

**Tool:** Claude Code CLI (`claude --print`)
**Plugin:** [`securable-claude-plugin`](https://github.com/Xcaciv/securable-claude-plugin)

Drives Anthropic's Claude Code in non-interactive (`--print`) mode. The prompt for each language and mode combination is written to a temp file and piped via stdin, avoiding shell quoting issues with multi-line strings.

For `securable` runs, the plugin is activated by copying its `CLAUDE.md`, `.claude/`, `skills/`, and `data/` directories into each target folder before invoking Claude. Claude Code reads `CLAUDE.md` automatically from the working directory. The `/secure-generate` command definition is also embedded inline in the prompt, since slash commands are not dispatched in `--print` mode.

**Default output directory:** `./codegen-output`

---

### 2. `run-codegen-copilot-claude-plugin.sh`

**Tool:** GitHub Copilot CLI (`copilot agent run`)
**Plugin:** [`securable-claude-plugin`](https://github.com/Xcaciv/securable-claude-plugin)

Drives GitHub Copilot CLI in non-interactive (`--yes`) mode. Uses the same `securable-claude-plugin` as script 1 — Copilot CLI's skill discovery path explicitly includes `<project>/.claude/skills/` (position 3 in its resolution order), so the plugin layout is natively compatible with both tools without modification.

For `securable` runs, the script copies `.claude/`, `CLAUDE.md`, `skills/`, and `data/` into each target folder before invoking the CLI. The plugin instructions are also embedded inline in the prompt as a belt-and-suspenders fallback for headless mode.

This script is the Linux equivalent of `run-codegen-copilot-claude-plugin.ps1`. Running it alongside `run-codegen-claude.sh` gives a **direct apples-to-apples comparison** between the two AI tools under identical plugin constraints.

**Default output directory:** `./copilot-codegen-output`

---

## Prerequisites

### Both scripts
- **bash 4+** (verify with `bash --version`; macOS ships bash 3 by default — install a newer version via Homebrew: `brew install bash`)
- **Git** on `PATH`
- **`realpath`** — included in GNU coreutils (Linux); on macOS install with `brew install coreutils`
- A PRD file (`.md` or `.txt`) describing the project to generate

### `run-codegen-claude.sh`
- **Claude Code CLI** installed and authenticated:
  ```bash
  npm install -g @anthropic-ai/claude-code
  claude auth login
  ```

### `run-codegen-copilot-claude-plugin.sh`
- **GitHub Copilot CLI** installed and authenticated:
  ```bash
  npm install -g @githubnext/copilot-cli
  copilot auth login
  ```
- An active GitHub Copilot subscription

### Make scripts executable (first-time setup)
```bash
chmod +x run-codegen-claude.sh
chmod +x run-codegen-copilot-claude-plugin.sh
```

---

## Usage

Both scripts share the same flag interface.

### Options

| Flag | Required | Default | Description |
|------|----------|---------|-------------|
| `--prd <file>` | Yes | — | Path to your PRD file |
| `--output-dir <dir>` | No | Script-specific (see above) | Root folder for all generated output |
| `--plugin-repo <url>` | No | Canonical repo URL | Override the plugin git URL (e.g. a fork) |
| `--dry-run` | No | off | Print what would run without calling the AI CLI |
| `-h`, `--help` | No | — | Show usage text |

### Quick start

Always run with `--dry-run` first to verify paths and review the prompts before spending tokens:

```bash
# Verify setup
./run-codegen-claude.sh                --prd ./my-prd.md --dry-run
./run-codegen-copilot-claude-plugin.sh --prd ./my-prd.md --dry-run

# Run for real
./run-codegen-claude.sh                --prd ./my-prd.md
./run-codegen-copilot-claude-plugin.sh --prd ./my-prd.md
```

### Custom output directory

```bash
./run-codegen-claude.sh --prd ./my-prd.md --output-dir ~/projects/codegen-test
```

### Using a plugin fork

```bash
./run-codegen-claude.sh --prd ./my-prd.md \
  --plugin-repo https://github.com/yourorg/securable-claude-plugin.git
```

---

## How Plugin Activation Works

Both scripts use the same plugin and the same file installation strategy. The difference is which CLI reads which file automatically.

### Claude Code — auto-load mechanism

Claude Code reads `CLAUDE.md` from the working directory on startup. The installed layout looks like:

```
securable/
├── CLAUDE.md                    ← auto-read by Claude Code on startup
├── .claude/
│   └── commands/
│       └── secure-generate.md   ← embedded inline in the prompt
├── skills/                      ← SSEM skill definitions
└── data/                        ← FIASSE RFC reference material
```

### Copilot CLI — auto-load mechanism

Copilot CLI discovers `<project>/.claude/skills/` automatically (position 3 in its skill resolution order). `CLAUDE.md` is included as additional project context. The layout installed is identical to the Claude Code case:

```
securable/
├── CLAUDE.md                    ← included as project context
├── .claude/
│   └── commands/
│       └── secure-generate.md   ← embedded inline in the prompt
├── skills/                      ← auto-discovered by Copilot CLI
└── data/                        ← FIASSE reference material
```

Because the installed layout is identical, the only variable between the two scripts' `securable/` outputs is the AI tool itself — making them directly comparable.

---

## Comparing Results

| Comparison | Scripts to run | What it isolates |
|---|---|---|
| Claude Code vs Copilot CLI | Both scripts | AI tool behaviour under identical constraints |
| Baseline vs secured (either tool) | `rawdog/` vs `securable/` within one script's output | Plugin impact on code quality |

A useful starting point is diffing the `README.md` files inside each `securable/` folder — both scripts ask the AI to include an SSEM attribute coverage summary there, giving a quick qualitative signal before examining the code itself.

---

## Troubleshooting

**`bash: declare -A: invalid option` or associative array errors**
Your system bash is version 3 (common on macOS). Install bash 4+ via Homebrew (`brew install bash`) and invoke the scripts explicitly: `bash run-codegen-claude.sh --prd ...`

**`realpath: command not found`**
On macOS, install GNU coreutils: `brew install coreutils`. On Debian/Ubuntu: `sudo apt install coreutils`.

**`copilot agent run --prompt-file` is not recognised**
The `--prompt-file` flag name has changed across Copilot CLI versions. Check your version with `copilot --version` and look up the correct flag with `copilot agent run --help`. Update the `invoke_copilot()` function in the script accordingly.

**`claude: command not found`**
Ensure Claude Code is installed globally: `npm install -g @anthropic-ai/claude-code`. If using a local npm install, add `node_modules/.bin` to your `PATH`.

**`git clone` fails**
Ensure `git` is on your `PATH` and you have network access to GitHub. If behind a proxy: `git config --global http.proxy http://proxy:port`.

**Permission denied when running the script**
Run `chmod +x <script-name>.sh` to make it executable.

**Plugin files not found after clone**
Run with `--dry-run` to confirm the clone target resolves correctly, then inspect the `_plugin_temp/` or `_securable_claude_plugin_temp/` directory inside your output folder to verify the expected layout is present.

---

## References

- [securable-claude-plugin](https://github.com/Xcaciv/securable-claude-plugin) — FIASSE/SSEM plugin for Claude Code (and Copilot CLI)
- [FIASSE RFC](https://github.com/Xcaciv/securable_software_engineering/blob/main/docs/FIASSE-RFC.md) — Framework for Integrating Application Security into Software Engineering
- [Claude Code documentation](https://docs.anthropic.com/en/docs/claude-code)
- [GitHub Copilot CLI documentation](https://docs.github.com/en/copilot/reference/copilot-cli-reference)
