# Unicorn Creative Magic — STL Generator

Describe a 3D object in text. A local LLM (qwen2.5-coder via Ollama) writes
CadQuery code, the code runs in a sandbox, and you get an STL file back.
You can then refine the model with follow-up instructions ("make it 5mm
taller", "add rounded corners"), and revert to any earlier step in the
history.

The frontend is a pastel React app called **Unicorn Creative Magic** with a
cloud-shaped prompt card, light/dark theme toggle, and an interactive 3D
preview powered by three.js.

## Quick start

```bash
./INSTALL.sh   # sets up venv, installs Python and npm dependencies, pulls the models
./RUN.sh       # starts backend (8000) and frontend (5173), Ctrl-C stops both
```

Then open http://localhost:5173.

If you'd rather set things up manually — or want to know exactly what the
scripts do — read on.

## Models

The app ships with two models you can pick from the **Model** dropdown in the
prompt card:

| ID         | Ollama model                             | Size  | Latency      | When to use                                            |
|------------|------------------------------------------|-------|--------------|--------------------------------------------------------|
| `quality`  | `qwen2.5-coder:32b-instruct-q4_K_S`      | 19 GB | ~15–30 s/req | New models from scratch — better CadQuery idioms.       |
| `fast`     | `qwen2.5-coder:14b-instruct-q6_K`        | 12 GB | ~5–10 s/req  | Tweaking an existing model. Weaker on greenfield code.  |

`quality` is the default. Both models are pulled by `INSTALL.sh`.

Only `quality` is warmed up at backend startup — the first time you switch
the dropdown to `fast`, expect a 15–30 s cold-load while Ollama brings the
14B into memory. After that, both models stay warm for `KEEP_ALIVE` (30 min
by default; lower it in [backend/llm.py](backend/llm.py) if you want faster
eviction).

### Memory budget

On a 36 GB Apple Silicon machine, keeping both models resident is roughly
19 GB + 12 GB = 31 GB, leaving ~5 GB for macOS, browser, and dev tooling.
That's tight; the app deliberately warms only the default to avoid swap.
If you want a smaller footprint, edit `MODELS` in
[backend/llm.py](backend/llm.py) and remove or replace one of the entries —
the dropdown picks up the change automatically.

### Smaller models

If 32B is too big and you want a smaller default, alternatives in
descending order:

| RAM    | Model                              | Size   |
|--------|------------------------------------|--------|
| 24 GB+ | `qwen2.5-coder:14b-instruct-q6_K` | 12 GB  |
| 16 GB  | `qwen2.5-coder:14b`                | 9 GB   |
| 8 GB   | `qwen2.5-coder:7b`                 | 4.7 GB |

Edit the `MODELS` registry in [backend/llm.py](backend/llm.py) — the
frontend dropdown reads it via `/api/models` so no UI changes are needed.

## Prerequisites

1. **Python 3.10, 3.11, or 3.12** (CadQuery has no wheels for 3.13/3.14 on PyPI)
2. **Node 20+**
3. **Ollama 0.5+** installed and running — https://ollama.com
   (Older versions don't support structured JSON output, which is what
   forces the model to return clean code.)
4. The two default models (pulled automatically by `INSTALL.sh`):

       ollama pull qwen2.5-coder:32b-instruct-q4_K_S
       ollama pull qwen2.5-coder:14b-instruct-q6_K

## Backend setup (manual)

With a regular pip venv (Python 3.10–3.12):

```bash
cd backend
python3.11 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
uvicorn main:app --reload --port 8000
```

Alternatively with conda/mamba:

```bash
mamba create -n stlgen python=3.11 -c conda-forge -y
mamba activate stlgen
mamba install -c conda-forge cadquery -y
pip install -r backend/requirements.txt
uvicorn main:app --reload --port 8000
```

The backend now listens on `http://localhost:8000`.

## Frontend setup

```bash
cd frontend
npm install
npm run dev
```

Open `http://localhost:5173`.

Vite proxies `/api` → `http://localhost:8000`, so the frontend and backend
talk without CORS hassles during development.

## Usage

### Generate

1. Type a description, for example:
   - `a 20×20×20 mm cube with a 10 mm cylindrical hole through the middle`
   - `a toothbrush holder with three compartments, 8 cm tall`
   - `a simple coffee mug, 8 cm tall, 7 cm diameter, with a handle`
   - `a hexagonal M10 nut with standard thread-profile clearance`
2. Pick a model from the dropdown (`Quality` for new designs, `Fast` for
   small tweaks once a model exists).
3. Click **Generate** (or press `⌘/Ctrl+Enter`).
4. Wait — the model writes code, the sandbox runs it, the STL appears in 3D.
5. Click **Download STL** to save the file.

The generated Python code is shown below the preview so you can see what
the model did.

### Refine and iterate

After a successful generation, the **Refine the model** card appears.
Type a follow-up instruction and press Enter or click **Apply change**:

- `make it 5mm taller`
- `add rounded corners radius 3`
- `move the holes 10mm apart`
- `remove the handle`

Each iteration appears in the **History** list with a numbered chip:

- The active step has a gradient-filled chip and a `current` badge
- All other steps have a **Show** button — click to revert to that step
- Iterating from a reverted step branches off it, not from the latest
- **Start over** clears the history and lets you start with a new prompt

History is browser-only state; refreshing the page loses it.

### Auto-repair on broken geometry

When CadQuery can't execute the generated code (e.g.,
`There are no suitable edges for chamfer or fillet` because a fillet
radius is too large or applied after the wrong cut), the backend
automatically asks the model to fix the code and runs it again. The user
sees a longer loading time (~2× normal) but a working result instead of
a 422 error.

The repair budget is one extra LLM round-trip per request. If repair
itself fails or the second sandbox run is also broken, the 422 is shown
with the latest code so you can iterate from it manually.

The sun/moon toggle in the upper-left switches between light and dark
themes; the choice persists in `localStorage`.

## Security

Because the backend runs LLM-generated code:

- Generated code **always** runs in a separate subprocess with a 30 s
  timeout — never `exec()` inside the FastAPI process.
- The subprocess uses `python -I` (isolated mode), runs in a temporary
  working directory, and has a minimal env (`PATH`, `HOME` only).
- A regex validator blocks suspicious patterns (`import os`,
  `import subprocess`, `open(`, `exec(`, `eval(`, `__import__`, etc.) before
  execution.
- `RLIMIT_AS` (1 GiB) and `RLIMIT_CPU` (60 s) are set on POSIX.

**For production: run the backend in a sandboxed container.** Drop the
backend into a Docker container with no network and a read-only root, or
use `firejail`. The current sandbox is good enough for local hobby use but
not for a public service.

## Endpoints (for API testing)

```bash
# Health
curl http://localhost:8000/api/health
# → {"status":"ok"}

# Available models (the dropdown reads this)
curl http://localhost:8000/api/models
# → {"default":"quality","models":[
#      {"id":"quality","label":"Quality (32B)","description":"…"},
#      {"id":"fast","label":"Fast (14B)","description":"…"}
#    ]}

# Generate
curl -X POST http://localhost:8000/api/generate \
  -H 'Content-Type: application/json' \
  -d '{"prompt":"a 20mm cube with a 10mm hole","temperature":0.2,"model":"quality"}'
# → {"job_id":"...","code":"...","stl_url":"/api/stl/..."}

# Iterate (refine an existing model)
curl -X POST http://localhost:8000/api/iterate \
  -H 'Content-Type: application/json' \
  -d '{"previous_code":"<code from /api/generate>","instruction":"make it 30mm","model":"quality"}'
# → {"job_id":"...","code":"...","stl_url":"/api/stl/..."}

# Download the STL
curl -O http://localhost:8000/api/stl/<job_id>
```

## Troubleshooting

| Symptom | Fix |
|---|---|
| `Could not connect to Ollama` | `ollama serve` is not running. Start it, or check whether port 11434 is in use. |
| `model '...' not found` | Run `ollama pull qwen2.5-coder:32b-instruct-q4_K_S` (or the 14B). |
| `Unknown model: '<id>'` | The frontend sent a model ID that isn't in the `MODELS` registry. Restart the backend after editing `MODELS` in [backend/llm.py](backend/llm.py). |
| `Ollama did not respond within timeout (10 min)` | The model probably hung — `pkill ollama && ollama serve`, wait 30 s, try again. See "The model takes forever" below. |
| `ModuleNotFoundError: No module named 'cadquery'` | CadQuery isn't installed in the Python that uvicorn runs with. Install via conda/mamba (see Backend setup). |
| `Generated code contains a forbidden construct` | The model tried to import something forbidden. Adjust the prompt or lower the temperature. |
| `Variable 'result' is missing` | The model didn't follow the system prompt. Try again — possibly lower `temperature`. |
| `Code execution took longer than 30 seconds` | Complex object or infinite loop. Simplify the prompt. |
| `Failed after auto-repair: ...` | The model couldn't fix the broken code on the first repair attempt. The latest broken code is shown — iterate from it manually with a clearer instruction, or **Start over** with a different prompt. |
| 3D view shows nothing | Open the devtools console — the STL may be empty. Verify that the backend returned a valid STL. |
| **Show** button on a history step 404s | STL files in `backend/generated/` are auto-cleaned after 24 h. Older history entries lose their STL even though the code is still in the browser. Iterate from the entry instead — the code is still there. |

### The model takes forever or times out

The first request after Ollama starts loads the model into memory:
~15–30 s for 14B, ~30–90 s for 32B. The backend's startup hook pre-warms
the default model (`quality` / 32B) so the first prompt is already warm.
The first prompt with `fast` will cold-load.

To keep models loaded permanently (skip cold-loads entirely) start Ollama
with:

```bash
pkill ollama
OLLAMA_KEEP_ALIVE=-1 ollama serve
```

Pre-warm right after start:

```bash
curl http://localhost:11434/api/chat \
  -d '{"model":"qwen2.5-coder:32b-instruct-q4_K_S","messages":[{"role":"user","content":"hi"}],"keep_alive":-1}'
```

The backend already sends `keep_alive: 30m` on every request, so models
stay warm for 30 min after the last call. Switching models in the dropdown
counts as inactivity for the previous model — Ollama unloads it after
30 min and frees the RAM. Lower `KEEP_ALIVE` in
[backend/llm.py](backend/llm.py) (e.g. `"5m"`) for faster eviction at the
cost of more cold-loads.

### Generation feels twice as slow as expected

It's probably auto-repair: the first sandbox run failed (usually a fillet
or boolean error), the backend silently asked the model to fix it, and the
second sandbox run succeeded. Check `backend/.uvicorn.log` — you'll see
two POSTs to `/api/chat` for the same request. The result is correct;
just slower. To disable auto-repair entirely, set `MAX_REPAIR_ATTEMPTS = 0`
in [backend/main.py](backend/main.py).

### The model returns explanatory text instead of just code

This shouldn't happen with qwen2.5-coder + structured output, but if it
does: check that your Ollama is version 0.5+ (`ollama --version`).
Structured output (`format` with a JSON schema) requires Ollama 0.5 or
later. Upgrade with `brew upgrade ollama` on macOS.

## Status

Implemented:

- Cloud-shaped prompt card with sun/moon dark-mode toggle
- Two-model dropdown driven by the `/api/models` registry (`quality` default)
- Adjustable `temperature` per request
- Live elapsed-seconds counter and pulsing gradient loader
- Cold-load hint after 30 s
- Iteration: refine the current model with follow-up instructions
- History list with numbered steps, "Show" buttons to revert, and a
  `current` badge — iterating from a reverted step branches off it
- Auto-repair: on `SandboxError`, the backend asks the model to fix the
  code and retries once before surfacing a 422
- Sandboxed CadQuery execution (subprocess, isolated mode, regex validator,
  resource limits, temp-dir cwd)
- 3D preview with theme-aware background and pink rim light
- Syntax-highlighted code panel
- Background warmup of the default model at backend startup
- Auto-cleanup of STL files older than 24 h

Not yet implemented:

- History persisted to `localStorage` (currently lost on refresh)
- "Fork" indicator in the history UI when a step branches from a
  reverted parent
