#!/usr/bin/env bash
# =============================================================================
# run-codegen-copilot.sh
#
# Automates GitHub Copilot CLI to generate a project from a PRD in 3 languages,
# each with a "rawdog" (plain) and "securable" (FIASSE plugin) variant.
#
# Uses the securable-copilot plugin (.github/ layout) for the securable runs.
# The plugin provides prompts, agents, and copilot-instructions.md inside
# .github/, which Copilot CLI discovers natively.
#
# Output structure:
#   <output-dir>/
#     aspnet/
#       rawdog/     <- Plain Copilot generation
#       securable/  <- Generation with securable-copilot active
#     jsp/
#       rawdog/
#       securable/
#     node/
#       rawdog/
#       securable/
#
# Usage:
#   ./run-codegen-copilot.sh --prd <file> [--output-dir <dir>] [--plugin-repo <url>] [--dry-run] [--resume]
#   ./run-codegen-copilot.sh --clean [--output-dir <dir>]
#
# Options:
#   --prd          Path to your PRD markdown or text file (required unless --clean)
#   --output-dir   Root folder for generated output (default: ./copilot-codegen-output)
#   --plugin-repo  Git URL of the securable-copilot repo (default: canonical repo)
#   --dry-run      Print what would run without calling Copilot CLI
#   --resume       Skip completed variations and preserve existing directories
#   --clean        Remove cached plugin clone and finished flags, then exit
#   -h, --help     Show this help text
#
# Requirements:
#   - bash 4+, git, copilot (GitHub Copilot CLI), tee, mktemp
#
# Examples:
#   ./run-codegen-copilot.sh --prd ./my-prd.md
#   ./run-codegen-copilot.sh --prd ./my-prd.md --output-dir ~/tests/copilot --dry-run
#   ./run-codegen-copilot.sh --prd ./my-prd.md --resume
#   ./run-codegen-copilot.sh --clean --output-dir ~/tests/copilot
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
PLUGIN_REPO="https://github.com/Xcaciv/securable-copilot.git"
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

    PLUGIN_TEMP="$OUTPUT_DIR/_securable_copilot_temp"
    if [[ -d "$PLUGIN_TEMP" ]]; then
        _yellow "  Removing plugin cache: $PLUGIN_TEMP"
        rm -rf "$PLUGIN_TEMP"
    else
        _gray "  Plugin cache not found (already clean)"
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
# install_plugin  <plugin-source-dir>  <target-dir>
#
# Copies .github/ from the cloned securable-copilot repo into the target
# directory.  The .github/ directory contains prompts/, agents/, and
# copilot-instructions.md that Copilot CLI discovers natively.
# -----------------------------------------------------------------------------
install_plugin() {
    local src="$1"
    local dst="$2"

    if [[ -d "$src/.github" ]]; then
        cp -r "$src/.github" "$dst/"
        _gray "  Installed .github/ -> $dst/.github"
    else
        _yellow "  WARNING: Plugin .github/ directory not found at $src/.github"
    fi
}

# -----------------------------------------------------------------------------
# get_secure_instructions  <plugin-source-dir>
#
# Reads copilot-instructions.md and prompt files from the securable-copilot
# plugin, printing them to stdout for inline embedding in the prompt.
# -----------------------------------------------------------------------------
get_secure_instructions() {
    local src="$1"
    local instr_file="$src/.github/copilot-instructions.md"
    local output=""

    if [[ -f "$instr_file" ]]; then
        output+="$(cat "$instr_file")"$'\n\n'
    fi

    # Also include prompt files for additional context
    for prompt_file in "$src/.github/prompts/input-handling.prompt.md" \
                       "$src/.github/prompts/security-requirements.prompt.md"; do
        if [[ -f "$prompt_file" ]]; then
            local basename
            basename="$(basename "$prompt_file")"
            output+="---"$'\n'"# $basename"$'\n'
            output+="$(cat "$prompt_file")"$'\n\n'
        fi
    done

    if [[ -n "$output" ]]; then
        printf '%s' "$output"
        return
    fi

    # Fallback if plugin files not found
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
# set_copilot_write_permissions  <target-dir>  <allowed-dirs...>
#
# Writes .claude/claude.json with allowed_write_directories so Copilot CLI
# can write to the target directories without interactive prompts.
# -----------------------------------------------------------------------------
set_copilot_write_permissions() {
    local target_dir="$1"
    shift
    local allowed_dirs=("$@")

    local claude_dir="$target_dir/.claude"
    local claude_json="$claude_dir/claude.json"

    mkdir -p "$claude_dir"

    # Build JSON array of allowed directories
    local dirs_json="["
    local first=true
    for dir in "${allowed_dirs[@]}"; do
        if [[ "$first" == true ]]; then
            first=false
        else
            dirs_json+=","
        fi
        dirs_json+="\"$dir\""
    done
    dirs_json+="]"

    cat > "$claude_json" <<EOF
{
  "allowed_write_directories": $dirs_json
}
EOF
}

# -----------------------------------------------------------------------------
# invoke_copilot  <working-dir>  <prompt-file>  <label>
#
# Runs copilot with --allow-tool=write in the given directory.
# Output is tee'd to copilot-output.log.
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
        local copilot_args=(
            "--allow-tool=write"
            "--add-dir" "$working_dir"
            "--allow-all-urls"
            "--no-alt-screen"
        )
        if [[ "$RESUME" == true ]]; then
            copilot_args+=("--resume")
        fi
        copilot_args+=("-p" "$prompt_file")
        copilot "${copilot_args[@]}" 2>&1 | tee "$log_file"
    ) || _yellow "  WARNING: copilot exited non-zero for $label — check $log_file"
}

# =============================================================================
# MAIN
# =============================================================================

_magenta ">>> Starting Copilot CLI codegen run (securable-copilot)"
_gray "  PRD file   : $PRD_FILE"
_gray "  Output dir : $OUTPUT_DIR"
_gray "  Dry run    : $DRY_RUN"
_gray "  Resume     : $RESUME"

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
PLUGIN_TEMP="$OUTPUT_DIR/_securable_copilot_temp"

if [[ -d "$PLUGIN_TEMP" ]]; then
    write_step "Plugin already cloned at $PLUGIN_TEMP — skipping clone"
else
    write_step "Cloning securable-copilot ..."
    if [[ "$DRY_RUN" == true ]]; then
        _yellow "  [DRY-RUN] git clone $PLUGIN_REPO $PLUGIN_TEMP"
        mkdir -p "$PLUGIN_TEMP/.github/prompts"
        mkdir -p "$PLUGIN_TEMP/.github/agents"
        echo "# securable-copilot stub (dry-run)" > "$PLUGIN_TEMP/.github/copilot-instructions.md"
    else
        git clone "$PLUGIN_REPO" "$PLUGIN_TEMP"
    fi
fi

SECURE_INSTRUCTIONS="$(get_secure_instructions "$PLUGIN_TEMP")"

# Collect all target dirs for write permissions
ALL_TARGET_DIRS=()
for lang_key in "${LANG_KEYS[@]}"; do
    for m in rawdog securable; do
        ALL_TARGET_DIRS+=("$OUTPUT_DIR/$lang_key/$m")
    done
done

# ---------------------------------------------------------------------------
# Step 2 — Loop over languages × modes
# ---------------------------------------------------------------------------
PROMPT_TMP="$(mktemp /tmp/copilot_prompt_XXXXXX.txt)"
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

        # NOTE: No CLAUDE.md context fence is needed for rawdog directories here.
        # The securable-copilot plugin uses .github/ layout (not CLAUDE.md), so
        # there is no risk of upward directory context loading from parent dirs.

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
            install_plugin "$PLUGIN_TEMP" "$target_dir"

            cat > "$PROMPT_TMP" <<PROMPT
You are operating with the securable-copilot FIASSE plugin active.
The following securability engineering instructions and prompts are your
primary constraints — treat them as non-negotiable design requirements,
not optional guidelines.

=== SECURABLE-COPILOT PLUGIN INSTRUCTIONS ===
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
When the project is fully complete, create a file named ${FINISHED_FLAG} in the
current working directory. Only create this file after all required project files are done.

PRD:
---
${PRD_CONTENT}
---
PROMPT
        fi

        # Set write permissions
        if [[ "$DRY_RUN" == false ]]; then
            set_copilot_write_permissions "$target_dir" "${ALL_TARGET_DIRS[@]}"
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

if [[ "$DRY_RUN" == true ]]; then
    echo
    _yellow "[DRY-RUN MODE] No Copilot calls were made."
    _yellow "Remove --dry-run to execute for real."
fi
