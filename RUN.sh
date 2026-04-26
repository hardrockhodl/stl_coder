#!/usr/bin/env bash
# Starts the backend (uvicorn) and the frontend (vite) in parallel.
# Ctrl-C stops both (including child processes). Logs are truncated on start
# and written to backend/.uvicorn.log and frontend/.vite.log.
#
# Tip: launch Ollama with 'OLLAMA_KEEP_ALIVE=-1 ollama serve' so the model
# stays in memory between requests and the first call is fast.

set -euo pipefail
set -m  # job control ON — background jobs get their own process groups so we
        # can kill them and all their children (uvicorn-reload, esbuild, etc.)

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
# Prerequisites
# ─────────────────────────────────────────────────────────────────────────────
[[ -d "$VENV" ]] || fail "Venv missing at $VENV. Run ./INSTALL.sh first"
[[ -x "$VENV/bin/uvicorn" ]] || fail "uvicorn missing in venv. Re-run ./INSTALL.sh"
[[ -d "$FRONTEND/node_modules" ]] || fail "node_modules missing. Run ./INSTALL.sh first"
command -v curl >/dev/null || fail "curl is required but not in PATH."

# ─────────────────────────────────────────────────────────────────────────────
# Port collision check before we even try to start
# ─────────────────────────────────────────────────────────────────────────────
port_in_use() {
  local port="$1"
  if command -v lsof >/dev/null 2>&1; then
    lsof -iTCP:"$port" -sTCP:LISTEN >/dev/null 2>&1
  elif command -v ss >/dev/null 2>&1; then
    ss -ltn "sport = :$port" 2>/dev/null | grep -q LISTEN
  else
    # Last resort — try connecting. Not watertight but better than nothing.
    (echo >"/dev/tcp/127.0.0.1/$port") 2>/dev/null
  fi
}

for port in "$BACKEND_PORT" "$FRONTEND_PORT"; do
  if port_in_use "$port"; then
    fail "Port $port is in use. Stop the process listening there and try again."
  fi
done

# ─────────────────────────────────────────────────────────────────────────────
# Soft-check: is Ollama up + does the right model exist?
# ─────────────────────────────────────────────────────────────────────────────
MODEL="qwen2.5-coder:32b-instruct-q4_K_S"

if ! curl -sf -m 2 http://localhost:11434/api/tags >/dev/null 2>&1; then
  warn "Ollama is not responding at http://localhost:11434"
  warn "Start 'ollama serve' in another terminal — the app won't crash, but"
  warn "/api/generate will return 502 until it's up."
else
  if curl -sf -m 2 http://localhost:11434/api/tags 2>/dev/null \
       | grep -q "\"$MODEL\""; then
    ok "Model $MODEL is available in Ollama."
  else
    warn "Model $MODEL was not found in Ollama."
    warn "Run 'ollama pull $MODEL' or ./INSTALL.sh to fetch it."
    warn "The app starts anyway but /api/generate will return 502."
  fi
fi

# ─────────────────────────────────────────────────────────────────────────────
# Cleanup on Ctrl-C / EXIT
# ─────────────────────────────────────────────────────────────────────────────
BACKEND_PID=""
FRONTEND_PID=""
CLEANED_UP=0

kill_group() {
  # $1 = pid to kill (the entire process group)
  local pid="$1"
  [[ -z "$pid" ]] && return 0
  kill -0 "$pid" 2>/dev/null || return 0

  # Polite signal to the whole group
  kill -TERM -"$pid" 2>/dev/null || kill -TERM "$pid" 2>/dev/null || true

  # Wait up to 3 seconds
  for _ in {1..15}; do
    kill -0 "$pid" 2>/dev/null || return 0
    sleep 0.2
  done

  # Force
  kill -KILL -"$pid" 2>/dev/null || kill -KILL "$pid" 2>/dev/null || true
}

cleanup() {
  # Guard so cleanup doesn't run twice (INT → EXIT)
  [[ "$CLEANED_UP" -eq 1 ]] && return 0
  CLEANED_UP=1

  echo
  step "Shutting down…"
  kill_group "$BACKEND_PID"
  kill_group "$FRONTEND_PID"
  ok "Done."
}
trap cleanup EXIT
trap 'exit 130' INT TERM   # let the EXIT trap handle the cleanup

# ─────────────────────────────────────────────────────────────────────────────
# Start backend
# ─────────────────────────────────────────────────────────────────────────────
BACKEND_LOG="$BACKEND/.uvicorn.log"
: > "$BACKEND_LOG"   # truncate
step "Starting backend (uvicorn) on http://localhost:$BACKEND_PORT  → $BACKEND_LOG"
(
  cd "$BACKEND"
  exec "$VENV/bin/uvicorn" main:app --host 127.0.0.1 --port "$BACKEND_PORT" --reload
) >"$BACKEND_LOG" 2>&1 &
BACKEND_PID=$!

# Wait for /api/health (up to ~10s)
backend_ready=0
for _ in {1..20}; do
  if curl -sf -m 1 "http://127.0.0.1:$BACKEND_PORT/api/health" >/dev/null 2>&1; then
    backend_ready=1
    break
  fi
  if ! kill -0 "$BACKEND_PID" 2>/dev/null; then
    echo
    cat "$BACKEND_LOG" >&2
    fail "Backend crashed during startup. Log above."
  fi
  sleep 0.5
done

if [[ "$backend_ready" -ne 1 ]]; then
  cat "$BACKEND_LOG" >&2
  fail "Backend started but /api/health did not respond within 10 s."
fi
ok "Backend ready (pid $BACKEND_PID)"

# ─────────────────────────────────────────────────────────────────────────────
# Start frontend
# ─────────────────────────────────────────────────────────────────────────────
FRONTEND_LOG="$FRONTEND/.vite.log"
: > "$FRONTEND_LOG"   # truncate
step "Starting frontend (vite) on http://localhost:$FRONTEND_PORT  → $FRONTEND_LOG"
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
    fail "Frontend crashed during startup. Log above."
  fi
  sleep 0.5
done

if [[ "$frontend_ready" -ne 1 ]]; then
  cat "$FRONTEND_LOG" >&2
  fail "Frontend started but did not respond within 15 s."
fi
ok "Frontend ready (pid $FRONTEND_PID)"

echo
echo "${C_GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${C_RESET}"
echo "  Open ${C_BLUE}http://localhost:$FRONTEND_PORT${C_RESET} in your browser."
echo "  Press Ctrl-C to shut down both servers."
echo "${C_GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${C_RESET}"

# Wait until either backend or frontend dies. Portable variant — no `wait -n`
# (requires Bash 5.1+, not present in macOS system Bash 3.2).
while kill -0 "$BACKEND_PID" 2>/dev/null && kill -0 "$FRONTEND_PID" 2>/dev/null; do
  sleep 1
done

# If we got here without Ctrl-C, one of the processes died unexpectedly.
if kill -0 "$BACKEND_PID" 2>/dev/null; then
  warn "Frontend died unexpectedly. Last lines from $FRONTEND_LOG:"
  tail -n 20 "$FRONTEND_LOG" >&2 || true
elif kill -0 "$FRONTEND_PID" 2>/dev/null; then
  warn "Backend died unexpectedly. Last lines from $BACKEND_LOG:"
  tail -n 20 "$BACKEND_LOG" >&2 || true
fi
