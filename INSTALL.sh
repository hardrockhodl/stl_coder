#!/usr/bin/env bash
# Sätter upp backend (Python venv + CadQuery + FastAPI) och frontend (npm)
# samt verifierar att Ollama och qwen3-coder:30b finns.
#
# Krav: bash, en kompatibel Python (3.10–3.12) och Node 20+.
# CadQuery finns inte som wheel för Python 3.13/3.14 på PyPI (per 2026-04),
# så scriptet letar efter en stödd Python-version automatiskt.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BACKEND="$ROOT/backend"
FRONTEND="$ROOT/frontend"
VENV="$BACKEND/.venv"

# Färger om terminalen stödjer det
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
# 1. Hitta en CadQuery-kompatibel Python (3.10, 3.11 eller 3.12)
# ─────────────────────────────────────────────────────────────────────────────
step "Letar efter CadQuery-kompatibel Python (3.10–3.12)"

PYTHON=""
for candidate in python3.11 python3.12 python3.10; do
  if command -v "$candidate" >/dev/null 2>&1; then
    PYTHON="$(command -v "$candidate")"
    break
  fi
done

if [[ -z "$PYTHON" ]]; then
  cat <<EOF
${C_RED}Hittar ingen Python 3.10/3.11/3.12.${C_RESET}

CadQuery distribuerar wheels för 3.10–3.12 på PyPI. Din 'python3' är troligen
för ny (3.13/3.14) och saknar wheels.

Installera python@3.11 via Homebrew:
    brew install python@3.11

Eller använd conda/mamba istället:
    mamba create -n stlgen python=3.11 -c conda-forge -y
    mamba activate stlgen
    mamba install -c conda-forge cadquery -y
    pip install -r backend/requirements.txt
EOF
  exit 1
fi
ok "Använder $PYTHON ($($PYTHON --version))"

# ─────────────────────────────────────────────────────────────────────────────
# 2. Skapa/uppdatera venv (bygg om om versionen inte matchar)
# ─────────────────────────────────────────────────────────────────────────────
WANT_VER="$("$PYTHON" -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")')"

needs_rebuild=0
if [[ -d "$VENV" ]]; then
  if [[ -x "$VENV/bin/python" ]]; then
    HAVE_VER="$("$VENV/bin/python" -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")' 2>/dev/null || echo "?")"
    if [[ "$HAVE_VER" != "$WANT_VER" ]]; then
      warn "Existerande venv är Python $HAVE_VER men vi behöver $WANT_VER. Bygger om."
      needs_rebuild=1
    else
      ok "Venv finns och är Python $HAVE_VER — återanvänder"
    fi
  else
    warn "Venv finns men $VENV/bin/python saknas. Bygger om."
    needs_rebuild=1
  fi
else
  needs_rebuild=1
fi

if (( needs_rebuild )); then
  step "Skapar venv i $VENV (Python $WANT_VER)"
  rm -rf "$VENV"
  "$PYTHON" -m venv "$VENV"
  ok "Venv skapad"
fi

# shellcheck source=/dev/null
source "$VENV/bin/activate"

step "Uppgraderar pip"
pip install --quiet --upgrade pip

# ─────────────────────────────────────────────────────────────────────────────
# 3. Installera Python-beroenden
# ─────────────────────────────────────────────────────────────────────────────
step "Installerar backend-beroenden (kan ta några minuter — CadQuery är stor)"
if ! pip install -r "$BACKEND/requirements.txt"; then
  fail "Pip kunde inte lösa beroenden. Se output ovan."
fi
ok "Backend-beroenden installerade"

step "Verifierar att CadQuery kan importeras"
if "$VENV/bin/python" -c "import cadquery" 2>/dev/null; then
  ok "CadQuery importerades"
else
  fail "CadQuery installerades men kan inte importeras. Kolla felmeddelandet ovan."
fi

# ─────────────────────────────────────────────────────────────────────────────
# 4. Installera frontend-beroenden
# ─────────────────────────────────────────────────────────────────────────────
step "Kontrollerar Node"
if ! command -v node >/dev/null 2>&1; then
  fail "Node är inte installerat. Installera Node 20+ (t.ex. 'brew install node')."
fi
NODE_MAJOR="$(node -p 'process.versions.node.split(".")[0]')"
if (( NODE_MAJOR < 20 )); then
  fail "Node $NODE_MAJOR är för gammal. Behöver Node 20+."
fi
ok "Node $(node --version)"

step "Installerar frontend-beroenden"
( cd "$FRONTEND" && npm install --silent )
ok "Frontend-beroenden installerade"

# ─────────────────────────────────────────────────────────────────────────────
# 5. Kontrollera Ollama + modell
# ─────────────────────────────────────────────────────────────────────────────
step "Kontrollerar Ollama"
if ! command -v ollama >/dev/null 2>&1; then
  warn "Ollama är inte i PATH. Installera från https://ollama.com och kör:"
  warn "    ollama pull qwen3-coder:30b"
else
  ok "Ollama hittades ($(ollama --version 2>&1 | head -1))"
  if curl -sf -m 2 http://localhost:11434/api/tags >/dev/null 2>&1; then
    if curl -sf http://localhost:11434/api/tags | grep -q "qwen3-coder:30b"; then
      ok "Modellen qwen3-coder:30b är hämtad"
    else
      warn "Ollama körs men qwen3-coder:30b saknas. Hämta den med:"
      warn "    ollama pull qwen3-coder:30b"
    fi
  else
    warn "Ollama-daemonen svarar inte på http://localhost:11434."
    warn "Starta den: 'ollama serve' (eller starta Ollama-appen) och kör sedan:"
    warn "    ollama pull qwen3-coder:30b"
  fi
fi

# ─────────────────────────────────────────────────────────────────────────────
echo
ok "Installation klar."
echo "Starta appen med: ${C_BLUE}./RUN.sh${C_RESET}"
