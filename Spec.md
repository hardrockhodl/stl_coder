# STL Generator Web App – Build Spec

Build a web app that lets the user describe a 3D object in text, sends the description to a local LLM (qwen3-coder:30b via Ollama), has the model write CadQuery Python code, runs the code in a sandbox, and returns an STL file to the user.

## Stack

- **Backend:** Python 3.11+, FastAPI, uvicorn, httpx, cadquery
- **Frontend:** React + Vite (JavaScript, not TypeScript for simplicity), three.js for 3D preview
- **LLM:** Ollama at `http://localhost:11434`, model `qwen3-coder:30b`
- **CAD engine:** CadQuery (real Python — the model handles it better than OpenSCAD)

## Project structure

```
stl-generator/
├── backend/
│   ├── main.py              # FastAPI app
│   ├── llm.py               # Ollama client
│   ├── sandbox.py           # Safe execution of CadQuery code
│   ├── prompts.py           # System prompts
│   ├── requirements.txt
│   └── generated/           # Output STL files (gitignored)
├── frontend/
│   ├── src/
│   │   ├── App.jsx
│   │   ├── StlViewer.jsx    # three.js-based preview
│   │   ├── main.jsx
│   │   └── index.css
│   ├── index.html
│   ├── package.json
│   └── vite.config.js
├── README.md
└── .gitignore
```

## Backend – requirements

### `requirements.txt`
```
fastapi>=0.110
uvicorn[standard]>=0.27
httpx>=0.27
cadquery>=2.4
python-multipart>=0.0.9
```

> Note: CadQuery is easiest to install via conda/mamba (`mamba install -c conda-forge cadquery`). Note this in the README.

### `prompts.py`
A system prompt that instructs the model to:
- Reply only with executable Python code (no markdown, no explanatory text)
- Use CadQuery (`import cadquery as cq`)
- Assign the final object to a variable named `result`
- Never import modules other than `cadquery`, `math`, and standard-library math
- Never read/write files, never make network calls, never call `exec` / `eval` / `__import__`

Include 1–2 few-shot examples (e.g. a cube with a hole, a simple mug).

### `llm.py`
- Async function `generate_code(prompt: str) -> str`
- POSTs to `http://localhost:11434/api/generate` with `model="qwen3-coder:30b"`, `stream=False`
- Sends the system prompt from `prompts.py`
- Strips any markdown fences (```python … ```) from the response before returning

### `sandbox.py`
- Function `run_cadquery(code: str, out_path: Path) -> None`
- Runs the code in a subprocess with a timeout (e.g. 30 seconds) — use `subprocess.run` with `python -c`, NOT `exec()` in the same process
- The subprocess must:
  1. Run the code
  2. Pull out the variable `result`
  3. Call `cq.exporters.export(result, str(out_path))`
- Return a clear error if the code crashes, times out, or `result` is missing

### `main.py`
Endpoints:
- `POST /api/generate` — body: `{"prompt": "..."}` → returns `{"job_id": "...", "code": "...", "stl_url": "/api/stl/{job_id}"}`
- `GET /api/stl/{job_id}` — returns the STL file as `application/sla`
- CORS: allow `http://localhost:5173` (Vite dev server)

The job id can be a UUID. Store STL files at `backend/generated/{job_id}.stl`.

## Frontend – requirements

### `App.jsx`
- Large textarea for the prompt (placeholder e.g. "A toothbrush holder with three compartments, 8 cm tall")
- "Generate" button (disabled while a request is in flight)
- When the response arrives:
  - Show the generated CadQuery code in a collapsible `<pre>` block with syntax highlighting (use `highlight.js` or `prismjs`)
  - Show the STL file inside `<StlViewer />`
  - Show a download button linking to `stl_url`
- Error handling: clearly show an error message when the backend returns 4xx/5xx

### `StlViewer.jsx`
- Use `three` + `three/examples/jsm/loaders/STLLoader` + `OrbitControls`
- Takes a `url` prop, loads the STL, renders it in a `<canvas>` about 500 px tall
- Auto-center and scale the camera so the object fits
- Light + grid floor for a polished look

### `vite.config.js`
Proxy `/api` → `http://localhost:8000` so the frontend can call the backend without CORS hassles in dev.

## README.md – requirements

Contents:
1. Prerequisites: Python 3.11+, Node 20+, Ollama installed, the model pulled: `ollama pull qwen3-coder:30b`
2. Backend setup: create a conda env, `mamba install -c conda-forge cadquery`, `pip install -r requirements.txt`, `uvicorn main:app --reload`
3. Frontend setup: `cd frontend && npm install && npm run dev`
4. Open `http://localhost:5173`
5. Example prompts to try
6. Troubleshooting: what to do if Ollama doesn't respond, if the CadQuery code doesn't run, etc.

## Security requirements (important!)

Because we run LLM-generated code:
- **Never** `exec()` the code in the backend process — always subprocess with a timeout
- Validate that the generated code does not contain strings like `import os`, `import subprocess`, `open(`, `__import__`, `eval(`, `exec(` (regex check before running, return an error on hit)
- The subprocess runs as the same user in this version, but mention in the README that one should run it in Docker / firejail for production
- Set resource limits in the subprocess where possible (`resource.setrlimit` for memory/CPU on Linux/Mac)

## Acceptance criteria

- `uvicorn main:app` starts without errors
- `npm run dev` starts the Vite server
- Prompt "a 20×20×20 mm cube with a 10 mm diameter cylindrical hole straight through" generates an STL that shows up in the 3D viewer and can be downloaded
- If Ollama isn't running: a clear error in the frontend, not a crashed backend
- If the model produces broken code: the error is shown in the frontend together with the code, so the user can adjust the prompt

## Bonus features (do if time permits)

- "Iterate" button: send the code + error message back to the model for another shot
- History of previous generations (in localStorage)
- Adjustable `temperature` for the Ollama call
- Support for multiple models (dropdown)
