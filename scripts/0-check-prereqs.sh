#!/usr/bin/env bash
# =============================================================================
# 0-check-prereqs.sh — Verify prerequisites for every FabricOEEDemo script
#
# Run this FIRST. It inspects your machine and reports, grouped by setup step,
# which tools/extensions/logins are present and which are missing — with exact
# remediation commands for anything that is not satisfied.
#
# It never changes anything; it only checks and advises. Exit code is non-zero
# only when a CORE prerequisite (needed by the required Fabric provisioner,
# scripts/1-setup-fabric.sh) is missing.
#
# Prerequisite groups:
#   CORE            scripts/1-setup-fabric.sh and every other script
#                     → az (logged in), jq, curl, base64, sed
#   FABRIC IQ       scripts/6-publish-ontology.py, scripts/7-setup-data-agent.py
#                     → python3 (standard library); optional pyodbc + ODBC Driver 18
#                       for 6-publish-ontology.py --check-metrics
#   FOUNDRY/SEARCH  scripts/8-setup-foundry.sh, scripts/9-setup-aisearch.sh
#                     → Azure CLI 2.67+ (Foundry project management), plus
#                       consumption (GlobalStandard) model quota in your region
#   FOUNDRY AGENT   scripts/10-setup-foundry-agent.py, scripts/12-evaluate-agent.py
#                     → python3 + azure-ai-projects (2.x) + azure-identity + openai
#   LOCAL SIM       running the simulator locally with 'dotnet run'
#                     → .NET SDK 10
#   DEV (optional)  scripts/dev-build-sops.sh — regenerate SOP PDFs (committed already)
#                     → pandoc, wkhtmltopdf
#
# Usage:
#   bash scripts/0-check-prereqs.sh
#   bash scripts/0-check-prereqs.sh --help
# =============================================================================
set -uo pipefail

# ── Colours ───────────────────────────────────────────────────────────────────
if [[ -t 1 ]]; then
  GREEN='\033[92m'; YELLOW='\033[93m'; RED='\033[91m'; BOLD='\033[97m'; DIM='\033[90m'; RESET='\033[0m'
else
  GREEN=''; YELLOW=''; RED=''; BOLD=''; DIM=''; RESET=''
fi
pass()  { printf "   ${GREEN}✓${RESET} %s\n" "$*"; }
fail()  { printf "   ${RED}✗${RESET} %s\n" "$*"; }
warn()  { printf "   ${YELLOW}!${RESET} %s\n" "$*"; }
fix()   { printf "       ${DIM}↳ %s${RESET}\n" "$*"; }
group() { printf "\n${BOLD}── %s${RESET}\n" "$*"; }

case "${1:-}" in
  -h|--help)
    sed -n '2,33p' "$0" | sed 's/^# \{0,1\}//'
    exit 0 ;;
esac

# ── Tallies ───────────────────────────────────────────────────────────────────
CORE_MISSING=0      # blocks scripts/1 — causes non-zero exit
FABRIC_IQ_MISSING=0
SIM_MISSING=0

# ── OS detection (for remediation hints) ──────────────────────────────────────
OS="$(uname -s 2>/dev/null || echo unknown)"
case "$OS" in
  Linux*)  PKG_HINT="sudo apt-get install -y" ;;
  Darwin*) PKG_HINT="brew install" ;;
  *)       PKG_HINT="<your package manager> install" ;;
esac

# ── Helpers ───────────────────────────────────────────────────────────────────
# have <cmd> → returns 0 if the command exists on PATH
have() { command -v "$1" >/dev/null 2>&1; }

printf "${BOLD}FabricOEEDemo — prerequisite check${RESET}\n"
printf "${DIM}Detected OS: %s${RESET}\n" "$OS"

# ── CORE ──────────────────────────────────────────────────────────────────────
group "CORE — required by scripts/1-setup-fabric.sh and all others"

if have az; then
  AZ_VER="$(az version --query '"azure-cli"' -o tsv 2>/dev/null || echo '?')"
  pass "Azure CLI present (az $AZ_VER)"
  # Foundry (scripts 4/8) need 2.67+ for --allow-project-management / project subcommands
  if [[ "$AZ_VER" != "?" ]]; then
    if [[ "$(printf '2.67.0\n%s\n' "$AZ_VER" | sort -V | head -n1)" != "2.67.0" ]]; then
      warn "Azure CLI $AZ_VER is older than 2.67.0 — scripts/8-setup-foundry.sh needs 2.67+ (Foundry project management). Core Fabric scripts still work."
      fix "az upgrade   # or reinstall the MSI from https://aka.ms/installazurecliwindows"
    fi
  fi
  if az account show -o none >/dev/null 2>&1; then
    AZ_ACCT="$(az account show --query name -o tsv 2>/dev/null || echo '?')"
    pass "Azure CLI logged in (subscription: $AZ_ACCT)"
  else
    fail "Azure CLI is NOT logged in"
    fix "az login            # add --use-device-code on headless/SSH sessions"
    CORE_MISSING=$((CORE_MISSING + 1))
  fi
else
  fail "Azure CLI (az) not found"
  fix "Install: https://learn.microsoft.com/cli/azure/install-azure-cli"
  CORE_MISSING=$((CORE_MISSING + 1))
fi

if have jq; then
  pass "jq present ($(jq --version 2>/dev/null))"
else
  fail "jq not found"
  fix "$PKG_HINT jq        # Windows: winget install jqlang.jq"
  CORE_MISSING=$((CORE_MISSING + 1))
fi

if have curl; then
  pass "curl present"
else
  fail "curl not found"
  fix "$PKG_HINT curl"
  CORE_MISSING=$((CORE_MISSING + 1))
fi

if have base64; then
  pass "base64 present"
else
  fail "base64 not found (normally part of coreutils)"
  fix "$PKG_HINT coreutils"
  CORE_MISSING=$((CORE_MISSING + 1))
fi

if have sed; then
  pass "sed present"
else
  fail "sed not found"
  fix "$PKG_HINT sed"
  CORE_MISSING=$((CORE_MISSING + 1))
fi

# ── FABRIC IQ (ontology + Data Agent) ─────────────────────────────────────────
group "FABRIC IQ — scripts/6-publish-ontology.py, scripts/7-setup-data-agent.py"

PY=""
if have python3; then PY=python3; elif have python; then PY=python; fi

if [[ -n "$PY" ]]; then
  PY_VER="$($PY -c 'import sys; print(".".join(map(str, sys.version_info[:3])))' 2>/dev/null || echo '?')"
  pass "Python present ($PY $PY_VER)"
  if $PY -c 'import pyodbc, sys; sys.exit(0 if any("ODBC Driver 18" in d for d in pyodbc.drivers()) else 1)' >/dev/null 2>&1; then
    pass "pyodbc + ODBC Driver 18 present (6-publish-ontology.py --check-metrics)"
  else
    warn "pyodbc / ODBC Driver 18 not found (only needed for 6-publish-ontology.py --check-metrics)"
  fi
else
  fail "Python 3 not found"
  fix "$PKG_HINT python3   # Windows: winget install Python.Python.3.12  (need <3.13 for some SDKs)"
  FABRIC_IQ_MISSING=$((FABRIC_IQ_MISSING + 1))
fi

# ── FOUNDRY AGENT (prompt agent automation + evaluation) ──────────────────────
group "FOUNDRY AGENT — scripts/10-setup-foundry-agent.py, scripts/12-evaluate-agent.py"

if [[ -n "$PY" ]]; then
  if $PY -c 'import azure.ai.projects, azure.identity, openai, httpx' >/dev/null 2>&1; then
    pass "azure-ai-projects + azure-identity + openai present"
  else
    warn "azure-ai-projects / azure-identity / openai not installed (needed to script and evaluate the Foundry agent)"
    fix "$PY -m pip install \"azure-ai-projects>=2.2.0\" azure-identity openai httpx"
  fi
else
  warn "Python 3 not found — needed for scripts/10-setup-foundry-agent.py and scripts/12-evaluate-agent.py"
  fix "$PKG_HINT python3"
fi

# ── LOCAL SIMULATOR RUN ───────────────────────────────────────────────────────
group "LOCAL SIM — running the simulator with 'dotnet run'"

if have dotnet; then
  DOTNET_VER="$(dotnet --version 2>/dev/null || echo '?')"
  DOTNET_MAJOR="${DOTNET_VER%%.*}"
  if [[ "$DOTNET_MAJOR" =~ ^[0-9]+$ ]] && (( DOTNET_MAJOR >= 10 )); then
    pass ".NET SDK present ($DOTNET_VER)"
  else
    warn ".NET SDK present ($DOTNET_VER) but the simulator targets .NET 10"
    fix "Install .NET 10 SDK: https://dotnet.microsoft.com/download/dotnet/10.0"
    SIM_MISSING=$((SIM_MISSING + 1))
  fi
else
  warn ".NET SDK (dotnet) not found (needed to build and run the WPF simulator locally on Windows)"
  fix "Install .NET 10 SDK: https://dotnet.microsoft.com/download/dotnet/10.0"
  SIM_MISSING=$((SIM_MISSING + 1))
fi

# ── DEV-ONLY: SOP PDF rebuild ─────────────────────────────────────────────────
group "DEV (optional) — scripts/dev-build-sops.sh (PDFs are already committed)"

if have pandoc; then pass "pandoc present"; else warn "pandoc not found — only needed to regenerate SOP PDFs"; fix "$PKG_HINT pandoc"; fi
if have wkhtmltopdf; then pass "wkhtmltopdf present"; else warn "wkhtmltopdf not found — only needed to regenerate SOP PDFs"; fix "$PKG_HINT wkhtmltopdf"; fi

# ── Summary ───────────────────────────────────────────────────────────────────
W=$(printf '═%.0s' {1..65})
printf "\n${BOLD}%s${RESET}\n"   "$W"
printf "${BOLD}  Summary${RESET}\n"
printf "${BOLD}%s${RESET}\n"     "$W"

status_line() { # <missing-count> <label>
  if (( $1 == 0 )); then printf "  ${GREEN}READY${RESET}    %s\n" "$2"
  else                   printf "  ${YELLOW}ACTION${RESET}   %s (%d item(s) above)\n" "$2" "$1"; fi
}

if (( CORE_MISSING == 0 )); then
  printf "  ${GREEN}READY${RESET}    CORE — you can run scripts/1-setup-fabric.sh\n"
else
  printf "  ${RED}BLOCKED${RESET}  CORE — fix the %d item(s) above before scripts/1-setup-fabric.sh\n" "$CORE_MISSING"
fi
status_line "$FABRIC_IQ_MISSING" "FABRIC IQ — ontology + Data Agent (scripts 6 & 7)"
status_line "$SIM_MISSING"       "LOCAL SIM — dotnet run"
printf "${BOLD}%s${RESET}\n\n"   "$W"

if (( CORE_MISSING > 0 )); then
  printf "${RED}Core prerequisites are missing — resolve them, then re-run this check.${RESET}\n"
  exit 1
fi
printf "${GREEN}Core prerequisites satisfied. Optional groups marked ACTION are only${RESET}\n"
printf "${GREEN}needed for the corresponding feature.${RESET}\n"
exit 0
