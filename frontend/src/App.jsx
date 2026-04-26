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

const EXAMPLE_PROMPTS = [
  "a toothbrush holder for 4 toothbrushes, cylindrical 60mm diameter, 100mm tall, with 16mm holes evenly spaced in a circle 5mm from the top, 3mm walls",
  "a parts tray, 120 × 80 × 25mm, divided into 6 compartments (3 × 2 grid), 2mm walls, 1.5mm floor, rounded outer corners 4mm radius",
  "a wall-mount hook: rectangular back plate 40 × 80 × 5mm with two 4mm screw holes 50mm apart, hook arm extending 60mm forward and curving up 30mm",
  "a soap dish, oval 110 × 70 × 25mm, recessed pocket 90 × 50 × 15mm, four 4mm drainage holes in the bottom",
];

const PLACEHOLDER_PROMPTS = [
  "A toothbrush holder for 4 toothbrushes...",
  "A parts tray with 6 compartments...",
  "A wall-mount hook with two screw holes...",
  "A soap dish with drainage holes...",
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
  const [models, setModels] = useState([]);
  const [selectedModel, setSelectedModel] = useState(null);
  const [iterateInstruction, setIterateInstruction] = useState("");
  const [iterating, setIterating] = useState(false);
  const [history, setHistory] = useState([]);
  const [currentStep, setCurrentStep] = useState(null);
  const [clarification, setClarification] = useState(null);
  const [placeholderIndex, setPlaceholderIndex] = useState(0);
  const codeRef = useRef(null);

  useEffect(() => {
    if (prompt.trim()) return; // pause rotation while user is typing
    const id = setInterval(() => {
      setPlaceholderIndex((i) => (i + 1) % PLACEHOLDER_PROMPTS.length);
    }, 4000);
    return () => clearInterval(id);
  }, [prompt]);

  useEffect(() => {
    fetch("/api/models")
      .then((r) => r.json())
      .then((data) => {
        setModels(data.models);
        setSelectedModel(data.default);
      })
      .catch((e) => console.error("Failed to load models:", e));
  }, []);

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
    setClarification(null);
    setResult(null);
    try {
      const res = await fetch("/api/generate", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          prompt,
          temperature,
          model: selectedModel,
        }),
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
      if (data.clarification) {
        setClarification(data.clarification);
        return;
      }
      setClarification(null);
      setResult(data);
      setHistory((h) => {
        const next = [
          ...h,
          {
            instruction: prompt,
            code: data.code,
            stl_url: data.stl_url,
            job_id: data.job_id,
          },
        ];
        setCurrentStep(next.length - 1);
        return next;
      });
    } catch (e) {
      setError(`Network error: ${e.message}`);
    } finally {
      setLoading(false);
    }
  };

  const iterate = async () => {
    if (!iterateInstruction.trim() || iterating || !result?.code) return;
    setIterating(true);
    setError(null);
    try {
      const res = await fetch("/api/iterate", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          previous_code: history[currentStep]?.code || result.code,
          instruction: iterateInstruction,
          temperature,
          model: selectedModel,
        }),
      });
      const data = await res.json().catch(() => ({}));
      if (!res.ok) {
        const detail = data.detail;
        if (detail && typeof detail === "object" && detail.code) {
          setError(detail.message || "Iteration failed.");
          setResult({ code: detail.code, stl_url: null, job_id: null });
        } else {
          setError(typeof detail === "string" ? detail : `HTTP ${res.status}`);
        }
        return;
      }
      setResult(data);
      setHistory((h) => {
        const next = [
          ...h,
          {
            instruction: iterateInstruction,
            code: data.code,
            stl_url: data.stl_url,
            job_id: data.job_id,
          },
        ];
        setCurrentStep(next.length - 1);
        return next;
      });
      setIterateInstruction("");
    } catch (e) {
      setError(`Network error: ${e.message}`);
    } finally {
      setIterating(false);
    }
  };

  const revertTo = (index) => {
    const step = history[index];
    if (!step) return;
    setResult({
      code: step.code,
      stl_url: step.stl_url,
      job_id: step.job_id,
    });
    setCurrentStep(index);
    setError(null);
  };

  const reset = () => {
    setResult(null);
    setError(null);
    setHistory([]);
    setIterateInstruction("");
    setPrompt("");
    setCurrentStep(null);
    setClarification(null);
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
          placeholder={PLACEHOLDER_PROMPTS[placeholderIndex]}
          value={prompt}
          onChange={(e) => setPrompt(e.target.value)}
          onKeyDown={onKeyDown}
          disabled={loading}
        />
        {!result && (
          <div className="example-chips">
            <span className="example-label">Try:</span>
            {EXAMPLE_PROMPTS.map((ex, i) => (
              <button
                key={i}
                type="button"
                className="example-chip"
                onClick={() => setPrompt(ex)}
                disabled={loading}
                title={ex}
              >
                {ex.split(",")[0].replace(/^a /i, "")}
              </button>
            ))}
          </div>
        )}
        <div className="controls">
          <button
            className="btn-primary"
            onClick={submit}
            disabled={loading || !prompt.trim() || !selectedModel}
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
          <label className="model-picker">
            Model
            <select
              value={selectedModel || ""}
              onChange={(e) => setSelectedModel(e.target.value)}
              disabled={loading || models.length === 0}
            >
              {models.map((m) => (
                <option key={m.id} value={m.id} title={m.description}>
                  {m.label}
                </option>
              ))}
            </select>
          </label>
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

      {clarification && (
        <section className="card clarification-card">
          <div className="clarification-header">
            <span className="clarification-icon" aria-hidden="true">
              ?
            </span>
            <h2>One quick question</h2>
          </div>
          <p className="clarification-question">{clarification}</p>
          <p className="clarification-hint">
            Edit your prompt above with this detail and click Generate again.
          </p>
        </section>
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

      {result?.stl_url && (
        <section className="card iterate-card">
          <div className="card-header">
            <h2>Refine the model</h2>
            <button className="code-toggle" onClick={reset}>
              Start over
            </button>
          </div>
          <div className="iterate-input-row">
            <input
              type="text"
              className="iterate-input"
              placeholder='e.g. "make it 5mm taller" or "add rounded corners"'
              value={iterateInstruction}
              onChange={(e) => setIterateInstruction(e.target.value)}
              onKeyDown={(e) => {
                if (e.key === "Enter") iterate();
              }}
              disabled={iterating}
            />
            <button
              className="btn-primary"
              onClick={iterate}
              disabled={iterating || !iterateInstruction.trim()}
            >
              {iterating ? (
                <>
                  <span className="pulse" />
                  Refining...
                </>
              ) : (
                "Apply change"
              )}
            </button>
          </div>
          {history.length > 0 && (
            <div className="history">
              <div className="history-label">History</div>
              <ol>
                {history.map((h, i) => (
                  <li
                    key={h.job_id || i}
                    className={
                      i === currentStep ? "history-item active" : "history-item"
                    }
                  >
                    <span className="history-text">
                      {i === 0 ? (
                        <span className="history-initial">{h.instruction}</span>
                      ) : (
                        h.instruction
                      )}
                    </span>
                    {i !== currentStep && (
                      <button
                        className="history-revert"
                        onClick={() => revertTo(i)}
                        title={`Revert to step ${i + 1}`}
                        disabled={iterating || loading}
                      >
                        Show
                      </button>
                    )}
                    {i === currentStep && (
                      <span className="history-current" aria-label="current step">
                        current
                      </span>
                    )}
                  </li>
                ))}
              </ol>
            </div>
          )}
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
