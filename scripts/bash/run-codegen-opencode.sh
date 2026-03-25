#!/usr/bin/env bash
# =============================================================================
# run-codegen-opencode.sh
#
# Automates OpenCode CLI to generate a project from a PRD in 3 languages,
# each with a "rawdog" (plain) and "securable" (FIASSE module) variant.
#
# Uses the securable-opencode-module for the securable runs. The module is
# copied into .securable/ in each target directory, and an opencode.json is
# written at the project root to configure the MCP server and instructions.
# OpenCode discovers the MCP tools and instructions automatically.
#
# OpenCode invocation:
#   opencode run -f <prompt-file>
#   (run mode suppresses the interactive TUI; the agent writes files directly
#   into the current working directory)
#
# Output structure:
#   <output-dir>/
#     aspnet/
#       rawdog/     <- Plain OpenCode generation
#       securable/  <- Generation with securable-opencode-module active
#     jsp/
#       rawdog/
#       securable/
#     node/
#       rawdog/
#       securable/
#
# Usage:
#   ./run-codegen-opencode.sh --prd <file> [--output-dir <dir>] [--plugin-repo <url>] [--dry-run] [--resume]
#   ./run-codegen-opencode.sh --clean [--output-dir <dir>]
#
# Options:
#   --prd          Path to your PRD markdown or text file (required unless --clean)
#   --output-dir   Root folder for generated output (default: ./opencode-codegen-output)
#   --plugin-repo  Git URL of the securable-opencode-module (default: canonical repo)
#   --dry-run      Print what would run without calling OpenCode
#   --resume       Skip completed variations and preserve existing directories
#   --clean        Remove cached module clone and finished flags, then exit
#   -h, --help     Show this help text
#
# Requirements:
#   - bash 4+, git, opencode, python (3.10+ for MCP server), tee, mktemp
#
# Examples:
#   ./run-codegen-opencode.sh --prd ./my-prd.md
#   ./run-codegen-opencode.sh --prd ./my-prd.md --output-dir ~/tests/opencode --dry-run
#   ./run-codegen-opencode.sh --prd ./my-prd.md --resume
#   ./run-codegen-opencode.sh --clean --output-dir ~/tests/opencode
# =============================================================================

set -euo pipefail

# -----------------------------------------------------------------------------
# ANSI colour helpers
# -----------------------------------------------------------------------------
_cyan()    { printf '\033[0;36m%s\033[0m\n' "$*"; }
_green()   { printf '\033[0;32m%s\033[0m\n' "$*"; }
_yellow()  { printf '\033[0;33m%s\033[0m\n' "$*"; }
_magenta() { printf '\033[0;35m%s\033[0m\n' "$*"; }
_gray()    { printf '\033[0;90m%s\033[0m\n' "$*"; }
_red()     { printf '\033[0;31m%s\033[0m\n' "$*" >&2; }

write_step() { echo; _cyan ">>> $*"; }

# -----------------------------------------------------------------------------
# Defaults
# -----------------------------------------------------------------------------
PRD_FILE=""
OUTPUT_DIR="./opencode-codegen-output"
PLUGIN_REPO="https://github.com/Xcaciv/securable-opencode-module.git"
DRY_RUN=false
RESUME=false
CLEAN=false
FINISHED_FLAG=".codegen-finished"

# -----------------------------------------------------------------------------
# Language definitions
# -----------------------------------------------------------------------------
LANG_KEYS=("aspnet" "jsp" "node")
declare -A LANG_LABELS=(
    ["aspnet"]="ASP.NET Core (C#) Web API / MVC application"
    ["jsp"]="Java web application using JSP (Java Server Pages) and servlets"
    ["node"]="Node.js web application using Express.js"
)

# -----------------------------------------------------------------------------
# Usage
# -----------------------------------------------------------------------------
usage() {
    sed -n '/^# Usage:/,/^# =\+$/p' "$0" | grep '^#' | sed 's/^# \?//'
    exit 0
}

# -----------------------------------------------------------------------------
# Argument parsing
# -----------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
    case "$1" in
        --prd)          PRD_FILE="$2";    shift 2 ;;
        --output-dir)   OUTPUT_DIR="$2";  shift 2 ;;
        --plugin-repo)  PLUGIN_REPO="$2"; shift 2 ;;
        --dry-run)      DRY_RUN=true;     shift   ;;
        --resume)       RESUME=true;      shift   ;;
        --clean)        CLEAN=true;       shift   ;;
        -h|--help)      usage ;;
        *) _red "Unknown option: $1"; usage ;;
    esac
done

# -----------------------------------------------------------------------------
# Validation
# -----------------------------------------------------------------------------
OUTPUT_DIR="$(realpath -m "$OUTPUT_DIR")"

# --clean mode: early exit — no PRD required
if [[ "$CLEAN" == true ]]; then
    _magenta ">>> Cleaning cache files from $OUTPUT_DIR"

    PLUGIN_TEMP="$OUTPUT_DIR/_securable_opencode_temp"
    if [[ -d "$PLUGIN_TEMP" ]]; then
        _yellow "  Removing module cache: $PLUGIN_TEMP"
        rm -rf "$PLUGIN_TEMP"
    else
        _gray "  Module cache not found (already clean)"
    fi

    flags_removed=0
    if [[ -d "$OUTPUT_DIR" ]]; then
        while IFS= read -r -d '' flag_file; do
            _yellow "  Removing finished flag: $flag_file"
            rm -f "$flag_file"
            ((flags_removed++))
        done < <(find "$OUTPUT_DIR" -name "$FINISHED_FLAG" -print0 2>/dev/null)
    fi
    _gray "  Removed $flags_removed finished flag(s)."

    _magenta ">>> Clean complete."
    exit 0
fi

if [[ -z "$PRD_FILE" ]]; then
    _red "Error: --prd is required."
    usage
fi

if [[ ! -f "$PRD_FILE" ]]; then
    _red "Error: PRD file not found: $PRD_FILE"
    exit 1
fi

PRD_FILE="$(cd "$(dirname "$PRD_FILE")" && pwd)/$(basename "$PRD_FILE")"

# -----------------------------------------------------------------------------
# Prerequisite check
# -----------------------------------------------------------------------------
assert_tool() {
    local name="$1"
    if ! command -v "$name" &>/dev/null; then
        _red "Error: Required tool '$name' not found on PATH. Please install it."
        exit 1
    fi
    _gray "  [OK] $name -> $(command -v "$name")"
}

# -----------------------------------------------------------------------------
# install_module  <module-source-dir>  <target-dir>
#
# Copies the securable-opencode-module into .securable/ in the target
# directory, and writes an opencode.json at the target root to configure
# the MCP server, instructions, and permissions.
#
# Module layout in target:
#   .securable/instructions.md
#   .securable/tools/mcp_server.py
#   .securable/workflows/
#   .securable/data/fiasse/
#   .securable/data/asvs/
#   .securable/templates/
#   .securable/scripts/
#   opencode.json  (MCP server config + permissions)
# -----------------------------------------------------------------------------
install_module() {
    local src="$1"
    local dst="$2"
    local dst_securable="$dst/.securable"

    mkdir -p "$dst_securable"

    # Copy module directories
    for asset_dir in tools workflows data templates scripts; do
        if [[ -d "$src/$asset_dir" ]]; then
            cp -r "$src/$asset_dir" "$dst_securable/"
            _gray "  Installed $asset_dir/ -> $dst_securable/$asset_dir"
        fi
    done

    # Copy module files
    if [[ -f "$src/instructions.md" ]]; then
        cp "$src/instructions.md" "$dst_securable/instructions.md"
        _gray "  Installed instructions.md -> $dst_securable/instructions.md"
    fi

    # Write opencode.json at target root with MCP server config and permissions
    cat > "$dst/opencode.json" <<'OCJSON'
{
  "$schema": "https://opencode.ai/config.json",
  "mcpServers": {
    "securable": {
      "command": "python",
      "args": ["./.securable/tools/mcp_server.py"],
      "env": {
        "SECURABLE_DATA_DIR": "./.securable/data",
        "SECURABLE_TEMPLATES_DIR": "./.securable/templates",
        "SECURABLE_WORKFLOWS_DIR": "./.securable/workflows"
      }
    }
  },
  "instructions": "./.securable/instructions.md",
  "permission": {
    "edit": "allow",
    "bash": "allow"
  }
}
OCJSON
    _gray "  Wrote opencode.json -> $dst/opencode.json"
}

# -----------------------------------------------------------------------------
# get_secure_instructions  <module-source-dir>
#
# Reads instructions.md and the review workflow from the module, printing them
# to stdout for inline embedding in the prompt.
# -----------------------------------------------------------------------------
get_secure_instructions() {
    local src="$1"
    local instr_file="$src/instructions.md"
    local review_file="$src/workflows/securability-engineering-review.md"
    local output=""

    if [[ -f "$instr_file" ]]; then
        output+="$(cat "$instr_file")"$'\n\n'
    fi

    if [[ -f "$review_file" ]]; then
        output+="---"$'\n'"# Securability Engineering Review Workflow"$'\n'
        output+="$(cat "$review_file")"$'\n'
    fi

    if [[ -n "$output" ]]; then
        printf '%s' "$output"
        return
    fi

    # Fallback if module files not found
    cat <<'FALLBACK'
Apply FIASSE/SSEM securability engineering principles as hard constraints.
Satisfy all nine SSEM attributes:
  Maintainability: Analyzability, Modifiability, Testability
  Trustworthiness: Confidentiality, Accountability, Authenticity
  Reliability:     Availability, Integrity, Resilience
Apply canonical input handling (Canonicalize -> Sanitize -> Validate) at all
trust boundaries. Enforce the Derived Integrity Principle for business-critical
values. Produce structured audit logging for all accountable actions.
FALLBACK
}

# -----------------------------------------------------------------------------
# set_opencode_permissions  <target-dir>
#
# Writes or merges permission config into opencode.json at the target root.
# Also sets the OPENCODE_PERMISSION env var at invocation time (done in
# invoke_opencode).
# -----------------------------------------------------------------------------
set_opencode_permissions() {
    local target_dir="$1"
    local config_path="$target_dir/opencode.json"

    if [[ ! -f "$config_path" ]]; then
        cat > "$config_path" <<'OCJSON'
{
  "$schema": "https://opencode.ai/config.json",
  "permission": {
    "edit": "allow",
    "bash": "allow"
  }
}
OCJSON
    fi
    # If it already exists (e.g. from install_module), permissions are
    # already included in the template. No further action needed.
}

# -----------------------------------------------------------------------------
# invoke_opencode  <working-dir>  <prompt-file>  <label>
#
# Runs `opencode run -f <prompt-file>` in the given directory.
# The run subcommand suppresses the interactive TUI.
# Output is tee'd to opencode-output.log.
#
# Write permissions are granted via:
#   1. OPENCODE_PERMISSION env var (set for the subprocess)
#   2. opencode.json permission config (written by set_opencode_permissions)
# -----------------------------------------------------------------------------
invoke_opencode() {
    local working_dir="$1"
    local prompt_file="$2"
    local label="$3"
    local log_file="$working_dir/opencode-output.log"

    if [[ "$DRY_RUN" == true ]]; then
        _yellow "  [DRY-RUN] Would run in: $working_dir"
        _yellow "  [DRY-RUN] Prompt starts: $(head -c 120 "$prompt_file")..."
        return
    fi

    write_step "Running OpenCode for: $label"
    _gray "  Output dir : $working_dir"
    _gray "  Log file   : $log_file"

    (
        cd "$working_dir"
        # Set permission env var for the subprocess
        export OPENCODE_PERMISSION='{"edit": "allow", "bash": "allow"}'
        opencode run -f "$prompt_file" 2>&1 | tee "$log_file"
    ) || _yellow "  WARNING: opencode run exited non-zero for $label — check $log_file"
}

# =============================================================================
# MAIN
# =============================================================================

_magenta ">>> Starting OpenCode codegen run"
_gray "  PRD file   : $PRD_FILE"
_gray "  Output dir : $OUTPUT_DIR"
_gray "  Dry run    : $DRY_RUN"
_gray "  Resume     : $RESUME"

write_step "Checking prerequisites ..."
if [[ "$DRY_RUN" == false ]]; then
    assert_tool "opencode"
    assert_tool "git"
    assert_tool "python"
else
    _yellow "  [DRY-RUN] Skipping tool checks"
fi

PRD_CONTENT="$(cat "$PRD_FILE")"

mkdir -p "$OUTPUT_DIR"

# ---------------------------------------------------------------------------
# Step 1 — Clone the module once
# ---------------------------------------------------------------------------
PLUGIN_TEMP="$OUTPUT_DIR/_securable_opencode_temp"

if [[ -d "$PLUGIN_TEMP" ]]; then
    write_step "Module already cloned at $PLUGIN_TEMP — skipping clone"
else
    write_step "Cloning securable-opencode-module ..."
    if [[ "$DRY_RUN" == true ]]; then
        _yellow "  [DRY-RUN] git clone $PLUGIN_REPO $PLUGIN_TEMP"
        # Create stub structure for dry-run
        mkdir -p "$PLUGIN_TEMP/tools"
        mkdir -p "$PLUGIN_TEMP/workflows"
        mkdir -p "$PLUGIN_TEMP/data/fiasse"
        mkdir -p "$PLUGIN_TEMP/data/asvs"
        mkdir -p "$PLUGIN_TEMP/templates"
        mkdir -p "$PLUGIN_TEMP/scripts"
        echo "# securable-opencode-module stub (dry-run)" > "$PLUGIN_TEMP/instructions.md"
        echo "{}" > "$PLUGIN_TEMP/opencode.json"
    else
        git clone "$PLUGIN_REPO" "$PLUGIN_TEMP"
    fi
fi

SECURE_INSTRUCTIONS="$(get_secure_instructions "$PLUGIN_TEMP")"

# ---------------------------------------------------------------------------
# Step 2 — Loop over languages × modes
# ---------------------------------------------------------------------------
PROMPT_TMP="$(mktemp /tmp/opencode_prompt_XXXXXX.txt)"
trap 'rm -f "$PROMPT_TMP"' EXIT

for lang_key in "${LANG_KEYS[@]}"; do
    lang_label="${LANG_LABELS[$lang_key]}"

    for mode in rawdog securable; do
        target_dir="$OUTPUT_DIR/$lang_key/$mode"
        finished_flag_path="$target_dir/$FINISHED_FLAG"

        # ------------------------------------------------------------------
        # Resume: skip completed variations
        # ------------------------------------------------------------------
        if [[ "$RESUME" == true ]] && [[ -f "$finished_flag_path" ]]; then
            if [[ "$DRY_RUN" == true ]]; then
                _yellow "  [DRY-RUN] Would skip completed variation: $target_dir"
            else
                _green "  Skipping completed variation: $target_dir"
            fi
            continue
        fi

        # ------------------------------------------------------------------
        # Directory preparation
        # ------------------------------------------------------------------
        if [[ -d "$target_dir" ]]; then
            if [[ "$RESUME" == true ]]; then
                if [[ "$DRY_RUN" == true ]]; then
                    _yellow "  [DRY-RUN] Would keep existing (resume mode): $target_dir"
                else
                    _gray "  Resume mode: keeping existing directory: $target_dir"
                fi
            else
                if [[ "$DRY_RUN" == true ]]; then
                    _yellow "  [DRY-RUN] Would wipe existing: $target_dir"
                else
                    _gray "  Cleaning previous run: $target_dir"
                    rm -rf "$target_dir"
                fi
            fi
        fi
        mkdir -p "$target_dir"

        # ------------------------------------------------------------------
        # Isolation: place a minimal AGENTS.md in rawdog directories as a
        # context fence. OpenCode uses AGENTS.md as the project context file,
        # so placing one here prevents it from walking up the directory tree
        # and loading module files from parent directories.
        # ------------------------------------------------------------------
        if [[ "$mode" == "rawdog" ]]; then
            cat > "$target_dir/AGENTS.md" <<'FENCE'
# codegen-test: rawdog baseline
# This file exists only to prevent context from parent directories
# being loaded into this isolated test run.  Do not add instructions here.
FENCE
        fi

        if [[ "$mode" == "rawdog" ]]; then
            cat > "$PROMPT_TMP" <<PROMPT
Generate a complete, working ${lang_label} project based on the following PRD.

Create all necessary source files, configuration files, and folder structure
inside the current working directory.

Include a README.md with setup and run instructions.
When the project is fully complete, create a file named ${FINISHED_FLAG} in the
current working directory. Only create this file after all required project files are done.

PRD:
---
${PRD_CONTENT}
---
PROMPT

        else
            # Install module files so OpenCode auto-loads MCP server
            install_module "$PLUGIN_TEMP" "$target_dir"

            cat > "$PROMPT_TMP" <<PROMPT
You are operating with the securable-opencode-module active (.securable/ directory
and opencode.json are present in this directory). The MCP tools securability_review,
secure_generate, and fiasse_lookup are available.

The following securability engineering instructions are your primary
constraints — treat them as non-negotiable design requirements.

=== SECURABLE-OPENCODE-MODULE INSTRUCTIONS ===
${SECURE_INSTRUCTIONS}
=== END MODULE INSTRUCTIONS ===

Now generate a complete, working ${lang_label} project based on the following PRD,
applying every FIASSE/SSEM constraint above throughout all generated code.

Create all necessary source files, configuration files, and folder structure
inside the current working directory.

Include a README.md with:
  - Setup and run instructions
  - A brief SSEM attribute coverage summary describing how each of the nine
    attributes is addressed in the generated code
When the project is fully complete, create a file named ${FINISHED_FLAG} in the
current working directory. Only create this file after all required project files are done.

PRD:
---
${PRD_CONTENT}
---
PROMPT
        fi

        # Ensure OpenCode has write permissions
        if [[ "$DRY_RUN" == false ]]; then
            set_opencode_permissions "$target_dir"
        fi

        invoke_opencode "$target_dir" "$PROMPT_TMP" "$lang_key / $mode"
    done
done

# ---------------------------------------------------------------------------
# Step 3 — Summary
# ---------------------------------------------------------------------------
write_step "All done!"
echo
_cyan "Generated folder structure:"
for lang_key in "${LANG_KEYS[@]}"; do
    _cyan "  $OUTPUT_DIR/$lang_key/"
    _gray "    rawdog/     <- plain OpenCode generation"
    _gray "    securable/  <- FIASSE/SSEM secured generation"
done
echo
_gray "Each folder contains an opencode-output.log with the full CLI response."

if [[ "$DRY_RUN" == true ]]; then
    echo
    _yellow "[DRY-RUN MODE] No OpenCode calls were made."
    _yellow "Remove --dry-run to execute for real."
fi
