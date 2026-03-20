#!/usr/bin/env bash
# =============================================================================
# run-codegen-copilot-claude-plugin.sh
#
# Automates GitHub Copilot CLI to generate a project from a PRD in 3 languages,
# each with a "rawdog" (plain) and "securable" (FIASSE plugin) variant.
#
# Uses the securable-claude-plugin for the securable runs.  Copilot CLI's skill
# discovery path includes <project>/.claude/skills/, so the Claude plugin layout
# is natively compatible with Copilot CLI — no adapter needed.
#
# Output structure:
#   <output-dir>/
#     aspnet/
#       rawdog/     <- Plain Copilot generation
#       securable/  <- Generation with securable-claude-plugin active
#     jsp/
#       rawdog/
#       securable/
#     node/
#       rawdog/
#       securable/
#
# Usage:
#   ./run-codegen-copilot-claude-plugin.sh --prd <file> [--output-dir <dir>] [--plugin-repo <url>] [--dry-run]
#
# Options:
#   --prd          Path to your PRD markdown or text file (required)
#   --output-dir   Root folder for generated output (default: ./copilot-codegen-output)
#   --plugin-repo  Git URL of the securable-claude-plugin (default: canonical repo)
#   --dry-run      Print what would run without calling Copilot CLI
#   -h, --help     Show this help text
#
# Requirements:
#   - bash 4+, git, copilot (GitHub Copilot CLI), tee, mktemp
#
# Examples:
#   ./run-codegen-copilot-claude-plugin.sh --prd ./my-prd.md
#   ./run-codegen-copilot-claude-plugin.sh --prd ./my-prd.md --output-dir ~/tests/copilot --dry-run
#
# NOTE — Copilot CLI flag compatibility:
#   This script uses `copilot agent run --prompt-file <file> --yes`.
#   If your version of the CLI uses a different flag name, update the
#   invoke_copilot() function below.  Check with `copilot agent run --help`.
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
OUTPUT_DIR="./copilot-codegen-output"
PLUGIN_REPO="https://github.com/Xcaciv/securable-claude-plugin.git"
DRY_RUN=false

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
        -h|--help)      usage ;;
        *) _red "Unknown option: $1"; usage ;;
    esac
done

# -----------------------------------------------------------------------------
# Validation
# -----------------------------------------------------------------------------
if [[ -z "$PRD_FILE" ]]; then
    _red "Error: --prd is required."
    usage
fi

if [[ ! -f "$PRD_FILE" ]]; then
    _red "Error: PRD file not found: $PRD_FILE"
    exit 1
fi

PRD_FILE="$(cd "$(dirname "$PRD_FILE")" && pwd)/$(basename "$PRD_FILE")"
OUTPUT_DIR="$(realpath -m "$OUTPUT_DIR")"

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
# install_plugin  <plugin-source-dir>  <target-dir>
#
# Copies .claude/, CLAUDE.md, skills/, and data/ into the target directory.
# Copilot CLI's skill discovery includes <project>/.claude/skills/ (position 3
# in its resolution order), making this plugin layout natively compatible.
# -----------------------------------------------------------------------------
install_plugin() {
    local src="$1"
    local dst="$2"

    for asset in ".claude" "skills" "data"; do
        if [[ -d "$src/$asset" ]]; then
            cp -r "$src/$asset" "$dst/"
            _gray "  Installed $asset/ -> $dst/$asset"
        fi
    done

    if [[ -f "$src/CLAUDE.md" ]]; then
        cp "$src/CLAUDE.md" "$dst/CLAUDE.md"
        _gray "  Installed CLAUDE.md -> $dst/CLAUDE.md"
    fi
}

# -----------------------------------------------------------------------------
# get_secure_instructions  <plugin-source-dir>
#
# Reads CLAUDE.md and the /secure-generate command definition, printing them
# to stdout for inline embedding in the prompt.  Belt-and-suspenders: ensures
# the constraints are present even in headless (--yes) mode where the CLI may
# not auto-load project context files.
# -----------------------------------------------------------------------------
get_secure_instructions() {
    local src="$1"
    local claude_md="$src/CLAUDE.md"
    local cmd_file="$src/.claude/commands/secure-generate.md"
    local output=""

    if [[ -f "$claude_md" ]]; then
        output+="$(cat "$claude_md")"$'\n\n'
    fi

    if [[ -f "$cmd_file" ]]; then
        output+="---"$'\n'"# /secure-generate command definition"$'\n'
        output+="$(cat "$cmd_file")"$'\n'
    fi

    if [[ -n "$output" ]]; then
        printf '%s' "$output"
        return
    fi

    # Fallback if repo layout differs
    cat <<'FALLBACK'
Apply FIASSE/SSEM securability engineering principles as hard constraints.
Satisfy all nine SSEM attributes:
  Maintainability: Analyzability, Modifiability, Testability
  Trustworthiness: Confidentiality, Accountability, Authenticity
  Reliability:     Availability, Integrity, Resilience
Apply canonical input handling (Canonicalize -> Sanitize -> Validate) at all
trust boundaries.  Enforce the Derived Integrity Principle for business-critical
values.  Produce structured audit logging for all accountable actions.
Use the /secure-generate approach from the securable-claude-plugin.
FALLBACK
}

# -----------------------------------------------------------------------------
# invoke_copilot  <working-dir>  <prompt-file>  <label>
#
# Runs `copilot agent run --prompt-file <file> --yes` in the given directory.
# The agent writes generated files directly into the working directory.
# Output is tee'd to copilot-output.log.
#
# If your version of the Copilot CLI uses a different flag for supplying the
# prompt, update the copilot invocation line below.
# -----------------------------------------------------------------------------
invoke_copilot() {
    local working_dir="$1"
    local prompt_file="$2"
    local label="$3"
    local log_file="$working_dir/copilot-output.log"

    if [[ "$DRY_RUN" == true ]]; then
        _yellow "  [DRY-RUN] Would run in: $working_dir"
        _yellow "  [DRY-RUN] Prompt starts: $(head -c 120 "$prompt_file")..."
        return
    fi

    write_step "Running Copilot CLI for: $label"
    _gray "  Output dir : $working_dir"
    _gray "  Log file   : $log_file"

    (
        cd "$working_dir"
        copilot agent run --prompt-file "$prompt_file" --yes 2>&1 | tee "$log_file"
    ) || _yellow "  WARNING: copilot agent run exited non-zero for $label — check $log_file"
}

# =============================================================================
# MAIN
# =============================================================================

_magenta ">>> Starting Copilot CLI codegen run (securable-claude-plugin)"
_gray "  PRD file   : $PRD_FILE"
_gray "  Output dir : $OUTPUT_DIR"
_gray "  Dry run    : $DRY_RUN"

write_step "Checking prerequisites ..."
if [[ "$DRY_RUN" == false ]]; then
    assert_tool "copilot"
    assert_tool "git"
else
    _yellow "  [DRY-RUN] Skipping tool checks"
fi

PRD_CONTENT="$(cat "$PRD_FILE")"

mkdir -p "$OUTPUT_DIR"

# ---------------------------------------------------------------------------
# Step 1 — Clone the plugin once
# ---------------------------------------------------------------------------
PLUGIN_TEMP="$OUTPUT_DIR/_securable_claude_plugin_temp"

if [[ -d "$PLUGIN_TEMP" ]]; then
    write_step "Plugin already cloned at $PLUGIN_TEMP — skipping clone"
else
    write_step "Cloning securable-claude-plugin ..."
    if [[ "$DRY_RUN" == true ]]; then
        _yellow "  [DRY-RUN] git clone $PLUGIN_REPO $PLUGIN_TEMP"
        mkdir -p "$PLUGIN_TEMP/.claude/commands"
        mkdir -p "$PLUGIN_TEMP/skills"
        mkdir -p "$PLUGIN_TEMP/data"
        echo "# securable-claude-plugin stub (dry-run)"    > "$PLUGIN_TEMP/CLAUDE.md"
        echo "# secure-generate stub (dry-run)"            > "$PLUGIN_TEMP/.claude/commands/secure-generate.md"
    else
        git clone "$PLUGIN_REPO" "$PLUGIN_TEMP"
    fi
fi

SECURE_INSTRUCTIONS="$(get_secure_instructions "$PLUGIN_TEMP")"

# ---------------------------------------------------------------------------
# Step 2 — Loop over languages × modes
# ---------------------------------------------------------------------------
PROMPT_TMP="$(mktemp /tmp/copilot_prompt_XXXXXX.txt)"
trap 'rm -f "$PROMPT_TMP"' EXIT

for lang_key in "${LANG_KEYS[@]}"; do
    lang_label="${LANG_LABELS[$lang_key]}"

    for mode in rawdog securable; do
        target_dir="$OUTPUT_DIR/$lang_key/$mode"
        mkdir -p "$target_dir"

        if [[ "$mode" == "rawdog" ]]; then
            cat > "$PROMPT_TMP" <<PROMPT
Generate a complete, working ${lang_label} project based on the following PRD.

Create all necessary source files, configuration files, and folder structure
inside the current working directory.

Include a README.md with setup and run instructions.

PRD:
---
${PRD_CONTENT}
---
PROMPT

        else
            install_plugin "$PLUGIN_TEMP" "$target_dir"

            cat > "$PROMPT_TMP" <<PROMPT
You are operating with the securable-claude-plugin active (CLAUDE.md and
.claude/commands/ are present in this directory).

The following securability engineering instructions are your primary
constraints — treat them as non-negotiable design requirements.

=== SECURABLE-CLAUDE-PLUGIN INSTRUCTIONS ===
${SECURE_INSTRUCTIONS}
=== END PLUGIN INSTRUCTIONS ===

Now generate a complete, working ${lang_label} project based on the following PRD,
applying every FIASSE/SSEM constraint above throughout all generated code.

Create all necessary source files, configuration files, and folder structure
inside the current working directory.

Include a README.md with:
  - Setup and run instructions
  - A brief SSEM attribute coverage summary describing how each of the nine
    attributes is addressed in the generated code

PRD:
---
${PRD_CONTENT}
---
PROMPT
        fi

        invoke_copilot "$target_dir" "$PROMPT_TMP" "$lang_key / $mode"
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
    _gray "    rawdog/     <- plain Copilot generation"
    _gray "    securable/  <- FIASSE/SSEM secured generation"
done
echo
_gray "Each folder contains a copilot-output.log with the full CLI response."
echo
_yellow "NOTE: If 'copilot agent run --prompt-file' is not recognised by your"
_yellow "      version of the CLI, check 'copilot agent run --help' and update"
_yellow "      the invoke_copilot() function in this script accordingly."

if [[ "$DRY_RUN" == true ]]; then
    echo
    _yellow "[DRY-RUN MODE] No Copilot calls were made."
    _yellow "Remove --dry-run to execute for real."
fi
