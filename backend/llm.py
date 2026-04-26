import asyncio
import json
import re

import httpx

from prompts import SYSTEM_PROMPT

OLLAMA_URL = "http://localhost:11434/api/chat"
KEEP_ALIVE = "30m"

# Registry of available models. Keys are the user-facing IDs sent from the
# frontend; values are the actual Ollama model strings + metadata.
MODELS = {
    "quality": {
        "ollama_name": "qwen2.5-coder:32b-instruct-q4_K_S",
        "label": "Quality (32B)",
        "description": "~15-30s. Better CadQuery idioms. Use for new models.",
    },
    "fast": {
        "ollama_name": "qwen2.5-coder:14b-instruct-q6_K",
        "label": "Fast (14B)",
        "description": "~5-10s. Good for tweaking existing models, weaker for new ones.",
    },
}

DEFAULT_MODEL_ID = "quality"


class LLMError(Exception):
    pass


def resolve_model(model_id: str | None) -> str:
    """Map user-facing model ID to actual Ollama model name."""
    if not model_id:
        model_id = DEFAULT_MODEL_ID
    if model_id not in MODELS:
        raise LLMError(
            f"Unknown model: '{model_id}'. Choose one of: {list(MODELS.keys())}"
        )
    return MODELS[model_id]["ollama_name"]


def _strip_code_fences(text: str) -> str:
    """Fallback: extract first fenced code block if model ignores schema."""
    text = text.strip()
    m = re.search(r"```(?:python|py)?\s*\n(.*?)```", text, re.DOTALL)
    if m:
        return m.group(1).strip()
    return text


async def generate_code(
    prompt: str,
    model_id: str | None = None,
    temperature: float = 0.2,
    research_context: str = "",
) -> str:
    model = resolve_model(model_id)

    system = SYSTEM_PROMPT
    if research_context:
        system = (
            f"{SYSTEM_PROMPT}\n\n"
            f"# Reference data for this request\n\n"
            f"{research_context}"
        )

    payload = {
        "model": model,
        "messages": [
            {"role": "system", "content": system},
            {"role": "user", "content": prompt},
        ],
        "stream": False,
        "keep_alive": KEEP_ALIVE,
        "format": {
            "type": "object",
            "properties": {
                "code": {
                    "type": "string",
                    "description": (
                        "Executable Python code using CadQuery. "
                        "Must define a variable named 'result'."
                    ),
                },
            },
            "required": ["code"],
        },
        "options": {"temperature": temperature},
    }

    timeout = httpx.Timeout(connect=5.0, read=600.0, write=10.0, pool=5.0)
    response = None
    for attempt in range(3):
        try:
            async with httpx.AsyncClient(timeout=timeout) as client:
                response = await client.post(OLLAMA_URL, json=payload)
            break
        except httpx.ConnectError as e:
            raise LLMError(
                f"Could not connect to Ollama at {OLLAMA_URL}. "
                f"Start Ollama with 'ollama serve' and run 'ollama pull {model}'."
            ) from e
        except httpx.TimeoutException as e:
            raise LLMError(
                "Ollama did not respond within timeout (10 min). The model may have "
                "hung. Try 'pkill ollama && ollama serve'."
            ) from e
        except (httpx.ReadError, httpx.RemoteProtocolError) as e:
            if attempt == 2:
                raise LLMError(
                    f"Network error to Ollama after 3 attempts: {e}"
                ) from e
            await asyncio.sleep(2 ** attempt)

    if response is None or response.status_code != 200:
        status = response.status_code if response else "no response"
        body = response.text[:300] if response else ""
        raise LLMError(f"Ollama returned HTTP {status}: {body}")

    data = response.json()
    raw = data.get("message", {}).get("content", "")
    if not raw:
        raise LLMError("Empty response from Ollama.")

    # Structured output returns JSON in the content field — parse it.
    try:
        parsed = json.loads(raw)
        code = parsed.get("code", "").strip()
    except json.JSONDecodeError:
        # Fallback: the model didn't honor the schema (older Ollama versions)
        code = _strip_code_fences(raw)

    if not code:
        raise LLMError("No code in response from Ollama.")

    return code


async def iterate_code(
    previous_code: str,
    instruction: str,
    model_id: str | None = None,
    temperature: float = 0.2,
) -> str:
    """Refine an existing CadQuery script based on user feedback."""
    from prompts import ITERATE_PROMPT  # local import to avoid circular if any

    model = resolve_model(model_id)

    user_message = (
        f"Previous code:\n{previous_code}\n\n"
        f"Change request: {instruction}"
    )

    payload = {
        "model": model,
        "messages": [
            {"role": "system", "content": ITERATE_PROMPT},
            {"role": "user", "content": user_message},
        ],
        "stream": False,
        "keep_alive": KEEP_ALIVE,
        "format": {
            "type": "object",
            "properties": {
                "code": {
                    "type": "string",
                    "description": (
                        "Updated executable Python code using CadQuery. "
                        "Must define a variable named 'result'."
                    ),
                },
            },
            "required": ["code"],
        },
        "options": {"temperature": temperature},
    }

    timeout = httpx.Timeout(connect=5.0, read=600.0, write=10.0, pool=5.0)
    response = None
    for attempt in range(3):
        try:
            async with httpx.AsyncClient(timeout=timeout) as client:
                response = await client.post(OLLAMA_URL, json=payload)
            break
        except httpx.ConnectError as e:
            raise LLMError(
                f"Could not connect to Ollama at {OLLAMA_URL}."
            ) from e
        except httpx.TimeoutException as e:
            raise LLMError(
                "Ollama did not respond within timeout (10 min)."
            ) from e
        except (httpx.ReadError, httpx.RemoteProtocolError) as e:
            if attempt == 2:
                raise LLMError(
                    f"Network error to Ollama after 3 attempts: {e}"
                ) from e
            await asyncio.sleep(2 ** attempt)

    if response is None or response.status_code != 200:
        status = response.status_code if response else "no response"
        body = response.text[:300] if response else ""
        raise LLMError(f"Ollama returned HTTP {status}: {body}")

    data = response.json()
    raw = data.get("message", {}).get("content", "")
    if not raw:
        raise LLMError("Empty response from Ollama.")

    try:
        parsed = json.loads(raw)
        code = parsed.get("code", "").strip()
    except json.JSONDecodeError:
        code = _strip_code_fences(raw)

    if not code:
        raise LLMError("No code in response from Ollama.")

    return code


async def repair_code(
    broken_code: str,
    error_message: str,
    model_id: str | None = None,
    temperature: float = 0.2,
) -> str:
    """Ask the model to fix code that failed to execute."""
    from prompts import REPAIR_PROMPT

    model = resolve_model(model_id)

    user_message = (
        f"Broken code:\n{broken_code}\n\n"
        f"Error: {error_message}"
    )

    payload = {
        "model": model,
        "messages": [
            {"role": "system", "content": REPAIR_PROMPT},
            {"role": "user", "content": user_message},
        ],
        "stream": False,
        "keep_alive": KEEP_ALIVE,
        "format": {
            "type": "object",
            "properties": {
                "code": {
                    "type": "string",
                    "description": (
                        "Corrected executable Python code using CadQuery."
                    ),
                },
            },
            "required": ["code"],
        },
        "options": {"temperature": temperature},
    }

    timeout = httpx.Timeout(connect=5.0, read=600.0, write=10.0, pool=5.0)
    response = None
    for attempt in range(3):
        try:
            async with httpx.AsyncClient(timeout=timeout) as client:
                response = await client.post(OLLAMA_URL, json=payload)
            break
        except httpx.ConnectError as e:
            raise LLMError(
                f"Could not connect to Ollama at {OLLAMA_URL}."
            ) from e
        except httpx.TimeoutException as e:
            raise LLMError(
                "Ollama did not respond within timeout (10 min)."
            ) from e
        except (httpx.ReadError, httpx.RemoteProtocolError) as e:
            if attempt == 2:
                raise LLMError(
                    f"Network error to Ollama after 3 attempts: {e}"
                ) from e
            await asyncio.sleep(2 ** attempt)

    if response is None or response.status_code != 200:
        status = response.status_code if response else "no response"
        body = response.text[:300] if response else ""
        raise LLMError(f"Ollama returned HTTP {status}: {body}")

    data = response.json()
    raw = data.get("message", {}).get("content", "")
    if not raw:
        raise LLMError("Empty response from Ollama.")

    try:
        parsed = json.loads(raw)
        code = parsed.get("code", "").strip()
    except json.JSONDecodeError:
        code = _strip_code_fences(raw)

    if not code:
        raise LLMError("No code in response from Ollama.")

    return code


async def warmup(model_id: str | None = None) -> bool:
    """Trigger model load without generating. True if Ollama responded."""
    model = resolve_model(model_id)
    payload = {
        "model": model,
        "messages": [{"role": "user", "content": ""}],
        "stream": False,
        "keep_alive": KEEP_ALIVE,
    }
    try:
        timeout = httpx.Timeout(connect=5.0, read=300.0, write=10.0, pool=5.0)
        async with httpx.AsyncClient(timeout=timeout) as client:
            r = await client.post(OLLAMA_URL, json=payload)
        return r.status_code == 200
    except Exception:
        return False
