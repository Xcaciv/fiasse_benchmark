# PRD Codegen Automation Scripts — Linux / bash

Bash automation for iterative prompt testing — generates a project from a PRD specification using multiple AI coding tools and security plugin configurations, producing a consistent folder tree for side-by-side comparison.

> **Windows users:** See the sibling [`README.md`](../README.md) for the equivalent PowerShell scripts.

## Overview

Each script takes a single PRD file as input and runs AI-assisted code generation across three target languages and two modes:

| Mode | Description |
|------|-------------|
| `rawdog` | Plain generation — no security plugin active |
| `securable` | Generation with FIASSE/SSEM security constraints applied |

All scripts produce output under the same six-folder structure:

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

Every folder also contains a log file with the full CLI output for that run. A `.codegen-finished` sentinel file is created by the LLM upon completion of each variation.

---

## The Scripts

### 1. `run-codegen-claude.sh`

**Tool:** Claude Code CLI (`claude --print --permission-mode bypassPermissions`)
**Plugin:** [`securable-claude-plugin`](https://github.com/Xcaciv/securable-claude-plugin)

Drives Anthropic's Claude Code in non-interactive (`--print`) mode. The prompt is written to a temp file and piped via stdin. For `securable` runs, `CLAUDE.md`, `.claude/`, `skills/`, and `data/` are copied into each target folder. The `/secure-generate` command definition is embedded inline in the prompt.

**Default output directory:** `./codegen-output`

---

### 2. `run-codegen-copilot-claude-plugin.sh`

**Tool:** GitHub Copilot CLI (`copilot agent run`)
**Plugin:** [`securable-claude-plugin`](https://github.com/Xcaciv/securable-claude-plugin)

Uses the same plugin as script 1. Copilot CLI's skill discovery path includes `<project>/.claude/skills/`, so the plugin layout is natively compatible. This gives a direct apples-to-apples comparison between Claude Code and Copilot CLI under identical constraints.

**Default output directory:** `./copilot-codegen-output`

---

### 3. `run-codegen-copilot.sh`

**Tool:** GitHub Copilot CLI (`copilot --allow-tool=write`)
**Plugin:** [`securable-copilot`](https://github.com/Xcaciv/securable-copilot)

Uses the `.github/` plugin layout (prompts, agents, `copilot-instructions.md`) that Copilot CLI discovers natively. No `CLAUDE.md` context fence is needed for rawdog directories since the plugin uses `.github/` rather than `CLAUDE.md`.

**Default output directory:** `./copilot-codegen-output`

---

### 4. `run-codegen-opencode.sh`

**Tool:** OpenCode CLI (`opencode run -f <prompt-file>`)
**Plugin:** [`securable-opencode-module`](https://github.com/Xcaciv/securable-opencode-module)

Drives OpenCode in non-interactive (`run`) mode. The module is installed into `.securable/` in each target directory, with an `opencode.json` configuring the MCP server, instructions, and permissions. Three MCP tools are available: `securability_review`, `secure_generate`, `fiasse_lookup`. Context fence uses `AGENTS.md` in rawdog directories.

**Default output directory:** `./opencode-codegen-output`

---

## Prerequisites

### All scripts
- **bash 4+** (verify with `bash --version`; macOS ships bash 3 by default — install via Homebrew: `brew install bash`)
- **Git** on `PATH`
- **`realpath`** — included in GNU coreutils (Linux); on macOS install with `brew install coreutils`
- A PRD file (`.md` or `.txt`) describing the project to generate

### `run-codegen-claude.sh`
- **Claude Code CLI** installed and authenticated:
  ```bash
  npm install -g @anthropic-ai/claude-code
  claude auth login
  ```

### `run-codegen-copilot-claude-plugin.sh` / `run-codegen-copilot.sh`
- **GitHub Copilot CLI** installed and authenticated:
  ```bash
  npm install -g @githubnext/copilot-cli
  copilot auth login
  ```
- An active GitHub Copilot subscription

### `run-codegen-opencode.sh`
- **OpenCode CLI** installed: see [opencode.ai](https://opencode.ai/docs/)
- **Python 3.10+** on `PATH` (required by the MCP server)

### Make scripts executable (first-time setup)
```bash
chmod +x run-codegen-*.sh
```

---

## Usage

All scripts share the same flag interface.

### Options

| Flag | Required | Default | Description |
|------|----------|---------|-------------|
| `--prd <file>` | Yes (unless `--clean`) | — | Path to your PRD file |
| `--output-dir <dir>` | No | Script-specific (see above) | Root folder for all generated output |
| `--plugin-repo <url>` | No | Canonical repo URL | Override the plugin git URL (e.g. a fork) |
| `--dry-run` | No | off | Print what would run without calling the AI CLI |
| `--resume` | No | off | Skip completed variations (where `.codegen-finished` exists) and preserve existing directories |
| `--clean` | No | off | Remove cached plugin clone and all `.codegen-finished` flags, then exit. `--prd` is not required. |
| `-h`, `--help` | No | — | Show usage text |

### Quick start

Always run with `--dry-run` first to verify paths and review the prompts before spending tokens:

```bash
# Verify setup
./run-codegen-claude.sh                --prd ./my-prd.md --dry-run
./run-codegen-copilot-claude-plugin.sh --prd ./my-prd.md --dry-run
./run-codegen-copilot.sh               --prd ./my-prd.md --dry-run
./run-codegen-opencode.sh              --prd ./my-prd.md --dry-run

# Run for real
./run-codegen-claude.sh                --prd ./my-prd.md
./run-codegen-copilot-claude-plugin.sh --prd ./my-prd.md
./run-codegen-copilot.sh               --prd ./my-prd.md
./run-codegen-opencode.sh              --prd ./my-prd.md
```

### Resume an interrupted run

```bash
./run-codegen-claude.sh --prd ./my-prd.md --resume
```

### Clean cached plugin files

```bash
./run-codegen-claude.sh --clean --output-dir ./codegen-output
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

### Claude Code — `CLAUDE.md` + `.claude/` layout

Claude Code reads `CLAUDE.md` from the working directory on startup. The installed layout:

```
securable/
├── CLAUDE.md                    ← auto-read by Claude Code on startup
├── .claude/
│   └── commands/
│       └── secure-generate.md   ← embedded inline in the prompt
├── skills/                      ← SSEM skill definitions
└── data/                        ← FIASSE RFC reference material
```

### Copilot CLI (claude-plugin) — Same layout

Copilot CLI discovers `<project>/.claude/skills/` automatically. The installed layout is identical to Claude Code, making the two directly comparable.

### Copilot CLI (securable-copilot) — `.github/` layout

Uses Copilot-native `.github/` structure:

```
securable/
└── .github/
    ├── copilot-instructions.md  ← auto-read by Copilot CLI
    ├── prompts/                 ← prompt templates
    └── agents/                  ← agent definitions
```

### OpenCode — `.securable/` + `opencode.json` layout

Module is installed into `.securable/`, with `opencode.json` at the project root:

```
securable/
├── opencode.json                ← MCP server config + permissions
└── .securable/
    ├── instructions.md          ← system instructions
    ├── tools/mcp_server.py      ← MCP server (Python 3.10+)
    ├── workflows/               ← review workflow definitions
    ├── data/                    ← FIASSE/ASVS reference data
    └── templates/               ← code generation templates
```

---

## Comparing Results

| Comparison | Scripts to run | What it isolates |
|---|---|---|
| Claude vs Copilot (same plugin) | claude + copilot-claude-plugin | AI tool behaviour under identical constraints |
| Copilot plugin variants | copilot-claude-plugin vs copilot | Plugin layout impact (`.claude/` vs `.github/`) |
| OpenCode vs others | opencode + any other | MCP-based vs file-based plugin activation |
| Baseline vs secured (any tool) | `rawdog/` vs `securable/` within one script | Plugin impact on code quality |

A useful starting point is diffing the `README.md` files inside each `securable/` folder — all scripts ask the AI to include an SSEM attribute coverage summary there.

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

**`opencode: command not found`**
See [opencode.ai/docs](https://opencode.ai/docs/) for installation instructions.

**`git clone` fails**
Ensure `git` is on your `PATH` and you have network access to GitHub. If behind a proxy: `git config --global http.proxy http://proxy:port`.

**Permission denied when running the script**
Run `chmod +x <script-name>.sh` to make it executable.

**Plugin files not found after clone**
Run with `--dry-run` to confirm the clone target resolves correctly, then inspect the plugin temp directory inside your output folder to verify the expected layout.

---

## References

- [securable-claude-plugin](https://github.com/Xcaciv/securable-claude-plugin) — FIASSE/SSEM plugin for Claude Code (and Copilot CLI)
- [securable-copilot](https://github.com/Xcaciv/securable-copilot) — FIASSE/SSEM plugin for Copilot CLI (`.github/` layout)
- [securable-opencode-module](https://github.com/Xcaciv/securable-opencode-module) — FIASSE/SSEM module for OpenCode (MCP-based)
- [FIASSE RFC](https://github.com/Xcaciv/securable_software_engineering/blob/main/docs/FIASSE-RFC.md) — Framework for Integrating Application Security into Software Engineering
- [Claude Code documentation](https://docs.anthropic.com/en/docs/claude-code)
- [GitHub Copilot CLI documentation](https://docs.github.com/en/copilot/reference/copilot-cli-reference)
- [OpenCode documentation](https://opencode.ai/docs/)
