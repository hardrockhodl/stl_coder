"""Wikipedia-based design research.

Looks up real-world dimensions and proportions for objects mentioned in
the user's prompt, so the coder model has accurate reference data when
generating CadQuery code.

Why Wikipedia: zero auth, generous rate limits, structured article text,
permissive license (CC BY-SA). Limitation: only works for objects with
Wikipedia articles. For your friend's homemade widget, research returns
nothing and the model falls back to guessing — same as before.
"""
import asyncio
import re
from dataclasses import dataclass

try:
    import wikipediaapi
except ImportError:
    wikipediaapi = None


# Polite User-Agent per Wikimedia policy. Anonymous requests get rate-limited
# more aggressively, so always identify the project.
USER_AGENT = "UnicornCreativeMagic/1.0 (https://github.com/your-repo; STL generator)"

MAX_EXTRACT_CHARS = 2000   # cap how much article text we pass to the model
MAX_CANDIDATES = 3         # try up to N search results before giving up


@dataclass
class ResearchResult:
    used: bool                    # True if we found and returned an article
    context: str                  # Text to inject into the system prompt
    source_title: str | None      # Wikipedia article title used
    source_url: str | None        # Article URL (for logging/debug)
    error: str | None = None      # Non-fatal error message


# Singleton wiki client
_wiki = None


def _get_wiki():
    global _wiki
    if _wiki is not None:
        return _wiki
    if wikipediaapi is None:
        return None
    _wiki = wikipediaapi.Wikipedia(
        user_agent=USER_AGENT,
        language="en",
        extract_format=wikipediaapi.ExtractFormat.WIKI,
    )
    return _wiki


# Generic geometric vocabulary — if the prompt is mostly these words, skip
# the Wikipedia lookup. False positives just cost a free API call;
# false negatives cost us the whole point of the feature. Tuned to be
# inclusive (skip aggressively only when prompt is OBVIOUSLY abstract).
_GENERIC_TERMS = {
    "cube", "box", "cylinder", "sphere", "cone", "ring", "disc", "disk",
    "prism", "pyramid", "torus", "rectangle", "square", "circle", "shape",
    "thing", "object", "model", "block", "plate", "rod", "bar", "tube",
    "with", "and", "the", "a", "an", "of", "for", "in", "on", "at",
    "mm", "cm", "m", "tall", "wide", "long", "deep", "high", "thick",
    "diameter", "radius", "hole", "holes", "compartment", "compartments",
    "wall", "edge", "corner", "rounded", "sharp", "small", "large",
    "tiny", "big", "simple", "basic",
}


# Letter-start identifier OR a standalone digit run (with no adjacent
# word char). Lookbehind/lookahead make sure dimension digits like "30mm"
# don't match — "30" is dropped because "m" follows. Standalone digits
# like model numbers in "Volvo 240" survive.
_TOKEN_RE = re.compile(
    r"[a-zA-Z][a-zA-Z0-9]*|(?<![a-zA-Z0-9])\d+(?![a-zA-Z0-9])"
)


def _looks_abstract(prompt: str) -> bool:
    """Return True if the prompt has no real-world object to look up."""
    words = re.findall(r"[a-zA-Z]+", prompt.lower())
    content_words = {w for w in words if len(w) > 1 and w not in _GENERIC_TERMS}
    return len(content_words) < 1


def _extract_search_terms(prompt: str) -> str:
    """Pull the 'noun phrase' part of the prompt to feed Wikipedia search.

    Heuristic: take the first ~6 content tokens after stripping generic
    terms and dimension digits. Good enough for prompts like:
      "a Volvo 240 toy car, 100mm long" → "Volvo 240 toy car"
      "an iPhone 15 case with MagSafe cutout" → "iPhone 15 case MagSafe cutout"
    """
    tokens = _TOKEN_RE.findall(prompt)
    content = [t for t in tokens if t.lower() not in _GENERIC_TERMS]
    return " ".join(content[:6])


def _truncate(text: str, limit: int) -> str:
    if len(text) <= limit:
        return text
    # Cut at last sentence boundary before the limit
    cut = text[:limit].rsplit(".", 1)[0]
    if len(cut) < limit * 0.5:
        # No sentence boundary nearby — hard cut
        cut = text[:limit]
    return cut.rstrip() + "..."


def _do_research_sync(prompt: str) -> ResearchResult:
    """Synchronous research — runs in a thread via asyncio.to_thread."""
    if _looks_abstract(prompt):
        return ResearchResult(used=False, context="", source_title=None, source_url=None)

    wiki = _get_wiki()
    if wiki is None:
        return ResearchResult(
            used=False, context="", source_title=None, source_url=None,
            error="wikipedia-api not installed",
        )

    query = _extract_search_terms(prompt)
    if not query:
        return ResearchResult(used=False, context="", source_title=None, source_url=None)

    try:
        # Search returns a SearchResults whose .pages is a dict-like mapping
        # title -> WikipediaPage, ranked by relevance.
        candidates = wiki.search(query, limit=MAX_CANDIDATES)
    except Exception as e:
        return ResearchResult(
            used=False, context="", source_title=None, source_url=None,
            error=f"Wikipedia search failed: {e}",
        )

    pages_dict = getattr(candidates, "pages", None)
    if not pages_dict:
        return ResearchResult(used=False, context="", source_title=None, source_url=None)

    # Try candidates in order, return the first one that exists and has
    # substantive content
    for title in pages_dict:
        page = pages_dict[title]
        try:
            if not page.exists():
                continue
            summary = page.summary
            if not summary or len(summary) < 100:
                continue
        except Exception:
            continue

        context = (
            "Real-world reference data from Wikipedia "
            "(use these dimensions and proportions, scaled appropriately):\n\n"
            f"Article: {page.title}\n\n"
            f"{_truncate(summary, MAX_EXTRACT_CHARS)}"
        )

        return ResearchResult(
            used=True,
            context=context,
            source_title=page.title,
            source_url=page.fullurl,
        )

    return ResearchResult(used=False, context="", source_title=None, source_url=None)


async def research(prompt: str) -> ResearchResult:
    """Async wrapper. Always returns — never raises."""
    try:
        return await asyncio.to_thread(_do_research_sync, prompt)
    except Exception as e:
        return ResearchResult(
            used=False, context="", source_title=None, source_url=None,
            error=f"Research thread crashed: {e}",
        )
