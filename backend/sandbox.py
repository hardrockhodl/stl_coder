import re
import subprocess
import sys
import tempfile
import textwrap
from pathlib import Path

DEFAULT_TIMEOUT = 30

FORBIDDEN_PATTERNS = [
    r"\bimport\s+os\b",
    r"\bimport\s+sys\b",
    r"\bimport\s+subprocess\b",
    r"\bimport\s+socket\b",
    r"\bimport\s+shutil\b",
    r"\bimport\s+pathlib\b",
    r"\bimport\s+requests\b",
    r"\bimport\s+httpx\b",
    r"\bimport\s+urllib\b",
    r"\bfrom\s+os\b",
    r"\bfrom\s+sys\b",
    r"\bfrom\s+subprocess\b",
    r"\bfrom\s+pathlib\b",
    r"\b__import__\s*\(",
    r"\bexec\s*\(",
    r"\beval\s*\(",
    r"\bcompile\s*\(",
    r"\bopen\s*\(",
    r"\bglobals\s*\(",
    r"\blocals\s*\(",
    r"\bgetattr\s*\(",
    r"\bsetattr\s*\(",
]


class SandboxError(Exception):
    pass


def validate_code(code: str) -> None:
    for pattern in FORBIDDEN_PATTERNS:
        if re.search(pattern, code):
            raise SandboxError(
                f"Generated code contains a forbidden construct (matches /{pattern}/). "
                f"This is blocked for security reasons."
            )


RUNNER_TEMPLATE = textwrap.dedent("""
    import sys
    try:
        import resource
        resource.setrlimit(resource.RLIMIT_AS, (1024 * 1024 * 1024, 1024 * 1024 * 1024))
        resource.setrlimit(resource.RLIMIT_CPU, (60, 60))
    except Exception:
        pass

    import cadquery as cq
    import math

    _user_globals = {"cq": cq, "math": math, "__name__": "__sandbox__"}
    _user_code = __USER_CODE__
    _out_path = __OUT_PATH__

    try:
        exec(compile(_user_code, "<user_code>", "exec"), _user_globals)
    except Exception as e:
        sys.stderr.write(f"USER_CODE_ERROR: {type(e).__name__}: {e}\\n")
        sys.exit(2)

    result = _user_globals.get("result")
    if result is None:
        sys.stderr.write("USER_CODE_ERROR: Variable 'result' is missing or None.\\n")
        sys.exit(3)

    try:
        cq.exporters.export(result, _out_path)
    except Exception as e:
        sys.stderr.write(f"EXPORT_ERROR: {type(e).__name__}: {e}\\n")
        sys.exit(4)
""")


def run_cadquery(code: str, out_path: Path, timeout: int = DEFAULT_TIMEOUT) -> None:
    validate_code(code)

    out_path = out_path.resolve()
    out_path.parent.mkdir(parents=True, exist_ok=True)

    runner = (
        RUNNER_TEMPLATE
        .replace("__USER_CODE__", repr(code))
        .replace("__OUT_PATH__", repr(str(out_path)))
    )

    with tempfile.TemporaryDirectory() as tmpdir:
        try:
            proc = subprocess.run(
                [sys.executable, "-I", "-c", runner],
                capture_output=True,
                text=True,
                timeout=timeout,
                cwd=tmpdir,
                env={"PATH": "/usr/bin:/bin", "HOME": tmpdir},
            )
        except subprocess.TimeoutExpired as e:
            raise SandboxError(
                f"Code execution took longer than {timeout} seconds and was aborted."
            ) from e

    if proc.returncode != 0:
        stderr = proc.stderr.strip() or proc.stdout.strip() or "Unknown error"
        raise SandboxError(f"Code execution failed:\n{stderr}")

    if not out_path.exists() or out_path.stat().st_size == 0:
        raise SandboxError("No STL file was produced.")
