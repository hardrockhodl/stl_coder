# STL Generator

Beskriv ett 3D-objekt i text. En lokal LLM (qwen3-coder:30b via Ollama) skriver
CadQuery-kod, koden körs i en sandbox och du får en STL-fil tillbaka.

## Snabbstart

```bash
./INSTALL.sh   # sätter upp venv, installerar Python- och npm-beroenden, kollar Ollama
./RUN.sh       # startar backend (8000) och frontend (5173), Ctrl-C stänger båda
```

Öppna sedan http://localhost:5173.

Behöver du sätta upp manuellt — eller vill veta exakt vad scripten gör — läs
vidare.

## Förkrav

- **Python 3.10, 3.11 eller 3.12** (CadQuery saknar wheels för 3.13/3.14 på PyPI)
- **Node 20+**
- **Ollama** installerat och igång — https://ollama.com
- Modellen hämtad: `ollama pull qwen3-coder:30b`

## Backend-setup (manuellt)

Med en vanlig pip-venv (Python 3.10–3.12):

```bash
cd backend
python3.11 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
uvicorn main:app --reload --port 8000
```

Alternativt med conda/mamba:

```bash
mamba create -n stlgen python=3.11 -c conda-forge -y
mamba activate stlgen
mamba install -c conda-forge cadquery -y
pip install -r backend/requirements.txt
uvicorn main:app --reload --port 8000
```

Backend lyssnar nu på `http://localhost:8000`.

## Frontend-setup

```bash
cd frontend
npm install
npm run dev
```

Öppna `http://localhost:5173`.

Vite proxy:ar `/api` → `http://localhost:8000`, så frontend och backend
talar utan CORS-strul under utveckling.

## Användning

1. Skriv in en beskrivning, t.ex.:
   - `en kub 20×20×20 mm med ett cylindriskt hål med diameter 10 mm rakt igenom`
   - `en tandkrämshållare med tre fack, 8 cm hög`
   - `en enkel kaffemugg, 8 cm hög, 7 cm diameter, med ett handtag`
   - `en hexagonal mutter M10 med standardgängprofil-clearance`
2. Klicka "Generera" (eller `⌘/Ctrl+Enter`).
3. Vänta — modellen genererar kod, sandboxen kör den, STL-filen visas i 3D.
4. Klicka "Ladda ner STL" för att spara filen.

Den genererade Python-koden visas under previewen så du kan se vad modellen
gjorde och justera prompten om resultatet inte stämmer.

## Säkerhet

Eftersom backend kör LLM-genererad kod gäller följande:

- Genererad kod körs **alltid** i en separat subprocess med 30s timeout —
  aldrig `exec()` i FastAPI-processen.
- En regex-validator blockerar misstänkta mönster (`import os`,
  `import subprocess`, `open(`, `exec(`, `eval(`, `__import__`, m.fl.) före
  körning.
- I subprocessen sätts `RLIMIT_AS` (1 GiB) och `RLIMIT_CPU` (60 s) på
  POSIX-system.

**För produktion: kör backend i en sandboxad container.** Lägg t.ex.
backend i en Docker-container utan nätverk och med en read-only rot, eller
använd `firejail`. Den nuvarande sandboxen är tillräcklig för lokal
hobbyanvändning men inte för en publik tjänst.

## Felsökning

| Symptom | Lösning |
|---|---|
| `Kunde inte ansluta till Ollama` | `ollama serve` körs inte. Starta den, eller se om porten 11434 är upptagen. |
| `model 'qwen3-coder:30b' not found` | Kör `ollama pull qwen3-coder:30b`. |
| `Ollama svarade inte inom timeout (10 min)` | Modellen har förmodligen hängt sig — `pkill ollama && ollama serve`, vänta 30 s, försök igen. Se även "Tips: håll modellen varm" nedan. |
| `ModuleNotFoundError: No module named 'cadquery'` | CadQuery är inte installerat i den python som uvicorn körs med. Installera via conda/mamba (se Backend-setup). |
| `Genererad kod innehåller en otillåten konstruktion` | Modellen försökte importera något förbjudet. Justera prompten eller modellens temperature. |
| `Variabeln 'result' saknas` | Modellen följde inte system-prompten. Försök igen — eventuellt sänk `temperature`. |
| `Kodexekvering tog längre än 30 sekunder` | Komplext objekt eller oändlig loop. Förenkla prompten. |
| 3D-vyn visar ingenting | Öppna devtools-konsolen — STL kan vara tom. Kolla att backend returnerade en korrekt STL. |

### Tips: håll modellen varm

`qwen3-coder:30b` tar ~60–120 s att ladda in i minnet första gången. Ollama
unloadar modeller efter 5 minuters inaktivitet som default. För att slippa
cold loads, starta Ollama med:

```bash
OLLAMA_KEEP_ALIVE=-1 ollama serve
```

Då stannar modellen i minnet tills du stänger Ollama. Använder ~18 GB RAM
permanent — värt det om du genererar ofta.

Backenden gör två saker som hjälper utan environment-variabeln:

1. Skickar `keep_alive: 30m` i varje request
2. Triggar en bakgrundsmässig "warmup" mot Ollama vid uvicorn-uppstart, så
   modellen ofta är inladdad innan första prompten kommer in

`OLLAMA_KEEP_ALIVE=-1` är ändå säkrast.

## Endpoints (för API-tester)

```bash
curl http://localhost:8000/api/health
# → {"status":"ok"}

curl -X POST http://localhost:8000/api/generate \
  -H 'Content-Type: application/json' \
  -d '{"prompt":"a 20mm cube with a 10mm hole","temperature":0.2}'
# → {"job_id":"...","code":"...","stl_url":"/api/stl/..."}

curl -O http://localhost:8000/api/stl/<job_id>
```

## Bonusfunktioner

- Justerbar temperature: implementerat (input i UI)
- Modell-väljare: stöds av API:et (`model` i request-body) — inget UI ännu
- Iterate-knapp: ej implementerad
- Historik i localStorage: ej implementerad
