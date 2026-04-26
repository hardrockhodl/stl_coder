#!/usr/bin/env bash
# Startar backend (uvicorn) och frontend (vite) parallellt.
# Ctrl-C stänger båda (inkl. barnprocesser). Loggar trunkeras vid start
# och skrivs till backend/.uvicorn.log och frontend/.vite.log.

set -euo pipefail
set -m  # job control PÅ — bakgrundsjobb får egna process groups så vi kan
        # döda dem och alla deras barn (uvicorn-reload, esbuild, etc.)

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BACKEND="$ROOT/backend"
FRONTEND="$ROOT/frontend"
VENV="$BACKEND/.venv"

BACKEND_PORT=8000
FRONTEND_PORT=5173

if [[ -t 1 ]]; then
  C_GREEN=$'\033[0;32m'; C_YELLOW=$'\033[0;33m'; C_RED=$'\033[0;31m'
  C_BLUE=$'\033[0;34m'; C_RESET=$'\033[0m'
else
  C_GREEN=""; C_YELLOW=""; C_RED=""; C_BLUE=""; C_RESET=""
fi

step()  { echo "${C_BLUE}==>${C_RESET} $*"; }
ok()    { echo "${C_GREEN}OK${C_RESET}  $*"; }
warn()  { echo "${C_YELLOW}!!${C_RESET}  $*"; }
fail()  { echo "${C_RED}xx${C_RESET}  $*" >&2; exit 1; }

# ─────────────────────────────────────────────────────────────────────────────
# Förkrav
# ─────────────────────────────────────────────────────────────────────────────
[[ -d "$VENV" ]] || fail "Venv saknas på $VENV. Kör först ./INSTALL.sh"
[[ -x "$VENV/bin/uvicorn" ]] || fail "uvicorn saknas i venv. Kör om ./INSTALL.sh"
[[ -d "$FRONTEND/node_modules" ]] || fail "node_modules saknas. Kör först ./INSTALL.sh"
command -v curl >/dev/null || fail "curl krävs men hittades inte i PATH."

# ─────────────────────────────────────────────────────────────────────────────
# Port-kollision innan vi ens försöker starta
# ─────────────────────────────────────────────────────────────────────────────
port_in_use() {
  local port="$1"
  if command -v lsof >/dev/null 2>&1; then
    lsof -iTCP:"$port" -sTCP:LISTEN >/dev/null 2>&1
  elif command -v ss >/dev/null 2>&1; then
    ss -ltn "sport = :$port" 2>/dev/null | grep -q LISTEN
  else
    # Sista utvägen — försök ansluta. Inte vattentätt men bättre än inget.
    (echo >"/dev/tcp/127.0.0.1/$port") 2>/dev/null
  fi
}

for port in "$BACKEND_PORT" "$FRONTEND_PORT"; do
  if port_in_use "$port"; then
    fail "Port $port är upptagen. Stäng processen som lyssnar där och försök igen."
  fi
done

# ─────────────────────────────────────────────────────────────────────────────
# Soft-check: är Ollama uppe?
# ─────────────────────────────────────────────────────────────────────────────
if ! curl -sf -m 2 http://localhost:11434/api/tags >/dev/null 2>&1; then
  warn "Ollama svarar inte på http://localhost:11434"
  warn "Starta 'ollama serve' i en annan terminal — appen kraschar inte, men"
  warn "/api/generate kommer returnera 502 tills den är uppe."
fi

# ─────────────────────────────────────────────────────────────────────────────
# Cleanup vid Ctrl-C / EXIT
# ─────────────────────────────────────────────────────────────────────────────
BACKEND_PID=""
FRONTEND_PID=""
CLEANED_UP=0

kill_group() {
  # $1 = pid att döda (hela dess process group)
  local pid="$1"
  [[ -z "$pid" ]] && return 0
  kill -0 "$pid" 2>/dev/null || return 0

  # Snäll signal till hela gruppen
  kill -TERM -"$pid" 2>/dev/null || kill -TERM "$pid" 2>/dev/null || true

  # Vänta upp till 3 sekunder
  for _ in {1..15}; do
    kill -0 "$pid" 2>/dev/null || return 0
    sleep 0.2
  done

  # Tvinga
  kill -KILL -"$pid" 2>/dev/null || kill -KILL "$pid" 2>/dev/null || true
}

cleanup() {
  # Guard så vi inte kör cleanup två gånger (INT → EXIT)
  [[ "$CLEANED_UP" -eq 1 ]] && return 0
  CLEANED_UP=1

  echo
  step "Stänger ner…"
  kill_group "$BACKEND_PID"
  kill_group "$FRONTEND_PID"
  ok "Klart."
}
trap cleanup EXIT
trap 'exit 130' INT TERM   # låter EXIT-trapen sköta städningen

# ─────────────────────────────────────────────────────────────────────────────
# Starta backend
# ─────────────────────────────────────────────────────────────────────────────
BACKEND_LOG="$BACKEND/.uvicorn.log"
: > "$BACKEND_LOG"   # trunkera
step "Startar backend (uvicorn) på http://localhost:$BACKEND_PORT  → $BACKEND_LOG"
(
  cd "$BACKEND"
  exec "$VENV/bin/uvicorn" main:app --host 127.0.0.1 --port "$BACKEND_PORT" --reload
) >"$BACKEND_LOG" 2>&1 &
BACKEND_PID=$!

# Vänta in /api/health (max ~10s)
backend_ready=0
for _ in {1..20}; do
  if curl -sf -m 1 "http://127.0.0.1:$BACKEND_PORT/api/health" >/dev/null 2>&1; then
    backend_ready=1
    break
  fi
  if ! kill -0 "$BACKEND_PID" 2>/dev/null; then
    echo
    cat "$BACKEND_LOG" >&2
    fail "Backend kraschade under uppstart. Logg ovan."
  fi
  sleep 0.5
done

if [[ "$backend_ready" -ne 1 ]]; then
  cat "$BACKEND_LOG" >&2
  fail "Backend startade men /api/health svarar inte inom 10 s."
fi
ok "Backend redo (pid $BACKEND_PID)"

# ─────────────────────────────────────────────────────────────────────────────
# Starta frontend
# ─────────────────────────────────────────────────────────────────────────────
FRONTEND_LOG="$FRONTEND/.vite.log"
: > "$FRONTEND_LOG"   # trunkera
step "Startar frontend (vite) på http://localhost:$FRONTEND_PORT  → $FRONTEND_LOG"
(
  cd "$FRONTEND"
  exec npm run dev -- --host 127.0.0.1 --port "$FRONTEND_PORT"
) >"$FRONTEND_LOG" 2>&1 &
FRONTEND_PID=$!

frontend_ready=0
for _ in {1..30}; do
  if curl -sf -m 1 "http://127.0.0.1:$FRONTEND_PORT/" >/dev/null 2>&1; then
    frontend_ready=1
    break
  fi
  if ! kill -0 "$FRONTEND_PID" 2>/dev/null; then
    echo
    cat "$FRONTEND_LOG" >&2
    fail "Frontend kraschade under uppstart. Logg ovan."
  fi
  sleep 0.5
done

if [[ "$frontend_ready" -ne 1 ]]; then
  cat "$FRONTEND_LOG" >&2
  fail "Frontend startade men svarar inte inom 15 s."
fi
ok "Frontend redo (pid $FRONTEND_PID)"

echo
echo "${C_GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${C_RESET}"
echo "  Öppna ${C_BLUE}http://localhost:$FRONTEND_PORT${C_RESET} i webbläsaren."
echo "  Tryck Ctrl-C för att stänga ner båda servrarna."
echo "${C_GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${C_RESET}"

# Vänta tills antingen backend eller frontend dör. Portabel variant — ingen
# `wait -n` (kräver Bash 5.1+, finns inte på macOS-systemets Bash 3.2).
while kill -0 "$BACKEND_PID" 2>/dev/null && kill -0 "$FRONTEND_PID" 2>/dev/null; do
  sleep 1
done

# Om vi kom hit utan Ctrl-C så dog en av processerna oväntat — visa loggen
if kill -0 "$BACKEND_PID" 2>/dev/null; then
  warn "Frontend dog oväntat. Sista raderna ur $FRONTEND_LOG:"
  tail -n 20 "$FRONTEND_LOG" >&2 || true
elif kill -0 "$FRONTEND_PID" 2>/dev/null; then
  warn "Backend dog oväntat. Sista raderna ur $BACKEND_LOG:"
  tail -n 20 "$BACKEND_LOG" >&2 || true
fi