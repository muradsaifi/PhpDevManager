import { useState, useEffect, useRef, useCallback } from "react";

// ─── Constants ──────────────────────────────────────────────────────────────

const PHP_VERSIONS = [
  { ver: "8.3.31", label: "PHP 8.3", status: "latest",   url: "https://windows.php.net/downloads/releases/php-8.3.31-Win32-vs16-x64.zip" },
  { ver: "8.2.31", label: "PHP 8.2", status: "stable",   url: "https://windows.php.net/downloads/releases/php-8.2.31-Win32-vs16-x64.zip" },
  { ver: "8.1.34", label: "PHP 8.1", status: "security", url: "https://windows.php.net/downloads/releases/php-8.1.34-Win32-vs16-x64.zip" },
  { ver: "8.0.30", label: "PHP 8.0", status: "eol",      url: "https://windows.php.net/downloads/releases/archives/php-8.0.30-Win32-vs16-x64.zip" },
  { ver: "7.4.33", label: "PHP 7.4", status: "eol",      url: "https://windows.php.net/downloads/releases/archives/php-7.4.33-Win32-vc15-x64.zip" },
  { ver: "7.3.33", label: "PHP 7.3", status: "eol",      url: "https://windows.php.net/downloads/releases/archives/php-7.3.33-Win32-vc15-x64.zip" },
];

const WEB_SERVERS = [
  { value: "Apache", label: "Apache 2.4" },
  { value: "Nginx",  label: "Nginx 1.28" },
];

const PHP_BASE_PATH = "php";
const FCGI_PORT_START = 9000;
const HTTP_PORT_START = 80;

const STATUS_COLORS = {
  latest:   { bg: "#e6f9ee", color: "#1a6b3a", label: "Latest" },
  stable:   { bg: "#e8f0fe", color: "#1a4fa8", label: "Stable" },
  security: { bg: "#fff8e1", color: "#856404", label: "Security" },
  eol:      { bg: "#fce8e8", color: "#a32d2d", label: "EOL" },
};

const BLANK_SITE = { name: "", root: "", port: 80, phpVer: "8.3.31", server: "Apache", ssl: false };

// ─── Port helpers ────────────────────────────────────────────────────────────

/** Returns the next unused port from `start` not present in `usedSet`. */
function nextFreePort(usedSet, start) {
  let p = start;
  while (usedSet.has(p)) p++;
  return p;
}

/** Collect every HTTP port already used by the given sites list. */
function usedHttpPorts(sites) {
  return new Set(sites.map((s) => Number(s.port)).filter(Boolean));
}

/** Collect every fcgiPort already used by the given sites list. */
function usedFcgiPorts(sites) {
  return new Set(sites.map((s) => Number(s.fcgiPort)).filter(Boolean));
}

/** Assign a fresh fcgiPort for every site that lacks one, mutating nothing — returns new array. */
function repairFcgiPorts(sites) {
  const used = usedFcgiPorts(sites);
  return sites.map((s) => {
    if (s.fcgiPort) return s;
    const port = nextFreePort(used, FCGI_PORT_START);
    used.add(port);
    return { ...s, fcgiPort: port };
  });
}

// ─── Sub-components ──────────────────────────────────────────────────────────

function Badge({ status }) {
  const c = STATUS_COLORS[status] ?? STATUS_COLORS.eol;
  return (
    <span style={{ background: c.bg, color: c.color, fontSize: 11, fontWeight: 600, padding: "2px 8px", borderRadius: 20, letterSpacing: "0.03em" }}>
      {c.label}
    </span>
  );
}

function LogLine({ line, i }) {
  const color =
    line.includes("[ERROR]") ? "#d93025" :
    line.includes("[OK]")    ? "#1a6b3a" :
    line.includes("[WARN]")  ? "#c87700" :
    line.includes("[INFO]")  ? "#1a4fa8" : "#888";
  return (
    <div style={{ color, fontFamily: "monospace", fontSize: 12, lineHeight: 1.7, padding: "1px 0" }}>
      <span style={{ color: "#555", marginRight: 10, userSelect: "none" }}>{String(i + 1).padStart(3, "0")}</span>
      {line}
    </div>
  );
}

function FieldRow({ label, children }) {
  return (
    <div>
      <label style={{ fontSize: 12, color: "#666", display: "block", marginBottom: 4 }}>{label}</label>
      {children}
    </div>
  );
}

const inputStyle = {
  width: "100%", padding: "8px 12px", borderRadius: 6,
  border: "1px solid #ddd", fontSize: 13, boxSizing: "border-box",
};

// ─── SiteForm (shared by Add + Edit) ─────────────────────────────────────────

function SiteForm({ title, draft, onChange, onSubmit, onCancel, phpInstalls, existingPorts, existingFcgiPorts, editId }) {
  const portConflict = existingPorts.has(Number(draft.port)) && !editId;
  const fcgiConflict = existingFcgiPorts.has(Number(draft.fcgiPort));
  const valid = draft.name.trim() && draft.root.trim() && !portConflict && !fcgiConflict;

  return (
    <div style={{ background: "#fff", border: "1.5px solid #6c63ff", borderRadius: 12, padding: 20, marginBottom: 20 }}>
      <div style={{ fontWeight: 600, marginBottom: 14 }}>{title}</div>
      <div style={{ display: "grid", gridTemplateColumns: "1fr 1fr", gap: 12 }}>
        <FieldRow label="Hostname">
          <input value={draft.name} onChange={(e) => onChange("name", e.target.value)}
            placeholder="mysite.local" style={inputStyle} />
        </FieldRow>
        <FieldRow label="Document Root">
          <input value={draft.root} onChange={(e) => onChange("root", e.target.value)}
            placeholder="C:\dev\mysite\public" style={inputStyle} />
        </FieldRow>

        <FieldRow label={`HTTP Port${portConflict ? " ⚠ conflict" : ""}`}>
          <input type="number" min={1} max={65535} value={draft.port}
            onChange={(e) => onChange("port", parseInt(e.target.value) || 80)}
            style={{ ...inputStyle, borderColor: portConflict ? "#d93025" : "#ddd" }} />
        </FieldRow>

        <FieldRow label={`FastCGI Port (Nginx)${fcgiConflict ? " ⚠ conflict" : ""}`}>
          <input type="number" min={1024} max={65535} value={draft.fcgiPort}
            onChange={(e) => onChange("fcgiPort", parseInt(e.target.value) || FCGI_PORT_START)}
            style={{ ...inputStyle, borderColor: fcgiConflict ? "#d93025" : "#ddd" }} />
          <span style={{ fontSize: 11, color: "#aaa", marginTop: 3, display: "block" }}>
            Auto-assigned; only used by Nginx sites.
          </span>
        </FieldRow>

        <FieldRow label="PHP Version">
          <select value={draft.phpVer} onChange={(e) => onChange("phpVer", e.target.value)} style={inputStyle}>
            {phpInstalls.map((p) => <option key={p.ver} value={p.ver}>PHP {p.ver}</option>)}
          </select>
        </FieldRow>

        <FieldRow label="Web Server">
          <select value={draft.server} onChange={(e) => onChange("server", e.target.value)} style={inputStyle}>
            {WEB_SERVERS.map((sv) => <option key={sv.value} value={sv.value}>{sv.label}</option>)}
          </select>
        </FieldRow>

        <div style={{ display: "flex", alignItems: "center", gap: 8, paddingTop: 20 }}>
          <input type="checkbox" id="ssl-field" checked={!!draft.ssl}
            onChange={(e) => onChange("ssl", e.target.checked)} />
          <label htmlFor="ssl-field" style={{ fontSize: 13, cursor: "pointer" }}>Enable self-signed SSL (HTTPS)</label>
        </div>
      </div>

      <div style={{ display: "flex", gap: 10, marginTop: 16 }}>
        <button onClick={onSubmit} disabled={!valid}
          style={{ background: valid ? "#6c63ff" : "#ccc", color: "#fff", border: "none", borderRadius: 6, padding: "8px 20px", fontSize: 13, fontWeight: 600, cursor: valid ? "pointer" : "not-allowed" }}>
          {editId ? "Save Changes" : "Add Site"}
        </button>
        <button onClick={onCancel}
          style={{ background: "#f0f0f7", color: "#555", border: "none", borderRadius: 6, padding: "8px 20px", fontSize: 13, cursor: "pointer" }}>
          Cancel
        </button>
      </div>
    </div>
  );
}

// ─── Main App ─────────────────────────────────────────────────────────────────

export default function App() {
  const [tab, setTab] = useState("sites");

  // sites carries: { id, name, root, port, phpVer, server, ssl, running, fcgiPort }
  const [sites, setSites] = useState([]);
  const [phpInstalls, setPhpInstalls] = useState([
    { ver: "8.3.31", installed: true, systemDefault: true,  path: `${PHP_BASE_PATH}\\8.3.31` },
    { ver: "7.4.33", installed: true, systemDefault: false, path: `${PHP_BASE_PATH}\\7.4.33` },
  ]);
  const [logs, setLogs] = useState([
    "[INFO] PHPDevManager v1.1.0 started",
    "[INFO] Config loaded from config.json",
    "[OK]   Dynamic port allocation enabled",
  ]);
  const [globalPHP, setGlobalPHP]     = useState("8.3.31");
  const [serverState, setServerState] = useState({ apacheInstalled: false, nginxInstalled: false, apacheRunning: false, nginxRunning: false });
  const [downloading, setDownloading] = useState({});
  const [showAddSite, setShowAddSite] = useState(false);
  const [editTarget, setEditTarget]   = useState(null); // site id being edited
  const [formDraft, setFormDraft]     = useState(null); // current form state
  const logRef = useRef(null);

  // ── Auto-scroll logs
  useEffect(() => {
    if (logRef.current) logRef.current.scrollTop = logRef.current.scrollHeight;
  }, [logs]);

  // ── Detect servers (Node/Electron env)
  useEffect(() => {
    const detect = async () => {
      const isNode = typeof process !== "undefined" && process?.versions?.node;
      if (!isNode) return;
      try {
        const fs   = await import("fs");
        const path = await import("path");
        const root = path.resolve(process.cwd());
        const ap   = path.join(root, "apache24", "bin", "httpd.exe");
        const ng   = path.join(root, "nginx", "nginx.exe");
        const apacheInstalled = fs.existsSync(ap);
        const nginxInstalled  = fs.existsSync(ng);
        setServerState((p) => ({ ...p, apacheInstalled, nginxInstalled }));
        addLog(`[INFO] Apache: ${apacheInstalled ? ap : "not found"}`);
        addLog(`[INFO] Nginx:  ${nginxInstalled  ? ng : "not found"}`);
      } catch (e) {
        addLog(`[WARN] Server autodetect failed: ${e.message}`);
      }
    };
    detect();
  }, []);

  // ── Load config.json if available
  useEffect(() => {
    const load = async () => {
      const isNode = typeof process !== "undefined" && process?.versions?.node;
      if (!isNode) return;
      try {
        const fs   = await import("fs");
        const path = await import("path");
        const cfgPath = path.join(process.cwd(), "config.json");
        if (!fs.existsSync(cfgPath)) return;
        const raw  = fs.readFileSync(cfgPath, "utf8");
        const cfg  = JSON.parse(raw);
        if (cfg.systemPhp) setGlobalPHP(cfg.systemPhp);
        if (Array.isArray(cfg.sites) && cfg.sites.length > 0) {
          const repaired = repairFcgiPorts(
            cfg.sites.map((s, i) => ({ ...s, id: s.id ?? Date.now() + i, running: false }))
          );
          setSites(repaired);
          addLog(`[OK]   Loaded ${repaired.length} site(s) from config.json`);
        }
      } catch (e) {
        addLog(`[WARN] Could not load config.json: ${e.message}`);
      }
    };
    load();
  }, []);

  // ── Save config.json whenever sites or globalPHP change (Node env only)
  const saveConfig = useCallback(async (currentSites, currentPhp) => {
    const isNode = typeof process !== "undefined" && process?.versions?.node;
    if (!isNode) return;
    try {
      const fs   = await import("fs");
      const path = await import("path");
      const cfgPath = path.join(process.cwd(), "config.json");
      const payload = {
        systemPhp: currentPhp,
        sites: currentSites.map(({ id: _id, running: _r, ...rest }) => rest),
      };
      fs.writeFileSync(cfgPath, JSON.stringify(payload, null, 4));
    } catch {/* silent */ }
  }, []);

  useEffect(() => { saveConfig(sites, globalPHP); }, [sites, globalPHP, saveConfig]);

  // ── Logging helper
  const addLog = (msg) =>
    setLogs((l) => [...l, `[${new Date().toLocaleTimeString()}] ${msg}`]);

  // ── Dynamic port helpers (scoped to current sites state)
  const nextHttpPort  = () => nextFreePort(usedHttpPorts(sites),  HTTP_PORT_START);
  const nextFcgiPort  = () => nextFreePort(usedFcgiPorts(sites),  FCGI_PORT_START);

  // ── Open Add form with auto-assigned ports
  const openAddForm = () => {
    const fcgi = nextFcgiPort();
    const http = nextHttpPort();
    const ver  = phpInstalls[0]?.ver ?? "8.3.31";
    setFormDraft({ ...BLANK_SITE, port: http, fcgiPort: fcgi, phpVer: ver });
    setEditTarget(null);
    setShowAddSite(true);
  };

  // ── Open Edit form pre-filled with existing site data
  const openEditForm = (site) => {
    setFormDraft({ ...site });
    setEditTarget(site.id);
    setShowAddSite(true);
  };

  const closeSiteForm = () => { setShowAddSite(false); setEditTarget(null); setFormDraft(null); };

  const patchDraft = (key, val) => setFormDraft((d) => ({ ...d, [key]: val }));

  // ── Commit add / edit
  const commitSite = () => {
    if (!formDraft) return;
    if (editTarget !== null) {
      // Edit existing
      setSites((prev) =>
        prev.map((s) => (s.id === editTarget ? { ...formDraft, id: editTarget, running: s.running } : s))
      );
      addLog(`[OK]   Site '${formDraft.name}' updated`);
    } else {
      // Add new
      const id = Date.now();
      setSites((prev) => [...prev, { ...formDraft, id, running: false }]);
      addLog(`[OK]   Site '${formDraft.name}' added — HTTP :${formDraft.port}, FCGI :${formDraft.fcgiPort}`);
    }
    closeSiteForm();
  };

  // ── Site actions
  const toggleSite = (id) => {
    setSites((prev) =>
      prev.map((s) => {
        if (s.id !== id) return s;
        const next = !s.running;
        addLog(
          next
            ? `[OK]   '${s.name}' started — ${s.ssl ? "https" : "http"}://${s.name}:${s.port} (${s.server}, PHP ${s.phpVer}, FCGI :${s.fcgiPort})`
            : `[INFO] '${s.name}' stopped`
        );
        return { ...s, running: next };
      })
    );
  };

  const deleteSite = (id) => {
    const s = sites.find((x) => x.id === id);
    if (!s) return;
    if (s.running) {
      addLog(`[WARN] Stopping '${s.name}' before deletion`);
    }
    setSites((prev) => prev.filter((x) => x.id !== id));
    addLog(`[INFO] Site '${s.name}' removed (HTTP :${s.port} freed, FCGI :${s.fcgiPort} freed)`);
  };

  const setSitePhp = (siteId, ver) => {
    setSites((prev) => prev.map((s) => (s.id === siteId ? { ...s, phpVer: ver } : s)));
    const s = sites.find((x) => x.id === siteId);
    addLog(`[OK]   '${s?.name}' PHP → ${ver}`);
  };

  const stopAll  = () => { setSites((s) => s.map((x) => ({ ...x, running: false }))); addLog("[INFO] All sites stopped"); };
  const startAll = () => { setSites((s) => s.map((x) => ({ ...x, running: true  }))); addLog("[OK]   All sites started");  };

  // ── PHP management
  const downloadPHP = (ver) => {
    if (phpInstalls.some((p) => p.ver === ver)) { addLog(`[INFO] PHP ${ver} already installed.`); return; }
    setDownloading((d) => ({ ...d, [ver]: 0 }));
    addLog(`[INFO] Downloading PHP ${ver}...`);
    let prog = 0;
    const iv = setInterval(() => {
      prog += Math.random() * 18 + 5;
      if (prog >= 100) {
        prog = 100;
        clearInterval(iv);
        setDownloading((d) => { const nd = { ...d }; delete nd[ver]; return nd; });
        setPhpInstalls((prev) => [...prev, { ver, installed: true, systemDefault: false, path: `${PHP_BASE_PATH}\\${ver}` }]);
        addLog(`[OK]   PHP ${ver} installed at ${PHP_BASE_PATH}\\${ver}`);
      }
      setDownloading((d) => ({ ...d, [ver]: Math.round(prog) }));
    }, 180);
  };

  const setSystemDefault = (ver) => {
    setGlobalPHP(ver);
    setPhpInstalls((prev) => prev.map((p) => ({ ...p, systemDefault: p.ver === ver })));
    addLog(`[OK]   System default PHP → ${ver} (PATH updated)`);
  };

  // ── Server management
  const getLabel = (sv) => WEB_SERVERS.find((w) => w.value === sv)?.label ?? sv;
  const isInstalled = (sv) => (sv === "Apache" ? serverState.apacheInstalled : serverState.nginxInstalled);
  const isRunning   = (sv) => (sv === "Apache" ? serverState.apacheRunning   : serverState.nginxRunning);

  const installServer = (sv) => {
    if (isInstalled(sv)) { addLog(`[INFO] ${getLabel(sv)} already installed.`); return; }
    setServerState((p) => ({ ...p, [`${sv.toLowerCase()}Installed`]: true }));
    addLog(`[OK]   ${getLabel(sv)} installed in ${sv === "Apache" ? "apache24" : "nginx"}`);
  };
  const startServer = (sv) => {
    if (!isInstalled(sv)) { addLog(`[ERROR] ${getLabel(sv)} must be installed first.`); return; }
    if (isRunning(sv))    { addLog(`[INFO] ${getLabel(sv)} already running.`); return; }
    setServerState((p) => ({ ...p, [`${sv.toLowerCase()}Running`]: true }));
    addLog(`[OK]   ${getLabel(sv)} started`);
  };
  const stopServer = (sv) => {
    if (!isRunning(sv)) { addLog(`[INFO] ${getLabel(sv)} is not running.`); return; }
    setServerState((p) => ({ ...p, [`${sv.toLowerCase()}Running`]: false }));
    addLog(`[OK]   ${getLabel(sv)} stopped`);
  };

  // ── Derived state
  const installedVersions = phpInstalls.map((p) => p.ver);
  const runningSites      = sites.filter((s) => s.running);
  const allRunning        = sites.length > 0 && sites.every((s) => s.running);

  // excluded ports for form conflict detection
  const httpPortsExcluding = (excludeId) =>
    new Set(sites.filter((s) => s.id !== excludeId).map((s) => Number(s.port)));
  const fcgiPortsExcluding = (excludeId) =>
    new Set(sites.filter((s) => s.id !== excludeId).map((s) => Number(s.fcgiPort)));

  // ── Styles
  const tabStyle = (t) => ({
    padding: "8px 20px", border: "none",
    background: tab === t ? "#1a1a2e" : "transparent",
    color: tab === t ? "#fff" : "#888",
    fontWeight: tab === t ? 600 : 400, fontSize: 13, cursor: "pointer", borderRadius: 6, transition: "all 0.15s",
  });

  const btnStyle = (bg, color, border) => ({
    background: bg, color, border: `1px solid ${border}`, borderRadius: 6,
    padding: "5px 14px", fontSize: 12, fontWeight: 600, cursor: "pointer",
  });

  // ─────────────────────────────────────────────────────────────────────────────

  return (
    <div style={{ fontFamily: "'Segoe UI', system-ui, sans-serif", background: "#f7f8fc", minHeight: "100vh", color: "#1a1a2e" }}>

      {/* ── Header */}
      <div style={{ background: "#1a1a2e", color: "#fff", padding: "14px 28px", display: "flex", alignItems: "center", justifyContent: "space-between" }}>
        <div style={{ display: "flex", alignItems: "center", gap: 12 }}>
          <div style={{ background: "#6c63ff", borderRadius: 8, width: 32, height: 32, display: "flex", alignItems: "center", justifyContent: "center", fontSize: 18 }}>⚡</div>
          <div>
            <div style={{ fontWeight: 700, fontSize: 16 }}>PHPDevManager</div>
            <div style={{ fontSize: 11, color: "#8888aa" }}>Portable PHP Dev Environment v1.1.0</div>
          </div>
        </div>
        <div style={{ display: "flex", gap: 8, alignItems: "center" }}>
          <div style={{ background: "#0d2a1a", color: "#3ecf8e", fontSize: 12, padding: "4px 12px", borderRadius: 20, fontFamily: "monospace" }}>
            PHP {globalPHP} (system)
          </div>
          <div style={{ background: "#2a1a0d", color: "#f5a623", fontSize: 12, padding: "4px 12px", borderRadius: 20, fontFamily: "monospace" }}>
            {runningSites.length}/{sites.length} running
          </div>
        </div>
      </div>

      {/* ── Tabs */}
      <div style={{ background: "#fff", borderBottom: "1px solid #e8eaf6", padding: "8px 24px", display: "flex", gap: 4 }}>
        {[["sites", "🌐 Sites"], ["servers", "🛠 Servers"], ["php", "🐘 PHP Versions"], ["logs", "📋 Logs"]].map(([k, lbl]) => (
          <button key={k} onClick={() => setTab(k)} style={tabStyle(k)}>{lbl}</button>
        ))}
        <div style={{ flex: 1 }} />
        {sites.length > 0 && (
          <button onClick={allRunning ? stopAll : startAll}
            style={{ background: allRunning ? "#fce8e8" : "#e8f9ee", color: allRunning ? "#a32d2d" : "#1a6b3a", border: `1px solid ${allRunning ? "#f5c1c1" : "#b3e8c8"}`, borderRadius: 6, padding: "6px 18px", fontSize: 13, fontWeight: 600, cursor: "pointer" }}>
            {allRunning ? "⏹ Stop All" : "▶ Start All"}
          </button>
        )}
      </div>

      <div style={{ padding: "24px 28px" }}>

        {/* ════════ SITES TAB ════════ */}
        {tab === "sites" && (
          <div>
            <div style={{ display: "flex", justifyContent: "space-between", alignItems: "center", marginBottom: 16 }}>
              <div style={{ fontWeight: 700, fontSize: 18 }}>Virtual Hosts</div>
              <button onClick={openAddForm}
                style={{ background: "#6c63ff", color: "#fff", border: "none", borderRadius: 8, padding: "8px 20px", fontSize: 13, fontWeight: 600, cursor: "pointer" }}>
                + Add Site
              </button>
            </div>

            {/* Add / Edit form */}
            {showAddSite && formDraft && (
              <SiteForm
                title={editTarget ? "Edit Virtual Host" : "New Virtual Host"}
                draft={formDraft}
                onChange={patchDraft}
                onSubmit={commitSite}
                onCancel={closeSiteForm}
                phpInstalls={phpInstalls}
                existingPorts={httpPortsExcluding(editTarget)}
                existingFcgiPorts={fcgiPortsExcluding(editTarget)}
                editId={editTarget}
              />
            )}

            {sites.map((site) => (
              <div key={site.id} style={{ background: "#fff", borderRadius: 12, border: `1.5px solid ${site.running ? "#b3e8c8" : "#e8eaf6"}`, padding: "16px 20px", marginBottom: 12, transition: "border-color 0.2s" }}>
                <div style={{ display: "flex", alignItems: "center", gap: 14 }}>
                  {/* Status dot */}
                  <div style={{ width: 12, height: 12, borderRadius: "50%", background: site.running ? "#3ecf8e" : "#d1d5e8", flexShrink: 0, boxShadow: site.running ? "0 0 8px #3ecf8e88" : "none", transition: "all 0.3s" }} />

                  {/* Site info */}
                  <div style={{ flex: 1, minWidth: 0 }}>
                    <div style={{ display: "flex", alignItems: "center", gap: 8, flexWrap: "wrap" }}>
                      <span style={{ fontWeight: 700, fontSize: 15 }}>{site.name}</span>
                      {site.ssl && <span style={{ background: "#e8f0fe", color: "#1a4fa8", fontSize: 11, padding: "1px 8px", borderRadius: 20, fontWeight: 600 }}>🔒 HTTPS</span>}
                      <span style={{ background: site.server === "Apache" ? "#fff3e0" : "#e8f5e9", color: site.server === "Apache" ? "#bf6c00" : "#1a6b3a", fontSize: 11, padding: "1px 8px", borderRadius: 20, fontWeight: 600 }}>
                        {site.server}
                      </span>
                    </div>
                    <div style={{ fontSize: 12, color: "#888", marginTop: 3, display: "flex", gap: 12, flexWrap: "wrap" }}>
                      <span title="Document root">{site.root}</span>
                      <span title="HTTP port">HTTP :{site.port}</span>
                      {site.server === "Nginx" && (
                        <span title="FastCGI port" style={{ color: "#6c63ff" }}>FCGI :{site.fcgiPort}</span>
                      )}
                    </div>
                  </div>

                  {/* Controls */}
                  <div style={{ display: "flex", alignItems: "center", gap: 8, flexShrink: 0, flexWrap: "wrap" }}>
                    <select value={site.phpVer} onChange={(e) => setSitePhp(site.id, e.target.value)}
                      style={{ padding: "5px 10px", borderRadius: 6, border: "1px solid #e0e0e0", fontSize: 12, background: "#f7f8fc", cursor: "pointer" }}>
                      {installedVersions.map((v) => <option key={v} value={v}>PHP {v}</option>)}
                    </select>

                    {site.running && (
                      <a href={`http${site.ssl ? "s" : ""}://${site.name}:${site.port}`} target="_blank" rel="noreferrer"
                        style={{ fontSize: 12, color: "#6c63ff", textDecoration: "none", padding: "5px 10px", border: "1px solid #d0ccff", borderRadius: 6 }}>
                        🔗 Open
                      </a>
                    )}

                    <button onClick={() => toggleSite(site.id)}
                      style={btnStyle(site.running ? "#fce8e8" : "#e8f9ee", site.running ? "#a32d2d" : "#1a6b3a", site.running ? "#f5c1c1" : "#b3e8c8")}>
                      {site.running ? "⏹ Stop" : "▶ Start"}
                    </button>

                    <button onClick={() => openEditForm(site)} title="Edit site"
                      style={{ background: "transparent", color: "#6c63ff", border: "1px solid #d0ccff", borderRadius: 6, padding: "5px 10px", fontSize: 12, cursor: "pointer" }}>
                      ✏
                    </button>

                    <button onClick={() => deleteSite(site.id)} title="Delete site"
                      style={{ background: "transparent", color: "#ccc", border: "1px solid #eee", borderRadius: 6, padding: "5px 10px", fontSize: 12, cursor: "pointer" }}>
                      🗑
                    </button>
                  </div>
                </div>
              </div>
            ))}

            {sites.length === 0 && !showAddSite && (
              <div style={{ textAlign: "center", color: "#aaa", padding: "48px 0" }}>
                <div style={{ fontSize: 32, marginBottom: 10 }}>🌐</div>
                <div style={{ fontSize: 15, marginBottom: 6 }}>No sites yet.</div>
                <div style={{ fontSize: 13 }}>Click <strong>+ Add Site</strong> — ports are assigned automatically.</div>
              </div>
            )}
          </div>
        )}

        {/* ════════ SERVERS TAB ════════ */}
        {tab === "servers" && (
          <div>
            <div style={{ display: "flex", justifyContent: "space-between", alignItems: "center", marginBottom: 16 }}>
              <div>
                <div style={{ fontWeight: 700, fontSize: 18 }}>Web Server Manager</div>
                <div style={{ fontSize: 12, color: "#666", marginTop: 4 }}>
                  Detects local <code>apache24</code> and <code>nginx</code> binaries when running in Node/Electron.
                </div>
              </div>
              <button onClick={() => WEB_SERVERS.forEach((sv) => installServer(sv.value))}
                style={{ background: "#6c63ff", color: "#fff", border: "none", borderRadius: 8, padding: "8px 20px", fontSize: 13, fontWeight: 600, cursor: "pointer" }}>
                Install All
              </button>
            </div>

            <div style={{ display: "grid", gap: 16 }}>
              {WEB_SERVERS.map((server) => {
                const installed = isInstalled(server.value);
                const running   = isRunning(server.value);
                return (
                  <div key={server.value} style={{ background: "#fff", borderRadius: 12, border: "1.5px solid #e8eaf6", padding: 20, display: "grid", gridTemplateColumns: "1fr auto", gap: 14, alignItems: "center" }}>
                    <div>
                      <div style={{ fontWeight: 700, fontSize: 15 }}>{server.label}</div>
                      <div style={{ fontSize: 12, color: "#666", marginTop: 4 }}>{server.value} service for local virtual hosts</div>
                      <div style={{ marginTop: 10, display: "flex", gap: 8, flexWrap: "wrap" }}>
                        <span style={{ fontSize: 12, color: installed ? "#1a6b3a" : "#a32d2d", padding: "4px 10px", borderRadius: 18, background: installed ? "#e8f9ee" : "#fdecea" }}>
                          {installed ? "✓ Installed" : "✗ Not installed"}
                        </span>
                        <span style={{ fontSize: 12, color: running ? "#1a6b3a" : "#666", padding: "4px 10px", borderRadius: 18, background: running ? "#e8f9ee" : "#f3f4f6" }}>
                          {running ? "● Running" : "○ Stopped"}
                        </span>
                      </div>
                    </div>
                    <div style={{ display: "flex", gap: 8, flexWrap: "wrap" }}>
                      <button onClick={() => installServer(server.value)} disabled={installed}
                        style={{ background: installed ? "#f0f0f7" : "#6c63ff", color: installed ? "#999" : "#fff", border: "none", borderRadius: 8, padding: "8px 16px", fontSize: 12, cursor: installed ? "not-allowed" : "pointer", opacity: installed ? 0.7 : 1 }}>
                        Install
                      </button>
                      <button onClick={() => startServer(server.value)} disabled={running || !installed}
                        style={{ background: "#e8f9ee", color: "#1a6b3a", border: "none", borderRadius: 8, padding: "8px 16px", fontSize: 12, cursor: (running || !installed) ? "not-allowed" : "pointer", opacity: (running || !installed) ? 0.6 : 1 }}>
                        Start
                      </button>
                      <button onClick={() => stopServer(server.value)} disabled={!running}
                        style={{ background: "#fce8e8", color: "#a32d2d", border: "none", borderRadius: 8, padding: "8px 16px", fontSize: 12, cursor: !running ? "not-allowed" : "pointer", opacity: !running ? 0.6 : 1 }}>
                        Stop
                      </button>
                    </div>
                  </div>
                );
              })}
            </div>

            {/* Port overview */}
            {sites.length > 0 && (
              <div style={{ marginTop: 24, background: "#fff", borderRadius: 12, border: "1px solid #e8eaf6", padding: 20 }}>
                <div style={{ fontWeight: 700, fontSize: 15, marginBottom: 12 }}>Port Allocation Overview</div>
                <table style={{ width: "100%", borderCollapse: "collapse", fontSize: 13 }}>
                  <thead>
                    <tr style={{ borderBottom: "2px solid #e8eaf6", textAlign: "left" }}>
                      <th style={{ padding: "6px 10px", color: "#666", fontWeight: 600 }}>Site</th>
                      <th style={{ padding: "6px 10px", color: "#666", fontWeight: 600 }}>Server</th>
                      <th style={{ padding: "6px 10px", color: "#666", fontWeight: 600 }}>HTTP Port</th>
                      <th style={{ padding: "6px 10px", color: "#666", fontWeight: 600 }}>FCGI Port</th>
                      <th style={{ padding: "6px 10px", color: "#666", fontWeight: 600 }}>Status</th>
                    </tr>
                  </thead>
                  <tbody>
                    {sites.map((s) => (
                      <tr key={s.id} style={{ borderBottom: "1px solid #f0f2f8" }}>
                        <td style={{ padding: "7px 10px", fontWeight: 600 }}>{s.name}</td>
                        <td style={{ padding: "7px 10px", color: "#666" }}>{s.server}</td>
                        <td style={{ padding: "7px 10px", fontFamily: "monospace", color: "#1a4fa8" }}>:{s.port}</td>
                        <td style={{ padding: "7px 10px", fontFamily: "monospace", color: s.server === "Nginx" ? "#6c63ff" : "#ccc" }}>
                          {s.server === "Nginx" ? `:${s.fcgiPort}` : "—"}
                        </td>
                        <td style={{ padding: "7px 10px" }}>
                          <span style={{ background: s.running ? "#e8f9ee" : "#f3f4f6", color: s.running ? "#1a6b3a" : "#888", borderRadius: 12, padding: "2px 10px", fontSize: 12 }}>
                            {s.running ? "Running" : "Stopped"}
                          </span>
                        </td>
                      </tr>
                    ))}
                  </tbody>
                </table>
              </div>
            )}
          </div>
        )}

        {/* ════════ PHP TAB ════════ */}
        {tab === "php" && (
          <div>
            <div style={{ fontWeight: 700, fontSize: 18, marginBottom: 6 }}>PHP Version Manager</div>
            <div style={{ fontSize: 13, color: "#888", marginBottom: 20 }}>Download and manage multiple PHP versions. Set system-wide or per-site.</div>

            <div style={{ background: "#fff", borderRadius: 12, border: "1px solid #e8eaf6", overflow: "hidden", marginBottom: 24 }}>
              <div style={{ background: "#f7f8fc", padding: "10px 18px", fontSize: 12, fontWeight: 600, color: "#666", borderBottom: "1px solid #e8eaf6", display: "grid", gridTemplateColumns: "140px 90px 1fr 220px", gap: 12 }}>
                <span>Version</span><span>Status</span><span>Install Path</span><span style={{ textAlign: "right" }}>Actions</span>
              </div>
              {PHP_VERSIONS.map((pv) => {
                const inst    = phpInstalls.find((p) => p.ver === pv.ver);
                const dlProg  = downloading[pv.ver];
                const isDling = dlProg !== undefined;
                return (
                  <div key={pv.ver} style={{ display: "grid", gridTemplateColumns: "140px 90px 1fr 220px", gap: 12, padding: "12px 18px", borderBottom: "1px solid #f0f2f8", alignItems: "center" }}>
                    <div>
                      <div style={{ fontWeight: 600, fontSize: 14 }}>{pv.label}</div>
                      <div style={{ fontSize: 11, color: "#aaa", fontFamily: "monospace" }}>{pv.ver}</div>
                    </div>
                    <Badge status={pv.status} />
                    <div style={{ fontSize: 12, color: "#888", fontFamily: "monospace" }}>
                      {inst ? inst.path : <span style={{ color: "#ccc" }}>Not installed</span>}
                    </div>
                    <div style={{ display: "flex", gap: 8, justifyContent: "flex-end", alignItems: "center" }}>
                      {inst ? (
                        <>
                          {inst.systemDefault ? (
                            <span style={{ fontSize: 11, color: "#6c63ff", fontWeight: 600, padding: "4px 12px", background: "#f0eeff", borderRadius: 20 }}>✓ System Default</span>
                          ) : (
                            <button onClick={() => setSystemDefault(pv.ver)}
                              style={{ fontSize: 11, color: "#6c63ff", border: "1px solid #d0ccff", background: "#fff", borderRadius: 20, padding: "4px 12px", cursor: "pointer", fontWeight: 600 }}>
                              Set Default
                            </button>
                          )}
                          <span style={{ fontSize: 11, color: "#3ecf8e", fontWeight: 600 }}>✓ Installed</span>
                        </>
                      ) : isDling ? (
                        <div style={{ width: 130 }}>
                          <div style={{ fontSize: 11, color: "#888", marginBottom: 3 }}>Downloading {dlProg}%</div>
                          <div style={{ height: 6, background: "#eee", borderRadius: 4 }}>
                            <div style={{ height: "100%", width: `${dlProg}%`, background: "linear-gradient(90deg,#6c63ff,#3ecf8e)", borderRadius: 4, transition: "width 0.2s" }} />
                          </div>
                        </div>
                      ) : (
                        <button onClick={() => downloadPHP(pv.ver)}
                          style={{ fontSize: 12, color: "#fff", background: "#6c63ff", border: "none", borderRadius: 20, padding: "5px 16px", cursor: "pointer", fontWeight: 600 }}>
                          ⬇ Download & Install
                        </button>
                      )}
                    </div>
                  </div>
                );
              })}
            </div>

            <div style={{ background: "#fff", borderRadius: 12, border: "1px solid #e8eaf6", padding: 20 }}>
              <div style={{ fontWeight: 700, marginBottom: 12, fontSize: 15 }}>System PATH Configuration</div>
              <div style={{ fontSize: 13, color: "#555", marginBottom: 16 }}>
                Clicking <strong>Set Default</strong> above updates the Windows PATH so <code style={{ background: "#f0f2f8", padding: "1px 6px", borderRadius: 4 }}>php</code> in any terminal resolves to that version globally.
              </div>
              {phpInstalls.length === 0 ? (
                <div style={{ color: "#aaa", fontSize: 13 }}>No PHP versions installed yet.</div>
              ) : (
                <div style={{ display: "flex", gap: 10, flexWrap: "wrap" }}>
                  {phpInstalls.map((p) => (
                    <div key={p.ver} onClick={() => setSystemDefault(p.ver)}
                      style={{ padding: "10px 18px", borderRadius: 8, border: `2px solid ${p.systemDefault ? "#6c63ff" : "#e8eaf6"}`, background: p.systemDefault ? "#f0eeff" : "#fff", cursor: "pointer", transition: "all 0.15s" }}>
                      <div style={{ fontWeight: 700, color: p.systemDefault ? "#6c63ff" : "#1a1a2e" }}>PHP {p.ver}</div>
                      {p.systemDefault && <div style={{ fontSize: 11, color: "#6c63ff", marginTop: 2 }}>✓ Active</div>}
                    </div>
                  ))}
                </div>
              )}
            </div>
          </div>
        )}

        {/* ════════ LOGS TAB ════════ */}
        {tab === "logs" && (
          <div>
            <div style={{ display: "flex", justifyContent: "space-between", alignItems: "center", marginBottom: 16 }}>
              <div style={{ fontWeight: 700, fontSize: 18 }}>System Logs</div>
              <div style={{ display: "flex", gap: 8 }}>
                <button onClick={() => { const blob = new Blob([logs.join("\n")], { type: "text/plain" }); const a = document.createElement("a"); a.href = URL.createObjectURL(blob); a.download = "phpdevmanager.log"; a.click(); }}
                  style={{ background: "#f0f2f8", color: "#555", border: "none", borderRadius: 6, padding: "6px 14px", fontSize: 12, cursor: "pointer" }}>
                  ⬇ Export
                </button>
                <button onClick={() => setLogs([])}
                  style={{ background: "#fce8e8", color: "#a32d2d", border: "none", borderRadius: 6, padding: "6px 14px", fontSize: 12, cursor: "pointer" }}>
                  Clear
                </button>
              </div>
            </div>
            <div ref={logRef} style={{ background: "#101020", borderRadius: 10, padding: "16px 20px", height: 420, overflowY: "auto", border: "1px solid #2a2a4a" }}>
              {logs.length === 0
                ? <div style={{ color: "#444", fontFamily: "monospace", fontSize: 13 }}>// no logs</div>
                : logs.map((line, i) => <LogLine key={i} line={line} i={i} />)
              }
            </div>
            <div style={{ marginTop: 8, fontSize: 11, color: "#aaa", textAlign: "right" }}>{logs.length} entries</div>
          </div>
        )}

      </div>

      {/* ── Footer */}
      <div style={{ borderTop: "1px solid #e8eaf6", padding: "12px 28px", display: "flex", gap: 20, fontSize: 11, color: "#aaa", flexWrap: "wrap" }}>
        <span>📁 Base: {PHP_BASE_PATH}</span>
        <span>⚙ Config: config.json</span>
        <span>🪟 Windows x64</span>
        <span>🔌 HTTP ports in use: {[...usedHttpPorts(sites)].sort((a,b)=>a-b).join(", ") || "none"}</span>
        <span>🔌 FCGI ports in use: {[...usedFcgiPorts(sites)].sort((a,b)=>a-b).join(", ") || "none"}</span>
        <span style={{ marginLeft: "auto" }}>PHPDevManager v1.1.0 · Portable</span>
      </div>
    </div>
  );
}
