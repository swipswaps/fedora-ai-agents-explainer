import React, { useEffect, useMemo, useRef, useState } from 'react';
import { createArchitectureScene } from './architecture.js';
import UsageChart from './UsageChart.jsx';

const API = '/api';
const OPENCODE_INSTALL = 'bash ./install-opencode.sh\nopencode --version\nopencode auth list';
const BUILDER_FETCH = `curl --fail --location --show-error --output build-fedora-ai-agents-explainer.sh https://swipswaps.github.io/fedora-ai-agents-explainer/build-fedora-ai-agents-explainer.sh\nbash -n build-fedora-ai-agents-explainer.sh\nsha256sum build-fedora-ai-agents-explainer.sh\nbash build-fedora-ai-agents-explainer.sh`;
const QUICKSTART = `# Fedora AI Agents — local instance\n# 1. Install prerequisites: Node.js 20.19+ or 22.12+, Docker Engine, Docker Compose plugin, Git, Python 3.11+.\n# 2. Start the local backend from the repository root:\ndocker compose up --build -d\n# 3. Install frontend dependencies and start the local UI:\nnpm ci\nnpm run dev\n# 4. Open http://127.0.0.1:5173/\n# The API is bound to 127.0.0.1:8000; it is not exposed to your LAN.`;

function ArchitectureCanvas() {
  const canvasRef = useRef(null);
  useEffect(() => {
    if (!canvasRef.current) return undefined;
    try { return createArchitectureScene(canvasRef.current); }
    catch (error) { console.error('Three.js visualization unavailable:', error); return undefined; }
  }, []);
  return <canvas className="architecture-canvas" ref={canvasRef} aria-label="Three-dimensional architecture diagram" />;
}

function CopyButton({ value, children = 'Copy' }) {
  const [copied, setCopied] = useState(false);
  async function copy() {
    try {
      await navigator.clipboard.writeText(value);
      setCopied(true);
      window.setTimeout(() => setCopied(false), 1600);
    } catch (error) {
      console.error('Clipboard write failed:', error);
      window.prompt('Copy this text:', value);
    }
  }
  return <button className="button button-small" onClick={copy} type="button">{copied ? 'Copied' : children}</button>;
}

function CodePanel({ title, code, downloadHref }) {
  return <section className="code-panel">
    <div className="code-heading"><strong>{title}</strong><div className="button-row"><CopyButton value={code} /><a className="button button-small" href={downloadHref} download>Download</a></div></div>
    <pre><code>{code}</code></pre>
  </section>;
}

export default function App() {
  const [backend, setBackend] = useState({ state: 'checking', capabilities: null, error: '' });
  const [usage, setUsage] = useState(null);
  const [agents, setAgents] = useState([]);
  const [search, setSearch] = useState('');
  const [searchResults, setSearchResults] = useState([]);
  const [searchMessage, setSearchMessage] = useState('');

  const isPages = window.location.hostname.endsWith('github.io');
  const localInstanceUrl = 'http://127.0.0.1:5173/';

  async function refreshBackend() {
    if (isPages) {
      setBackend({ state: 'static', capabilities: null, error: 'GitHub Pages is static hosting. Open the local instance to discover your loopback Docker backend.' });
      return;
    }
    try {
      const response = await fetch(`${API}/capabilities`, { headers: { Accept: 'application/json' } });
      if (!response.ok) throw new Error(`Backend returned HTTP ${response.status}`);
      const capabilities = await response.json();
      setBackend({ state: 'connected', capabilities, error: '' });
      const [agentResponse, usageResponse] = await Promise.all([
        fetch(`${API}/agents`), fetch(`${API}/usage/summary`),
      ]);
      if (agentResponse.ok) setAgents((await agentResponse.json()).agents || []);
      if (usageResponse.ok) setUsage(await usageResponse.json());
    } catch (error) {
      setBackend({ state: 'offline', capabilities: null, error: error.message });
    }
  }

  useEffect(() => { refreshBackend(); }, []);
  const chartData = useMemo(() => usage?.daily || [], [usage]);

  async function copyHostRefreshCommand() {
    const command = 'bash scripts/refresh_host_snapshot.sh';
    try {
      await navigator.clipboard.writeText(command);
      setSearchMessage('Manual host snapshot command copied. Automatic collection also runs through the systemd user timer every 15 minutes.');
    } catch (error) {
      console.error('Clipboard write failed:', error);
      window.prompt('Copy the host snapshot command:', command);
    }
  }

  async function runSearch(event) {
    event.preventDefault();
    setSearchMessage('');
    try {
      const response = await fetch(`${API}/search`, {
        method: 'POST', headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ query: search, limit: 8 }),
      });
      const result = await response.json();
      if (!response.ok) throw new Error(result.detail || `HTTP ${response.status}`);
      setSearchResults(result.results || []);
      setSearchMessage(`Search mode: ${result.mode}. Results: ${(result.results || []).length}.`);
    } catch (error) { setSearchMessage(`Search unavailable: ${error.message}`); }
  }

  return <main className="shell">
    <header className="topbar">
      <a className="brand" href="#top"><span className="brand-mark">FA</span><span>FEDORA AI AGENTS<small>OMARCHY-INSPIRED / FEDORA-NATIVE</small></span></a>
      <nav><a href="#architecture">Architecture</a><a href="#agents">Agents</a><a href="#database">Data plane</a><a href="#install">Install</a><a href="#references">References</a></nav>
      <span className={`status-pill ${backend.state}`}><i />{backend.state === 'connected' ? 'LOCAL BACKEND ONLINE' : backend.state === 'static' ? 'STATIC PAGES MODE' : backend.state === 'checking' ? 'CHECKING BACKEND' : 'BACKEND NOT DETECTED'}</span>
    </header>

    <section className="hero" id="top">
      <div className="hero-copy">
        <p className="eyebrow">A composable agent control plane for Fedora</p>
        <h1>Your coding agents.<br /><em>One observable workspace.</em></h1>
        <p className="hero-lede">A Fedora-native implementation inspired by Omarchy’s agent workflow: discover installed CLIs, launch them from one place, collect usage through isolated adapters, and query local operational knowledge without sending your agent database to a hosted dashboard.</p>
        <div className="button-row"><a className="button button-primary" href="#install">Get the Fedora installer <span>↗</span></a><a className="button" href="https://github.com/swipswaps/fedora-ai-agents-explainer" target="_blank" rel="noreferrer">View source</a></div>
        <div className="hero-facts"><span>01 / Static explainer</span><span>02 / Local Docker data plane</span><span>03 / OpenCode-first collector</span></div>
      </div>
      <div className="hero-orbit"><div className="orbit orbit-one"/><div className="orbit orbit-two"/><div className="orbit-core"><b>AI</b><span>AGENT<br/>FABRIC</span></div><div className="orbit-node node-a">OP</div><div className="orbit-node node-b">CX</div><div className="orbit-node node-c">CL</div><div className="orbit-node node-d">PI</div></div>
    </section>

    <section className="backend-banner">
      <div><span className="eyebrow">RUNTIME DISCOVERY</span><h2>{backend.state === 'connected' ? 'Local backend detected' : isPages ? 'You are viewing the static explainer' : 'The local backend has not answered yet'}</h2><p>{backend.state === 'connected' ? `SQLite ${backend.capabilities?.sqlite_version || ''} · FTS5 ${backend.capabilities?.fts5 ? 'available' : 'unavailable'} · sqlite-vec ${backend.capabilities?.sqlite_vec ? 'loaded' : 'not loaded'} · host snapshot ${backend.capabilities?.host_snapshot_at ? 'received' : 'waiting'} · OpenCode ${backend.capabilities?.opencode_status || 'unknown'} · ${backend.capabilities?.opencode_aggregation_basis || 'no usage basis'} ${backend.capabilities?.opencode_error || ''}` : backend.error || 'Start Docker Compose and the local Vite server to enable runtime discovery.'}</p></div>
      <div className="button-row"><button className="button button-small" onClick={refreshBackend}>Recheck</button>{isPages && <a className="button button-primary button-small" href={localInstanceUrl}>Open local instance ↗</a>}</div>
    </section>

    <section className="section" id="architecture">
      <div className="section-heading"><div><p className="eyebrow">01 / SYSTEM TOPOLOGY</p><h2>Separate the control plane from the data plane.</h2></div><p>Agents execute as user-owned processes. Collectors translate their local metadata into a stable contract. FastAPI mediates access. SQLite persists local telemetry and searchable documentation.</p></div>
      <div className="architecture-card"><div className="architecture-labels"><span>CLI PROCESS</span><span>COLLECTOR</span><span>API</span><span>DATABASE</span></div><ArchitectureCanvas/><div className="architecture-legend"><span><i className="dot mint"/> Agent process</span><span><i className="dot blue"/> Collector</span><span><i className="dot violet"/> FastAPI</span><span><i className="dot amber"/> SQLite + vectors</span></div></div>
      <div className="principle-grid"><article><b>01</b><h3>Process isolation</h3><p>Agents remain separate executables. The dashboard never embeds or silently changes their runtime.</p></article><article><b>02</b><h3>Collector contract</h3><p>Each adapter emits normalized usage events. Adding a collector does not require rewriting the dashboard.</p></article><article><b>03</b><h3>Local-first data</h3><p>The Docker API binds to loopback. The OpenCode database is read by a host-side user process and is never mounted into the container.</p></article></div>
    </section>

    <section className="section" id="agents">
      <div className="section-heading"><div><p className="eyebrow">02 / AGENT REGISTRY</p><h2>Launchability is not usage accounting.</h2></div><p>These capabilities are deliberately distinguished. Detecting an executable does not imply an authenticated account, a supported subscription-limit API, or a verified usage collector.</p></div>
      <div className="agent-grid">
        {[
          ['OpenCode','opencode','PRIMARY','V1/V2 per-message usage metadata, with V2 session-counter deltas as a fallback when message counters are absent.'],
          ['Claude Code','claude','DETECT','Executable discovery; collector extension point.'],
          ['Codex','codex','DETECT','Executable discovery; collector extension point.'],
          ['Gemini CLI','gemini','DETECT','Executable discovery; collector extension point.'],
          ['Pi','pi','DETECT','Executable discovery; collector extension point.'],
          ['GitHub Copilot','github-copilot','DETECT','CLI discovery where installed; no assumed billing API.'],
        ].map(([name, command, status, description]) => <article className="agent-card" key={command}><div className="agent-card-top"><span className="agent-icon">{name.slice(0,2).toUpperCase()}</span><span className="micro-tag">{status}</span></div><h3>{name}</h3><code>{command}</code><p>{description}</p><span className="agent-runtime">{agents.find((agent) => agent.id === (command === 'copilot' ? 'github-copilot' : command))?.installed ? 'DETECTED ON THIS MACHINE' : 'RUNTIME STATUS UNKNOWN / NOT DETECTED'}</span></article>)}
      </div>
      <div className="collector-row"><div><h3>Host-side OpenCode collector</h3><p>Runs as the logged-in Fedora user. V1 message JSON and V2 session_message JSON are projected to per-assistant-message usage metadata; SQLite returns only model, time, token and cost paths, never content/tool output. session_v2 cumulative counters are a fallback when per-message usage is absent and are differenced by the backend every 15 minutes. The Docker container never mounts the OpenCode database. Status: {backend.capabilities?.opencode_status || 'waiting for first snapshot'} · Basis: {backend.capabilities?.opencode_aggregation_basis || 'none'} · Timestamp: {backend.capabilities?.opencode_timestamp_semantics || 'not reported'} · Last snapshot: {backend.capabilities?.host_snapshot_at || 'not received'}.</p></div><CopyButton value="bash scripts/refresh_host_snapshot.sh" children="Copy manual refresh command"/></div>
      {searchMessage && <p className="inline-message">{searchMessage}</p>}
    </section>

    <section className="section" id="database">
      <div className="section-heading"><div><p className="eyebrow">03 / LOCAL DATA PLANE</p><h2>Operational memory, not a credential vault.</h2></div><p>SQLite is a single-host embedded database. WAL improves reader/writer overlap, but it is not a multi-host network database. This design keeps the database on the same host as the API.</p></div>
      <div className="database-grid">
        <article className="database-main"><div className="db-heading"><span className="db-symbol">◈</span><div><h3>SQLite + FTS5 + sqlite-vec</h3><p>One persistent local database</p></div></div><div className="db-features"><span>WAL journaling</span><span>Foreign keys</span><span>Busy timeout</span><span>FTS5 lexical search</span><span>Vector KNN search</span><span>Schema migrations</span><span>Integrity checks</span><span>Online backup API</span></div><div className="db-meter"><div><span>LOCAL STORAGE</span><b>{backend.capabilities?.database_path || 'Docker volume: agent-data'}</b></div><span className="status-pill">{backend.capabilities?.sqlite_vec ? 'VECTOR INDEX READY' : 'AWAITING BACKEND'}</span></div></article>
        <article className="usage-card"><div className="usage-heading"><div><span className="eyebrow">AGENT TELEMETRY</span><h3>Reported input + output by day</h3></div><span className="micro-tag">LIVE API / DEMO ZERO</span></div><UsageChart data={chartData}/><div className="usage-total"><div><small>ASSISTANT MESSAGES</small><strong>{usage?.assistant_messages ?? '—'}</strong></div><div><small>INPUT + OUTPUT COUNTERS</small><strong>{usage?.input_output_tokens?.toLocaleString?.() ?? '—'}</strong></div><div><small>OPENCode-REPORTED COST</small><strong>{usage?.cost_usd != null ? `$${usage.cost_usd.toFixed(4)}` : '—'}</strong></div></div><div className="usage-components"><div><small>REASONING COUNTER</small><strong>{usage?.reasoning_tokens?.toLocaleString?.() ?? '—'}</strong></div><div><small>CACHE READ</small><strong>{usage?.cache_read_tokens?.toLocaleString?.() ?? '—'}</strong></div><div><small>CACHE WRITE</small><strong>{usage?.cache_write_tokens?.toLocaleString?.() ?? '—'}</strong></div></div>{usage?.counter_reset_events > 0 && <p className="usage-warning">{usage.counter_reset_events} cumulative counter reset event(s) detected. The collector started a new counter epoch and retained the reset values as positive deltas; inspect session restore or database migration history.</p>}<p className="usage-footnote">Reasoning and cache counters are reported separately because provider accounting definitions can overlap. Cost is OpenCode-reported; $0 does not prove a provider supplied the service for free. V2 session-counter fallbacks are differenced against the prior 15-minute snapshot; the first fallback collection establishes a baseline and is not a historical per-message timeline. Counter decreases are surfaced as reset events and start a new counter epoch rather than generating negative usage.</p></article>
      </div>
      <div className="database-ops"><CodePanel title="Create a verified SQLite backup" code={'bash scripts/backup_db.sh'}/><CodePanel title="Restore with pre-restore backup and automatic rollback" code={'bash scripts/restore_db.sh /absolute/path/to/agents-backup.db'}/></div>
      <div className="search-card"><div><p className="eyebrow">HYBRID RETRIEVAL</p><h3>Search the local knowledge store</h3><p>Lexical retrieval uses FTS5. Semantic retrieval uses sqlite-vec when a query embedding is available from Ollama or the API request.</p></div><form onSubmit={runSearch}><input value={search} onChange={(event) => setSearch(event.target.value)} placeholder="Search architecture notes…" aria-label="Search local knowledge"/><button className="button button-primary" disabled={!search.trim() || backend.state !== 'connected'}>Search</button></form>{searchResults.length > 0 && <ol className="search-results">{searchResults.map((result) => <li key={result.id}><strong>{result.title}</strong><span>{result.excerpt}</span><small>{result.source} · {result.score_label}</small></li>)}</ol>}</div>
    </section>

    <section className="section" id="install">
      <div className="section-heading"><div><p className="eyebrow">04 / FEDORA INSTALLATION</p><h2>Install locally. Keep your agent configuration intact.</h2></div><p>The installer does not replace ~/.config/opencode, rewrite credentials, or modify the source OpenCode database. A systemd user timer runs the host collector as your login user; only sanitized usage metadata crosses loopback into the separate Docker database volume.</p></div>
      <div className="install-grid"><div className="install-copy"><div className="step"><b>01</b><div><h3>Check prerequisites</h3><p>Fedora 43, Xfce on X11, Node.js 20.19+/22.12+, Python 3.11+, Git, Docker Engine and Docker Compose plugin.</p></div></div><div className="step"><b>02</b><div><h3>Run the installer</h3><p>From the repository root, the installer creates dashboard and agent-launcher entries, starts the local API, configures the Vite UI service, and enables a 15-minute systemd user timer for host-side snapshots.</p></div></div><div className="step"><b>03</b><div><h3>Open the dashboard</h3><p>Visit http://127.0.0.1:5173. The backend is reachable only through loopback at port 8000.</p></div></div><a className="button button-primary" href={`${import.meta.env.BASE_URL}install-fedora-ai-agents.sh`} download>Download Fedora installer script ↧</a><a className="button" href={`${import.meta.env.BASE_URL}uninstall-fedora-ai-agents.sh`} download>Download safe uninstaller ↧</a><small>These two scripts are repository components; use the one-shot builder or download the complete repository before running them.</small></div><CodePanel title="One-shot repository builder and publisher" code={BUILDER_FETCH} downloadHref={`${import.meta.env.BASE_URL}build-fedora-ai-agents-explainer.sh`}/><CodePanel title="Local quick start" code={QUICKSTART} downloadHref={`${import.meta.env.BASE_URL}quickstart.sh`}/><CodePanel title="Install OpenCode (official V2 CLI)" code={OPENCODE_INSTALL} downloadHref={`${import.meta.env.BASE_URL}install-opencode.sh`}/></div>
      <div className="warning-note"><strong>Important browser boundary:</strong> a GitHub Pages HTTPS document cannot reliably probe a local HTTP API. Static mode therefore does not attempt an insecure mixed-content request. Use the “Open local instance” link and serve the UI from localhost for backend discovery.</div>
    </section>

    <section className="section" id="references">
      <div className="section-heading"><div><p className="eyebrow">05 / REFERENCES & EVIDENCE</p><h2>Claims are traceable to implementation sources.</h2></div><p>Primary documentation is preferred. Community repositories are treated as implementation evidence, not as normative specifications. Version-sensitive database layouts are detected defensively.</p></div>
      <div className="reference-list">
        {[
          ['Omarchy AI manual','Official list of agent launch commands, including OpenCode.','https://omarchy.org/manual/ai/'],
          ['Omarchy Agents plugin source','Current collector inventory: OpenCode Go limits and local usage from both OpenCode message stores.','https://github.com/omacom/omarchy/blob/quattro/shell/plugins/agents/README.md'],
          ['Omarchy collector contract','JSON record contract, independent collectors, provider routing and read-only local scans.','https://github.com/omacom/omarchy/blob/quattro/docs/agent-usage-collectors.md'],
          ['Omarchy shared OpenCode reader','Implementation reference for message/session_message, migration deduplication and fork filtering.','https://github.com/omacom/omarchy/blob/quattro/shell/plugins/agents/collectors.py'],
          ['OpenCode provider documentation','Authentication methods and credential storage boundaries.','https://opencode.ai/docs/cli/providers'],
          ['OpenCode CLI commands','Official stats --json and debug paths db commands.','https://opencode.ai/docs/cli/commands'],
          ['OpenCode generated V2 database schema','Official generated SQLite schema for session_v2 and session_message.','https://github.com/anomalyco/opencode/blob/dev/packages/core/src/database/schema.gen.ts'],
          ['OpenCode V2 per-message data guide','Community implementation guide documenting session_message.data model, cost, tokens and timestamps; treated as schema evidence, not normative specification.','https://github.com/MaxAnderson95/my-opencode-setup/blob/main/skills/opencode-db-querying/SKILL.md'],
          ['OpenCode cost reporting issue','Upstream report documenting cases where reported cost is zero; token counters remain a separate usage signal.','https://github.com/anomalyco/opencode/issues/60624'],
          ['Pulumi Homelab Explainer','User project precedent for a static Pages explainer plus local Docker/FastAPI/SQLite-vec backend and one-shot heredoc builder.','https://github.com/swipswaps/pulumi-homelab-explainer'],
          ['Pulumi Explainer builder','The actual one-shot setup script used as the build-method reference.','https://github.com/swipswaps/pulumi-homelab-explainer/blob/main/setup-pulumi-explainer.sh'],
          ['Receipts OCR architecture reference','User project precedent for Docker health detection, backend readiness, CI and test gates; no OCR-specific code is reused.','https://github.com/swipswaps/receipts-ocr'],
          ['SQLite 3.54.1 release','Official 2026-10-16 release notes and source identity; the Docker build pins the source archive and verifies its SHA-256 before compilation.','https://sqlite.org/releaselog/3_54_1.html'],
          ['SQLite official source download','Official source archive and SHA3-256 release checksum.','https://sqlite.org/download.html'],
          ['Buildroot SQLite 3.54.1 source hash','Independent package-maintainer SHA-256 record for sqlite-autoconf-3540100.tar.gz.','https://lists.busybox.net/pipermail/buildroot/2026-October/813774.html'],
          ['SQLite Write-Ahead Logging','Concurrency properties, checkpointing and same-host constraint.','https://www.sqlite.org/wal.html'],
          ['SQLite online backup API','Consistent online backups while the database is active.','https://www.sqlite.org/backup.html'],
          ['SQLite Python API','Connection, transaction and backup interfaces used by the backend.','https://docs.python.org/3/library/sqlite3.html'],
          ['SQLite user forum: FTS5 build options','Community discussion of enabling FTS5 in SQLite builds.','https://sqlite.org/forum/info/397faef44ff75bbd'],
          ['SQLite FTS5','Full-text virtual table and query facilities.','https://www.sqlite.org/fts5.html'],
          ['sqlite-vec','SQLite vector virtual tables; pre-v1 API stability caveat.','https://github.com/asg017/sqlite-vec'],
          ['sqlite-vec 0.1.9 release','Pinned stable release and checksums; the application deliberately pins this pre-1.0 API.','https://github.com/asg017/sqlite-vec/releases/tag/v0.1.9'],
          ['sqlite-vec Python binding','Documented connection loading and vector serialization API.','https://alexgarcia.xyz/sqlite-vec/python.html'],
          ['Docker Compose health dependencies','Use service_healthy rather than assuming a running container is ready.','https://docs.docker.com/compose/how-tos/startup-order/'],
          ['FastAPI','Official API framework documentation.','https://fastapi.tiangolo.com/'],
          ['React','Official component and state model documentation.','https://react.dev/'],
          ['Three.js','Official WebGL scene graph and renderer documentation.','https://threejs.org/docs/'],
          ['D3.js','Official data-driven visualization modules.','https://d3js.org/'],
          ['GitHub Pages','Official Pages hosting and workflow deployment guidance.','https://docs.github.com/en/pages/getting-started-with-github-pages/creating-a-github-pages-site'],
          ['systemd timer units','Official timer scheduling semantics for the user collector.','https://www.freedesktop.org/software/systemd/man/latest/systemd.timer.html'],
          ['systemd service units','Official oneshot user-service execution semantics.','https://www.freedesktop.org/software/systemd/man/latest/systemd.service.html'],
          ['Vite static deployment','Repository base path and GitHub Actions Pages workflow.','https://vite.dev/guide/static-deploy'],
          ['Designing Data-Intensive Applications','Martin Kleppmann, O’Reilly, 2017. ISBN 9781491903063.','https://www.oreilly.com/library/view/designing-data-intensive-applications/9781491903063/'],
          ['Designing Data-Intensive Applications, second edition','Kleppmann and Riccomini, O’Reilly, 2026. ISBN 9781098119058.','https://www.oreilly.com/library/view/designing-data-intensive-applications/9781098119058/'],
        ].map(([title, detail, url]) => <a className="reference" key={url} href={url} target="_blank" rel="noreferrer"><span className="reference-arrow">↗</span><div><strong>{title}</strong><p>{detail}</p><small>{url}</small></div></a>)}
      </div>
    </section>

    <footer><div className="brand"><span className="brand-mark">FA</span><span>FEDORA AI AGENTS<small>LOCAL-FIRST / AUDITABLE / EXTENSIBLE</small></span></div><p>Static explainer · Local FastAPI backend · SQLite data plane</p><a href="https://github.com/swipswaps/fedora-ai-agents-explainer" target="_blank" rel="noreferrer">Source repository ↗</a></footer>
  </main>;
}
