#!/usr/bin/env bash
# =============================================================================
# build-sops.sh — Regenerate SOP PDFs from knowledge/source/*.md
#
# Developer-only helper. Demo users do NOT need to run this — the resulting
# PDFs are committed to the repo under knowledge/. This script is only used
# when authoring or updating an SOP.
#
# What it does:
#   - Reads every *.md under knowledge/source/ (excluding _template.md).
#   - Renders each to knowledge/<basename>.pdf via pandoc.
#   - Supports two PDF engines:
#       • wkhtmltopdf (default) — HTML/CSS path, no LaTeX needed.
#       • xelatex             — TeX path, prettier output, requires TeX Live.
#
# Prerequisites:
#   - pandoc (https://pandoc.org)
#   - wkhtmltopdf (default) OR a TeX distribution providing xelatex
#
# Missing prerequisites are auto-installed via the platform package manager:
#   - Linux:   apt-get (Debian/Ubuntu), dnf, or yum
#   - macOS:   Homebrew (https://brew.sh must be installed first)
#   - Windows: winget (preferred) or choco
# On Linux the install steps use sudo. If auto-install is undesirable, install
# the tools manually beforehand and the script will skip the install step.
#
# Usage:
#   bash scripts/build-sops.sh                          # build all 36 SOPs
#   bash scripts/build-sops.sh --file Line-A_01_CNC-Lathe_SOP
#   bash scripts/build-sops.sh --engine xelatex
#   bash scripts/build-sops.sh --help
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SOURCE_DIR="$REPO_ROOT/knowledge/source"
OUTPUT_DIR="$REPO_ROOT/knowledge"

ENGINE="wkhtmltopdf"
SINGLE_FILE=""

if [[ -t 1 ]]; then
  GREEN='\033[92m'; YELLOW='\033[93m'; RED='\033[91m'; RESET='\033[0m'
else
  GREEN=''; YELLOW=''; RED=''; RESET=''
fi
ok()   { printf "   ${GREEN}✓${RESET} %s\n" "$*"; }
warn() { printf "   ${YELLOW}!${RESET} %s\n" "$*"; }
err()  { printf "   ${RED}✗${RESET} %s\n" "$*" >&2; }
step() { printf "\n${GREEN}==>${RESET} %s\n" "$*"; }

usage() {
  cat <<'EOF'
Usage: bash scripts/build-sops.sh [options]

Options:
  --file <basename>     Build a single doc. <basename> is the filename without
                        path or extension, e.g. "Line-A_01_CNC-Lathe_SOP".
  --engine <name>       PDF engine. One of: wkhtmltopdf (default), xelatex.
  --help                Show this help.

Examples:
  bash scripts/build-sops.sh
  bash scripts/build-sops.sh --file Line-A_05_CMM-Inspection_Calibration
  bash scripts/build-sops.sh --engine xelatex
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --file)   SINGLE_FILE="$2"; shift 2 ;;
    --engine) ENGINE="$2"; shift 2 ;;
    --help|-h) usage; exit 0 ;;
    *) err "Unknown argument: $1"; usage; exit 1 ;;
  esac
done

# ── Prerequisite checks ───────────────────────────────────────────────────────
step "Checking prerequisites"

# ── Auto-install helpers ──────────────────────────────────────────────────────
detect_os() {
  case "$(uname -s)" in
    Linux*)   echo "linux" ;;
    Darwin*)  echo "macos" ;;
    MINGW*|MSYS*|CYGWIN*) echo "windows" ;;
    *)        echo "unknown" ;;
  esac
}

OS="$(detect_os)"

# Package keys per OS for each tool. Empty string = "no package, point user at site".
declare -A APT_PKG=( [pandoc]="pandoc" [wkhtmltopdf]="wkhtmltopdf" [xelatex]="texlive-xetex" )
declare -A BREW_PKG=( [pandoc]="pandoc" [wkhtmltopdf]="--cask wkhtmltopdf" [xelatex]="--cask mactex-no-gui" )
declare -A WINGET_PKG=( [pandoc]="JohnMacFarlane.Pandoc" [wkhtmltopdf]="wkhtmltopdf.wkhtmltox" [xelatex]="MiKTeX.MiKTeX" )
declare -A CHOCO_PKG=( [pandoc]="pandoc" [wkhtmltopdf]="wkhtmltopdf" [xelatex]="miktex" )

ensure_tool() {
  local tool="$1"
  if command -v "$tool" >/dev/null 2>&1; then
    return 0
  fi
  warn "$tool not found — attempting install on $OS"
  case "$OS" in
    linux)
      if command -v apt-get >/dev/null 2>&1; then
        local pkg="${APT_PKG[$tool]:-}"
        [[ -z "$pkg" ]] && { err "No apt package mapped for $tool"; return 1; }
        sudo apt-get update -y && sudo apt-get install -y $pkg
      elif command -v dnf >/dev/null 2>&1; then
        sudo dnf install -y "$tool"
      elif command -v yum >/dev/null 2>&1; then
        sudo yum install -y "$tool"
      else
        err "No supported package manager (apt/dnf/yum) found."
        return 1
      fi
      ;;
    macos)
      if ! command -v brew >/dev/null 2>&1; then
        err "Homebrew not found. Install from https://brew.sh and re-run."
        return 1
      fi
      local pkg="${BREW_PKG[$tool]:-}"
      [[ -z "$pkg" ]] && { err "No brew package mapped for $tool"; return 1; }
      # shellcheck disable=SC2086
      brew install $pkg
      ;;
    windows)
      if command -v winget >/dev/null 2>&1; then
        local pkg="${WINGET_PKG[$tool]:-}"
        [[ -z "$pkg" ]] && { err "No winget package mapped for $tool"; return 1; }
        winget install --id "$pkg" --silent --accept-package-agreements --accept-source-agreements
      elif command -v choco >/dev/null 2>&1; then
        local pkg="${CHOCO_PKG[$tool]:-}"
        [[ -z "$pkg" ]] && { err "No choco package mapped for $tool"; return 1; }
        choco install -y "$pkg"
      else
        err "Neither winget nor choco available. Install $tool manually."
        return 1
      fi
      # winget/choco install to paths that may not be on the current shell's PATH
      # until a new shell starts. Add the common install dirs so the rest of this
      # run can find the binary.
      case "$tool" in
        pandoc)      export PATH="/c/Program Files/Pandoc:$PATH" ;;
        wkhtmltopdf) export PATH="/c/Program Files/wkhtmltopdf/bin:$PATH" ;;
        xelatex)     export PATH="/c/Program Files/MiKTeX/miktex/bin/x64:/c/Users/$USER/AppData/Local/Programs/MiKTeX/miktex/bin/x64:$PATH" ;;
      esac
      ;;
    *)
      err "Unsupported OS for auto-install. Install $tool manually."
      return 1
      ;;
  esac
  if ! command -v "$tool" >/dev/null 2>&1; then
    err "$tool still not on PATH after install. Open a new shell and re-run, or install manually."
    return 1
  fi
  ok "$tool installed"
}

if ! ensure_tool pandoc; then exit 1; fi
ok "pandoc: $(pandoc --version | head -1)"

case "$ENGINE" in
  wkhtmltopdf)
    if ! ensure_tool wkhtmltopdf; then
      err "Falling back is possible with: --engine xelatex"
      exit 1
    fi
    ok "wkhtmltopdf: $(wkhtmltopdf --version 2>&1 | head -1)"
    ;;
  xelatex)
    if ! ensure_tool xelatex; then exit 1; fi
    ok "xelatex: $(xelatex --version | head -1)"
    ;;
  *)
    err "Unknown engine: $ENGINE (expected wkhtmltopdf or xelatex)"
    exit 1
    ;;
esac

if [[ ! -d "$SOURCE_DIR" ]]; then
  err "Source dir not found: $SOURCE_DIR"
  exit 1
fi

mkdir -p "$OUTPUT_DIR"

# ── Collect target files ──────────────────────────────────────────────────────
declare -a TARGETS
if [[ -n "$SINGLE_FILE" ]]; then
  src="$SOURCE_DIR/${SINGLE_FILE}.md"
  if [[ ! -f "$src" ]]; then
    err "Source file not found: $src"
    exit 1
  fi
  TARGETS=("$src")
else
  while IFS= read -r -d '' f; do
    base="$(basename "$f")"
    [[ "$base" == "_template.md" ]] && continue
    TARGETS+=("$f")
  done < <(find "$SOURCE_DIR" -maxdepth 1 -type f -name '*.md' -print0 | sort -z)
fi

if [[ ${#TARGETS[@]} -eq 0 ]]; then
  warn "No markdown sources matched."
  exit 0
fi

step "Rendering ${#TARGETS[@]} document(s) with engine: $ENGINE"

# ── Render loop ───────────────────────────────────────────────────────────────
fail_count=0
for src in "${TARGETS[@]}"; do
  base="$(basename "$src" .md)"
  out="$OUTPUT_DIR/${base}.pdf"

  args=(
    --from=markdown
    --pdf-engine="$ENGINE"
    --standalone
    --toc
    --toc-depth=2
    --metadata=lang=en
    -o "$out"
    "$src"
  )

  if [[ "$ENGINE" == "wkhtmltopdf" ]]; then
    args+=(
      -V margin-top=18mm
      -V margin-bottom=18mm
      -V margin-left=18mm
      -V margin-right=18mm
    )
  elif [[ "$ENGINE" == "xelatex" ]]; then
    args+=(
      -V geometry:margin=18mm
      -V mainfont="DejaVu Sans"
      -V monofont="DejaVu Sans Mono"
    )
  fi

  if pandoc "${args[@]}" 2>/tmp/build-sops.err; then
    ok "$base.pdf"
  else
    err "$base.pdf  ($(tail -1 /tmp/build-sops.err))"
    fail_count=$((fail_count + 1))
  fi
done

echo
if [[ $fail_count -eq 0 ]]; then
  ok "All ${#TARGETS[@]} document(s) rendered → $OUTPUT_DIR"
else
  err "$fail_count of ${#TARGETS[@]} document(s) failed."
  exit 1
fi
