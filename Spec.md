# STL Generator Web App – Build Spec

Bygg en webbapp som låter användaren beskriva ett 3D-objekt i text, skickar beskrivningen till en lokal LLM (qwen3-coder:30b via Ollama), låter modellen skriva CadQuery-Python-kod, kör koden i en sandbox och returnerar en STL-fil till användaren.

## Stack

- **Backend:** Python 3.11+, FastAPI, uvicorn, httpx, cadquery
- **Frontend:** React + Vite (JavaScript, inte TypeScript för enkelhet), three.js för 3D-preview
- **LLM:** Ollama på `http://localhost:11434`, modell `qwen3-coder:30b`
- **CAD-motor:** CadQuery (riktig Python — modellen hanterar det bättre än OpenSCAD)

## Projektstruktur

```
stl-generator/
├── backend/
│   ├── main.py              # FastAPI-app
│   ├── llm.py               # Ollama-klient
│   ├── sandbox.py           # Säker exekvering av CadQuery-kod
│   ├── prompts.py           # System-prompts
│   ├── requirements.txt
│   └── generated/           # Output STL-filer (gitignored)
├── frontend/
│   ├── src/
│   │   ├── App.jsx
│   │   ├── StlViewer.jsx    # three.js-baserad preview
│   │   ├── main.jsx
│   │   └── index.css
│   ├── index.html
│   ├── package.json
│   └── vite.config.js
├── README.md
└── .gitignore
```

## Backend – krav

### `requirements.txt`
```
fastapi>=0.110
uvicorn[standard]>=0.27
httpx>=0.27
cadquery>=2.4
python-multipart>=0.0.9
```

> Notera: CadQuery installeras enklast via conda/mamba (`mamba install -c conda-forge cadquery`). Skriv det i README.

### `prompts.py`
En system-prompt som instruerar modellen att:
- Bara svara med körbar Python-kod (ingen markdown, ingen förklarande text)
- Använda CadQuery (`import cadquery as cq`)
- Tilldela det slutliga objektet till en variabel som heter `result`
- Aldrig importera moduler utöver `cadquery`, `math` och standardlib-matematik
- Aldrig läsa/skriva filer, aldrig göra nätverksanrop, aldrig anropa `exec`/`eval`/`__import__`

Inkludera 1–2 few-shot-exempel (t.ex. en kub med hål, en enkel mugg).

### `llm.py`
- Async-funktion `generate_code(prompt: str) -> str`
- POSTar till `http://localhost:11434/api/generate` med `model="qwen3-coder:30b"`, `stream=False`
- Skickar med system-prompten från `prompts.py`
- Strippar eventuella markdown-staket (```python … ```) från svaret innan retur

### `sandbox.py`
- Funktion `run_cadquery(code: str, out_path: Path) -> None`
- Kör koden i en subprocess med timeout (t.ex. 30 sekunder) — använd `subprocess.run` med `python -c`, INTE `exec()` i samma process
- Subprocessen ska:
  1. Köra koden
  2. Plocka ut variabeln `result`
  3. Anropa `cq.exporters.export(result, str(out_path))`
- Returnera tydligt fel om koden kraschar, timeout, eller om `result` saknas

### `main.py`
Endpoints:
- `POST /api/generate` — body: `{"prompt": "..."}` → returnerar `{"job_id": "...", "code": "...", "stl_url": "/api/stl/{job_id}"}`
- `GET /api/stl/{job_id}` — returnerar STL-filen som `application/sla`
- CORS: tillåt `http://localhost:5173` (Vite dev-server)

Job-id kan vara en UUID. Lagra STL-filer i `backend/generated/{job_id}.stl`.

## Frontend – krav

### `App.jsx`
- Stort textfält för prompt (placeholder: t.ex. "En tandkrämshållare med tre fack, 8 cm hög")
- "Generera"-knapp (disabled medan request pågår)
- När svaret kommer:
  - Visa den genererade CadQuery-koden i ett kollapsbart `<pre>`-block med syntax-highlighting (använd `highlight.js` eller `prismjs`)
  - Visa STL-filen i `<StlViewer />`
  - Visa en nedladdningsknapp som länkar till `stl_url`
- Felhantering: visa tydligt felmeddelande om backend returnerar 4xx/5xx

### `StlViewer.jsx`
- Använd `three` + `three/examples/jsm/loaders/STLLoader` + `OrbitControls`
- Tar emot prop `url`, laddar STL:en, renderar i en `<canvas>` ca 500px hög
- Auto-centrera och skala kameran så objektet får plats
- Ljus + grid floor så det ser snyggt ut

### `vite.config.js`
Proxy `/api` → `http://localhost:8000` så frontend kan anropa backend utan CORS-trubbel under dev.

## README.md – krav

Innehåll:
1. Förkrav: Python 3.11+, Node 20+, Ollama installerat, modellen hämtad: `ollama pull qwen3-coder:30b`
2. Backend-setup: skapa conda-miljö, `mamba install -c conda-forge cadquery`, `pip install -r requirements.txt`, `uvicorn main:app --reload`
3. Frontend-setup: `cd frontend && npm install && npm run dev`
4. Öppna `http://localhost:5173`
5. Exempel-prompts att testa
6. Felsökning: vad göra om Ollama inte svarar, om CadQuery-koden inte kör, etc.

## Säkerhetskrav (viktigt!)

Eftersom vi kör LLM-genererad kod:
- **Aldrig** `exec()` koden i backend-processen — alltid subprocess med timeout
- Validera att den genererade koden inte innehåller strängar som `import os`, `import subprocess`, `open(`, `__import__`, `eval(`, `exec(` (regex-check innan körning, returnera fel om hit)
- Subprocessen körs som samma användare i denna version, men nämn i README att man bör köra i Docker/firejail för produktion
- Sätt resursgränser i subprocessen om möjligt (`resource.setrlimit` för minne/CPU på Linux/Mac)

## Acceptanskriterier

- `uvicorn main:app` startar utan fel
- `npm run dev` startar Vite-servern
- Prompt "en kub 20×20×20 mm med ett cylindriskt hål med diameter 10 mm rakt igenom" genererar en STL som visas i 3D-viewern och kan laddas ner
- Om Ollama inte är igång: tydligt felmeddelande i frontend, inte en kraschad backend
- Om modellen genererar trasig kod: felet visas i frontend tillsammans med koden, så användaren kan justera prompten

## Bonusfunktioner (gör om tid finns)

- "Iterate"-knapp: skicka tillbaka kod + felmeddelande till modellen för en ny tagning
- Historik över tidigare genereringar (i localStorage)
- Justerbar `temperature` för Ollama-anropet
- Stöd för flera modeller (dropdown)