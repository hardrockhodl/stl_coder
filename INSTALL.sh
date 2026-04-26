#!/usr/bin/env bash
# Sets up the backend (Python venv + CadQuery + FastAPI) and the frontend (npm),
# and verifies that Ollama and qwen2.5-coder:32b-instruct-q4_K_S are available.
#
# Requires: bash, a compatible Python (3.10–3.12), and Node 20+.
# CadQuery does not have wheels for Python 3.13/3.14 on PyPI (as of 2026-04),
# so the script auto-detects a supported Python version.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BACKEND="$ROOT/backend"
FRONTEND="$ROOT/frontend"
VENV="$BACKEND/.venv"

# Colors if the terminal supports them
if [[ -t 1 ]]; then
  C_GREEN=$'\033[0;32m'; C_YELLOW=$'\033[0;33m'; C_RED=$'\033[0;31m'
  C_BLUE=$'\033[0;34m'; C_RESET=$'\033[0m'
else
  C_GREEN=""; C_YELLOW=""; C_RED=""; C_BLUE=""; C_RESET=""
fi

step()  { echo "${C_BLUE}==>${C_RESET} $*"; }
ok()    { echo "${C_GREEN}OK${C_RESET}  $*"; }
warn()  { echo "${C_YELLOW}!!${C_RESET}  $*"; }
fail()  { echo "${C_RED}xx${C_RESET}  $*"; exit 1; }

# ─────────────────────────────────────────────────────────────────────────────
# 1. Find a CadQuery-compatible Python (3.10, 3.11, or 3.12)
# ─────────────────────────────────────────────────────────────────────────────
step "Looking for a CadQuery-compatible Python (3.10–3.12)"

PYTHON=""
for candidate in python3.11 python3.12 python3.10; do
  if command -v "$candidate" >/dev/null 2>&1; then
    PYTHON="$(command -v "$candidate")"
    break
  fi
done

if [[ -z "$PYTHON" ]]; then
  cat <<EOF
${C_RED}No Python 3.10/3.11/3.12 found.${C_RESET}

CadQuery distributes wheels for 3.10–3.12 on PyPI. Your 'python3' is probably
too new (3.13/3.14) and lacks wheels.

Install python@3.11 via Homebrew:
    brew install python@3.11

Or use conda/mamba instead:
    mamba create -n stlgen python=3.11 -c conda-forge -y
    mamba activate stlgen
    mamba install -c conda-forge cadquery -y
    pip install -r backend/requirements.txt
EOF
  exit 1
fi
ok "Using $PYTHON ($($PYTHON --version))"

# ─────────────────────────────────────────────────────────────────────────────
# 2. Create / update venv (rebuild if version doesn't match)
# ─────────────────────────────────────────────────────────────────────────────
WANT_VER="$("$PYTHON" -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")')"

needs_rebuild=0
if [[ -d "$VENV" ]]; then
  if [[ -x "$VENV/bin/python" ]]; then
    HAVE_VER="$("$VENV/bin/python" -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")' 2>/dev/null || echo "?")"
    if [[ "$HAVE_VER" != "$WANT_VER" ]]; then
      warn "Existing venv is Python $HAVE_VER but we need $WANT_VER. Rebuilding."
      needs_rebuild=1
    else
      ok "Venv exists and is Python $HAVE_VER — reusing"
    fi
  else
    warn "Venv exists but $VENV/bin/python is missing. Rebuilding."
    needs_rebuild=1
  fi
else
  needs_rebuild=1
fi

if (( needs_rebuild )); then
  step "Creating venv at $VENV (Python $WANT_VER)"
  rm -rf "$VENV"
  "$PYTHON" -m venv "$VENV"
  ok "Venv created"
fi

# shellcheck source=/dev/null
source "$VENV/bin/activate"

step "Upgrading pip"
pip install --quiet --upgrade pip

# ─────────────────────────────────────────────────────────────────────────────
# 3. Install Python dependencies
# ─────────────────────────────────────────────────────────────────────────────
step "Installing backend dependencies (may take a few minutes — CadQuery is large)"
if ! pip install -r "$BACKEND/requirements.txt"; then
  fail "Pip could not resolve dependencies. See output above."
fi
ok "Backend dependencies installed"

step "Verifying that CadQuery can be imported"
if "$VENV/bin/python" -c "import cadquery" 2>/dev/null; then
  ok "CadQuery imported"
else
  fail "CadQuery installed but cannot be imported. Check the error above."
fi

# ─────────────────────────────────────────────────────────────────────────────
# 4. Install frontend dependencies
# ─────────────────────────────────────────────────────────────────────────────
step "Checking Node"
if ! command -v node >/dev/null 2>&1; then
  fail "Node is not installed. Install Node 20+ (e.g. 'brew install node')."
fi
NODE_MAJOR="$(node -p 'process.versions.node.split(".")[0]')"
if (( NODE_MAJOR < 20 )); then
  fail "Node $NODE_MAJOR is too old. Node 20+ required."
fi
ok "Node $(node --version)"

step "Installing frontend dependencies"
( cd "$FRONTEND" && npm install --silent )
ok "Frontend dependencies installed"

# ─────────────────────────────────────────────────────────────────────────────
# 5. Check Ollama + model
# ─────────────────────────────────────────────────────────────────────────────
MODEL="qwen2.5-coder:32b-instruct-q4_K_S"

step "Checking Ollama"
if ! command -v ollama >/dev/null 2>&1; then
  warn "Ollama is not in PATH. Install from https://ollama.com/download then run:"
  warn "    ollama pull $MODEL"
else
  ok "Ollama found ($(ollama --version 2>&1 | head -1))"
  if curl -sf -m 2 http://localhost:11434/api/tags >/dev/null 2>&1; then
    if ollama list 2>/dev/null | awk '{print $1}' | grep -qx "$MODEL"; then
      ok "Model $MODEL is already present"
    else
      step "Pulling $MODEL (~19 GB, this may take a while)…"
      if ollama pull "$MODEL"; then
        ok "Model pulled"
      else
        warn "Could not pull the model. Run 'ollama pull $MODEL' manually."
      fi
    fi
  else
    warn "Ollama daemon is not responding at http://localhost:11434."
    warn "Start it with 'ollama serve' (or launch the Ollama app) and then:"
    warn "    ollama pull $MODEL"
  fi
fi

# ─────────────────────────────────────────────────────────────────────────────
echo
ok "Installation done."
echo "Start the app with: ${C_BLUE}./RUN.sh${C_RESET}"
