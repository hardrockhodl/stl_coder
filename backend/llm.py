import asyncio
import re

import httpx

from prompts import SYSTEM_PROMPT

OLLAMA_URL = "http://localhost:11434/api/generate"
DEFAULT_MODEL = "qwen3-coder:30b"
KEEP_ALIVE = "30m"  # håll modellen i RAM 30 min efter senaste request


class LLMError(Exception):
    pass


def _strip_code_fences(text: str) -> str:
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
        "prompt": prompt,
        "system": SYSTEM_PROMPT,
        "stream": False,
        "keep_alive": KEEP_ALIVE,
        "options": {"temperature": temperature},
    }

    response = None
    last_exc: Exception | None = None
    for attempt in range(3):
        try:
            timeout = httpx.Timeout(connect=5.0, read=600.0, write=10.0, pool=5.0)
            async with httpx.AsyncClient(timeout=timeout) as client:
                response = await client.post(OLLAMA_URL, json=payload)
            break
        except httpx.ConnectError as e:
            raise LLMError(
                f"Kunde inte ansluta till Ollama på {OLLAMA_URL}. "
                f"Starta Ollama med 'ollama serve' och kör 'ollama pull {model}'."
            ) from e
        except httpx.TimeoutException as e:
            raise LLMError(
                "Ollama svarade inte inom timeout (10 min). Modellen kan ha "
                "hängt sig. Testa 'pkill ollama && ollama serve' i en terminal."
            ) from e
        except (httpx.ReadError, httpx.RemoteProtocolError) as e:
            last_exc = e
            if attempt == 2:
                raise LLMError(
                    f"Nätverksfel mot Ollama efter 3 försök: {e}"
                ) from e
            await asyncio.sleep(2 ** attempt)

    assert response is not None  # loop antingen breakar eller raise:ar

    if response.status_code != 200:
        raise LLMError(
            f"Ollama returnerade HTTP {response.status_code}: {response.text[:300]}"
        )

    data = response.json()
    raw = data.get("response", "")
    if not raw:
        raise LLMError("Tomt svar från Ollama.")

    return _strip_code_fences(raw)


async def warmup(model: str = DEFAULT_MODEL) -> bool:
    """Trigger model load utan att generera. True om Ollama svarade."""
    payload = {
        "model": model,
        "prompt": "",
        "keep_alive": KEEP_ALIVE,
    }
    try:
        timeout = httpx.Timeout(connect=5.0, read=300.0, write=10.0, pool=5.0)
        async with httpx.AsyncClient(timeout=timeout) as client:
            r = await client.post(OLLAMA_URL, json=payload)
        return r.status_code == 200
    except Exception:
        return False
