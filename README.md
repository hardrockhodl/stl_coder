# STL Generator

Describe a 3D object in text. A local LLM (qwen2.5-coder:32b-instruct-q4_K_S
via Ollama) writes CadQuery code, the code runs in a sandbox, and you get
an STL file back.

## Quick start

```bash
./INSTALL.sh   # sets up venv, installs Python and npm dependencies, checks Ollama
./RUN.sh       # starts backend (8000) and frontend (5173), Ctrl-C stops both
```

Then open http://localhost:5173.

If you'd rather set things up manually — or want to know exactly what the
scripts do — read on.

## Prerequisites

1. **Python 3.10, 3.11, or 3.12** (CadQuery has no wheels for 3.13/3.14 on PyPI)
2. **Node 20+**
3. **Ollama** installed and running — https://ollama.com
4. Pull the LLM model (~19 GB):

       ollama pull qwen2.5-coder:32b-instruct-q4_K_S

   Requires ~36 GB unified memory to run smoothly. If you have less RAM,
   see "Smaller models" below.

### Smaller models

If the 32B model is too big for your machine, alternatives in descending order:

| RAM    | Model                                  | Size   |
|--------|----------------------------------------|--------|
| 36 GB+ | `qwen2.5-coder:32b-instruct-q4_K_S`   | 19 GB  |
| 24 GB  | `qwen2.5-coder:14b-instruct-q6_K`     | 12 GB  |
| 16 GB  | `qwen2.5-coder:14b`                    | 9 GB   |
| 8 GB   | `qwen2.5-coder:7b`                     | 4.7 GB |

Change `DEFAULT_MODEL` in `backend/llm.py` if you switch models.

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

1. Type a description, for example:
   - `a 20×20×20 mm cube with a 10 mm cylindrical hole through the middle`
   - `a toothbrush holder with three compartments, 8 cm tall`
   - `a simple coffee mug, 8 cm tall, 7 cm diameter, with a handle`
   - `a hexagonal M10 nut with standard thread-profile clearance`
2. Click "Generate" (or press `⌘/Ctrl+Enter`).
3. Wait — the model writes code, the sandbox runs it, the STL appears in 3D.
4. Click "Download STL" to save the file.

The generated Python code is shown below the preview so you can see what
the model did and tweak the prompt if the result isn't right.

## Security

Because the backend runs LLM-generated code:

- Generated code **always** runs in a separate subprocess with a 30 s
  timeout — never `exec()` inside the FastAPI process.
- A regex validator blocks suspicious patterns (`import os`,
  `import subprocess`, `open(`, `exec(`, `eval(`, `__import__`, etc.) before
  execution.
- The subprocess sets `RLIMIT_AS` (1 GiB) and `RLIMIT_CPU` (60 s) on POSIX.

**For production: run the backend in a sandboxed container.** Drop the
backend into a Docker container with no network and a read-only root, or
use `firejail`. The current sandbox is good enough for local hobby use but
not for a public service.

## Troubleshooting

| Symptom | Fix |
|---|---|
| `Could not connect to Ollama` | `ollama serve` is not running. Start it, or check whether port 11434 is in use. |
| `model '...' not found` | Run `ollama pull qwen2.5-coder:32b-instruct-q4_K_S`. |
| `Ollama did not respond within the timeout (10 min)` | The model probably hung — `pkill ollama && ollama serve`, wait 30 s, try again. See also "Keeping the model warm" below. |
| `ModuleNotFoundError: No module named 'cadquery'` | CadQuery isn't installed in the Python that uvicorn runs with. Install via conda/mamba (see Backend setup). |
| `Generated code contains a forbidden construct` | The model tried to import something forbidden. Adjust the prompt or the temperature. |
| `Variable 'result' is missing` | The model didn't follow the system prompt. Try again — possibly lower `temperature`. |
| `Code execution took longer than 30 seconds` | Complex object or infinite loop. Simplify the prompt. |
| 3D view shows nothing | Open the devtools console — the STL may be empty. Verify that the backend returned a valid STL. |

### The model takes forever or times out

The first request after Ollama starts loads the model into memory, which
takes 30–90 seconds for the 32B model. To avoid that:

```bash
pkill ollama
OLLAMA_KEEP_ALIVE=-1 ollama serve
```

The model now stays in memory permanently (~19 GB RAM). Pre-warm right
after start:

```bash
curl http://localhost:11434/api/generate \
  -d '{"model":"qwen2.5-coder:32b-instruct-q4_K_S","prompt":"hi","keep_alive":-1}'
```

The backend already sends `keep_alive: 30m` on every request and triggers
a background "warmup" against Ollama at uvicorn startup. `OLLAMA_KEEP_ALIVE=-1`
is still the safest bet if you generate often.

### The model returns explanatory text instead of just code

This shouldn't happen with qwen2.5-coder + structured output, but if it
does: check that your Ollama is version 0.5+ (run `ollama --version`).
Structured output (`format` with a JSON schema) requires Ollama 0.5 or
later. Upgrade with `brew upgrade ollama` on Mac.

## Endpoints (for API testing)

```bash
curl http://localhost:8000/api/health
# → {"status":"ok"}

curl -X POST http://localhost:8000/api/generate \
  -H 'Content-Type: application/json' \
  -d '{"prompt":"a 20mm cube with a 10mm hole","temperature":0.2}'
# → {"job_id":"...","code":"...","stl_url":"/api/stl/..."}

curl -O http://localhost:8000/api/stl/<job_id>
```

## Bonus features

- Adjustable temperature: implemented (input in the UI)
- Model selector: supported by the API (`model` in request body) — no UI yet
- Iterate button: not implemented
- History in localStorage: not implemented
