import asyncio
import json
import re

import httpx

from prompts import SYSTEM_PROMPT

OLLAMA_URL = "http://localhost:11434/api/chat"
DEFAULT_MODEL = "qwen2.5-coder:32b-instruct-q4_K_S"
KEEP_ALIVE = "30m"


class LLMError(Exception):
    pass


def _strip_code_fences(text: str) -> str:
    """Fallback: extract first fenced code block if model ignores schema."""
    text = text.strip()
    m = re.search(r"```(?:python|py)?\s*\n(.*?)```", text, re.DOTALL)
    if m:
        return m.group(1).strip()
    return text


async def generate_code(
    prompt: str,
    model: str = DEFAULT_MODEL,
    temperature: float = 0.2,
) -> str:
    payload = {
        "model": model,
        "messages": [
            {"role": "system", "content": SYSTEM_PROMPT},
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
                f"Start Ollama with 'ollama serve' and run "
                f"'ollama pull {model}'."
            ) from e
        except httpx.TimeoutException as e:
            raise LLMError(
                "Ollama did not respond within the timeout (10 min). The model "
                "may have hung. Try 'pkill ollama && ollama serve'."
            ) from e
        except (httpx.ReadError, httpx.RemoteProtocolError) as e:
            if attempt == 2:
                raise LLMError(
                    f"Network error talking to Ollama after 3 attempts: {e}"
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
        raise LLMError("No code in the response from Ollama.")

    return code


async def warmup(model: str = DEFAULT_MODEL) -> bool:
    """Trigger model load without generating. True if Ollama responded."""
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
