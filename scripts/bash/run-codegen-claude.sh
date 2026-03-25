#!/usr/bin/env bash
# =============================================================================
# run-codegen-claude.sh
#
# Automates Claude Code CLI to generate a project from a PRD in 3 languages,
# each with a "rawdog" (plain) and "securable" (FIASSE plugin) variant.
#
# Output structure:
#   <output-dir>/
#     aspnet/
#       rawdog/     <- Plain Claude Code generation
#       securable/  <- Generation with securable-claude-plugin active
#     jsp/
#       rawdog/
#       securable/
#     node/
#       rawdog/
#       securable/
#
# Usage:
#   ./run-codegen-claude.sh --prd <file> [--output-dir <dir>] [--plugin-repo <url>] [--dry-run] [--resume]
#   ./run-codegen-claude.sh --clean [--output-dir <dir>]
#
# Options:
#   --prd          Path to your PRD markdown or text file (required unless --clean)
#   --output-dir   Root folder for generated output (default: ./codegen-output)
#   --plugin-repo  Git URL of the securable-claude-plugin (default: canonical repo)
#   --dry-run      Print what would run without calling Claude Code
#   --resume       Skip completed variations and preserve existing directories
#   --clean        Remove cached plugin clone and finished flags, then exit
#   -h, --help     Show this help text
#
# Requirements:
#   - bash 4+, git, claude (Claude Code CLI), tee
#
# Examples:
#   ./run-codegen-claude.sh --prd ./my-prd.md
#   ./run-codegen-claude.sh --prd ./my-prd.md --output-dir ~/projects/codegen --dry-run
#   ./run-codegen-claude.sh --prd ./my-prd.md --resume
#   ./run-codegen-claude.sh --clean --output-dir ~/projects/codegen
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
OUTPUT_DIR="./codegen-output"
PLUGIN_REPO="https://github.com/Xcaciv/securable-claude-plugin.git"
DRY_RUN=false
RESUME=false
CLEAN=false
FINISHED_FLAG=".codegen-finished"

# -----------------------------------------------------------------------------
# Language definitions  (keys and labels kept in parallel arrays for bash 3
# compatibility, though bash 4 associative arrays would also work)
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
# Argument parsing  (manual loop — getopts only handles short flags)
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

    PLUGIN_TEMP="$OUTPUT_DIR/_plugin_temp"
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

# Resolve to absolute path
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
# Copies .claude/, CLAUDE.md, skills/, and data/ from the cloned plugin repo
# into the target directory so Claude Code auto-loads the plugin on startup.
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
# to stdout.  The output is embedded directly in the prompt so the constraints
# are active even in --print (non-interactive) mode.
# -----------------------------------------------------------------------------
get_secure_instructions() {
    local src="$1"
    local cmd_file="$src/.claude/commands/secure-generate.md"
    local claude_md="$src/CLAUDE.md"
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
trust boundaries. Enforce the Derived Integrity Principle for business-critical
values. Produce structured audit logging for all accountable actions.
FALLBACK
}

# -----------------------------------------------------------------------------
# invoke_claude  <working-dir>  <prompt-file>  <label>
#
# Runs `claude --print` in the given directory, piping the prompt from a
# temp file via stdin.  Output is tee'd to claude-output.log.
# -----------------------------------------------------------------------------
invoke_claude() {
    local working_dir="$1"
    local prompt_file="$2"
    local label="$3"
    local log_file="$working_dir/claude-output.log"

    if [[ "$DRY_RUN" == true ]]; then
        _yellow "  [DRY-RUN] Would run in: $working_dir"
        _yellow "  [DRY-RUN] Prompt starts: $(head -c 120 "$prompt_file")..."
        return
    fi

    write_step "Running Claude Code for: $label"
    _gray "  Output dir : $working_dir"
    _gray "  Log file   : $log_file"

    # cd into the target dir so Claude Code picks up CLAUDE.md / .claude/
    # --permission-mode bypassPermissions prevents interactive write approval prompts
    (
        cd "$working_dir"
        claude --print --permission-mode bypassPermissions < "$prompt_file" 2>&1 | tee "$log_file"
    ) || _yellow "  WARNING: claude exited non-zero for $label — check $log_file"
}

# =============================================================================
# MAIN
# =============================================================================

_magenta ">>> Starting Claude Code codegen run"
_gray "  PRD file   : $PRD_FILE"
_gray "  Output dir : $OUTPUT_DIR"
_gray "  Dry run    : $DRY_RUN"
_gray "  Resume     : $RESUME"

write_step "Checking prerequisites ..."
if [[ "$DRY_RUN" == false ]]; then
    assert_tool "claude"
    assert_tool "git"
else
    _yellow "  [DRY-RUN] Skipping tool checks"
fi

# Read PRD content once
PRD_CONTENT="$(cat "$PRD_FILE")"

# Create root output directory
mkdir -p "$OUTPUT_DIR"

# ---------------------------------------------------------------------------
# Step 1 — Clone the plugin once
# ---------------------------------------------------------------------------
PLUGIN_TEMP="$OUTPUT_DIR/_plugin_temp"

if [[ -d "$PLUGIN_TEMP" ]]; then
    write_step "Plugin already cloned at $PLUGIN_TEMP — skipping clone"
else
    write_step "Cloning securable-claude-plugin ..."
    if [[ "$DRY_RUN" == true ]]; then
        _yellow "  [DRY-RUN] git clone $PLUGIN_REPO $PLUGIN_TEMP"
        # Create stub structure so the rest of the script can run in dry-run mode
        mkdir -p "$PLUGIN_TEMP/.claude/commands"
        mkdir -p "$PLUGIN_TEMP/skills"
        mkdir -p "$PLUGIN_TEMP/data"
        echo "# Securable Plugin (dry-run stub)"       > "$PLUGIN_TEMP/CLAUDE.md"
        echo "# secure-generate stub (dry-run)"        > "$PLUGIN_TEMP/.claude/commands/secure-generate.md"
    else
        git clone "$PLUGIN_REPO" "$PLUGIN_TEMP"
    fi
fi

SECURE_INSTRUCTIONS="$(get_secure_instructions "$PLUGIN_TEMP")"

# ---------------------------------------------------------------------------
# Step 2 — Loop over languages × modes
# ---------------------------------------------------------------------------
PROMPT_TMP="$(mktemp /tmp/claude_prompt_XXXXXX.txt)"
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
        # Isolation: install an empty CLAUDE.md into rawdog directories as a
        # context fence.  Claude Code and Copilot CLI both stop their upward
        # directory walk when they find a CLAUDE.md, so this prevents plugin
        # files in any parent directory from bleeding into the plain run.
        # ------------------------------------------------------------------
        if [[ "$mode" == "rawdog" ]]; then
            cat > "$target_dir/CLAUDE.md" <<'FENCE'
# codegen-test: rawdog baseline
# This file exists only to prevent context from parent directories
# being loaded into this isolated test run.  Do not add instructions here.
FENCE
        fi

        if [[ "$mode" == "rawdog" ]]; then
            # Plain prompt — no plugin
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
            # Securable — install plugin files, then embed instructions in prompt
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
When the project is fully complete, create a file named ${FINISHED_FLAG} in the
current working directory. Only create this file after all required project files are done.

PRD:
---
${PRD_CONTENT}
---
PROMPT
        fi

        invoke_claude "$target_dir" "$PROMPT_TMP" "$lang_key / $mode"
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
    _gray "    rawdog/     <- plain generation"
    _gray "    securable/  <- FIASSE/SSEM secured generation"
done
echo
_gray "Each folder contains a claude-output.log with the full Claude response."

if [[ "$DRY_RUN" == true ]]; then
    echo
    _yellow "[DRY-RUN MODE] No Claude calls were made."
    _yellow "Remove --dry-run to execute for real."
fi
