import { useEffect, useRef, useState } from "react";
import hljs from "highlight.js/lib/core";
import python from "highlight.js/lib/languages/python";
import StlViewer from "./StlViewer.jsx";
import ThemeToggle from "./ThemeToggle.jsx";

hljs.registerLanguage("python", python);

const LOADING_MESSAGES = [
  "Weaving magic...",
  "Conjuring geometry...",
  "Folding pixels into polygons...",
];

export default function App() {
  const [prompt, setPrompt] = useState("");
  const [temperature, setTemperature] = useState(0.2);
  const [loading, setLoading] = useState(false);
  const [loadingMsg, setLoadingMsg] = useState(LOADING_MESSAGES[0]);
  const [elapsed, setElapsed] = useState(0);
  const [error, setError] = useState(null);
  const [result, setResult] = useState(null);
  const [showCode, setShowCode] = useState(true);
  const codeRef = useRef(null);

  useEffect(() => {
    if (codeRef.current && result?.code && showCode) {
      codeRef.current.removeAttribute("data-highlighted");
      hljs.highlightElement(codeRef.current);
    }
  }, [result, showCode]);

  useEffect(() => {
    if (!loading) return;
    let i = 0;
    setLoadingMsg(LOADING_MESSAGES[0]);
    const id = setInterval(() => {
      i = (i + 1) % LOADING_MESSAGES.length;
      setLoadingMsg(LOADING_MESSAGES[i]);
    }, 2200);
    return () => clearInterval(id);
  }, [loading]);

  useEffect(() => {
    if (!loading) {
      setElapsed(0);
      return;
    }
    const start = Date.now();
    const id = setInterval(() => {
      setElapsed(Math.floor((Date.now() - start) / 1000));
    }, 250);
    return () => clearInterval(id);
  }, [loading]);

  const submit = async () => {
    if (!prompt.trim() || loading) return;
    setLoading(true);
    setError(null);
    setResult(null);
    try {
      const res = await fetch("/api/generate", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ prompt, temperature }),
      });
      const data = await res.json().catch(() => ({}));
      if (!res.ok) {
        const detail = data.detail;
        if (detail && typeof detail === "object" && detail.code) {
          setError(detail.message || "Something went sideways.");
          setResult({ code: detail.code, stl_url: null, job_id: null });
        } else {
          setError(typeof detail === "string" ? detail : `HTTP ${res.status}`);
        }
        return;
      }
      setResult(data);
    } catch (e) {
      setError(`Network error: ${e.message}`);
    } finally {
      setLoading(false);
    }
  };

  const onKeyDown = (e) => {
    if ((e.metaKey || e.ctrlKey) && e.key === "Enter") submit();
  };

  return (
    <div className="app">
      <ThemeToggle />
      <header className="header">
        <h1 className="wordmark">Unicorn Creative Magic</h1>
        <p className="tagline">Conjure 3D models from pure imagination</p>
        <div className="divider" />
      </header>

      <section className="card cloud-card">
        <label htmlFor="prompt" className="field-label">
          Describe what you want to create
        </label>
        <textarea
          id="prompt"
          className={`prompt${loading ? " shimmer" : ""}`}
          placeholder="A toothbrush holder with three compartments, 8 cm tall"
          value={prompt}
          onChange={(e) => setPrompt(e.target.value)}
          onKeyDown={onKeyDown}
          disabled={loading}
        />
        <div className="controls">
          <button
            className="btn-primary"
            onClick={submit}
            disabled={loading || !prompt.trim()}
          >
            {loading ? (
              <>
                <span className="pulse" />
                {loadingMsg}
                <span style={{ marginLeft: 10, opacity: 0.7, fontSize: 13 }}>
                  {elapsed}s
                </span>
              </>
            ) : (
              <>
                <span className="star" aria-hidden="true">
                  &#x2726;
                </span>
                Generate
              </>
            )}
          </button>
          <label>
            Temperature
            <input
              type="number"
              min="0"
              max="2"
              step="0.1"
              value={temperature}
              onChange={(e) => setTemperature(parseFloat(e.target.value) || 0)}
              disabled={loading}
            />
          </label>
          <span style={{ color: "var(--uc-text-soft)", fontSize: 13 }}>
            Tip: Cmd / Ctrl + Enter
          </span>
        </div>
      </section>

      {loading && elapsed > 30 && (
        <div
          style={{
            marginTop: 12,
            fontSize: 13,
            color: "var(--uc-text-soft)",
            textAlign: "center",
          }}
        >
          First request after Ollama restart takes longer — the 30B model is
          loading into memory. Subsequent requests are fast.
        </div>
      )}

      {error && (
        <div className="error">
          <div className="error-title">Something went sideways</div>
          {error}
        </div>
      )}

      {result?.stl_url && (
        <section className="card">
          <div className="card-header">
            <h2>3D preview</h2>
          </div>
          <div className="viewer-wrap">
            <StlViewer url={result.stl_url} />
          </div>
          <div className="viewer-actions">
            <a className="download-btn" href={result.stl_url} download>
              Download STL
            </a>
          </div>
        </section>
      )}

      {result?.code && (
        <section className="card">
          <div className="card-header">
            <h2>Generated CadQuery code</h2>
            <button
              className="code-toggle"
              onClick={() => setShowCode((v) => !v)}
            >
              {showCode ? "Hide generated code" : "Show generated code"}
            </button>
          </div>
          {showCode && (
            <pre className="code-block">
              <code ref={codeRef} className="language-python">
                {result.code}
              </code>
            </pre>
          )}
        </section>
      )}
    </div>
  );
}
