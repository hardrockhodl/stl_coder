import asyncio
import re
import time
import uuid
from contextlib import asynccontextmanager
from pathlib import Path

from fastapi import FastAPI, HTTPException
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import FileResponse
from pydantic import BaseModel, Field

from llm import (
    DEFAULT_MODEL_ID,
    MODELS,
    LLMError,
    generate_code,
    iterate_code,
    warmup,
)
from sandbox import SandboxError, run_cadquery

GENERATED_DIR = Path(__file__).parent / "generated"
GENERATED_DIR.mkdir(parents=True, exist_ok=True)

_JOB_ID_RE = re.compile(r"[0-9a-f]{32}")
_gen_semaphore = asyncio.Semaphore(1)


@asynccontextmanager
async def lifespan(app: FastAPI):
    # Only warm up the default model. Loading both 14b + 32b would take
    # ~31 GB resident, which is too much on a 36 GB machine alongside
    # macOS, browser, and dev tooling. The other model cold-loads on
    # first selection (~30-60 s wait once, then cached for `keep_alive`).
    asyncio.create_task(warmup(DEFAULT_MODEL_ID))
    yield


app = FastAPI(title="STL Generator", lifespan=lifespan)

app.add_middleware(
    CORSMiddleware,
    allow_origins=["http://localhost:5173"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)


def _cleanup_old_stls(max_age_seconds: int = 86400) -> None:
    # 24h window so iteration history's revert links don't 404 mid-session.
    # Anything older is fair game — these are LLM-generated parts, not data.
    now = time.time()
    for f in GENERATED_DIR.glob("*.stl"):
        try:
            if now - f.stat().st_mtime > max_age_seconds:
                f.unlink(missing_ok=True)
        except OSError:
            pass


class GenerateRequest(BaseModel):
    prompt: str = Field(..., min_length=1, max_length=4000)
    temperature: float = Field(default=0.2, ge=0.0, le=2.0)
    model: str = Field(default=DEFAULT_MODEL_ID)


class IterateRequest(BaseModel):
    previous_code: str = Field(..., min_length=1, max_length=50_000)
    instruction: str = Field(..., min_length=1, max_length=2000)
    temperature: float = Field(default=0.2, ge=0.0, le=2.0)
    model: str = Field(default=DEFAULT_MODEL_ID)


class GenerateResponse(BaseModel):
    job_id: str
    code: str
    stl_url: str


@app.get("/api/health")
async def health() -> dict:
    return {"status": "ok"}


@app.get("/api/models")
async def list_models() -> dict:
    return {
        "default": DEFAULT_MODEL_ID,
        "models": [
            {
                "id": model_id,
                "label": meta["label"],
                "description": meta["description"],
            }
            for model_id, meta in MODELS.items()
        ],
    }


@app.post("/api/generate", response_model=GenerateResponse)
async def generate(req: GenerateRequest) -> GenerateResponse:
    async with _gen_semaphore:
        _cleanup_old_stls()

        try:
            code = await generate_code(
                req.prompt,
                model_id=req.model,
                temperature=req.temperature,
            )
        except LLMError as e:
            raise HTTPException(status_code=502, detail=str(e))

        job_id = uuid.uuid4().hex
        out_path = GENERATED_DIR / f"{job_id}.stl"

        try:
            run_cadquery(code, out_path)
        except SandboxError as e:
            raise HTTPException(
                status_code=422,
                detail={"message": str(e), "code": code},
            )

        return GenerateResponse(
            job_id=job_id,
            code=code,
            stl_url=f"/api/stl/{job_id}",
        )


@app.post("/api/iterate", response_model=GenerateResponse)
async def iterate(req: IterateRequest) -> GenerateResponse:
    async with _gen_semaphore:
        _cleanup_old_stls()

        try:
            code = await iterate_code(
                req.previous_code,
                req.instruction,
                model_id=req.model,
                temperature=req.temperature,
            )
        except LLMError as e:
            raise HTTPException(status_code=502, detail=str(e))

        job_id = uuid.uuid4().hex
        out_path = GENERATED_DIR / f"{job_id}.stl"

        try:
            run_cadquery(code, out_path)
        except SandboxError as e:
            raise HTTPException(
                status_code=422,
                detail={"message": str(e), "code": code},
            )

        return GenerateResponse(
            job_id=job_id,
            code=code,
            stl_url=f"/api/stl/{job_id}",
        )


@app.get("/api/stl/{job_id}")
async def get_stl(job_id: str) -> FileResponse:
    if not _JOB_ID_RE.fullmatch(job_id):
        raise HTTPException(status_code=400, detail="Invalid job_id")

    path = GENERATED_DIR / f"{job_id}.stl"
    if not path.exists():
        raise HTTPException(status_code=404, detail="STL file not found")

    return FileResponse(
        path,
        media_type="application/sla",
        filename=f"{job_id}.stl",
    )
