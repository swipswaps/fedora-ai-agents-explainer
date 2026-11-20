#!/usr/bin/env bash
# One-shot, idempotent repository generator and publisher for Fedora AI Agents Explainer.
# The script is intentionally verbose: every phase reports what it is checking or changing.
# Existing changed files are backed up outside the repository before replacement.
# No credentials are embedded, no existing OpenCode database is modified, and no Docker
# volume is deleted. Publishing occurs only after frontend/backend/shell validation passes.
#
# VERIFIED IMPLEMENTATION REFERENCES (reviewed 2026-11-20):
# - GitHub Pages workflow publishing and artifact/deploy job permissions:
#   https://docs.github.com/en/pages/getting-started-with-github-pages/using-custom-workflows-with-github-pages
# - GitHub Pages artifact/deployment action contract and page_url output:
#   https://github.com/actions/deploy-pages
# - GitHub Actions workflow monitoring and run metadata via REST API:
#   https://docs.github.com/en/rest/actions/workflow-runs
# - GitHub Pages REST API (build_type, html_url, status):
#   https://docs.github.com/en/rest/pages
# - GitHub CLI authenticated REST API interface (`gh api`):
#   https://cli.github.com/manual/gh_api
# - Vite public base path for project Pages URLs:
#   https://vite.dev/guide/static-deploy
# - Compose health-check/startup semantics:
#   https://docs.docker.com/compose/how-tos/startup-order/
# - sqlite-vec Python extension loading (must load on every connection):
#   https://github.com/asg017/sqlite-vec/blob/main/site/getting-started/installation.md

set -o pipefail
set -u

PROJECT_SLUG="swipswaps/fedora-ai-agents-explainer"
PROJECT_NAME="fedora-ai-agents-explainer"
PAGES_URL="https://swipswaps.github.io/fedora-ai-agents-explainer/"
REPO_URL="https://github.com/${PROJECT_SLUG}.git"
# Scope the generated project to the directory containing this builder by default.
# This prevents surprise creation of ~/Documents/fedora-ai-agents-explainer and keeps
# all generated files inside the repository folder the operator deliberately selected.
# An explicit PROJECT_DIR override remains supported for automation.
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
PROJECT_DIR="${PROJECT_DIR:-${SCRIPT_DIR}}"
SKIP_PUBLISH="${SKIP_PUBLISH:-0}"
SKIP_DEPENDENCY_INSTALL="${SKIP_DEPENDENCY_INSTALL:-0}"
TIMESTAMP="$(date -u +%Y%m%dT%H%M%SZ)"
BACKUP_ROOT="${XDG_STATE_HOME:-${HOME}/.local/state}/${PROJECT_NAME}/backups/${TIMESTAMP}"

printf '\n============================================================\n'
printf ' FEDORA AI AGENTS EXPLAINER — ONE-SHOT BUILD\n'
printf ' Repository: %s\n' "$PROJECT_SLUG"
printf ' Target:     %s\n' "$PROJECT_DIR"
printf '============================================================\n'

fail() {
    printf '\nERROR: %s\n' "$*" >&2
    return 1
}


# Automatically select or start a usable Docker Engine.
# Prefer the logged-in user's rootless daemon; otherwise reuse a reachable daemon.
# Never change the global Docker context, enable lingering, or delete Docker data.
fedora_ai_agents_ensure_docker() {
    local runtime_dir rootless_socket probe_log unit_log attempt
    local rootless_ready=0

    printf '\n===== DOCKER ENGINE AUTO-RESOLUTION =====\n'

    if ! command -v docker; then
        printf 'ERROR: Docker CLI is not installed.\n' >&2
        return 1
    fi
    if ! command -v timeout; then
        printf 'ERROR: timeout utility is required.\n' >&2
        return 1
    fi
    if ! docker compose version; then
        printf 'ERROR: Docker Compose v2 is unavailable.\n' >&2
        return 1
    fi

    runtime_dir="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
    rootless_socket="${runtime_dir}/docker.sock"
    probe_log="$(mktemp /tmp/fedora-ai-agents-docker-probe.XXXXXX)" || return 1
    unit_log="$(mktemp /tmp/fedora-ai-agents-docker-unit.XXXXXX)" || {
        rm -f -- "$probe_log"
        return 1
    }

    printf 'Checking rootless Docker socket: %s\n' "$rootless_socket"

    if [ -S "$rootless_socket" ]; then
        if timeout 20s env -u DOCKER_CONTEXT \
            DOCKER_HOST="unix://${rootless_socket}" \
            docker info --format \
            'Server={{.ServerVersion}} Root={{.DockerRootDir}} Security={{json .SecurityOptions}}' \
            >"$probe_log" 2>&1; then

            export DOCKER_HOST="unix://${rootless_socket}"
            unset DOCKER_CONTEXT
            rootless_ready=1
            printf 'Reusing the already-running rootless Docker daemon.\n'
            cat "$probe_log"
        else
            printf 'Rootless socket exists but is not responding.\n'
            cat "$probe_log"
        fi
    else
        printf 'Rootless socket is not present yet.\n'
    fi

    if [ "$rootless_ready" -ne 1 ]; then
        printf '\nChecking the currently configured Docker daemon.\n'

        if timeout 20s docker info --format \
            'Server={{.ServerVersion}} Root={{.DockerRootDir}} Security={{json .SecurityOptions}}' \
            >"$probe_log" 2>&1; then

            printf 'Configured Docker daemon is reachable; reusing it.\n'
            cat "$probe_log"
        else
            printf 'Configured Docker daemon is not reachable.\n'
            cat "$probe_log"

            printf '\nAttempting user-scoped rootless Docker startup.\n'

            if ! command -v dockerd-rootless-setuptool.sh; then
                printf 'ERROR: Rootless Docker setup utility is unavailable.\n' >&2
                rm -f -- "$probe_log" "$unit_log"
                return 1
            fi

            if ! systemctl --user status --no-pager >"$unit_log" 2>&1; then
                printf 'ERROR: User systemd manager is unavailable.\n' >&2
                cat "$unit_log" >&2
                rm -f -- "$probe_log" "$unit_log"
                return 1
            fi

            if ! systemctl --user cat docker.service >"$unit_log" 2>&1; then
                printf 'Rootless Docker user service is not installed.\n'

                if ! dockerd-rootless-setuptool.sh check; then
                    printf 'ERROR: Rootless Docker prerequisites failed.\n' >&2
                    rm -f -- "$probe_log" "$unit_log"
                    return 1
                fi

                printf 'Installing rootless Docker user service.\n'
                if ! dockerd-rootless-setuptool.sh install; then
                    printf 'ERROR: Rootless Docker service installation failed.\n' >&2
                    rm -f -- "$probe_log" "$unit_log"
                    return 1
                fi
            else
                printf 'Existing rootless Docker user service found.\n'
            fi

            printf 'Starting current-user Docker service; lingering remains unchanged.\n'

            if ! systemctl --user enable --now docker.service; then
                printf 'ERROR: Could not start rootless Docker service.\n' >&2
                systemctl --user status docker.service --no-pager >&2
                rm -f -- "$probe_log" "$unit_log"
                return 1
            fi

            attempt=0
            while [ "$attempt" -lt 30 ]; do
                attempt=$((attempt + 1))

                if [ -S "$rootless_socket" ] && \
                    timeout 10s env -u DOCKER_CONTEXT \
                    DOCKER_HOST="unix://${rootless_socket}" \
                    docker info --format \
                    'Server={{.ServerVersion}} Root={{.DockerRootDir}} Security={{json .SecurityOptions}}' \
                    >"$probe_log" 2>&1; then

                    export DOCKER_HOST="unix://${rootless_socket}"
                    unset DOCKER_CONTEXT
                    rootless_ready=1
                    printf 'Rootless Docker ready after %s/30 attempts.\n' "$attempt"
                    cat "$probe_log"
                    break
                fi

                if [ "$attempt" -eq 1 ] || [ $((attempt % 5)) -eq 0 ]; then
                    printf 'Waiting for Docker readiness: %s/30\n' "$attempt"
                fi
                sleep 1
            done

            if [ "$rootless_ready" -ne 1 ]; then
                printf 'ERROR: Rootless Docker did not become ready within 30 seconds.\n' >&2
                cat "$probe_log" >&2
                systemctl --user status docker.service --no-pager >&2
                rm -f -- "$probe_log" "$unit_log"
                return 1
            fi
        fi
    fi

    printf '\n===== VERIFY SELECTED DOCKER ENGINE =====\n'

    if ! timeout 20s docker info --format \
        'Server={{.ServerVersion}} Root={{.DockerRootDir}} Security={{json .SecurityOptions}}'; then
        printf 'ERROR: Final Docker daemon verification failed.\n' >&2
        rm -f -- "$probe_log" "$unit_log"
        return 1
    fi

    if ! docker compose version; then
        printf 'ERROR: Docker Compose verification failed.\n' >&2
        rm -f -- "$probe_log" "$unit_log"
        return 1
    fi

    rm -f -- "$probe_log" "$unit_log"

    printf 'Docker Engine and Compose are ready.\n'
    printf 'Existing containers and named volumes have not been removed.\n'
    return 0
}

main() {
command -v bash >/tmp/fedora-ai-agents-command-check.log 2>&1 || { fail 'Bash is required.'; return 1; }
command -v git >/tmp/fedora-ai-agents-command-check.log 2>&1 || { fail 'Git is required.'; return 1; }
command -v node >/tmp/fedora-ai-agents-command-check.log 2>&1 || { fail 'Node.js is required. Install Node.js 20.19+ or 22.12+.'; return 1; }
command -v npm >/tmp/fedora-ai-agents-command-check.log 2>&1 || { fail 'npm is required.'; return 1; }
command -v python3 >/tmp/fedora-ai-agents-command-check.log 2>&1 || { fail 'Python 3 is required.'; return 1; }

if [ "$SKIP_PUBLISH" != "1" ]; then
    command -v gh >/tmp/fedora-ai-agents-command-check.log 2>&1 || { fail 'GitHub CLI (gh) is required for automatic publication.'; return 1; }
    command -v xdg-open >/tmp/fedora-ai-agents-command-check.log 2>&1 || { fail 'xdg-open is required to open the deployed site.'; return 1; }
    gh auth status || { fail 'GitHub CLI is not authenticated. Run gh auth login before building.'; return 1; }
fi
if [ "$SKIP_DEPENDENCY_INSTALL" != "1" ]; then
    fedora_ai_agents_ensure_docker || {
        fail 'Unable to make Docker Engine and Compose available automatically.'
        return 1
    }
fi

NODE_VERSION="$(node -p 'process.versions.node')"
if ! node -e 'const [major,minor] = process.versions.node.split(".").map(Number); const ok = major > 22 || (major === 22 && minor >= 12) || (major === 20 && minor >= 19); if (!ok) process.exitCode = 1;'; then
    fail "Vite 7 requires Node.js 20.19+, 22.12+, or newer; detected ${NODE_VERSION}."
    return 1
fi

printf '\n===== PREFLIGHT: TARGET DIRECTORY =====\n'
printf 'Project directory: %s\n' "$PROJECT_DIR"
mkdir -p "$(dirname "$PROJECT_DIR")"
if [ -L "$PROJECT_DIR" ]; then
    fail 'The target project directory is a symbolic link. Refusing to write through it.'
    return 1
fi
mkdir -p "$PROJECT_DIR"

if [ -e "$PROJECT_DIR/.git" ]; then
    printf 'Existing Git repository detected. Auditing its state before file generation.\n'
    GIT_STATUS_FILE="$(mktemp)" || return 1
    git -C "$PROJECT_DIR" status --porcelain=v1 > "$GIT_STATUS_FILE" || { fail 'Unable to read the existing Git working tree.'; return 1; }
    if awk 'NF { found=1 } END { exit(found ? 0 : 1) }' "$GIT_STATUS_FILE"; then
        rm -f -- "$GIT_STATUS_FILE"
        fail 'The target Git repository has uncommitted changes. Commit/stash them before rerunning; no files were changed.'
        return 1
    else
        rm -f -- "$GIT_STATUS_FILE"
        printf 'Git working tree is clean.\n'
    fi
    if git -C "$PROJECT_DIR" remote | awk '$0 == "origin" { found=1 } END { exit(found ? 0 : 1) }'; then
        EXISTING_ORIGIN="$(git -C "$PROJECT_DIR" remote get-url origin)"
        if [ "$EXISTING_ORIGIN" != "$REPO_URL" ] && [ "$EXISTING_ORIGIN" != "https://github.com/${PROJECT_SLUG}" ]; then
            fail "Existing origin does not match the approved repository: ${EXISTING_ORIGIN}"
            return 1
        fi
    fi
else
    printf 'No Git repository exists yet. Existing files will be individually backed up if changed.\n'
fi

mkdir -p "$BACKUP_ROOT"

write_file() {
    local relative="$1"
    local destination="${PROJECT_DIR}/${relative}"
    local parent temporary
    parent="$(dirname "$destination")"
    mkdir -p "$parent" || return 1
    temporary="$(mktemp "${parent}/.fedora-ai-agents.XXXXXX")" || return 1
    cat > "$temporary" || return 1
    if [ -f "$destination" ] && cmp -s "$temporary" "$destination"; then
        # Content idempotence must not preserve an accidental restrictive mode.
        chmod 0644 "$destination" || return 1
        printf 'UNCHANGED  %s\n' "$relative"
        rm -f -- "$temporary"
        return 0
    fi
    if [ -e "$destination" ]; then
        local backup_path="${BACKUP_ROOT}/${relative}"
        mkdir -p "$(dirname "$backup_path")" || return 1
        cp -a -- "$destination" "$backup_path" || return 1
        printf 'BACKUP     %s -> %s\n' "$relative" "$backup_path"
    fi
    chmod 0644 "$temporary" || return 1
    expected_hash="$(sha256sum "$temporary" | awk '{print $1}')" || return 1
    mv -f -- "$temporary" "$destination" || return 1
    actual_hash="$(sha256sum "$destination" | awk '{print $1}')" || return 1
    if [ "$expected_hash" != "$actual_hash" ]; then
        fail "Read-back SHA-256 verification failed for ${relative}."
        return 1
    fi
    printf 'WRITE      %s\n' "$relative"
}

printf '\n===== GENERATING COMPLETE REPOSITORY =====\n'

write_file 'package.json' <<'EOF'
{
  "name": "fedora-ai-agents-explainer",
  "private": true,
  "version": "1.0.0",
  "type": "module",
  "engines": { "node": "^20.19.0 || >=22.12.0" },
  "scripts": {
    "dev": "vite --host 127.0.0.1",
    "build": "vite build",
    "preview": "vite preview --host 127.0.0.1"
  },
  "dependencies": {
    "d3": "^7.9.0",
    "react": "^19.1.0",
    "react-dom": "^19.1.0",
    "three": "^0.179.1"
  },
  "devDependencies": {
    "@vitejs/plugin-react": "^5.0.0",
    "vite": "^7.0.0"
  }
}
EOF

write_file 'vite.config.js' <<'EOF'
import { defineConfig } from 'vite';
import react from '@vitejs/plugin-react';

// GitHub Pages serves this repository beneath /fedora-ai-agents-explainer/.
// The development server proxies /api to the loopback-only FastAPI container.
export default defineConfig({
  plugins: [react()],
  base: process.env.GITHUB_ACTIONS === 'true' ? '/fedora-ai-agents-explainer/' : '/',
  server: {
    host: '127.0.0.1',
    port: 5173,
    strictPort: true,
    proxy: {
      '/api': {
        target: 'http://127.0.0.1:8000',
        changeOrigin: false,
      },
    },
  },
  preview: { host: '127.0.0.1', port: 4173, strictPort: true },
  build: { sourcemap: true, outDir: 'dist' },
});
EOF

write_file 'index.html' <<'EOF'
<!doctype html>
<html lang="en">
  <head>
    <meta charset="UTF-8" />
    <meta name="viewport" content="width=device-width, initial-scale=1.0" />
    <meta name="theme-color" content="#0b1018" />
    <meta name="description" content="An evidence-led, Fedora-native guide to an Omarchy-inspired AI coding agent launcher, usage dashboard, and local data plane." />
    <title>Fedora AI Agents — Omarchy-inspired, Fedora-native</title>
  </head>
  <body>
    <div id="root"></div>
    <script type="module" src="/src/main.jsx"></script>
  </body>
</html>
EOF

write_file 'src/main.jsx' <<'EOF'
import React from 'react';
import { createRoot } from 'react-dom/client';
import App from './App.jsx';
import './style.css';

createRoot(document.getElementById('root')).render(
  <React.StrictMode>
    <App />
  </React.StrictMode>,
);
EOF

write_file 'src/architecture.js' <<'EOF'
import * as THREE from 'three';

// A small, deterministic 3D topology view. It is explanatory, not a live network
// scanner: live state is obtained separately from the FastAPI capability endpoint.
export function createArchitectureScene(canvas) {
  const scene = new THREE.Scene();
  scene.background = new THREE.Color('#0b1018');
  const camera = new THREE.PerspectiveCamera(42, 1, 0.1, 100);
  camera.position.set(0, 5.5, 11);
  const renderer = new THREE.WebGLRenderer({ canvas, antialias: true, alpha: false });
  renderer.setPixelRatio(Math.min(window.devicePixelRatio || 1, 2));
  renderer.shadowMap.enabled = true;

  scene.add(new THREE.AmbientLight(0xffffff, 1.35));
  const key = new THREE.DirectionalLight(0x9bc7ff, 2.1);
  key.position.set(4, 7, 5);
  scene.add(key);

  const nodes = [
    { name: 'Agents', position: [-4.1, 0, 0], color: 0x71d5bd },
    { name: 'Collector', position: [-1.4, 0, 0], color: 0x75a9ff },
    { name: 'FastAPI', position: [1.4, 0, 0], color: 0xd5a6ff },
    { name: 'SQLite', position: [4.1, 0, 0], color: 0xffc77d },
  ];
  const materialFor = (color) => new THREE.MeshStandardMaterial({
    color, roughness: 0.36, metalness: 0.18,
    emissive: color, emissiveIntensity: 0.12,
  });
  const geometry = new THREE.IcosahedronGeometry(0.78, 2);
  const meshes = nodes.map((node) => {
    const mesh = new THREE.Mesh(geometry, materialFor(node.color));
    mesh.position.set(...node.position);
    mesh.castShadow = true;
    scene.add(mesh);
    return mesh;
  });

  // Lines represent explicit data flow, not implied trust or authentication.
  for (let index = 0; index < nodes.length - 1; index += 1) {
    const start = new THREE.Vector3(...nodes[index].position);
    const end = new THREE.Vector3(...nodes[index + 1].position);
    const line = new THREE.Line(
      new THREE.BufferGeometry().setFromPoints([start, end]),
      new THREE.LineBasicMaterial({ color: 0x43556e, transparent: true, opacity: 0.9 }),
    );
    scene.add(line);
  }

  const floor = new THREE.GridHelper(13, 26, 0x26374b, 0x172333);
  floor.position.y = -1.35;
  scene.add(floor);

  let frame = 0;
  let disposed = false;
  const resize = () => {
    const width = Math.max(canvas.clientWidth, 320);
    const height = Math.max(canvas.clientHeight, 220);
    camera.aspect = width / height;
    camera.updateProjectionMatrix();
    renderer.setSize(width, height, false);
  };
  const observer = new ResizeObserver(resize);
  observer.observe(canvas);
  resize();

  const animate = () => {
    if (disposed) return;
    frame = requestAnimationFrame(animate);
    const t = performance.now() * 0.00045;
    meshes.forEach((mesh, index) => {
      mesh.rotation.y = t + index * 0.35;
      mesh.position.y = Math.sin(t * 2 + index) * 0.12;
    });
    renderer.render(scene, camera);
  };
  animate();

  return () => {
    disposed = true;
    cancelAnimationFrame(frame);
    observer.disconnect();
    scene.traverse((object) => {
      if (object.geometry) object.geometry.dispose();
      if (object.material) {
        const materials = Array.isArray(object.material) ? object.material : [object.material];
        materials.forEach((material) => material.dispose());
      }
    });
    renderer.dispose();
  };
}
EOF

write_file 'src/UsageChart.jsx' <<'EOF'
import React, { useEffect, useRef } from 'react';
import * as d3 from 'd3';

// D3 owns the SVG marks and scales; React owns the surrounding component lifecycle.
export default function UsageChart({ data }) {
  const svgRef = useRef(null);
  useEffect(() => {
    const svg = d3.select(svgRef.current);
    svg.selectAll('*').remove();
    const width = 620;
    const height = 210;
    const margin = { top: 14, right: 18, bottom: 34, left: 48 };
    const innerWidth = width - margin.left - margin.right;
    const innerHeight = height - margin.top - margin.bottom;
    const values = data?.length ? data : [
      { day: 'Mon', input_output_tokens: 0 }, { day: 'Tue', input_output_tokens: 0 },
      { day: 'Wed', input_output_tokens: 0 }, { day: 'Thu', input_output_tokens: 0 },
      { day: 'Fri', input_output_tokens: 0 }, { day: 'Sat', input_output_tokens: 0 },
      { day: 'Sun', input_output_tokens: 0 },
    ];
    const x = d3.scaleBand().domain(values.map((item) => item.day)).range([0, innerWidth]).padding(0.32);
    const y = d3.scaleLinear().domain([0, Math.max(1, d3.max(values, (item) => item.input_output_tokens) || 1)]).nice().range([innerHeight, 0]);
    const group = svg.attr('viewBox', `0 0 ${width} ${height}`).append('g')
      .attr('transform', `translate(${margin.left},${margin.top})`);
    group.append('g').call(d3.axisLeft(y).ticks(4).tickFormat(d3.format('~s')))
      .call((axis) => axis.selectAll('text').attr('fill', '#92a2b7'))
      .call((axis) => axis.selectAll('line,path').attr('stroke', '#2a3a4d'));
    group.append('g').attr('transform', `translate(0,${innerHeight})`)
      .call(d3.axisBottom(x).tickSize(0))
      .call((axis) => axis.selectAll('text').attr('fill', '#92a2b7').attr('dy', '1.5em'))
      .call((axis) => axis.select('.domain').attr('stroke', '#2a3a4d'));
    group.selectAll('rect.bar').data(values).join('rect')
      .attr('class', 'bar').attr('x', (item) => x(item.day))
      .attr('y', (item) => y(item.input_output_tokens)).attr('width', x.bandwidth())
      .attr('height', (item) => innerHeight - y(item.input_output_tokens))
      .attr('rx', 5).attr('fill', '#71d5bd');
    group.selectAll('text.value').data(values.filter((item) => item.input_output_tokens > 0)).join('text')
      .attr('class', 'value').attr('x', (item) => x(item.day) + x.bandwidth() / 2)
      .attr('y', (item) => y(item.input_output_tokens) - 7).attr('text-anchor', 'middle')
      .attr('fill', '#dce8f5').attr('font-size', 10).text((item) => d3.format('~s')(item.input_output_tokens));
  }, [data]);
  return <svg className="usage-chart" ref={svgRef} role="img" aria-label="Daily reported input plus output token counters" />;
}
EOF

write_file 'src/App.jsx' <<'EOF'
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
EOF

write_file 'src/style.css' <<'EOF'
@import url('https://fonts.googleapis.com/css2?family=DM+Mono:wght@400;500&family=Manrope:wght@400;500;600;700;800&display=swap');
:root{font-family:Manrope,system-ui,sans-serif;color:#e8eef7;background:#0b1018;font-synthesis:none;text-rendering:optimizeLegibility;font-optical-sizing:auto;font-weight:400;--muted:#91a0b5;--line:#263446;--panel:#111a26;--mint:#71d5bd;--blue:#75a9ff;--violet:#d5a6ff;--amber:#ffc77d}*{box-sizing:border-box}html{scroll-behavior:smooth}body{margin:0;min-width:320px;background:radial-gradient(ellipse at 18% 0%,#142537 0,transparent 34%),#0b1018}a{color:inherit;text-decoration:none}.shell{width:min(1200px,calc(100% - 48px));margin:auto}.topbar{height:86px;display:flex;align-items:center;justify-content:space-between;border-bottom:1px solid var(--line);gap:24px}.brand{display:flex;align-items:center;gap:11px;font-size:12px;font-weight:800;letter-spacing:.12em}.brand small{display:block;color:var(--muted);font:9px 'DM Mono',monospace;letter-spacing:.12em;margin-top:4px}.brand-mark{display:grid;place-items:center;width:38px;height:38px;border:1px solid #3d6e69;color:var(--mint);border-radius:12px;background:#102721;font:600 13px 'DM Mono',monospace}.topbar nav{display:flex;gap:25px;color:#aab8ca;font-size:12px}.topbar nav a:hover,.reference:hover strong{color:var(--mint)}.status-pill{display:inline-flex;align-items:center;gap:8px;border:1px solid var(--line);border-radius:99px;padding:8px 11px;color:#a9b7c9;font:9px 'DM Mono',monospace;white-space:nowrap}.status-pill i{width:6px;height:6px;border-radius:50%;background:#8896a9}.status-pill.connected i{background:var(--mint);box-shadow:0 0 12px var(--mint)}.status-pill.offline i{background:#f0a16c}.hero{display:grid;grid-template-columns:1.15fr .85fr;align-items:center;min-height:520px;padding:70px 0 62px;border-bottom:1px solid var(--line)}.eyebrow{font:10px 'DM Mono',monospace;letter-spacing:.16em;color:var(--mint);margin:0 0 15px}.hero h1{font-size:clamp(44px,6vw,74px);line-height:1.06;letter-spacing:-.065em;margin:0;font-weight:700}.hero h1 em{font-style:normal;color:var(--mint)}.hero-lede{max-width:620px;color:#aab8ca;line-height:1.8;font-size:14px;margin:24px 0 26px}.button-row{display:flex;gap:10px;align-items:center;flex-wrap:wrap}.button{display:inline-flex;align-items:center;justify-content:center;gap:9px;border:1px solid #35465b;border-radius:8px;padding:12px 16px;color:#e9f0f8;background:#111b28;font:600 11px Manrope,sans-serif;cursor:pointer;transition:.18s ease}.button:hover{border-color:var(--mint);transform:translateY(-1px)}.button-primary{background:var(--mint);color:#092019;border-color:var(--mint)}.button-primary:hover{background:#8ae4d0}.button-small{padding:8px 11px;font-size:10px}.button:disabled{opacity:.45;cursor:not-allowed;transform:none}.hero-facts{display:flex;gap:20px;flex-wrap:wrap;margin-top:36px;color:#72849a;font:9px 'DM Mono',monospace}.hero-orbit{height:330px;position:relative;display:grid;place-items:center}.orbit{position:absolute;border:1px solid #294052;border-radius:50%;transform:rotate(-23deg)}.orbit-one{width:290px;height:150px}.orbit-two{width:220px;height:270px;transform:rotate(55deg)}.orbit-core{width:116px;height:116px;border:1px solid #3c7168;background:radial-gradient(circle,#183b37,#10201f);border-radius:50%;display:flex;flex-direction:column;align-items:center;justify-content:center;box-shadow:0 0 65px #4ac3a522;z-index:2}.orbit-core b{font:30px 'DM Mono',monospace;color:var(--mint)}.orbit-core span{font:8px 'DM Mono',monospace;line-height:1.5;letter-spacing:.12em;color:#a7cfc6;text-align:center}.orbit-node{position:absolute;z-index:3;display:grid;place-items:center;width:38px;height:38px;border-radius:12px;background:#152637;border:1px solid #45617d;color:#dce8f5;font:10px 'DM Mono',monospace;box-shadow:0 8px 30px #0008}.node-a{top:40px;left:45%}.node-b{right:7%;top:47%}.node-c{bottom:34px;left:44%}.node-d{left:6%;top:47%}.backend-banner{margin:28px 0 20px;border:1px solid #314657;background:linear-gradient(110deg,#142a2b,#121c29 65%);border-radius:12px;padding:22px 24px;display:flex;align-items:center;justify-content:space-between;gap:24px}.backend-banner h2{font-size:18px;margin:0 0 7px}.backend-banner p{color:var(--muted);font-size:11px;margin:0;line-height:1.6}.section{padding:76px 0 20px}.section-heading{display:grid;grid-template-columns:1.1fr .9fr;gap:60px;align-items:end;margin-bottom:28px}.section-heading h2{font-size:clamp(27px,3.3vw,40px);letter-spacing:-.045em;line-height:1.15;margin:0;max-width:620px}.section-heading>p{font-size:12px;line-height:1.8;color:var(--muted);margin:0 0 3px}.architecture-card,.database-main,.usage-card,.search-card,.code-panel{background:linear-gradient(145deg,#121d2a,#0f1722);border:1px solid var(--line);border-radius:13px}.architecture-card{padding:18px 22px 15px}.architecture-labels{display:grid;grid-template-columns:repeat(4,1fr);text-align:center;color:#74869c;font:9px 'DM Mono',monospace;letter-spacing:.1em}.architecture-canvas{display:block;width:100%;height:300px}.architecture-legend{display:flex;justify-content:center;gap:25px;flex-wrap:wrap;color:#9aaabd;font:9px 'DM Mono',monospace}.dot{display:inline-block;width:7px;height:7px;border-radius:50%;margin-right:7px}.mint{background:var(--mint)}.blue{background:var(--blue)}.violet{background:var(--violet)}.amber{background:var(--amber)}.principle-grid{display:grid;grid-template-columns:repeat(3,1fr);gap:14px;margin-top:15px}.principle-grid article,.agent-card{padding:20px;border:1px solid var(--line);border-radius:11px;background:#101925}.principle-grid b{color:var(--mint);font:10px 'DM Mono',monospace}.principle-grid h3,.agent-card h3{font-size:15px;margin:12px 0 8px}.principle-grid p,.agent-card p{color:var(--muted);font-size:11px;line-height:1.7;margin:0}.agent-grid{display:grid;grid-template-columns:repeat(3,1fr);gap:12px}.agent-card{min-height:185px}.agent-card-top{display:flex;align-items:center;justify-content:space-between}.agent-icon{width:34px;height:34px;display:grid;place-items:center;border:1px solid #38544f;border-radius:10px;color:var(--mint);font:11px 'DM Mono',monospace}.micro-tag{color:#8ca0b7;border:1px solid #304054;border-radius:5px;padding:5px 7px;font:8px 'DM Mono',monospace;letter-spacing:.08em}.agent-card h3{margin:13px 0 4px}.agent-card code{color:#8eb6ed;font:10px 'DM Mono',monospace}.agent-card p{margin-top:9px;min-height:38px}.agent-runtime{display:block;margin-top:13px;color:#72849a;font:8px 'DM Mono',monospace;letter-spacing:.07em}.collector-row{margin-top:14px;border:1px solid #38534f;border-radius:11px;padding:19px 21px;display:flex;align-items:center;justify-content:space-between;gap:22px;background:#11211f}.collector-row h3{font-size:14px;margin:0 0 6px}.collector-row p{font-size:11px;color:#a1b7b1;line-height:1.7;margin:0;max-width:760px}.inline-message{color:var(--mint);font-size:11px}.database-grid{display:grid;grid-template-columns:1fr 1fr;gap:14px}.database-ops{display:grid;grid-template-columns:repeat(2,minmax(0,1fr));gap:14px;margin-top:14px}.database-main,.usage-card{padding:22px}.db-heading{display:flex;gap:14px;align-items:center}.db-symbol{font-size:29px;color:var(--amber)}.db-heading h3,.usage-heading h3{margin:0;font-size:17px}.db-heading p{color:var(--muted);font-size:10px;margin:5px 0 0}.db-features{display:flex;flex-wrap:wrap;gap:8px;margin:28px 0}.db-features span{border:1px solid #34465a;background:#172332;padding:8px 10px;border-radius:6px;color:#b9c8d8;font:9px 'DM Mono',monospace}.db-meter{border-top:1px solid var(--line);padding-top:17px;display:flex;justify-content:space-between;align-items:center;gap:15px}.db-meter div span,.db-meter div b{display:block}.db-meter div span{font:8px 'DM Mono',monospace;color:#73849a}.db-meter div b{font:10px 'DM Mono',monospace;color:#c7d5e4;margin-top:7px}.usage-heading{display:flex;align-items:center;justify-content:space-between}.usage-heading .eyebrow{margin-bottom:7px}.usage-chart{width:100%;height:auto;margin-top:12px;overflow:visible}.usage-total{display:grid;grid-template-columns:repeat(3,1fr);border-top:1px solid var(--line);padding-top:14px;gap:10px}.usage-total small,.usage-total strong,.usage-components small,.usage-components strong{display:block}.usage-total small,.usage-components small{color:#73849a;font:8px 'DM Mono',monospace}.usage-total strong{font-size:17px;margin-top:6px}.usage-components{display:grid;grid-template-columns:repeat(3,1fr);gap:10px;margin-top:10px}.usage-components div{padding:10px;border:1px solid var(--line);border-radius:9px}.usage-components strong{font-size:14px;margin-top:6px}.usage-footnote{color:var(--muted);font-size:9px;line-height:1.7;margin:14px 0 0}.usage-warning{padding:10px 12px;border:1px solid var(--amber);border-radius:10px;color:var(--amber);font-size:10px;line-height:1.6;margin:12px 0 0}.search-card{margin-top:14px;padding:22px;display:grid;grid-template-columns:1fr 1fr;gap:14px;align-items:center}.search-card h3{margin:0 0 7px;font-size:17px}.search-card p:not(.eyebrow){font-size:10px;line-height:1.7;color:var(--muted);max-width:510px}.search-card form{display:flex;gap:8px}.search-card input{min-width:0;flex:1;border:1px solid #35465b;background:#0c141e;border-radius:8px;padding:12px;color:#eaf0f7;font:11px Manrope}.search-results{grid-column:1/-1;margin:0;padding-left:20px}.search-results li{padding:10px 0;border-top:1px solid var(--line);font-size:11px}.search-results span,.search-results small{display:block;color:var(--muted);margin-top:5px}.search-results small{font:9px 'DM Mono',monospace}.install-grid{display:grid;grid-template-columns:.9fr 1.1fr;gap:14px}.install-copy{padding:22px;border:1px solid var(--line);border-radius:13px;background:#101925}.step{display:flex;gap:14px;margin-bottom:23px}.step>b{color:var(--mint);font:11px 'DM Mono',monospace;padding-top:3px}.step h3{font-size:13px;margin:0 0 6px}.step p{font-size:10px;line-height:1.7;color:var(--muted);margin:0}.install-copy>.button{margin:8px 8px 0 0}.code-panel{overflow:hidden}.code-heading{display:flex;justify-content:space-between;align-items:center;padding:13px 15px;border-bottom:1px solid var(--line);font-size:10px}.code-panel pre{margin:0;padding:18px;overflow:auto;color:#b8c8d9;font:10px/1.8 'DM Mono',monospace;white-space:pre-wrap}.warning-note{margin-top:14px;padding:15px 18px;border-left:2px solid var(--amber);background:#201d18;color:#c9bba4;font-size:10px;line-height:1.7}.warning-note strong{color:#f2d09c}.reference-list{border-top:1px solid var(--line)}.reference{display:flex;gap:15px;padding:16px 4px;border-bottom:1px solid var(--line)}.reference-arrow{color:var(--mint);font-size:14px}.reference strong{font-size:12px}.reference p{margin:5px 0;color:var(--muted);font-size:10px}.reference small{color:#74869a;font:9px 'DM Mono',monospace;overflow-wrap:anywhere}footer{display:flex;align-items:center;justify-content:space-between;gap:20px;border-top:1px solid var(--line);margin-top:80px;padding:28px 0 35px}footer p{font-size:10px;color:var(--muted)}footer>a{font-size:10px;color:var(--mint)}@media(max-width:900px){.topbar nav{display:none}.hero{grid-template-columns:1fr}.hero-orbit{height:270px}.section-heading{grid-template-columns:1fr;gap:14px}.database-grid,.database-ops,.install-grid{grid-template-columns:1fr}.search-card{grid-template-columns:1fr}}@media(max-width:640px){.shell{width:min(100% - 28px,1200px)}.topbar{height:72px}.topbar>.status-pill{font-size:7px;padding:7px}.hero{padding:52px 0 35px}.hero h1{font-size:43px}.hero-orbit{height:230px;transform:scale(.86)}.backend-banner,.collector-row{align-items:flex-start;flex-direction:column}.principle-grid,.agent-grid{grid-template-columns:1fr}.architecture-canvas{height:220px}.architecture-labels{font-size:7px}.architecture-legend{gap:12px}.usage-total,.usage-components{grid-template-columns:1fr}.search-card form{flex-direction:column}.code-heading{align-items:flex-start;gap:10px;flex-direction:column}footer{align-items:flex-start;flex-direction:column}}
EOF

write_file 'backend/requirements.txt' <<'EOF'
fastapi==0.115.14
uvicorn[standard]==0.34.3
sqlite-vec==0.1.9
httpx==0.28.1
pytest==8.4.1
EOF

write_file 'requirements.txt' <<'EOF'
# Root convenience file; the canonical runtime/test pins live in backend/requirements.txt.
-r backend/requirements.txt
EOF

write_file 'backend/Dockerfile' <<'EOF'
# Build a current, hash-verified SQLite shared library separately from the runtime.
# SQLite upstream release/checksum reference: https://www.sqlite.org/download.html
# FTS5 build configuration reference: https://www.sqlite.org/fts5.html
# Python sqlite3 extension-loading API: https://docs.python.org/3/library/sqlite3.html#sqlite3.Connection.enable_load_extension
# Debian stable can ship an older SQLite patch level; the application database
# uses the upstream 3.54.1 release with FTS5, JSON1 and loadable extensions.
FROM python:3.12-slim-trixie AS sqlite-build
ARG SQLITE_VERSION=3540100
ARG SQLITE_SHA256=926ef8d3eab93fbf6e06011901273eec076b25594a4e1cdadd50c987f4f6d64e
RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential ca-certificates curl make && \
    curl --fail --location --silent --show-error \
      "https://www.sqlite.org/2026/sqlite-autoconf-${SQLITE_VERSION}.tar.gz" \
      --output /tmp/sqlite-autoconf.tar.gz && \
    printf '%s  %s\n' "$SQLITE_SHA256" /tmp/sqlite-autoconf.tar.gz | sha256sum -c - && \
    tar -xzf /tmp/sqlite-autoconf.tar.gz -C /tmp && \
    cd "/tmp/sqlite-autoconf-${SQLITE_VERSION}" && \
    ./configure --prefix=/opt/sqlite --enable-fts5 && \
    make -j"$(nproc)" && make install

FROM python:3.12-slim-trixie AS runtime
COPY --from=sqlite-build /opt/sqlite/lib/ /opt/sqlite/lib/
ENV LD_LIBRARY_PATH=/opt/sqlite/lib PYTHONDONTWRITEBYTECODE=1 PYTHONUNBUFFERED=1 PIP_NO_CACHE_DIR=1
RUN python -c 'import sqlite3; assert sqlite3.sqlite_version_info >= (3,54,1), sqlite3.sqlite_version; c=sqlite3.connect(":memory:"); c.execute("CREATE VIRTUAL TABLE fts_check USING fts5(content)"); assert c.execute("SELECT json_valid(?)", ("{\"ok\":true}",)).fetchone()[0] == 1; c.enable_load_extension(True); c.enable_load_extension(False); c.close(); print("Verified SQLite", sqlite3.sqlite_version, "with FTS5, JSON1 and extension loading")'
WORKDIR /app
COPY requirements.txt /app/requirements.txt
RUN python -m pip install --upgrade pip && python -m pip install -r /app/requirements.txt
COPY . /app
RUN useradd --create-home --uid 10001 appuser && mkdir -p /data && chown -R appuser:appuser /app /data
USER appuser
EXPOSE 8000
HEALTHCHECK --interval=20s --timeout=5s --start-period=15s --retries=4 CMD python -c "import urllib.request; urllib.request.urlopen('http://127.0.0.1:8000/health', timeout=3)"
CMD ["uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8000", "--proxy-headers", "--no-server-header"]
EOF

write_file 'backend/collectors/__init__.py' <<'EOF'
"""Independent agent usage collectors with a stable JSON record contract."""
EOF

write_file 'backend/collectors/opencode.py' <<'EOF'
"""Read-only OpenCode usage adapter for V1 and V2 SQLite layouts.

Schema evidence is checked against OpenCode's generated database schema:
https://github.com/anomalyco/opencode/blob/dev/packages/core/src/database/schema.gen.ts
The collector strategy is informed by Omarchy's shared OpenCode reader:
https://github.com/omacom/omarchy/blob/quattro/shell/plugins/agents/collectors.py
These are implementation references, not a promise that upstream schemas never change.

V1 stores per-message token/cost metadata in message.data JSON.
V2 assistant rows in session_message.data also contain per-message model,
cost, token and time metadata. session_v2 (or newer session) stores cumulative
counters, used only as a fallback when per-message usage is absent.

The adapter never reads message/part content for V2, and it never queries
credential/account tables. V1 JSON is projected by SQLite into usage metadata;
body fields are not returned to Python or transmitted.
"""
from __future__ import annotations

import json
import os
import sqlite3
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

DEFAULT_DATABASE = Path(os.environ.get(
    "OPENCODE_DB_PATH",
    str(Path(os.environ.get("XDG_DATA_HOME", str(Path.home() / ".local/share"))) / "opencode" / "opencode.db"),
))
MAX_USAGE_EVENTS = 100000
MAX_MESSAGE_ROWS = 1000000
USAGE_COLUMNS = (
    "tokens_input", "tokens_output", "tokens_reasoning",
    "tokens_cache_read", "tokens_cache_write", "cost",
)
ALLOWED_FUNCTIONS = {"json_valid", "json_extract"}


def _timestamp_seconds(value: Any) -> float | None:
    if value is None:
        return None
    try:
        if isinstance(value, str) and not value.strip().replace(".", "", 1).isdigit():
            parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
            if parsed.tzinfo is None:
                parsed = parsed.replace(tzinfo=timezone.utc)
            return parsed.timestamp()
        number = float(value)
        return number / 1000.0 if number > 100000000000 else number
    except (TypeError, ValueError, OverflowError):
        return None


def _iso_timestamp(value: Any) -> str | None:
    seconds = _timestamp_seconds(value)
    if seconds is None:
        return None
    try:
        return datetime.fromtimestamp(seconds, timezone.utc).isoformat()
    except (ValueError, OverflowError, OSError):
        return None


def _integer(value: Any) -> int:
    try:
        return max(0, int(value or 0))
    except (TypeError, ValueError, OverflowError):
        return 0


def _float(value: Any) -> float:
    try:
        number = float(value or 0)
        return max(0.0, number) if number == number and number not in (float("inf"), float("-inf")) else 0.0
    except (TypeError, ValueError, OverflowError):
        return 0.0


def _model_identifiers(value: Any) -> tuple[str | None, str | None]:
    try:
        model = json.loads(value) if isinstance(value, str) else value
    except (TypeError, ValueError, json.JSONDecodeError):
        model = None
    if not isinstance(model, dict):
        return None, None
    provider = model.get("providerID") or model.get("providerId")
    model_id = model.get("id") or model.get("modelID") or model.get("modelId")
    return (str(provider)[:128] if provider else None,
            str(model_id)[:256] if model_id else None)


def _table_columns(connection: sqlite3.Connection, table: str) -> set[str]:
    # Table names come only from the fixed allowlist below, never from user input.
    return {str(row["name"]) for row in connection.execute(f'PRAGMA table_info("{table}")')}


def _usage_record(
    *, event_id: str, session_id: str, provider_id: str | None, model_id: str | None,
    message_type: str, created_at: str, input_tokens: Any, output_tokens: Any,
    reasoning_tokens: Any, cache_read_tokens: Any, cache_write_tokens: Any,
    cost_usd: Any, assistant_message_count: int,
) -> dict[str, Any]:
    return {
        "event_id": event_id,
        "session_id": session_id,
        "provider_id": provider_id,
        "model_id": model_id,
        "message_type": message_type,
        "created_at": created_at,
        "input_tokens": _integer(input_tokens),
        "output_tokens": _integer(output_tokens),
        "reasoning_tokens": _integer(reasoning_tokens),
        "cache_read_tokens": _integer(cache_read_tokens),
        "cache_write_tokens": _integer(cache_write_tokens),
        "cost_usd": _float(cost_usd),
        "assistant_message_count": max(0, int(assistant_message_count)),
    }


def collect_opencode_usage(database_path: str | Path = DEFAULT_DATABASE) -> dict[str, Any]:
    """Return a schema-versioned, content-free usage projection from OpenCode."""
    path = Path(database_path).expanduser()
    if not path.is_file():
        raise FileNotFoundError(f"OpenCode database not found: {path}")

    # URI mode=ro plus query_only and an authorizer are three independent
    # restrictions. No checkpoint, migration, VACUUM, or write statement runs.
    uri = path.resolve().as_uri() + "?mode=ro"
    source = sqlite3.connect(uri, uri=True, timeout=3.0)
    source.row_factory = sqlite3.Row
    try:
        source.execute("PRAGMA query_only=ON")
        tables = {str(row[0]) for row in source.execute(
            "SELECT name FROM sqlite_master WHERE type='table'")}
        relevant = {"session", "session_v2", "message", "session_message"}
        if not (tables & relevant):
            raise RuntimeError("Unsupported OpenCode schema: no recognized session/message tables")

        allowed_reads = {
            "sqlite_master": {"name", "type"},
            "session": {"id", "model", "cost", "tokens_input", "tokens_output",
                        "tokens_reasoning", "tokens_cache_read", "tokens_cache_write",
                        "time_created", "time_updated"},
            "session_v2": {"id", "model", "cost", "tokens_input", "tokens_output",
                           "tokens_reasoning", "tokens_cache_read", "tokens_cache_write",
                           "time_created", "time_updated"},
            "message": {"id", "session_id", "data", "time_created"},
            # V2 data is read only through JSON1 projections; the raw JSON
            # column is never selected into Python or returned to the API.
            "session_message": {"id", "session_id", "type", "data", "seq", "time_created"},
        }

        def authorize(action: int, arg1: str | None, arg2: str | None,
                      database_name: str | None, trigger_name: str | None) -> int:
            if action == sqlite3.SQLITE_SELECT:
                return sqlite3.SQLITE_OK
            if action == sqlite3.SQLITE_READ:
                table_name, column_name = str(arg1 or ""), str(arg2 or "")
                if column_name in allowed_reads.get(table_name, set()):
                    return sqlite3.SQLITE_OK
                return sqlite3.SQLITE_DENY
            if action == sqlite3.SQLITE_FUNCTION:
                function_name = str(arg2 or arg1 or "").lower()
                return sqlite3.SQLITE_OK if function_name in ALLOWED_FUNCTIONS else sqlite3.SQLITE_DENY
            if action == sqlite3.SQLITE_PRAGMA:
                pragma_name, pragma_argument = str(arg1 or "").lower(), str(arg2 or "")
                if pragma_name == "table_info" and pragma_argument in relevant:
                    return sqlite3.SQLITE_OK
                return sqlite3.SQLITE_DENY
            return sqlite3.SQLITE_DENY

        source.set_authorizer(authorize)
        columns = {table: _table_columns(source, table) for table in relevant if table in tables}
        records: list[dict[str, Any]] = []
        seen_ids: set[str] = set()
        session_created: dict[str, float] = {}

        # Session creation timestamps are used only to reject copied pre-fork
        # legacy messages. They are metadata, not transcript content.
        for table in ("session", "session_v2"):
            if table in columns and {"id", "time_created"}.issubset(columns[table]):
                for row in source.execute(f'SELECT id,time_created FROM "{table}"'):
                    created = _timestamp_seconds(row["time_created"])
                    if created is not None:
                        session_created[str(row["id"])] = created

        # V2 message rows are inspected only for session_id and type. The data
        # column (which contains content arrays and tool output) is never read.
        v2_message_counts: dict[str, int] = {}
        if "session_message" in columns and not {"session_id", "type"}.issubset(columns["session_message"]):
            raise RuntimeError("OpenCode V2 session_message schema is missing session_id/type columns")
        if "session_message" in columns:
            row_count = 0
            for row in source.execute("SELECT session_id,type FROM session_message"):
                row_count += 1
                if row_count > MAX_MESSAGE_ROWS:
                    raise RuntimeError(f"OpenCode V2 message index exceeds the {MAX_MESSAGE_ROWS:,}-row safety cap")
                session_id = str(row["session_id"])
                v2_message_counts.setdefault(session_id, 0)
                if row["type"] == "assistant":
                    v2_message_counts[session_id] += 1
        v2_session_ids = set(v2_message_counts)
        v2_message_sessions: set[str] = set()
        message_level_sessions: set[str] = set()
        stores: list[str] = []

        # OpenCode V2 assistant rows retain per-message usage metadata in data.
        # JSON1 projects only model/tokens/cost/time; content and tool output are
        # never selected as a result column or returned to Python.
        if "session_message" in columns and {"id", "session_id", "type", "data"}.issubset(columns["session_message"]):
            row_time = "m.time_created" if "time_created" in columns["session_message"] else "NULL"
            v2_query = f"""
                SELECT m.id AS id, m.session_id AS session_id, m.type AS row_type,
                    {row_time} AS row_time,
                    CASE WHEN json_valid(m.data) THEN json_extract(m.data,'$.model.providerID') END AS provider_id,
                    CASE WHEN json_valid(m.data) THEN json_extract(m.data,'$.model.id') END AS model_id,
                    CASE WHEN json_valid(m.data) THEN json_extract(m.data,'$.time.created') END AS message_time,
                    CASE WHEN json_valid(m.data) THEN json_extract(m.data,'$.tokens.input') END AS input_tokens,
                    CASE WHEN json_valid(m.data) THEN json_extract(m.data,'$.tokens.output') END AS output_tokens,
                    CASE WHEN json_valid(m.data) THEN json_extract(m.data,'$.tokens.reasoning') END AS reasoning_tokens,
                    CASE WHEN json_valid(m.data) THEN json_extract(m.data,'$.tokens.cache.read') END AS cache_read_tokens,
                    CASE WHEN json_valid(m.data) THEN json_extract(m.data,'$.tokens.cache.write') END AS cache_write_tokens,
                    CASE WHEN json_valid(m.data) THEN json_extract(m.data,'$.cost') END AS cost_usd
                FROM session_message AS m WHERE m.type='assistant'
            """
            row_count = 0
            for row in source.execute(v2_query):
                row_count += 1
                if row_count > MAX_MESSAGE_ROWS:
                    raise RuntimeError(f"OpenCode V2 assistant scan exceeds the {MAX_MESSAGE_ROWS:,}-row safety cap")
                values = [row["input_tokens"], row["output_tokens"], row["reasoning_tokens"],
                          row["cache_read_tokens"], row["cache_write_tokens"], row["cost_usd"]]
                if not any(_float(value) > 0 for value in values):
                    continue
                session_id = str(row["session_id"])
                message_id = str(row["id"])
                event_id = f"message:{message_id}"
                if event_id in seen_ids:
                    continue
                message_seconds = _timestamp_seconds(row["message_time"] or row["row_time"])
                session_seconds = session_created.get(session_id)
                if message_seconds is None or (session_seconds is not None and message_seconds < session_seconds):
                    # A forked session can expose inherited history. A message
                    # timestamp before the child session's creation is not new
                    # usage attributable to that child.
                    continue
                created_at = _iso_timestamp(message_seconds)
                if created_at is None:
                    continue
                seen_ids.add(event_id)
                v2_message_sessions.add(session_id)
                message_level_sessions.add(session_id)
                records.append(_usage_record(
                    event_id=event_id, session_id=session_id,
                    provider_id=str(row["provider_id"])[:128] if row["provider_id"] else None,
                    model_id=str(row["model_id"])[:256] if row["model_id"] else None,
                    message_type="assistant", created_at=created_at,
                    input_tokens=row["input_tokens"], output_tokens=row["output_tokens"],
                    reasoning_tokens=row["reasoning_tokens"], cache_read_tokens=row["cache_read_tokens"],
                    cache_write_tokens=row["cache_write_tokens"], cost_usd=row["cost_usd"],
                    assistant_message_count=1,
                ))
                if len(records) > MAX_USAGE_EVENTS:
                    raise RuntimeError(f"OpenCode usage scan exceeds the {MAX_USAGE_EVENTS:,}-event safety cap")
            if v2_message_sessions:
                stores.append("session_message")

        def read_session_aggregates(table: str, include_ids: set[str] | None = None,
                                    exclude_ids: set[str] | None = None,
                                    strict: bool = False) -> set[str]:
            table_columns = columns.get(table, set())
            if not {"id", *USAGE_COLUMNS}.issubset(table_columns):
                if strict:
                    missing = sorted({"id", *USAGE_COLUMNS} - table_columns)
                    raise RuntimeError(f"OpenCode {table} usage schema is missing required columns: {missing}")
                return set()
            selected = ["id"]
            for column in ("model", "cost", "tokens_input", "tokens_output", "tokens_reasoning",
                           "tokens_cache_read", "tokens_cache_write", "time_created", "time_updated"):
                selected.append(f'"{column}"' if column in table_columns else f'NULL AS "{column}"')
            sql = f'SELECT {",".join(selected)} FROM "{table}"'
            added_sessions: set[str] = set()
            for row in source.execute(sql):
                session_id = str(row["id"])
                if include_ids is not None and session_id not in include_ids:
                    continue
                if exclude_ids is not None and session_id in exclude_ids:
                    continue
                values = [row["tokens_input"], row["tokens_output"], row["tokens_reasoning"],
                          row["tokens_cache_read"], row["tokens_cache_write"], row["cost"]]
                if not any(_float(value) > 0 for value in values):
                    continue
                created_at = _iso_timestamp(row["time_updated"] or row["time_created"])
                if created_at is None:
                    continue
                provider_id, model_id = _model_identifiers(row["model"])
                event_id = f"session-aggregate:{table}:{session_id}"
                if event_id in seen_ids:
                    continue
                seen_ids.add(event_id)
                records.append(_usage_record(
                    event_id=event_id, session_id=session_id, provider_id=provider_id, model_id=model_id,
                    message_type="session_aggregate", created_at=created_at,
                    input_tokens=row["tokens_input"], output_tokens=row["tokens_output"],
                    reasoning_tokens=row["tokens_reasoning"], cache_read_tokens=row["tokens_cache_read"],
                    cache_write_tokens=row["tokens_cache_write"], cost_usd=row["cost"],
                    assistant_message_count=v2_message_counts.get(session_id, 0),
                ))
                added_sessions.add(session_id)
                if len(records) > MAX_USAGE_EVENTS:
                    raise RuntimeError(f"OpenCode usage scan exceeds the {MAX_USAGE_EVENTS:,}-event safety cap")
            return added_sessions

        aggregate_sessions: set[str] = set()
        # V2 session aggregates are a fallback only when per-message usage
        # counters are absent for that session. The API differences successive
        # cumulative snapshots to avoid counting lifetime totals repeatedly.
        if "session_v2" in columns:
            aggregate_sessions |= read_session_aggregates(
                "session_v2", exclude_ids=v2_message_sessions, strict=True)
            if aggregate_sessions:
                stores.append("session_v2")
        elif "session" in columns and v2_session_ids:
            aggregate_sessions |= read_session_aggregates(
                "session", include_ids=v2_session_ids - v2_message_sessions, strict=True)
            if aggregate_sessions:
                stores.append("session")

        # V1 stores one usage-bearing assistant record per message. Exclude
        # sessions represented by the V2 message projection to prevent double
        # counting if a database contains both schema families.
        legacy_message_sessions: set[str] = set()
        if "message" in columns and {"id", "session_id", "data"}.issubset(columns["message"]):
            time_expression = 'm.time_created' if "time_created" in columns["message"] else "NULL"
            query = f"""
                SELECT m.id AS id, m.session_id AS session_id, {time_expression} AS row_time,
                    CASE WHEN json_valid(m.data) THEN json_extract(m.data,'$.role') END AS role,
                    CASE WHEN json_valid(m.data) THEN json_extract(m.data,'$.providerID') END AS provider_id,
                    CASE WHEN json_valid(m.data) THEN
                        CASE WHEN json_extract(m.data,'$.modelID') IS NOT NULL
                             THEN json_extract(m.data,'$.modelID')
                             ELSE json_extract(m.data,'$.model.modelID') END END AS model_id,
                    CASE WHEN json_valid(m.data) THEN json_extract(m.data,'$.time.created') END AS message_time,
                    CASE WHEN json_valid(m.data) THEN json_extract(m.data,'$.tokens.input') END AS input_tokens,
                    CASE WHEN json_valid(m.data) THEN json_extract(m.data,'$.tokens.output') END AS output_tokens,
                    CASE WHEN json_valid(m.data) THEN json_extract(m.data,'$.tokens.reasoning') END AS reasoning_tokens,
                    CASE WHEN json_valid(m.data) THEN json_extract(m.data,'$.tokens.cache.read') END AS cache_read_tokens,
                    CASE WHEN json_valid(m.data) THEN json_extract(m.data,'$.tokens.cache.write') END AS cache_write_tokens,
                    CASE WHEN json_valid(m.data) THEN json_extract(m.data,'$.cost') END AS cost_usd
                FROM message AS m
            """
            row_count = 0
            for row in source.execute(query):
                row_count += 1
                if row_count > MAX_MESSAGE_ROWS:
                    raise RuntimeError(f"OpenCode legacy message scan exceeds the {MAX_MESSAGE_ROWS:,}-row safety cap")
                session_id = str(row["session_id"])
                if session_id in v2_session_ids or row["role"] != "assistant":
                    continue
                message_seconds = _timestamp_seconds(row["message_time"] or row["row_time"])
                session_seconds = session_created.get(session_id)
                if message_seconds is None:
                    continue
                if session_seconds is not None and message_seconds < session_seconds:
                    continue
                values = [row["input_tokens"], row["output_tokens"], row["reasoning_tokens"],
                          row["cache_read_tokens"], row["cache_write_tokens"], row["cost_usd"]]
                if not any(_float(value) > 0 for value in values):
                    continue
                event_id = f"message:{row['id']}"
                if event_id in seen_ids:
                    continue
                created_at = _iso_timestamp(message_seconds)
                if created_at is None:
                    continue
                seen_ids.add(event_id)
                records.append(_usage_record(
                    event_id=event_id, session_id=session_id,
                    provider_id=str(row["provider_id"])[:128] if row["provider_id"] else None,
                    model_id=str(row["model_id"])[:256] if row["model_id"] else None,
                    message_type="assistant", created_at=created_at,
                    input_tokens=row["input_tokens"], output_tokens=row["output_tokens"],
                    reasoning_tokens=row["reasoning_tokens"], cache_read_tokens=row["cache_read_tokens"],
                    cache_write_tokens=row["cache_write_tokens"], cost_usd=row["cost_usd"],
                    assistant_message_count=1,
                ))
                legacy_message_sessions.add(session_id)
                message_level_sessions.add(session_id)
                if len(records) > MAX_USAGE_EVENTS:
                    raise RuntimeError(f"OpenCode usage scan exceeds the {MAX_USAGE_EVENTS:,}-event safety cap")
            if legacy_message_sessions:
                stores.append("message")

        # Newer databases may have session aggregates plus a V2 message table,
        # while V1-only databases can have aggregate columns but incomplete
        # per-message JSON. Use session aggregates only for sessions that did
        # not already contribute message-level usage.
        if "session" in columns and "session" not in stores:
            if "session_v2" in columns:
                include_ids = None
                exclude_ids = v2_session_ids | legacy_message_sessions | v2_message_sessions | aggregate_sessions
            elif v2_session_ids:
                include_ids = v2_session_ids - v2_message_sessions
                exclude_ids = legacy_message_sessions
            else:
                include_ids = None
                exclude_ids = legacy_message_sessions | message_level_sessions
            fallback_sessions = read_session_aggregates("session", include_ids, exclude_ids)
            if fallback_sessions:
                aggregate_sessions |= fallback_sessions
                stores.append("session")

        if "session_message" in columns and v2_message_counts and "session_message" not in stores:
            stores.append("session_message")
        if not records and not stores:
            raise RuntimeError("OpenCode database exists, but no supported usage schema was detected")
        basis = "mixed" if aggregate_sessions and message_level_sessions else (
            "session-aggregate" if aggregate_sessions else "message-level" if message_level_sessions else "none")
        return {
            "collector": "opencode-sqlite-host-v2",
            "schema_version": 1,
            "agent": "opencode",
            "status": "ok",
            "database": str(path),
            "stores": sorted(set(stores)),
            "aggregation_basis": basis,
            "timestamp_semantics": "V1/V2 message events use assistant-message creation times; V2 session-aggregate fallbacks are differenced by the API at host snapshot observation times.",
            "records": records,
            "privacy": {
                "message_bodies_selected": False,
                "credentials_selected": False,
                "source_database_modified": False,
            },
        }
    finally:
        source.close()


def main() -> int:
    try:
        envelope = collect_opencode_usage()
    except Exception as exc:
        print(json.dumps({"schema_version": 1, "agent": "opencode", "status": "error", "error": str(exc)}))
        return 1
    print(json.dumps({key: value for key, value in envelope.items() if key != "records"}, ensure_ascii=False))
    for record in envelope["records"]:
        print(json.dumps(record, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
EOF

write_file 'backend/restore_db.py' <<'EOF'
"""Validate and atomically restore a Fedora AI Agents SQLite backup.

SQLite online backup and transaction semantics:
https://www.sqlite.org/backup.html
Python's atomic os.replace filesystem operation:
https://docs.python.org/3/library/os.html#os.replace
This utility runs inside the API image as its unprivileged application UID.
Input arrives on stdin so the host backup file is not mounted into the container.
It uses SQLite's online backup API, validates FTS5/sqlite-vec, preserves the
pre-restore database and WAL sidecars, and replaces agents.db atomically.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import sqlite3
import sys
from datetime import datetime, timezone
from pathlib import Path

import sqlite_vec

DATA_DIR = Path("/data")
DB_PATH = DATA_DIR / "agents.db"
BACKUP_DIR = DATA_DIR / "backups"
REQUIRED_TABLES = {
    "agents", "usage_events", "app_meta", "documents",
    "documents_fts", "documents_vec", "schema_migrations",
}


def timestamp() -> str:
    return datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%S%fZ")


def connect_database(path: Path, readonly: bool = False) -> sqlite3.Connection:
    if readonly:
        connection = sqlite3.connect(path.resolve().as_uri() + "?mode=ro", uri=True, timeout=10)
    else:
        connection = sqlite3.connect(path, timeout=10)
    connection.row_factory = sqlite3.Row
    connection.enable_load_extension(True)
    try:
        sqlite_vec.load(connection)
    finally:
        connection.enable_load_extension(False)
    return connection


def validate_database(path: Path) -> dict:
    if not path.is_file() or path.stat().st_size < 100:
        raise RuntimeError(f"Database candidate is missing or too small: {path}")
    with path.open("rb") as source:
        if source.read(16) != b"SQLite format 3\x00":
            raise RuntimeError("Backup does not have a valid SQLite database header")
    connection = connect_database(path, readonly=True)
    try:
        integrity = connection.execute("PRAGMA integrity_check").fetchone()[0]
        if integrity != "ok":
            raise RuntimeError(f"SQLite integrity_check failed: {integrity}")
        foreign_key_errors = connection.execute("PRAGMA foreign_key_check").fetchmany(10)
        if foreign_key_errors:
            raise RuntimeError(f"SQLite foreign_key_check found violations: {[tuple(row) for row in foreign_key_errors]}")
        tables = {row[0] for row in connection.execute("SELECT name FROM sqlite_master WHERE type='table'")}
        missing = sorted(REQUIRED_TABLES - tables)
        if missing:
            raise RuntimeError(f"Backup is missing required application tables: {missing}")
        fts_rows = int(connection.execute("SELECT count(*) FROM documents_fts").fetchone()[0])
        vector_rows = int(connection.execute("SELECT count(*) FROM documents_vec").fetchone()[0])
        usage_rows = int(connection.execute("SELECT count(*) FROM usage_events").fetchone()[0])
        return {"integrity": integrity, "fts_rows": fts_rows,
                "vector_rows": vector_rows, "usage_rows": usage_rows,
                "sqlite_version": sqlite3.sqlite_version}
    finally:
        connection.close()


def online_backup(source_path: Path, target_path: Path) -> None:
    source = connect_database(source_path, readonly=True)
    target = connect_database(target_path)
    try:
        source.backup(target, pages=256, sleep=0.05)
        target.commit()
    finally:
        target.close()
        source.close()


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        while True:
            chunk = source.read(1024 * 1024)
            if not chunk:
                break
            digest.update(chunk)
    return digest.hexdigest()


def read_stdin_backup(candidate: Path) -> None:
    total = 0
    with candidate.open("xb") as destination:
        while True:
            chunk = sys.stdin.buffer.read(1024 * 1024)
            if not chunk:
                break
            destination.write(chunk)
            total += len(chunk)
        destination.flush()
        os.fsync(destination.fileno())
    os.chmod(candidate, 0o600)
    if total < 100:
        raise RuntimeError("No valid backup bytes arrived on standard input")


def restore(source_path: Path, skip_pre_restore_backup: bool = False) -> dict:
    BACKUP_DIR.mkdir(mode=0o700, parents=True, exist_ok=True)
    os.chmod(BACKUP_DIR, 0o700)
    stamp = timestamp()
    source_info = validate_database(source_path)

    # Preserve the current DB with SQLite's backup API before replacing it.
    pre_restore = BACKUP_DIR / f"agents-pre-restore-{stamp}.db"
    if DB_PATH.exists() and not skip_pre_restore_backup:
        online_backup(DB_PATH, pre_restore)
        os.chmod(pre_restore, 0o600)
        try:
            pre_restore_info = validate_database(pre_restore)
        except Exception as exc:
            # Preserve the exact pre-restore bytes even if the current DB has
            # a schema issue; rollback must not depend on a clean schema.
            pre_restore_info = {"integrity": "not-validated", "error": str(exc)[:300]}
    else:
        pre_restore = None
        pre_restore_info = None

    restore_temp = DATA_DIR / f".agents-restore-{stamp}.db"
    online_backup(source_path, restore_temp)
    restored_info = validate_database(restore_temp)

    # All SQLite connections are closed before touching WAL/SHM sidecars.
    # Preserve rather than delete them; the new DB must never inherit a stale WAL.
    if DB_PATH.exists():
        for suffix in ("-wal", "-shm"):
            sidecar = Path(str(DB_PATH) + suffix)
            if sidecar.exists():
                preserved = BACKUP_DIR / f"agents-sidecar-before-restore-{stamp}.db{suffix}"
                os.replace(sidecar, preserved)

    os.chmod(restore_temp, 0o600)
    os.replace(restore_temp, DB_PATH)
    directory_fd = os.open(DATA_DIR, os.O_RDONLY | getattr(os, "O_DIRECTORY", 0))
    try:
        os.fsync(directory_fd)
    finally:
        os.close(directory_fd)

    try:
        final_info = validate_database(DB_PATH)
    except Exception:
        # Best-effort automatic rollback from the verified pre-restore copy.
        if pre_restore is not None:
            rollback_temp = DATA_DIR / f".agents-rollback-{stamp}.db"
            online_backup(pre_restore, rollback_temp)
            os.chmod(rollback_temp, 0o600)
            os.replace(rollback_temp, DB_PATH)
        raise

    source_hash = sha256_file(source_path)
    return {
        "status": "restored",
        "database_path": str(DB_PATH),
        "restored_from": str(source_path),
        "source_sha256": source_hash,
        "restored_database": final_info,
        "pre_restore_backup": str(pre_restore) if pre_restore else None,
        "pre_restore_database": pre_restore_info,
    }


def main() -> int:
    parser = argparse.ArgumentParser(description="Validate and atomically restore the AI Agents SQLite database")
    parser.add_argument("--source-path", help="Existing backup inside /data/backups; stdin is used when omitted")
    parser.add_argument("--skip-pre-restore-backup", action="store_true",
                        help="Use only when a verified external rollback backup already exists")
    args = parser.parse_args()
    candidate: Path | None = None
    try:
        if args.source_path:
            candidate = Path(args.source_path).resolve()
            if BACKUP_DIR.resolve() not in candidate.parents:
                raise RuntimeError("--source-path must be a file inside /data/backups")
        else:
            candidate = DATA_DIR / f".restore-input-{timestamp()}.db"
            read_stdin_backup(candidate)
        result = restore(candidate, skip_pre_restore_backup=args.skip_pre_restore_backup)
        if not args.source_path and candidate.exists():
            retained = BACKUP_DIR / f"restore-source-{timestamp()}.db"
            os.replace(candidate, retained)
            os.chmod(retained, 0o600)
            result["restore_source_copy"] = str(retained)
        print(json.dumps(result, separators=(",", ":")))
        return 0
    except Exception as exc:
        print(json.dumps({"status": "error", "error": str(exc)}), file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
EOF

write_file 'backend/collectors/host_snapshot.py' <<'EOF'
"""Host-side agent detection and sanitized usage snapshot producer.

Run as the logged-in Fedora user, not inside Docker:
    PYTHONPATH=backend python3 -m collectors.host_snapshot

The output contains executable-presence metadata and normalized OpenCode usage
records only. It never serializes credentials, prompts, message bodies or tool output.
"""
from __future__ import annotations

import json
import shutil
from datetime import datetime, timezone

from collectors.opencode import collect_opencode_usage

SCHEMA_VERSION = 1
AGENT_REGISTRY = (
    ("opencode", "OpenCode", "opencode"),
    ("claude", "Claude Code", "claude"),
    ("codex", "OpenAI Codex", "codex"),
    ("gemini", "Gemini CLI", "gemini"),
    ("pi", "Pi", "pi"),
    ("github-copilot", "GitHub Copilot CLI", "copilot"),
)


def build_host_snapshot() -> dict:
    agents = [
        {"id": agent_id, "display_name": display_name, "executable": executable,
         "installed": bool(shutil.which(executable))}
        for agent_id, display_name, executable in AGENT_REGISTRY
    ]
    opencode_installed = next(agent["installed"] for agent in agents if agent["id"] == "opencode")
    status = "not-installed"
    records = []
    stores = []
    aggregation_basis = "none"
    timestamp_semantics = "No OpenCode usage data collected."
    if opencode_installed:
        try:
            collected = collect_opencode_usage()
            status = "available"
            records = collected["records"]
            stores = collected["stores"]
            aggregation_basis = collected.get("aggregation_basis", "none")
            timestamp_semantics = collected.get("timestamp_semantics", "Collector did not report timestamp semantics.")
        except FileNotFoundError:
            status = "database-unavailable"
            error = None
        except Exception as exc:
            status = "collector-error"
            error = str(exc)[:500]
        else:
            error = None
    else:
        error = None

    return {
        "schema_version": SCHEMA_VERSION,
        "collected_at": datetime.now(timezone.utc).isoformat(),
        "agents": agents,
        "opencode": {
            "schema_version": 1, "agent": "opencode", "status": status,
            "stores": stores, "records": records, "error": error,
            "aggregation_basis": aggregation_basis,
            "timestamp_semantics": timestamp_semantics,
            "privacy": {"message_bodies_selected": False,
                        "credentials_selected": False,
                        "source_database_modified": False},
        },
    }


def main() -> int:
    try:
        print(json.dumps(build_host_snapshot(), ensure_ascii=False, separators=(",", ":")))
        return 0
    except Exception as exc:
        print(json.dumps({"schema_version": SCHEMA_VERSION, "error": str(exc)}), file=__import__("sys").stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
EOF

write_file 'backend/main.py' <<'EOF'
"""Local-first FastAPI data plane for Fedora AI Agents Explainer.

Security invariants:
- The API is published by Compose on host loopback only.
- The OpenCode source database is never mounted into the Docker container.
- A host-side user process reads it mode=ro/query_only and posts only normalized
  usage metadata to the loopback API; prompts, content and auth are not selected.
- Provider credentials are never accepted by this API or returned to the browser.
"""
from __future__ import annotations

import hashlib
import json
import os
import sqlite3
import time
import urllib.error
import urllib.request
from contextlib import asynccontextmanager, contextmanager
from datetime import datetime, timezone, timedelta
from pathlib import Path
from typing import Any

import sqlite_vec
from fastapi import FastAPI, HTTPException
from fastapi.middleware.cors import CORSMiddleware
from pydantic import BaseModel, ConfigDict, Field

DB_PATH = Path(os.environ.get("DATABASE_PATH", "/data/agents.db"))
VECTOR_DIMENSIONS = int(os.environ.get("VECTOR_DIMENSIONS", "768"))
OLLAMA_BASE_URL = os.environ.get("OLLAMA_BASE_URL", "http://host.docker.internal:11434").rstrip("/")
OLLAMA_EMBED_MODEL = os.environ.get("OLLAMA_EMBED_MODEL", "nomic-embed-text")
ALLOWED_ORIGINS = [item.strip() for item in os.environ.get(
    "CORS_ORIGINS", "http://127.0.0.1:5173,http://localhost:5173,http://127.0.0.1:4173"
).split(",") if item.strip()]


def connect_db() -> sqlite3.Connection:
    # sqlite-vec's documented Python contract requires loading the extension on
    # every SQLite connection that queries vec0 tables. See:
    # https://github.com/asg017/sqlite-vec/blob/main/site/getting-started/installation.md
    # SQLite extension-loading controls are documented at:
    # https://docs.python.org/3/library/sqlite3.html#sqlite3.Connection.enable_load_extension
    DB_PATH.parent.mkdir(parents=True, exist_ok=True)
    connection = sqlite3.connect(DB_PATH, timeout=8.0)
    connection.row_factory = sqlite3.Row
    connection.execute("PRAGMA foreign_keys = ON")
    connection.execute("PRAGMA busy_timeout = 8000")
    connection.execute("PRAGMA journal_mode = WAL")
    connection.execute("PRAGMA synchronous = NORMAL")
    connection.execute("PRAGMA temp_store = MEMORY")
    connection.enable_load_extension(True)
    try:
        sqlite_vec.load(connection)
    finally:
        connection.enable_load_extension(False)
    return connection


@contextmanager
def database_connection():
    """Commit/rollback transaction scope and always close the SQLite handle."""
    connection = connect_db()
    try:
        with connection:
            yield connection
    finally:
        connection.close()


def initialize_database() -> None:
    with database_connection() as db:
        db.execute("""CREATE TABLE IF NOT EXISTS schema_migrations (
            version INTEGER PRIMARY KEY, applied_at TEXT NOT NULL, description TEXT NOT NULL
        )""")
        db.execute("""CREATE TABLE IF NOT EXISTS agents (
            id TEXT PRIMARY KEY, display_name TEXT NOT NULL, executable TEXT NOT NULL,
            installed INTEGER NOT NULL DEFAULT 0, first_seen_at TEXT NOT NULL,
            last_seen_at TEXT
        )""")
        db.execute("""CREATE TABLE IF NOT EXISTS usage_events (
            event_id TEXT PRIMARY KEY, agent_id TEXT NOT NULL, message_type TEXT NOT NULL DEFAULT 'assistant', session_id TEXT,
            provider_id TEXT, model_id TEXT, created_at TEXT NOT NULL,
            input_tokens INTEGER NOT NULL DEFAULT 0, output_tokens INTEGER NOT NULL DEFAULT 0,
            reasoning_tokens INTEGER NOT NULL DEFAULT 0, cache_read_tokens INTEGER NOT NULL DEFAULT 0,
            cache_write_tokens INTEGER NOT NULL DEFAULT 0, cost_usd REAL NOT NULL DEFAULT 0,
            assistant_message_count INTEGER NOT NULL DEFAULT 1,
            counter_reset_detected INTEGER NOT NULL DEFAULT 0,
            FOREIGN KEY(agent_id) REFERENCES agents(id)
        )""")
        usage_columns = {row["name"] for row in db.execute("PRAGMA table_info(usage_events)")}
        if "message_type" not in usage_columns:
            db.execute("ALTER TABLE usage_events ADD COLUMN message_type TEXT NOT NULL DEFAULT 'assistant'")
        if "assistant_message_count" not in usage_columns:
            db.execute("ALTER TABLE usage_events ADD COLUMN assistant_message_count INTEGER NOT NULL DEFAULT 1")
            db.execute("UPDATE usage_events SET assistant_message_count=CASE WHEN message_type='assistant' THEN 1 ELSE 0 END")
        if "counter_reset_detected" not in usage_columns:
            db.execute("ALTER TABLE usage_events ADD COLUMN counter_reset_detected INTEGER NOT NULL DEFAULT 0")
        db.execute("""CREATE TABLE IF NOT EXISTS session_usage_snapshots (
            session_id TEXT PRIMARY KEY, provider_id TEXT, model_id TEXT, observed_at TEXT NOT NULL,
            input_tokens INTEGER NOT NULL DEFAULT 0, output_tokens INTEGER NOT NULL DEFAULT 0,
            reasoning_tokens INTEGER NOT NULL DEFAULT 0, cache_read_tokens INTEGER NOT NULL DEFAULT 0,
            cache_write_tokens INTEGER NOT NULL DEFAULT 0, assistant_message_count INTEGER NOT NULL DEFAULT 0,
            cost_usd REAL NOT NULL DEFAULT 0, counter_reset_detected INTEGER NOT NULL DEFAULT 0
        )""")
        snapshot_columns = {row["name"] for row in db.execute("PRAGMA table_info(session_usage_snapshots)")}
        if "counter_reset_detected" not in snapshot_columns:
            db.execute("ALTER TABLE session_usage_snapshots ADD COLUMN counter_reset_detected INTEGER NOT NULL DEFAULT 0")
        db.execute("CREATE INDEX IF NOT EXISTS idx_session_snapshots_observed ON session_usage_snapshots(observed_at)")
        db.execute("INSERT OR IGNORE INTO schema_migrations(version,applied_at,description) VALUES (3,?,?)",
                   (datetime.now(timezone.utc).isoformat(), "Track cumulative OpenCode V2 session snapshots and ingest deltas"))
        db.execute("INSERT OR IGNORE INTO schema_migrations(version,applied_at,description) VALUES (4,?,?)",
                   (datetime.now(timezone.utc).isoformat(), "Record counter resets during cumulative session-delta ingestion"))
        db.execute("CREATE INDEX IF NOT EXISTS idx_usage_created ON usage_events(created_at)")
        db.execute("CREATE INDEX IF NOT EXISTS idx_usage_agent_model ON usage_events(agent_id, model_id)")
        db.execute("""CREATE TABLE IF NOT EXISTS app_meta (
            key TEXT PRIMARY KEY, value TEXT NOT NULL
        )""")
        configured_dimensions = db.execute("SELECT value FROM app_meta WHERE key='vector_dimensions'").fetchone()
        if configured_dimensions is None:
            db.execute("INSERT INTO app_meta(key,value) VALUES ('vector_dimensions',?)", (str(VECTOR_DIMENSIONS),))
        elif int(configured_dimensions["value"]) != VECTOR_DIMENSIONS:
            raise RuntimeError(
                f"Existing vector index uses {configured_dimensions['value']} dimensions; "
                f"configured value is {VECTOR_DIMENSIONS}. Back up and migrate the vector table before changing VECTOR_DIMENSIONS."
            )
        db.execute("""CREATE TABLE IF NOT EXISTS documents (
            id INTEGER PRIMARY KEY AUTOINCREMENT, title TEXT NOT NULL, body TEXT NOT NULL,
            source TEXT NOT NULL DEFAULT 'manual', created_at TEXT NOT NULL,
            updated_at TEXT NOT NULL, embedding_model TEXT, embedding_dimensions INTEGER
        )""")
        db.execute("""CREATE VIRTUAL TABLE IF NOT EXISTS documents_fts USING fts5(
            title, body, content='documents', content_rowid='id',
            tokenize='unicode61 remove_diacritics 2'
        )""")
        db.executescript("""
            CREATE TRIGGER IF NOT EXISTS documents_ai AFTER INSERT ON documents BEGIN
                INSERT INTO documents_fts(rowid, title, body) VALUES (new.id, new.title, new.body);
            END;
            CREATE TRIGGER IF NOT EXISTS documents_ad AFTER DELETE ON documents BEGIN
                INSERT INTO documents_fts(documents_fts, rowid, title, body)
                VALUES ('delete', old.id, old.title, old.body);
            END;
            CREATE TRIGGER IF NOT EXISTS documents_au AFTER UPDATE ON documents BEGIN
                INSERT INTO documents_fts(documents_fts, rowid, title, body)
                VALUES ('delete', old.id, old.title, old.body);
                INSERT INTO documents_fts(rowid, title, body) VALUES (new.id, new.title, new.body);
            END;
        """)
        # sqlite-vec is an explicit runtime dependency. Failing closed here is preferable
        # to advertising vector search when the extension is absent or incompatible.
        db.execute(f"""CREATE VIRTUAL TABLE IF NOT EXISTS documents_vec USING vec0(
            embedding float[{VECTOR_DIMENSIONS}]
        )""")
        db.execute("""INSERT OR IGNORE INTO schema_migrations(version, applied_at, description)
            VALUES (1, ?, 'Initial agent registry, usage ledger, FTS5 and sqlite-vec schema')""",
            (datetime.now(timezone.utc).isoformat(),))
        db.execute("""INSERT OR IGNORE INTO schema_migrations(version, applied_at, description)
            VALUES (2, ?, 'Add OpenCode message type for assistant and compaction accounting')""",
            (datetime.now(timezone.utc).isoformat(),))
        now = datetime.now(timezone.utc).isoformat()
        for agent_id, display_name, executable in (
            ("opencode", "OpenCode", "opencode"), ("claude", "Claude Code", "claude"),
            ("codex", "OpenAI Codex", "codex"), ("gemini", "Gemini CLI", "gemini"),
            ("pi", "Pi", "pi"), ("github-copilot", "GitHub Copilot CLI", "copilot"),
        ):
            db.execute("INSERT OR IGNORE INTO agents(id,display_name,executable,installed,first_seen_at) VALUES (?,?,?,?,?)",
                       (agent_id, display_name, executable, 0, now))
        integrity = db.execute("PRAGMA quick_check").fetchone()[0]
        if integrity != "ok":
            raise RuntimeError(f"SQLite quick_check failed during startup: {integrity}")
        db.execute("INSERT INTO app_meta(key,value) VALUES ('integrity_status',?) ON CONFLICT(key) DO UPDATE SET value=excluded.value", (integrity,))
        db.execute("INSERT INTO app_meta(key,value) VALUES ('last_integrity_check_at',?) ON CONFLICT(key) DO UPDATE SET value=excluded.value", (now,))


@asynccontextmanager
async def lifespan(_: FastAPI):
    initialize_database()
    yield


app = FastAPI(title="Fedora AI Agents Local API", version="1.0.0", lifespan=lifespan)
# Starlette CORS behavior and exact-origin allowlisting:
# https://www.starlette.io/middleware/#corsmiddleware
# CORS is not authentication; the Compose port is separately bound to loopback.
app.add_middleware(CORSMiddleware, allow_origins=ALLOWED_ORIGINS,
                   allow_credentials=False, allow_methods=["GET", "POST"],
                   allow_headers=["Content-Type", "Accept"])


class DocumentInput(BaseModel):
    title: str = Field(min_length=1, max_length=300)
    body: str = Field(min_length=1, max_length=100_000)
    source: str = Field(default="manual", max_length=300)
    embedding: list[float] | None = None


class SearchInput(BaseModel):
    query: str = Field(min_length=1, max_length=2000)
    limit: int = Field(default=8, ge=1, le=30)
    embedding: list[float] | None = None


def ollama_embedding(text: str) -> list[float] | None:
    """Ask a local Ollama server for an embedding; never send text to a cloud service."""
    request_body = json.dumps({"model": OLLAMA_EMBED_MODEL, "input": text}).encode()
    request = urllib.request.Request(
        f"{OLLAMA_BASE_URL}/api/embed", data=request_body,
        headers={"Content-Type": "application/json"}, method="POST")
    try:
        with urllib.request.urlopen(request, timeout=12) as response:
            payload = json.loads(response.read().decode("utf-8"))
        vectors = payload.get("embeddings") or []
        return vectors[0] if vectors else None
    except (urllib.error.URLError, TimeoutError, ValueError, KeyError):
        return None


def validate_embedding(embedding: list[float] | None) -> list[float] | None:
    if embedding is None:
        return None
    if len(embedding) != VECTOR_DIMENSIONS:
        raise HTTPException(422, f"Embedding must contain exactly {VECTOR_DIMENSIONS} float values")
    return [float(value) for value in embedding]


def database_capabilities() -> dict[str, Any]:
    with database_connection() as db:
        version = db.execute("SELECT sqlite_version() AS version").fetchone()["version"]
        fts5 = db.execute("SELECT 1 FROM sqlite_master WHERE type='table' AND name='documents_fts'").fetchone() is not None
        vec = db.execute("SELECT 1 FROM sqlite_master WHERE name='documents_vec'").fetchone() is not None
        meta = {row["key"]: row["value"] for row in db.execute("SELECT key,value FROM app_meta WHERE key IN ('integrity_status','last_integrity_check_at')")}
    return {
        "sqlite_version": version, "fts5": fts5, "sqlite_vec": vec,
        "vector_dimensions": VECTOR_DIMENSIONS, "database_path": str(DB_PATH),
        "journal_mode": "WAL", "integrity": meta.get("integrity_status", "not-run"),
        "last_integrity_check_at": meta.get("last_integrity_check_at"),
    }


def registered_agents() -> list[dict[str, Any]]:
    with database_connection() as db:
        rows = db.execute("SELECT id,display_name,executable,installed,last_seen_at FROM agents ORDER BY display_name").fetchall()
    return [{"id": row["id"], "name": row["display_name"], "command": row["executable"],
             "installed": bool(row["installed"]), "last_seen_at": row["last_seen_at"],
             "usage_collector": row["id"] == "opencode"} for row in rows]


@app.get("/health")
def health():
    with database_connection() as db:
        db.execute("SELECT 1").fetchone()
    return {"status": "ok", "service": "fedora-ai-agents-api", "timestamp": datetime.now(timezone.utc).isoformat()}


@app.get("/api/admin/integrity")
def integrity_check():
    checked_at = datetime.now(timezone.utc).isoformat()
    with database_connection() as db:
        result = db.execute("PRAGMA quick_check").fetchone()[0]
        db.execute("INSERT INTO app_meta(key,value) VALUES ('integrity_status',?) ON CONFLICT(key) DO UPDATE SET value=excluded.value", (result,))
        db.execute("INSERT INTO app_meta(key,value) VALUES ('last_integrity_check_at',?) ON CONFLICT(key) DO UPDATE SET value=excluded.value", (checked_at,))
    if result != "ok":
        raise HTTPException(503, f"SQLite quick_check failed: {result}")
    return {"status": result, "checked_at": checked_at}


@app.get("/api/capabilities")
def capabilities():
    db = database_capabilities()
    with database_connection() as connection:
        meta = {row["key"]: row["value"] for row in connection.execute("SELECT key,value FROM app_meta WHERE key IN ('host_snapshot_at','opencode_status','opencode_error','opencode_aggregation_basis','opencode_timestamp_semantics')")}
    return {**db, "host_snapshot_at": meta.get("host_snapshot_at"),
            "opencode_status": meta.get("opencode_status", "waiting-for-host-collector"),
            "opencode_error": meta.get("opencode_error", ""),
            "opencode_aggregation_basis": meta.get("opencode_aggregation_basis", "none"),
            "opencode_timestamp_semantics": meta.get("opencode_timestamp_semantics", ""),
            "ollama": ollama_reachable(), "vector_search": db["sqlite_vec"],
            "fts5_search": db["fts5"], "collector_contract": "host-snapshot-v1"}


def ollama_reachable() -> bool:
    try:
        with urllib.request.urlopen(f"{OLLAMA_BASE_URL}/api/tags", timeout=1.5) as response:
            return response.status == 200
    except (urllib.error.URLError, TimeoutError):
        return False


class StrictModel(BaseModel):
    model_config = ConfigDict(extra="forbid")


class HostAgentRecord(StrictModel):
    id: str = Field(min_length=1, max_length=64)
    display_name: str = Field(min_length=1, max_length=100)
    executable: str = Field(min_length=1, max_length=100)
    installed: bool


class OpenCodeUsageRecord(StrictModel):
    event_id: str = Field(min_length=1, max_length=256)
    session_id: str = Field(default="", max_length=256)
    provider_id: str | None = Field(default=None, max_length=128)
    model_id: str | None = Field(default=None, max_length=256)
    message_type: str = Field(default="assistant", pattern="^(assistant|compaction|session_aggregate)$")
    created_at: str = Field(min_length=1, max_length=64)
    assistant_message_count: int = Field(default=1, ge=0)
    input_tokens: int = Field(default=0, ge=0)
    output_tokens: int = Field(default=0, ge=0)
    reasoning_tokens: int = Field(default=0, ge=0)
    cache_read_tokens: int = Field(default=0, ge=0)
    cache_write_tokens: int = Field(default=0, ge=0)
    cost_usd: float = Field(default=0.0, ge=0, le=1e12)


class CollectorPrivacy(StrictModel):
    message_bodies_selected: bool
    credentials_selected: bool
    source_database_modified: bool


class OpenCodeSnapshot(StrictModel):
    schema_version: int
    agent: str
    status: str = Field(pattern="^(available|not-installed|database-unavailable|collector-error)$")
    stores: list[str] = Field(default_factory=list, max_length=4)
    records: list[OpenCodeUsageRecord] = Field(default_factory=list, max_length=100000)
    error: str | None = Field(default=None, max_length=500)
    aggregation_basis: str = Field(pattern="^(message-level|session-aggregate|mixed|none)$")
    timestamp_semantics: str = Field(max_length=500)
    privacy: CollectorPrivacy


class HostSnapshot(StrictModel):
    schema_version: int
    collected_at: str
    agents: list[HostAgentRecord]
    opencode: OpenCodeSnapshot


@app.get("/api/agents")
def agents():
    return {"agents": registered_agents()}


@app.get("/api/host-snapshot/status")
def host_snapshot_status():
    with database_connection() as db:
        meta = {row["key"]: row["value"] for row in db.execute("SELECT key,value FROM app_meta WHERE key IN ('host_snapshot_at','opencode_status','opencode_error','opencode_aggregation_basis','opencode_timestamp_semantics')")}
    return {"last_snapshot_at": meta.get("host_snapshot_at"),
            "opencode_status": meta.get("opencode_status", "waiting-for-host-collector"),
            "opencode_error": meta.get("opencode_error", ""),
            "opencode_aggregation_basis": meta.get("opencode_aggregation_basis", "none"),
            "opencode_timestamp_semantics": meta.get("opencode_timestamp_semantics", "")}


@app.post("/api/ingest/host-snapshot")
def ingest_host_snapshot(payload: HostSnapshot):
    if payload.schema_version != 1 or payload.opencode.schema_version != 1 or payload.opencode.agent != "opencode":
        raise HTTPException(422, "Unsupported host snapshot or collector schema version")
    allowed = {"opencode": "opencode", "claude": "claude", "codex": "codex",
               "gemini": "gemini", "pi": "pi", "github-copilot": "copilot"}
    received = {agent.id for agent in payload.agents}
    if len(payload.agents) != len(allowed) or received != set(allowed):
        raise HTTPException(422, "Host snapshot must include every registered agent exactly once")
    if any(agent.executable != allowed[agent.id] for agent in payload.agents):
        raise HTTPException(422, "Host snapshot executable does not match the fixed registry")
    opencode_installed = next(agent.installed for agent in payload.agents if agent.id == "opencode")
    if payload.opencode.status == "available" and not opencode_installed:
        raise HTTPException(422, "OpenCode usage cannot be available when its executable is not detected")
    if not opencode_installed and payload.opencode.status != "not-installed":
        raise HTTPException(422, "An absent OpenCode executable must use not-installed status")
    if opencode_installed and payload.opencode.status == "not-installed":
        raise HTTPException(422, "An installed OpenCode executable cannot use not-installed status")
    if len({item.event_id for item in payload.opencode.records}) != len(payload.opencode.records):
        raise HTTPException(422, "Host snapshot contains duplicate usage event IDs")
    if payload.opencode.privacy.message_bodies_selected or payload.opencode.privacy.credentials_selected or payload.opencode.privacy.source_database_modified:
        raise HTTPException(422, "Collector privacy contract violation: content/credentials selected or source database modified")
    if payload.opencode.status != "available" and payload.opencode.records:
        raise HTTPException(422, "A non-available OpenCode collector status cannot carry usage records")
    if any(store not in {"message", "session", "session_v2", "session_message"} for store in payload.opencode.stores):
        raise HTTPException(422, "Host snapshot contains an unsupported OpenCode usage store")
    if payload.opencode.status != "available" and payload.opencode.aggregation_basis != "none":
        raise HTTPException(422, "A non-available collector must declare aggregation_basis=none")
    if payload.opencode.status == "available" and payload.opencode.aggregation_basis == "none" and payload.opencode.records:
        raise HTTPException(422, "A snapshot with usage records must declare its aggregation basis")
    has_session_aggregates = any(item.message_type == "session_aggregate" for item in payload.opencode.records)
    has_message_events = any(item.message_type != "session_aggregate" for item in payload.opencode.records)
    if has_session_aggregates and payload.opencode.aggregation_basis not in {"session-aggregate", "mixed"}:
        raise HTTPException(422, "Session aggregate records require session-aggregate or mixed basis")
    if has_message_events and payload.opencode.aggregation_basis not in {"message-level", "mixed"}:
        raise HTTPException(422, "Message events require message-level or mixed basis")
    try:
        datetime.fromisoformat(payload.collected_at.replace("Z", "+00:00"))
        for item in payload.opencode.records:
            datetime.fromisoformat(item.created_at.replace("Z", "+00:00"))
    except ValueError as exc:
        raise HTTPException(422, "Host snapshot contains an invalid timestamp") from exc
    now = datetime.now(timezone.utc).isoformat()
    with database_connection() as db:
        before = db.total_changes
        for agent in payload.agents:
            db.execute("""INSERT INTO agents(id,display_name,executable,installed,first_seen_at,last_seen_at)
                VALUES (?,?,?,?,?,?) ON CONFLICT(id) DO UPDATE SET
                display_name=excluded.display_name, executable=excluded.executable,
                installed=excluded.installed, last_seen_at=excluded.last_seen_at""",
                (agent.id, agent.display_name, agent.executable, int(agent.installed), now, now))
        for item in payload.opencode.records:
            if item.message_type == "session_aggregate":
                # V2 session counters are lifetime cumulative values. Convert
                # each host snapshot to a positive delta so repeated polls do
                # not add the same session totals twice.
                previous = db.execute("SELECT * FROM session_usage_snapshots WHERE session_id=?", (item.session_id,)).fetchone()
                observed_at = datetime.fromisoformat(payload.collected_at.replace("Z", "+00:00")).astimezone(timezone.utc).isoformat()
                if previous and previous["observed_at"] >= observed_at:
                    continue
                current = {
                    "input_tokens": item.input_tokens,
                    "output_tokens": item.output_tokens,
                    "reasoning_tokens": item.reasoning_tokens,
                    "cache_read_tokens": item.cache_read_tokens,
                    "cache_write_tokens": item.cache_write_tokens,
                    "assistant_message_count": item.assistant_message_count,
                    "cost_usd": item.cost_usd,
                }
                reset_detected = bool(previous and any(value < previous[key] for key, value in current.items()))
                delta = {}
                for key, value in current.items():
                    prior = previous[key] if previous else 0
                    # A reset is explicitly recorded. The new value is treated
                    # as the first delta of a fresh counter epoch, never negative.
                    delta[key] = value - prior if value >= prior else value
                if any(value > 0 for value in delta.values()) or reset_detected:
                    session_hash = hashlib.sha256(item.session_id.encode("utf-8")).hexdigest()[:20]
                    delta_event_id = f"session-delta:{session_hash}:{observed_at}"
                    db.execute("""INSERT OR IGNORE INTO usage_events(
                        event_id,agent_id,message_type,session_id,provider_id,model_id,created_at,
                        input_tokens,output_tokens,reasoning_tokens,cache_read_tokens,cache_write_tokens,
                        cost_usd,assistant_message_count,counter_reset_detected
                    ) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)""",
                    (delta_event_id, "opencode", "session_delta", item.session_id,
                     item.provider_id, item.model_id, observed_at, delta["input_tokens"],
                     delta["output_tokens"], delta["reasoning_tokens"], delta["cache_read_tokens"],
                     delta["cache_write_tokens"], delta["cost_usd"], delta["assistant_message_count"],
                     int(reset_detected)))
                db.execute("""INSERT INTO session_usage_snapshots(
                    session_id,provider_id,model_id,observed_at,input_tokens,output_tokens,
                    reasoning_tokens,cache_read_tokens,cache_write_tokens,assistant_message_count,cost_usd,counter_reset_detected
                ) VALUES (?,?,?,?,?,?,?,?,?,?,?,?)
                ON CONFLICT(session_id) DO UPDATE SET
                    provider_id=excluded.provider_id, model_id=excluded.model_id,
                    observed_at=excluded.observed_at, input_tokens=excluded.input_tokens,
                    output_tokens=excluded.output_tokens, reasoning_tokens=excluded.reasoning_tokens,
                    cache_read_tokens=excluded.cache_read_tokens, cache_write_tokens=excluded.cache_write_tokens,
                    assistant_message_count=excluded.assistant_message_count, cost_usd=excluded.cost_usd,
                    counter_reset_detected=excluded.counter_reset_detected
                """, (item.session_id, item.provider_id, item.model_id, observed_at,
                      item.input_tokens, item.output_tokens, item.reasoning_tokens,
                      item.cache_read_tokens, item.cache_write_tokens,
                      item.assistant_message_count, item.cost_usd, int(reset_detected)))
            else:
                db.execute("""INSERT OR IGNORE INTO usage_events(
                    event_id,agent_id,message_type,session_id,provider_id,model_id,created_at,
                    input_tokens,output_tokens,reasoning_tokens,cache_read_tokens,cache_write_tokens,
                    cost_usd,assistant_message_count
                ) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?)""",
                (item.event_id, "opencode", item.message_type, item.session_id, item.provider_id,
                 item.model_id, item.created_at, item.input_tokens, item.output_tokens,
                 item.reasoning_tokens, item.cache_read_tokens, item.cache_write_tokens,
                 item.cost_usd, item.assistant_message_count))
        imported = db.total_changes - before
        db.execute("INSERT INTO app_meta(key,value) VALUES ('host_snapshot_at',?) ON CONFLICT(key) DO UPDATE SET value=excluded.value", (payload.collected_at,))
        db.execute("INSERT INTO app_meta(key,value) VALUES ('opencode_status',?) ON CONFLICT(key) DO UPDATE SET value=excluded.value", (payload.opencode.status,))
        db.execute("INSERT INTO app_meta(key,value) VALUES ('opencode_error',?) ON CONFLICT(key) DO UPDATE SET value=excluded.value", (payload.opencode.error or "",))
        db.execute("INSERT INTO app_meta(key,value) VALUES ('opencode_aggregation_basis',?) ON CONFLICT(key) DO UPDATE SET value=excluded.value", (payload.opencode.aggregation_basis,))
        db.execute("INSERT INTO app_meta(key,value) VALUES ('opencode_timestamp_semantics',?) ON CONFLICT(key) DO UPDATE SET value=excluded.value", (payload.opencode.timestamp_semantics,))
    return {"accepted": True, "agent_count": len(payload.agents),
            "observed_usage_events": len(payload.opencode.records),
            "imported_records_and_agent_updates": imported,
            "opencode_status": payload.opencode.status,
            "credentials_received": False, "message_bodies_received": False}


@app.get("/api/usage/summary")
def usage_summary():
    with database_connection() as db:
        totals = db.execute("""SELECT COALESCE(SUM(assistant_message_count),0) AS assistant_messages,
            COALESCE(SUM(input_tokens+output_tokens),0) AS input_output_tokens,
            COALESCE(SUM(reasoning_tokens),0) AS reasoning_tokens,
            COALESCE(SUM(cache_read_tokens),0) AS cache_read_tokens,
            COALESCE(SUM(cache_write_tokens),0) AS cache_write_tokens,
            COALESCE(SUM(cost_usd),0) AS cost_usd,
            COUNT(DISTINCT session_id) AS sessions, COUNT(*) AS usage_events,
            COALESCE(SUM(counter_reset_detected),0) AS counter_reset_events
            FROM usage_events WHERE agent_id='opencode'""").fetchone()
        start = (datetime.now(timezone.utc).date() - timedelta(days=6)).isoformat()
        rows = db.execute("""SELECT substr(created_at,1,10) AS day,
            SUM(input_tokens+output_tokens) AS input_output_tokens,
            SUM(reasoning_tokens) AS reasoning_tokens,
            SUM(cache_read_tokens) AS cache_read_tokens,
            SUM(cache_write_tokens) AS cache_write_tokens,
            SUM(cost_usd) AS cost_usd,
            SUM(assistant_message_count) AS assistant_messages,
            SUM(counter_reset_detected) AS counter_reset_events
            FROM usage_events WHERE agent_id='opencode' AND substr(created_at,1,10)>=?
            GROUP BY day ORDER BY day""", (start,)).fetchall()
    mapping = {row["day"]: dict(row) for row in rows}
    daily = []
    for offset in range(6, -1, -1):
        date_value = (datetime.now(timezone.utc).date() - timedelta(days=offset)).isoformat()
        row = mapping.get(date_value, {})
        daily.append({"day": (datetime.now(timezone.utc).date() - timedelta(days=offset)).strftime("%a"),
                      "date": date_value, "input_output_tokens": int(row.get("input_output_tokens") or 0),
                      "reasoning_tokens": int(row.get("reasoning_tokens") or 0),
                      "cache_read_tokens": int(row.get("cache_read_tokens") or 0),
                      "cache_write_tokens": int(row.get("cache_write_tokens") or 0),
                      "cost_usd": float(row.get("cost_usd") or 0),
                      "assistant_messages": int(row.get("assistant_messages") or 0),
                      "counter_reset_events": int(row.get("counter_reset_events") or 0)})
    return {**dict(totals), "daily": daily}


@app.post("/api/documents")
def add_document(payload: DocumentInput):
    embedding = validate_embedding(payload.embedding)
    if embedding is None:
        embedding = ollama_embedding(f"{payload.title}\n\n{payload.body}")
    if embedding is not None:
        embedding = validate_embedding(embedding)
    now = datetime.now(timezone.utc).isoformat()
    with database_connection() as db:
        cursor = db.execute("""INSERT INTO documents(title,body,source,created_at,updated_at,embedding_model,embedding_dimensions)
            VALUES (?,?,?,?,?,?,?)""", (payload.title, payload.body, payload.source, now, now,
            OLLAMA_EMBED_MODEL if embedding else None, len(embedding) if embedding else None))
        document_id = cursor.lastrowid
        if embedding is not None:
            db.execute("INSERT INTO documents_vec(rowid,embedding) VALUES (?,?)", (document_id, json.dumps(embedding)))
    return {"id": document_id, "indexed_fts5": True, "indexed_vector": embedding is not None,
            "vector_dimensions": len(embedding) if embedding else None}


@app.post("/api/search")
def search(payload: SearchInput):
    query_embedding = validate_embedding(payload.embedding) if payload.embedding is not None else ollama_embedding(payload.query)
    lexical: dict[int, dict[str, Any]] = {}
    with database_connection() as db:
        try:
            rows = db.execute("""SELECT d.id,d.title,d.body,d.source,bm25(documents_fts) AS rank
                FROM documents_fts JOIN documents d ON d.id=documents_fts.rowid
                WHERE documents_fts MATCH ? ORDER BY rank LIMIT ?""", (payload.query, payload.limit)).fetchall()
            for row in rows:
                lexical[int(row["id"])] = {"id": int(row["id"]), "title": row["title"],
                    "excerpt": row["body"][:260], "source": row["source"],
                    "lexical_rank": float(row["rank"]), "score": 0.0}
        except sqlite3.OperationalError:
            # Invalid FTS syntax is not interpolated into SQL; return an empty lexical set.
            lexical = {}
        semantic: dict[int, float] = {}
        if query_embedding is not None:
            try:
                matches = db.execute("""SELECT rowid,distance FROM documents_vec
                    WHERE embedding MATCH ? ORDER BY distance LIMIT ?""",
                    (json.dumps(query_embedding), payload.limit)).fetchall()
                semantic = {int(row["rowid"]): float(row["distance"]) for row in matches}
            except sqlite3.Error as exc:
                raise HTTPException(503, f"Vector search failed: {exc}") from exc
        for doc_id, distance in semantic.items():
            if doc_id not in lexical:
                row = db.execute("SELECT id,title,body,source FROM documents WHERE id=?", (doc_id,)).fetchone()
                if row:
                    lexical[doc_id] = {"id": int(row["id"]), "title": row["title"],
                        "excerpt": row["body"][:260], "source": row["source"],
                        "lexical_rank": None, "score": 0.0}
            if doc_id in lexical:
                lexical[doc_id]["vector_distance"] = distance
                lexical[doc_id]["score"] += 1.0 / (1.0 + max(distance, 0.0))
        for item in lexical.values():
            if item.get("lexical_rank") is not None:
                item["score"] += 1.0 / (1.0 + abs(item["lexical_rank"]))
            item["score_label"] = f"hybrid {item['score']:.3f}"
        results = sorted(lexical.values(), key=lambda item: item["score"], reverse=True)[:payload.limit]
    return {"mode": "hybrid" if query_embedding is not None else "lexical-only",
            "vector_available": query_embedding is not None, "results": results}


@app.post("/api/admin/backup")
def backup_database():
    # SQLite's backup API includes committed WAL content; copying only agents.db is unsafe.
    destination = DB_PATH.with_name(f"{DB_PATH.stem}-backup-{int(time.time())}.db")
    with database_connection() as source:
        target = sqlite3.connect(destination)
        try:
            source.backup(target)
            check = target.execute("PRAGMA integrity_check").fetchone()[0]
            if check != "ok":
                raise HTTPException(500, f"Backup integrity check failed: {check}")
        finally:
            target.close()
    return {"backup_path": str(destination), "integrity": "ok"}
EOF

write_file 'backend/tests/test_restore_db.py' <<'EOF'
from __future__ import annotations

import sqlite3
from pathlib import Path

import sqlite_vec

import restore_db


def create_database(path: Path, agent_id: str) -> None:
    connection = sqlite3.connect(path)
    connection.enable_load_extension(True)
    try:
        sqlite_vec.load(connection)
    finally:
        connection.enable_load_extension(False)
    connection.executescript("""
        CREATE TABLE app_meta(key TEXT PRIMARY KEY, value TEXT NOT NULL);
        CREATE TABLE agents(id TEXT PRIMARY KEY, display_name TEXT NOT NULL);
        CREATE TABLE usage_events(event_id TEXT PRIMARY KEY);
        CREATE TABLE documents(id INTEGER PRIMARY KEY, title TEXT NOT NULL);
        CREATE VIRTUAL TABLE documents_fts USING fts5(title);
        CREATE VIRTUAL TABLE documents_vec USING vec0(embedding float[768]);
        CREATE TABLE schema_migrations(version INTEGER PRIMARY KEY, applied_at TEXT, description TEXT);
    """)
    connection.execute("INSERT INTO agents VALUES (?,?)", (agent_id, agent_id.title()))
    connection.execute("INSERT INTO documents VALUES (1,?)", (agent_id,))
    connection.execute("INSERT INTO documents_fts VALUES (?)", (agent_id,))
    connection.commit()
    connection.close()


def test_restore_uses_online_backup_and_preserves_pre_restore_database(tmp_path, monkeypatch):
    data_dir = tmp_path / "data"
    data_dir.mkdir()
    db_path = data_dir / "agents.db"
    backup_dir = data_dir / "backups"
    source_backup = tmp_path / "source-backup.db"
    monkeypatch.setattr(restore_db, "DATA_DIR", data_dir)
    monkeypatch.setattr(restore_db, "DB_PATH", db_path)
    monkeypatch.setattr(restore_db, "BACKUP_DIR", backup_dir)

    create_database(db_path, "old-agent")
    create_database(source_backup, "new-agent")

    result = restore_db.restore(source_backup)
    assert result["status"] == "restored"
    assert result["restored_database"]["integrity"] == "ok"
    assert result["restored_database"]["fts_rows"] == 1
    assert result["pre_restore_backup"]

    with sqlite3.connect(db_path) as connection:
        assert connection.execute("SELECT id FROM agents").fetchone()[0] == "new-agent"
    with sqlite3.connect(result["pre_restore_backup"]) as connection:
        assert connection.execute("SELECT id FROM agents").fetchone()[0] == "old-agent"

    # A later restore from the saved pre-restore copy acts as a rollback.
    restore_db.restore(Path(result["pre_restore_backup"]))
    with sqlite3.connect(db_path) as connection:
        assert connection.execute("SELECT id FROM agents").fetchone()[0] == "old-agent"


def test_restore_rejects_non_sqlite_input(tmp_path, monkeypatch):
    data_dir = tmp_path / "data"
    data_dir.mkdir()
    monkeypatch.setattr(restore_db, "DATA_DIR", data_dir)
    monkeypatch.setattr(restore_db, "DB_PATH", data_dir / "agents.db")
    monkeypatch.setattr(restore_db, "BACKUP_DIR", data_dir / "backups")
    invalid = tmp_path / "not-a-database.db"
    invalid.write_bytes(b"X" * 128)
    try:
        restore_db.validate_database(invalid)
    except RuntimeError as exc:
        assert "SQLite" in str(exc)
    else:
        raise AssertionError("Non-SQLite backup was accepted")
EOF
write_file 'backend/tests/test_main.py' <<'EOF'
import json
import sqlite3

from fastapi.testclient import TestClient

import main
from collectors.opencode import collect_opencode_usage


def test_health_and_capabilities(tmp_path, monkeypatch):
    monkeypatch.setattr(main, "DB_PATH", tmp_path / "test.db")
    with TestClient(main.app) as client:
        health = client.get('/health')
        assert health.status_code == 200
        assert health.json()['status'] == 'ok'
        capabilities = client.get('/api/capabilities')
        assert capabilities.status_code == 200
        assert capabilities.json()['fts5'] is True
        assert capabilities.json()['sqlite_vec'] is True


def test_document_fts_search(tmp_path, monkeypatch):
    monkeypatch.setattr(main, "DB_PATH", tmp_path / "test.db")
    monkeypatch.setattr(main, "ollama_embedding", lambda _text: None)
    with TestClient(main.app) as client:
        created = client.post('/api/documents', json={
            'title': 'OpenCode database safety',
            'body': 'OpenCode usage metadata is read from a read-only SQLite database.',
            'source': 'test'
        })
        assert created.status_code == 200
        assert created.json()['indexed_fts5'] is True
        assert created.json()['indexed_vector'] is False
        result = client.post('/api/search', json={'query': 'OpenCode', 'limit': 5})
        assert result.status_code == 200
        assert result.json()['mode'] == 'lexical-only'
        assert result.json()['results'][0]['title'] == 'OpenCode database safety'


def test_vector_document_search(tmp_path, monkeypatch):
    monkeypatch.setattr(main, "DB_PATH", tmp_path / "vector-test.db")
    vector = [0.0] * main.VECTOR_DIMENSIONS
    vector[0] = 1.0
    with TestClient(main.app) as client:
        created = client.post('/api/documents', json={
            'title': 'Vector indexed agent architecture',
            'body': 'The local vector index supports nearest-neighbour retrieval.',
            'source': 'vector-test', 'embedding': vector
        })
        assert created.status_code == 200
        assert created.json()['indexed_vector'] is True
        result = client.post('/api/search', json={
            'query': 'semantic architecture', 'embedding': vector, 'limit': 3
        })
        assert result.status_code == 200
        assert result.json()['mode'] == 'hybrid'
        assert result.json()['results'][0]['title'] == 'Vector indexed agent architecture'


def test_opencode_dual_store_contract_uses_v1_messages_and_v2_session_aggregates(tmp_path):
    source_path = tmp_path / 'opencode.db'
    source = sqlite3.connect(source_path)
    source.executescript('''
      CREATE TABLE session (id TEXT PRIMARY KEY, time_created INTEGER, parent_id TEXT);
      CREATE TABLE session_v2 (
        id TEXT PRIMARY KEY, model TEXT, cost REAL, tokens_input INTEGER, tokens_output INTEGER,
        tokens_reasoning INTEGER, tokens_cache_read INTEGER, tokens_cache_write INTEGER,
        time_created INTEGER, time_updated INTEGER, fork_session_id TEXT
      );
      CREATE TABLE message (id TEXT PRIMARY KEY, session_id TEXT, data TEXT, time_created INTEGER);
      CREATE TABLE session_message (id TEXT PRIMARY KEY, session_id TEXT, type TEXT, data TEXT, time_created INTEGER, seq INTEGER);
      CREATE TABLE auth (id TEXT PRIMARY KEY, data TEXT);
    ''')
    source.execute('INSERT INTO auth VALUES (?,?)', ('provider-secret', '{"apiKey":"DO_NOT_READ_OR_RETURN"}'))
    source.execute('INSERT INTO session VALUES (?,?,?)', ('legacy-session', 1770000000000, None))
    source.execute('INSERT INTO session VALUES (?,?,?)', ('legacy-fork', 1790000000000, 'legacy-session'))
    source.execute('INSERT INTO session_v2 VALUES (?,?,?,?,?,?,?,?,?,?,?)',
                   ('v2-session', json.dumps({'providerID': 'openai', 'id': 'gpt-test'}),
                    0.02, 100, 20, 5, 7, 3, 1770000000000, 1780000000000, None))
    source.execute('INSERT INTO session_v2 VALUES (?,?,?,?,?,?,?,?,?,?,?)',
                   ('forked-session', json.dumps({'providerID': 'openai', 'id': 'gpt-test'}),
                    0, 0, 0, 0, 0, 0, 1790000000000, 1790000000000, 'v2-session'))
    source.execute('INSERT INTO session_v2 VALUES (?,?,?,?,?,?,?,?,?,?,?)',
                   ('fallback-session', json.dumps({'providerID': 'anthropic', 'id': 'claude-test'}),
                    0.03, 300, 40, 10, 20, 5, 1770000000000, 1785000000000, None))
    assistant = {
        'role': 'assistant', 'providerID': 'openai', 'modelID': 'gpt-test',
        'time': {'created': 1780000000000},
        'tokens': {'input': 10, 'output': 2, 'reasoning': 1, 'cache': {'read': 0, 'write': 0}},
        'cost': 0.002, 'content': 'PRIVATE PROMPT AND ASSISTANT BODY MUST NOT BE RETURNED'
    }
    v2_assistant = {
        'model': {'providerID': 'openai', 'id': 'gpt-test'},
        'time': {'created': 1780000000000},
        'tokens': {'input': 80, 'output': 12, 'reasoning': 2, 'cache': {'read': 5, 'write': 1}},
        'cost': 0.01, 'content': [{'type': 'text', 'text': 'PRIVATE V2 BODY'}]
    }
    source.execute('INSERT INTO session_message VALUES (?,?,?,?,?,?)',
                   ('v2-assistant-id', 'v2-session', 'assistant', json.dumps(v2_assistant), 1780000000000, 1))
    source.execute('INSERT INTO session_message VALUES (?,?,?,?,?,?)',
                   ('fallback-assistant-id', 'fallback-session', 'assistant', json.dumps({'content': 'PRIVATE FALLBACK BODY'}), 1785000000000, 1))
    source.execute('INSERT INTO session_message VALUES (?,?,?,?,?,?)',
                   ('compact-id', 'v2-session', 'compaction', json.dumps({'content': 'PRIVATE COMPACTION BODY'}), 1780000001000, 2))
    source.execute('INSERT INTO session_message VALUES (?,?,?,?,?,?)',
                   ('fork-copy', 'forked-session', 'assistant', json.dumps({**v2_assistant, 'content': [{'type':'text','text':'PRIVATE FORK BODY'}]}), 1780000000000, 1))
    source.execute('INSERT INTO session_message VALUES (?,?,?,?,?,?)',
                   ('user-prompt', 'v2-session', 'user', json.dumps({'content': 'PRIVATE USER PROMPT'}), 1780000000000, 3))
    source.execute('INSERT INTO message VALUES (?,?,?,?)',
                   ('legacy-assistant-id', 'legacy-session', json.dumps(assistant), 1780000000000))
    # Same global message ID across stores is counted once.
    source.execute('INSERT INTO message VALUES (?,?,?,?)',
                   ('v2-assistant-id', 'legacy-session', json.dumps(assistant), 1780000000000))
    # A copied pre-fork legacy row predating its fork session is excluded.
    source.execute('INSERT INTO message VALUES (?,?,?,?)',
                   ('legacy-fork-copy', 'legacy-fork', json.dumps(assistant), 1780000000000))
    source.commit()
    source.close()

    original_stat = source_path.stat()
    envelope = collect_opencode_usage(source_path)
    after_stat = source_path.stat()
    records = envelope['records']
    assert envelope['schema_version'] == 1
    assert envelope['agent'] == 'opencode'
    assert envelope['status'] == 'ok'
    assert envelope['aggregation_basis'] == 'mixed'
    assert set(envelope['stores']) == {'message', 'session_message', 'session_v2'}
    assert len(records) == 3
    v2_record = next(record for record in records if record['session_id'] == 'v2-session')
    aggregate_record = next(record for record in records if record['message_type'] == 'session_aggregate')
    v1_record = next(record for record in records if record['session_id'] == 'legacy-session')
    assert v2_record['event_id'] == 'message:v2-assistant-id'
    assert v2_record['provider_id'] == 'openai' and v2_record['model_id'] == 'gpt-test'
    assert v2_record['input_tokens'] == 80 and v2_record['assistant_message_count'] == 1
    assert aggregate_record['session_id'] == 'fallback-session'
    assert aggregate_record['input_tokens'] == 300 and aggregate_record['assistant_message_count'] == 1
    assert v1_record['event_id'] == 'message:legacy-assistant-id'
    assert v1_record['input_tokens'] == 10 and v1_record['assistant_message_count'] == 1
    assert not any(record['session_id'] in {'legacy-fork', 'forked-session'} for record in records)
    encoded = json.dumps(envelope)
    for private_value in ('PRIVATE PROMPT', 'PRIVATE V2 BODY', 'PRIVATE FALLBACK BODY', 'PRIVATE COMPACTION BODY',
                          'PRIVATE FORK BODY', 'PRIVATE USER PROMPT', 'DO_NOT_READ_OR_RETURN'):
        assert private_value not in encoded
    assert envelope['privacy']['message_bodies_selected'] is False
    assert original_stat.st_size == after_stat.st_size
    assert original_stat.st_mtime_ns == after_stat.st_mtime_ns


def test_opencode_session_aggregate_schema_without_session_v2(tmp_path):
    source_path = tmp_path / 'opencode-session-v2.db'
    source = sqlite3.connect(source_path)
    source.executescript('''
      CREATE TABLE session (
        id TEXT PRIMARY KEY, model TEXT, cost REAL, tokens_input INTEGER, tokens_output INTEGER,
        tokens_reasoning INTEGER, tokens_cache_read INTEGER, tokens_cache_write INTEGER,
        time_created INTEGER, time_updated INTEGER
      );
      CREATE TABLE session_message (
        id TEXT PRIMARY KEY, session_id TEXT, type TEXT, data TEXT, time_created INTEGER, seq INTEGER
      );
    ''')
    source.execute('INSERT INTO session VALUES (?,?,?,?,?,?,?,?,?,?)',
                   ('new-schema-session', json.dumps({'providerID':'anthropic','id':'claude-test'}),
                    0.04, 200, 30, 8, 70, 10, 1770000000000, 1780000000000))
    source.execute('INSERT INTO session_message VALUES (?,?,?,?,?,?)',
                   ('message-1','new-schema-session','assistant','{"content":"private"}',1780000000000,1))
    source.commit(); source.close()
    envelope = collect_opencode_usage(source_path)
    assert envelope['aggregation_basis'] == 'session-aggregate'
    assert envelope['stores'] == ['session', 'session_message']
    assert len(envelope['records']) == 1
    assert envelope['records'][0]['provider_id'] == 'anthropic'
    assert envelope['records'][0]['assistant_message_count'] == 1
    assert 'private' not in json.dumps(envelope)


def test_host_snapshot_ingestion(tmp_path, monkeypatch):
    monkeypatch.setattr(main, "DB_PATH", tmp_path / "snapshot-test.db")
    agents = [
        {"id": "opencode", "display_name": "OpenCode", "executable": "opencode", "installed": True},
        {"id": "claude", "display_name": "Claude Code", "executable": "claude", "installed": False},
        {"id": "codex", "display_name": "OpenAI Codex", "executable": "codex", "installed": True},
        {"id": "gemini", "display_name": "Gemini CLI", "executable": "gemini", "installed": False},
        {"id": "pi", "display_name": "Pi", "executable": "pi", "installed": False},
        {"id": "github-copilot", "display_name": "GitHub Copilot CLI", "executable": "copilot", "installed": False},
    ]
    snapshot = {
        "schema_version": 1,
        "collected_at": "2026-11-20T12:00:00+00:00",
        "agents": agents,
        "opencode": {
            "schema_version": 1, "agent": "opencode", "status": "available",
            "stores": ["message"], "error": None,
            "aggregation_basis": "message-level",
            "timestamp_semantics": "V1 assistant message creation timestamps.",
            "privacy": {"message_bodies_selected": False, "credentials_selected": False,
                        "source_database_modified": False},
            "records": [{
                "event_id": "snapshot-event-1", "session_id": "session-1",
                "provider_id": "openai", "model_id": "gpt-test", "message_type": "assistant",
                "created_at": "2026-11-20T11:00:00+00:00", "input_tokens": 12,
                "output_tokens": 8, "reasoning_tokens": 1, "cache_read_tokens": 2,
                "cache_write_tokens": 0, "cost_usd": 0.001
            }]
        }
    }
    with TestClient(main.app) as client:
        response = client.post('/api/ingest/host-snapshot', json=snapshot)
        assert response.status_code == 200, response.text
        assert response.json()['accepted'] is True
        agents_response = client.get('/api/agents')
        assert agents_response.status_code == 200
        assert next(item for item in agents_response.json()['agents'] if item['id'] == 'codex')['installed'] is True
        summary = client.get('/api/usage/summary').json()
        assert summary['assistant_messages'] == 1
        assert summary['input_output_tokens'] == 20
        assert summary['reasoning_tokens'] == 1
        assert summary['cache_read_tokens'] == 2
        status = client.get('/api/host-snapshot/status').json()
        assert status['opencode_status'] == 'available'


def test_v2_cumulative_session_snapshots_are_ingested_as_deltas(tmp_path, monkeypatch):
    monkeypatch.setattr(main, "DB_PATH", tmp_path / "v2-delta-test.db")
    agents = [
        {"id": "opencode", "display_name": "OpenCode", "executable": "opencode", "installed": True},
        {"id": "claude", "display_name": "Claude Code", "executable": "claude", "installed": False},
        {"id": "codex", "display_name": "OpenAI Codex", "executable": "codex", "installed": False},
        {"id": "gemini", "display_name": "Gemini CLI", "executable": "gemini", "installed": False},
        {"id": "pi", "display_name": "Pi", "executable": "pi", "installed": False},
        {"id": "github-copilot", "display_name": "GitHub Copilot CLI", "executable": "copilot", "installed": False},
    ]
    def payload(collected_at, input_tokens, output_tokens, reasoning, cache_read, cache_write, cost, messages):
        return {
            "schema_version": 1, "collected_at": collected_at, "agents": agents,
            "opencode": {
                "schema_version": 1, "agent": "opencode", "status": "available",
                "stores": ["session_v2", "session_message"], "error": None,
                "aggregation_basis": "session-aggregate",
                "timestamp_semantics": "V2 cumulative session counters converted to observation-time deltas.",
                "privacy": {"message_bodies_selected": False, "credentials_selected": False,
                            "source_database_modified": False},
                "records": [{
                    "event_id": "session-aggregate:session_v2:session-1", "session_id": "session-1",
                    "provider_id": "openai", "model_id": "gpt-test", "message_type": "session_aggregate",
                    "created_at": collected_at, "assistant_message_count": messages,
                    "input_tokens": input_tokens, "output_tokens": output_tokens,
                    "reasoning_tokens": reasoning, "cache_read_tokens": cache_read,
                    "cache_write_tokens": cache_write, "cost_usd": cost
                }]
            }
        }
    with TestClient(main.app) as client:
        first = client.post('/api/ingest/host-snapshot', json=payload('2026-11-20T12:00:00+00:00',100,20,5,50,5,0.02,2))
        assert first.status_code == 200, first.text
        second = client.post('/api/ingest/host-snapshot', json=payload('2026-11-20T12:15:00+00:00',150,30,8,75,10,0.03,3))
        assert second.status_code == 200, second.text
        duplicate = client.post('/api/ingest/host-snapshot', json=payload('2026-11-20T12:15:00+00:00',150,30,8,75,10,0.03,3))
        assert duplicate.status_code == 200, duplicate.text
        # A counter decrease starts a new epoch. The new value is retained as
        # a positive delta and the reset is made visible to the UI/audit log.
        reset = client.post('/api/ingest/host-snapshot', json=payload('2026-11-20T12:30:00+00:00',10,2,1,5,1,0.004,1))
        assert reset.status_code == 200, reset.text
        reset_duplicate = client.post('/api/ingest/host-snapshot', json=payload('2026-11-20T12:30:00+00:00',10,2,1,5,1,0.004,1))
        assert reset_duplicate.status_code == 200, reset_duplicate.text
        summary = client.get('/api/usage/summary').json()
        assert summary['input_output_tokens'] == 192, summary
        assert summary['assistant_messages'] == 4, summary
        assert summary['reasoning_tokens'] == 9, summary
        assert summary['cache_read_tokens'] == 80, summary
        assert summary['cache_write_tokens'] == 11, summary
        assert abs(summary['cost_usd'] - 0.034) < 1e-9, summary
        assert summary['usage_events'] == 3, summary
        assert summary['counter_reset_events'] == 1, summary


def test_embedding_dimension_validation():
    try:
        main.validate_embedding([0.1, 0.2])
    except Exception as exc:
        assert getattr(exc, 'status_code', None) == 422
    else:
        raise AssertionError('Invalid vector dimension was accepted')
EOF

write_file 'docker-compose.yml' <<'EOF'
services:
  api:
    build:
      context: ./backend
      dockerfile: Dockerfile
    container_name: fedora-ai-agents-api
    restart: unless-stopped
    environment:
      DATABASE_PATH: /data/agents.db
      VECTOR_DIMENSIONS: ${VECTOR_DIMENSIONS:-768}
      OLLAMA_BASE_URL: http://host.docker.internal:11434
      OLLAMA_EMBED_MODEL: ${OLLAMA_EMBED_MODEL:-nomic-embed-text}
      CORS_ORIGINS: http://127.0.0.1:5173,http://localhost:5173,http://127.0.0.1:4173
    ports:
      # Bind explicitly to loopback. Do not change to 0.0.0.0 for a desktop-local service.
      - "127.0.0.1:8000:8000"
    volumes:
      - agent-data:/data
    extra_hosts:
      - "host.docker.internal:host-gateway"
    healthcheck:
      test: ["CMD", "python", "-c", "import urllib.request; urllib.request.urlopen('http://127.0.0.1:8000/health', timeout=3)"]
      interval: 20s
      timeout: 5s
      retries: 4
      start_period: 20s
    security_opt:
      - no-new-privileges:true
    cap_drop:
      - ALL
    read_only: true
    tmpfs:
      - /tmp:size=32m,noexec,nosuid,nodev
    networks:
      - agent-net

volumes:
  agent-data:
    name: fedora-ai-agents-data

networks:
  agent-net:
    name: fedora-ai-agents-net
    driver: bridge
EOF

write_file '.env.example' <<'EOF'
# Optional overrides. Copy to .env only when you need non-default values.
# The database itself lives in the named Docker volume fedora-ai-agents-data.
VECTOR_DIMENSIONS=768
OLLAMA_EMBED_MODEL=nomic-embed-text
EOF

write_file 'install-opencode.sh' <<'EOF'
#!/usr/bin/env bash
# Official OpenCode V2 CLI installer command, with post-install verification.
# Review https://opencode.ai/docs/ before execution; this invokes the official upstream installer.
set -o pipefail
main() {
export PATH="$HOME/.local/bin:$HOME/.opencode/bin:$HOME/.local/share/npm/bin:$PATH"

if command -v opencode >/tmp/fedora-ai-agents-command-check.log 2>&1; then
    printf 'OpenCode is already installed: '
    opencode --version
    printf 'No reinstall was performed.\n'
    return 0
fi

printf 'Downloading the official OpenCode installer from https://opencode.ai/v2/install\n'
CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/fedora-ai-agents"
mkdir -p "$CACHE_DIR" || return 1
INSTALLER_FILE="$CACHE_DIR/opencode-v2-install.sh"
INSTALLER_TEMP="$(mktemp "$CACHE_DIR/.opencode-installer.XXXXXX")" || return 1
if ! curl --fail --location --silent --show-error \
    --output "$INSTALLER_TEMP" https://opencode.ai/v2/install; then
    printf 'OpenCode installer download failed; preserving the partial response for inspection.\n' >&2
    mv -f "$INSTALLER_TEMP" "$CACHE_DIR/opencode-installer-download-failed.$(date -u +%Y%m%dT%H%M%SZ)"
    return 1
fi
if ! bash -n "$INSTALLER_TEMP"; then
    printf 'Downloaded OpenCode installer failed bash syntax validation; preserving it for inspection.\n' >&2
    mv -f "$INSTALLER_TEMP" "$CACHE_DIR/opencode-installer-syntax-failed.$(date -u +%Y%m%dT%H%M%SZ)"
    return 1
fi
printf 'Downloaded installer SHA-256: '
sha256sum "$INSTALLER_TEMP" || return 1
if [ -f "$INSTALLER_FILE" ] && ! cmp -s "$INSTALLER_TEMP" "$INSTALLER_FILE"; then
    cp -a "$INSTALLER_FILE" "$INSTALLER_FILE.backup.$(date -u +%Y%m%dT%H%M%SZ)" || return 1
fi
mv -f "$INSTALLER_TEMP" "$INSTALLER_FILE" || return 1
printf 'Executing the downloaded, syntax-checked installer: %s\n' "$INSTALLER_FILE"
bash "$INSTALLER_FILE" || return 1

if ! command -v opencode >/tmp/fedora-ai-agents-command-check.log 2>&1; then
    printf 'Installer returned but opencode is not on PATH. Review the installer output and PATH.\n' >&2
    return 1
fi
opencode --version || return 1
printf '\nReview configured providers with:\n  opencode auth list\nThen authenticate a selected provider, for example:\n  opencode auth login anthropic\n'
    return 0
}
main "$@"
EOF

write_file 'agent-launcher.sh' <<'EOF'
#!/usr/bin/env bash
# Minimal Xfce-friendly launcher. It starts only installed commands from this fixed allowlist.
# It never evaluates arbitrary input as shell code and never handles provider credentials.
set -o pipefail
main() {

AGENT_NAMES=("OpenCode" "Claude Code" "OpenAI Codex" "Gemini CLI" "Pi" "GitHub Copilot CLI")
AGENT_COMMANDS=("opencode" "claude" "codex" "gemini" "pi" "copilot")
AVAILABLE_NAMES=()
AVAILABLE_COMMANDS=()

for index in "${!AGENT_COMMANDS[@]}"; do
    if command -v "${AGENT_COMMANDS[$index]}" >/tmp/fedora-ai-agents-command-check.log 2>&1; then
        AVAILABLE_NAMES+=("${AGENT_NAMES[$index]}")
        AVAILABLE_COMMANDS+=("${AGENT_COMMANDS[$index]}")
    fi
done

if [ "${#AVAILABLE_COMMANDS[@]}" -eq 0 ]; then
    printf 'No supported coding-agent executables were detected.\n' >&2
    printf 'Install OpenCode from the repository root with: bash ./install-opencode.sh\n' >&2
    return 1
fi

SELECTED=""
if command -v zenity >/tmp/fedora-ai-agents-command-check.log 2>&1; then
    ZENITY_ARGS=(--list --radiolist --title="AI Coding Agents" --text="Choose an installed coding agent" --column="Select" --column="Agent" --column="Command" --height=340 --width=520)
    for index in "${!AVAILABLE_COMMANDS[@]}"; do
        if [ "$index" -eq 0 ]; then PICK=TRUE; else PICK=FALSE; fi
        ZENITY_ARGS+=("$PICK" "${AVAILABLE_NAMES[$index]}" "${AVAILABLE_COMMANDS[$index]}")
    done
    SELECTED="$(zenity "${ZENITY_ARGS[@]}")"
    if [ -z "$SELECTED" ]; then return 0; fi
else
    printf '\nInstalled coding agents:\n'
    select SELECTED in "${AVAILABLE_COMMANDS[@]}" "Cancel"; do
        if [ "$SELECTED" = "Cancel" ] || [ -z "$SELECTED" ]; then return 0; fi
        break
    done
fi

if ! printf '%s\n' "${AVAILABLE_COMMANDS[@]}" | awk -v selected="$SELECTED" '$0 == selected { found=1 } END { exit(found ? 0 : 1) }'; then
    printf 'Selection is not in the detected executable allowlist.\n' >&2
    return 1
fi

if command -v xfce4-terminal >/tmp/fedora-ai-agents-command-check.log 2>&1; then
    xfce4-terminal --disable-server --command="$SELECTED"
else
    printf 'xfce4-terminal was not found. Starting %s in the current terminal.\n' "$SELECTED"
    exec "$SELECTED"
fi
    return 0
}
main "$@"
EOF

write_file 'install-fedora-ai-agents.sh' <<'EOF'
#!/usr/bin/env bash
# User-scoped Fedora 43 Xfce/X11 installer. It does not replace OpenCode configuration,
# edit OpenCode credentials, alter source databases, or remove Docker volumes.
set -o pipefail
main() {

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$SCRIPT_DIR"
USER_SERVICE_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
DESKTOP_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/applications"
SERVICE_FILE="$USER_SERVICE_DIR/fedora-ai-agents-web.service"
COLLECTOR_SERVICE_FILE="$USER_SERVICE_DIR/fedora-ai-agents-collector.service"
COLLECTOR_TIMER_FILE="$USER_SERVICE_DIR/fedora-ai-agents-collector.timer"
DESKTOP_FILE="$DESKTOP_DIR/fedora-ai-agents.desktop"
AGENT_DESKTOP_FILE="$DESKTOP_DIR/fedora-ai-agent-launcher.desktop"

printf '\n===== FEDORA AI AGENTS INSTALLER =====\n'
printf 'Repository: %s\n' "$REPO_DIR"
printf 'User: %s\n' "${USER:-unknown}"

for command_name in node npm python3 git docker curl; do
    if ! command -v "$command_name" >/tmp/fedora-ai-agents-command-check.log; then
        printf 'MISSING: %s\n' "$command_name" >&2
        printf 'Install the missing prerequisite, then rerun this script.\n' >&2
        return 1
    fi
done
if ! docker compose version >/tmp/fedora-ai-agents-command-check.log 2>&1; then
    printf 'Docker Compose v2 plugin is required.\n' >&2
    return 1
fi
if ! docker info >/tmp/fedora-ai-agents-command-check.log 2>&1; then
    printf 'Docker daemon is not reachable. Start/enable Docker before continuing.\n' >&2
    printf 'Typical Fedora command: sudo systemctl enable --now docker\n' >&2
    return 1
fi
NODE_VERSION="$(node -p 'process.versions.node')"
if ! node -e 'const [major,minor] = process.versions.node.split(".").map(Number); const ok = major > 22 || (major === 22 && minor >= 12) || (major === 20 && minor >= 19); if (!ok) process.exitCode = 1;'; then
    printf 'Vite 7 requires Node.js 20.19+, 22.12+, or newer; detected %s\n' "$NODE_VERSION" >&2
    return 1
fi

printf '\n===== VALIDATE PROJECT FILES =====\n'
for required in package.json vite.config.js docker-compose.yml backend/main.py backend/restore_db.py backend/Dockerfile backend/collectors agent-launcher.sh install-opencode.sh scripts/backup_db.sh scripts/restore_db.sh; do
    if [ ! -f "$REPO_DIR/$required" ]; then
        printf 'Missing project file: %s\n' "$required" >&2
        return 1
    fi
done

printf '\n===== INSTALL FRONTEND DEPENDENCIES =====\n'
cd "$REPO_DIR" || return 1
if [ -s package-lock.json ]; then
    npm ci
    NPM_STATUS=$?
else
    printf 'No package-lock.json exists yet; performing the first install and generating it.\n'
    npm install --no-audit --no-fund
    NPM_STATUS=$?
fi
if [ "$NPM_STATUS" -ne 0 ]; then
    printf 'npm install failed; no system files were changed.\n' >&2
    return "$NPM_STATUS"
fi

printf '\n===== BUILD LOCAL BACKEND =====\n'
docker compose config --quiet || return 1
docker compose up --build -d || return 1

printf '\n===== CREATE USER-LEVEL WEB SERVICE =====\n'
mkdir -p "$USER_SERVICE_DIR" "$DESKTOP_DIR"
NODE_BIN="$(command -v node)"
NPM_BIN="$(command -v npm)"
NODE_BIN_DIR="$(dirname "$NODE_BIN")"
SERVICE_TEMP="$(mktemp "${USER_SERVICE_DIR}/.fedora-ai-agents.XXXXXX")"
cat > "$SERVICE_TEMP" <<SERVICE_EOF
[Unit]
Description=Fedora AI Agents local Vite dashboard
After=network.target

[Service]
Type=simple
# systemd does not source interactive shell startup files. Use absolute Node/npm
# paths and explicitly preserve the Node bin directory for npm's child scripts.
# Environment and ExecStart semantics: https://www.freedesktop.org/software/systemd/man/latest/systemd.exec.html
WorkingDirectory="$REPO_DIR"
ExecStart="$NPM_BIN" run dev -- --host 127.0.0.1
Restart=on-failure
RestartSec=4
Environment=NODE_ENV=development
Environment="PATH=$NODE_BIN_DIR:$PATH"

[Install]
WantedBy=default.target
SERVICE_EOF
if [ -f "$SERVICE_FILE" ] && ! cmp -s "$SERVICE_TEMP" "$SERVICE_FILE"; then
    cp -a "$SERVICE_FILE" "${SERVICE_FILE}.backup.$(date -u +%Y%m%dT%H%M%SZ)"
fi
mv -f "$SERVICE_TEMP" "$SERVICE_FILE"

DESKTOP_TEMP="$(mktemp "${DESKTOP_DIR}/.fedora-ai-agents.XXXXXX")"
cat > "$DESKTOP_TEMP" <<DESKTOP_EOF
[Desktop Entry]
Type=Application
Name=Fedora AI Agents
Comment=Local AI coding agent dashboard
Exec=xdg-open http://127.0.0.1:5173/
Icon=applications-development
Terminal=false
Categories=Development;Utility;
StartupNotify=true
DESKTOP_EOF
if [ -f "$DESKTOP_FILE" ] && ! cmp -s "$DESKTOP_TEMP" "$DESKTOP_FILE"; then
    cp -a "$DESKTOP_FILE" "${DESKTOP_FILE}.backup.$(date -u +%Y%m%dT%H%M%SZ)"
fi
mv -f "$DESKTOP_TEMP" "$DESKTOP_FILE"
AGENT_DESKTOP_TEMP="$(mktemp "${DESKTOP_DIR}/.fedora-ai-agent-launcher.XXXXXX")"
cat > "$AGENT_DESKTOP_TEMP" <<AGENT_DESKTOP_EOF
[Desktop Entry]
Type=Application
Name=AI Coding Agents
Comment=Launch an installed AI coding agent
Exec=$REPO_DIR/agent-launcher.sh
Icon=utilities-terminal
Terminal=true
Categories=Development;Utility;
StartupNotify=true
AGENT_DESKTOP_EOF
if [ -f "$AGENT_DESKTOP_FILE" ] && ! cmp -s "$AGENT_DESKTOP_TEMP" "$AGENT_DESKTOP_FILE"; then
    cp -a "$AGENT_DESKTOP_FILE" "${AGENT_DESKTOP_FILE}.backup.$(date -u +%Y%m%dT%H%M%SZ)"
fi
mv -f "$AGENT_DESKTOP_TEMP" "$AGENT_DESKTOP_FILE"
COLLECTOR_SERVICE_TEMP="$(mktemp "${USER_SERVICE_DIR}/.fedora-ai-agents-collector.XXXXXX")"
cat > "$COLLECTOR_SERVICE_TEMP" <<COLLECTOR_SERVICE_EOF
[Unit]
Description=Fedora AI Agents host-side usage and executable snapshot
After=network.target

[Service]
Type=oneshot
TimeoutStartSec=180
WorkingDirectory=$REPO_DIR
Environment="PATH=$PATH:$HOME/.local/bin:$HOME/.opencode/bin:/usr/local/bin:/usr/bin:/bin"
Environment=PYTHONPATH=$REPO_DIR/backend
ExecStart=$REPO_DIR/scripts/refresh_host_snapshot.sh
COLLECTOR_SERVICE_EOF
if [ -f "$COLLECTOR_SERVICE_FILE" ] && ! cmp -s "$COLLECTOR_SERVICE_TEMP" "$COLLECTOR_SERVICE_FILE"; then
    cp -a "$COLLECTOR_SERVICE_FILE" "${COLLECTOR_SERVICE_FILE}.backup.$(date -u +%Y%m%dT%H%M%SZ)"
fi
mv -f "$COLLECTOR_SERVICE_TEMP" "$COLLECTOR_SERVICE_FILE"
COLLECTOR_TIMER_TEMP="$(mktemp "${USER_SERVICE_DIR}/.fedora-ai-agents-collector-timer.XXXXXX")"
cat > "$COLLECTOR_TIMER_TEMP" <<'COLLECTOR_TIMER_EOF'
[Unit]
Description=Periodic Fedora AI Agents host snapshot

[Timer]
OnBootSec=2min
OnUnitActiveSec=15min
Persistent=true
AccuracySec=1min
Unit=fedora-ai-agents-collector.service

[Install]
WantedBy=timers.target
COLLECTOR_TIMER_EOF
if [ -f "$COLLECTOR_TIMER_FILE" ] && ! cmp -s "$COLLECTOR_TIMER_TEMP" "$COLLECTOR_TIMER_FILE"; then
    cp -a "$COLLECTOR_TIMER_FILE" "${COLLECTOR_TIMER_FILE}.backup.$(date -u +%Y%m%dT%H%M%SZ)"
fi
mv -f "$COLLECTOR_TIMER_TEMP" "$COLLECTOR_TIMER_FILE"
chmod 0644 "$DESKTOP_FILE" "$AGENT_DESKTOP_FILE" "$SERVICE_FILE" "$COLLECTOR_SERVICE_FILE" "$COLLECTOR_TIMER_FILE"

systemctl --user daemon-reload || return 1
systemctl --user enable --now fedora-ai-agents-web.service || return 1
systemctl --user enable --now fedora-ai-agents-collector.timer || return 1
systemctl --user start fedora-ai-agents-collector.service || return 1

printf '\n===== VERIFY LOCAL SERVICES =====\n'
API_READY=0
for attempt in $(seq 1 30); do
    if curl --fail --silent --show-error http://127.0.0.1:8000/health; then
        printf '\nAPI health check passed.\n'
        API_READY=1
        break
    fi
    sleep 2
done
if [ "$API_READY" -ne 1 ]; then
    printf 'API health check did not pass after 60 seconds. Inspect: docker compose logs api\n' >&2
    return 1
fi
curl --fail --silent --show-error http://127.0.0.1:8000/api/capabilities | python3 -m json.tool || return 1

printf '\n===== VERIFY LOCAL FRONTEND BEFORE OPENING IT =====\n'
# The desktop launcher must not open a URL just because systemd accepted the
# service. Verify Vite returned the actual app shell before invoking xdg-open.
# xdg-open is supplied by xdg-utils: https://gitlab.freedesktop.org/xdg/xdg-utils
FRONTEND_URL="http://127.0.0.1:5173/"
FRONTEND_HTML="$(mktemp /tmp/fedora-ai-agents-local-page.XXXXXX.html)" || return 1
FRONTEND_READY=0
for attempt in $(seq 1 30); do
    FRONTEND_STATUS="$(curl --location --silent --show-error --connect-timeout 2 --max-time 5 \
        --output "$FRONTEND_HTML" --write-out '%{http_code}' "$FRONTEND_URL")"
    if [ "$FRONTEND_STATUS" = "200" ] && awk 'index($0, "Fedora AI Agents") { found=1 } END { exit(found ? 0 : 1) }' "$FRONTEND_HTML"; then
        printf 'Local frontend verification %s/30: HTTP 200 and expected app identity.\n' "$attempt"
        FRONTEND_READY=1
        break
    fi
    printf 'Local frontend verification %s/30: HTTP %s; waiting for Vite.\n' "$attempt" "${FRONTEND_STATUS:-no-response}"
    sleep 2
done
rm -f -- "$FRONTEND_HTML"
if [ "$FRONTEND_READY" -ne 1 ]; then
    printf 'Local frontend did not become ready. Inspect: systemctl --user status fedora-ai-agents-web.service\n' >&2
    journalctl --user -u fedora-ai-agents-web.service -n 80 --no-pager >&2
    return 1
fi

printf '\nInstalled desktop entry: %s\n' "$DESKTOP_FILE"
printf 'Verified local URL: %s\n' "$FRONTEND_URL"
if [ -z "${DISPLAY:-}" ] && [ -z "${WAYLAND_DISPLAY:-}" ]; then
    printf 'No graphical session detected; open manually: %s\n' "$FRONTEND_URL"
else
    XDG_OPEN_LOG="$(mktemp /tmp/fedora-ai-agents-local-xdg.XXXXXX.log)" || return 1
    if xdg-open "$FRONTEND_URL" > "$XDG_OPEN_LOG" 2>&1; then
        printf 'xdg-open accepted the verified local URL.\n'
        if [ -s "$XDG_OPEN_LOG" ]; then cat "$XDG_OPEN_LOG"; fi
    else
        XDG_STATUS=$?
        printf 'xdg-open failed (exit %s). Output follows.\n' "$XDG_STATUS" >&2
        cat "$XDG_OPEN_LOG" >&2
        rm -f -- "$XDG_OPEN_LOG"
        return 1
    fi
    rm -f -- "$XDG_OPEN_LOG"
fi
printf '\nInstallation completed. Existing OpenCode config and source DB were not modified.\n'
    return 0
}
main "$@"
EOF

write_file 'uninstall-fedora-ai-agents.sh' <<'EOF'
#!/usr/bin/env bash
# Safe user-level removal. Docker volume and database are preserved by default.
set -o pipefail
main() {
REPO_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
SERVICE_FILE="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user/fedora-ai-agents-web.service"
COLLECTOR_SERVICE_FILE="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user/fedora-ai-agents-collector.service"
COLLECTOR_TIMER_FILE="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user/fedora-ai-agents-collector.timer"
DESKTOP_FILE="${XDG_DATA_HOME:-$HOME/.local/share}/applications/fedora-ai-agents.desktop"
AGENT_DESKTOP_FILE="${XDG_DATA_HOME:-$HOME/.local/share}/applications/fedora-ai-agent-launcher.desktop"
printf '\n===== SAFE UNINSTALL =====\n'
systemctl --user disable --now fedora-ai-agents-collector.timer
systemctl --user disable --now fedora-ai-agents-collector.service
systemctl --user disable --now fedora-ai-agents-web.service
STATUS=$?
if [ "$STATUS" -ne 0 ]; then
    printf 'The user service was not active or could not be stopped (status %s). Continuing with file audit.\n' "$STATUS"
fi
for unit_file in "$COLLECTOR_SERVICE_FILE" "$COLLECTOR_TIMER_FILE"; do
    if [ -f "$unit_file" ]; then
        cp -a "$unit_file" "${unit_file}.backup.$(date -u +%Y%m%dT%H%M%SZ)"
        rm -f -- "$unit_file"
    fi
done
if [ -f "$SERVICE_FILE" ]; then
    cp -a "$SERVICE_FILE" "${SERVICE_FILE}.backup.$(date -u +%Y%m%dT%H%M%SZ)"
    rm -f -- "$SERVICE_FILE"
fi
if [ -f "$DESKTOP_FILE" ]; then
    cp -a "$DESKTOP_FILE" "${DESKTOP_FILE}.backup.$(date -u +%Y%m%dT%H%M%SZ)"
    rm -f -- "$DESKTOP_FILE"
fi
if [ -f "$AGENT_DESKTOP_FILE" ]; then
    cp -a "$AGENT_DESKTOP_FILE" "${AGENT_DESKTOP_FILE}.backup.$(date -u +%Y%m%dT%H%M%SZ)"
    rm -f -- "$AGENT_DESKTOP_FILE"
fi
systemctl --user daemon-reload
if command -v docker >/tmp/fedora-ai-agents-command-check.log 2>&1; then
    docker compose -f "$REPO_DIR/docker-compose.yml" down
fi
printf '\nApplication launcher removed. Docker data volume is intentionally preserved.\n'
printf 'To remove the application data permanently, first export/verify a backup, then explicitly run:\n'
printf '  docker volume rm fedora-ai-agents-data\n'
printf 'That destructive data-removal command is not executed by this uninstaller.\n'
    return 0
}
main "$@"
EOF

write_file 'scripts/restore_db.sh' <<'EOF'
#!/usr/bin/env bash
# Restore a verified SQLite backup while the API is stopped; preserve and verify rollback state.
# SQLite WAL and online backup references: https://www.sqlite.org/wal.html and
# https://www.sqlite.org/backup.html
set -o pipefail
wait_for_api() {
    local attempt
    for attempt in $(seq 1 30); do
        if curl --fail --silent --show-error --connect-timeout 3 --max-time 5 http://127.0.0.1:8000/health; then
            printf '\nAPI health check passed.\n'
            return 0
        fi
        sleep 2
    done
    return 1
}
main() {
umask 077
PROJECT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJECT_DIR" || return 1
BACKUP_PATH="${1:-}"
if [ -z "$BACKUP_PATH" ] || [ ! -s "$BACKUP_PATH" ]; then
    printf 'Usage: %s /absolute/path/to/verified-agents-backup.db\n' "$0" >&2
    return 2
fi
BACKUP_PATH="$(cd -- "$(dirname -- "$BACKUP_PATH")" && pwd)/$(basename -- "$BACKUP_PATH")"
if ! command -v docker >/tmp/fedora-ai-agents-command-check.log 2>&1; then
    printf 'Docker CLI is required for restore.\n' >&2
    return 1
fi
docker compose config --quiet || return 1
CONTAINER_ID="$(docker compose ps -q api)"
if [ -z "$CONTAINER_ID" ]; then
    printf 'The API container must be running so a verified pre-restore backup can be created.\n' >&2
    return 1
fi
PRE_RESTORE_DIR="$PROJECT_DIR/backups/pre-restore"
mkdir -p -m 0700 "$PRE_RESTORE_DIR" || return 1
chmod 0700 "$PRE_RESTORE_DIR" || return 1
printf '\n===== CREATE VERIFIED PRE-RESTORE BACKUP =====\n'
BACKUP_OUTPUT="$(bash "$PROJECT_DIR/scripts/backup_db.sh" "$PRE_RESTORE_DIR")" || return 1
printf '%s\n' "$BACKUP_OUTPUT"
PRE_HOST_PATH="$(printf '%s\n' "$BACKUP_OUTPUT" | awk -F': ' '/^Path: / {path=$2} END {print path}')"
if [ -z "$PRE_HOST_PATH" ] || [ ! -s "$PRE_HOST_PATH" ]; then
    printf 'Could not resolve the verified pre-restore backup path. Restore cancelled.\n' >&2
    return 1
fi
printf '\n===== STOP API AND VALIDATE/RESTORE BACKUP =====\n'
printf 'Requested backup: %s\n' "$BACKUP_PATH"
printf 'Host rollback backup: %s\n' "$PRE_HOST_PATH"
docker compose stop api || return 1
RESTORE_OUTPUT="$(cat "$BACKUP_PATH" | docker compose run --rm -T --no-deps api python /app/restore_db.py)"
RESTORE_STATUS=$?
if [ "$RESTORE_STATUS" -ne 0 ]; then
    printf '%s\n' "$RESTORE_OUTPUT" >&2
    printf 'Restore validation failed before commit or automatic rollback completed. Restarting the original API container.\n' >&2
    docker compose start api
    return "$RESTORE_STATUS"
fi
printf '%s\n' "$RESTORE_OUTPUT"
PRE_CONTAINER_PATH="$(printf '%s\n' "$RESTORE_OUTPUT" | awk '/^\{/ {json=$0} END {print json}' | python3 -c 'import json,sys; print(json.load(sys.stdin).get("pre_restore_backup") or "")')"
if [ -z "$PRE_CONTAINER_PATH" ]; then
    printf 'Restore helper did not return its internal rollback path. Starting API; host rollback backup remains available at %s.\n' "$PRE_HOST_PATH" >&2
    docker compose start api
    return 1
fi
printf '\n===== START AND VERIFY RESTORED API =====\n'
docker compose start api || return 1
if wait_for_api; then
    printf 'Restore completed. Pre-restore rollback copy: %s\nHost rollback copy: %s\n' "$PRE_CONTAINER_PATH" "$PRE_HOST_PATH"
    return 0
fi
printf 'Restored database did not pass API health. Attempting automatic rollback from the pre-restore database.\n' >&2
docker compose stop api || return 1
docker compose run --rm --no-deps api python /app/restore_db.py --source-path "$PRE_CONTAINER_PATH"
ROLLBACK_STATUS=$?
if [ "$ROLLBACK_STATUS" -ne 0 ]; then
    printf 'Internal rollback failed; restoring the verified host backup without taking another backup of the failed database.\n' >&2
    cat "$PRE_HOST_PATH" | docker compose run --rm -T --no-deps api python /app/restore_db.py --skip-pre-restore-backup
    ROLLBACK_STATUS=$?
fi
docker compose start api || return 1
if [ "$ROLLBACK_STATUS" -ne 0 ]; then
    printf 'Automatic rollback failed. Verified host rollback backup remains at: %s\n' "$PRE_HOST_PATH" >&2
    return "$ROLLBACK_STATUS"
fi
if wait_for_api; then
    printf 'Original database restored successfully after failed restore health check. Host backup: %s\n' "$PRE_HOST_PATH" >&2
else
    printf 'Rollback file restored, but API health still fails. Inspect docker compose logs api. Host backup: %s\n' "$PRE_HOST_PATH" >&2
fi
return 1
}
main "$@"
EOF
write_file 'scripts/refresh_host_snapshot.sh' <<'EOF'
#!/usr/bin/env bash
# Runs as the logged-in Fedora user. The Docker API never mounts the OpenCode DB.
# OpenCode's official database path command is documented at:
# https://opencode.ai/docs/cli/commands
set -o pipefail
main() {
REPO_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
API_URL="${FEDORA_AI_AGENTS_INGEST_URL:-http://127.0.0.1:8000/api/ingest/host-snapshot}"
TEMP_FILE="$(mktemp "${TMPDIR:-/tmp}/fedora-ai-agents-snapshot.XXXXXX")" || return 1
export PATH="$HOME/.local/bin:$HOME/.opencode/bin:$PATH"
if command -v opencode >/tmp/fedora-ai-agents-command-check.log 2>&1; then
    if OPENCODE_DATABASE="$(opencode debug paths db)"; then
        if [ -f "$OPENCODE_DATABASE" ]; then
            export OPENCODE_DB_PATH="$OPENCODE_DATABASE"
            printf 'OpenCode database resolved by the official CLI path command.\n'
        else
            printf 'OpenCode executable exists, but the resolved database file is absent; using the XDG default for explicit status reporting.\n'
            export OPENCODE_DB_PATH="${OPENCODE_DB_PATH:-${XDG_DATA_HOME:-$HOME/.local/share}/opencode/opencode.db}"
        fi
    else
        printf 'OpenCode debug paths db failed; collector will report database-unavailable unless the XDG default exists.\n' >&2
        export OPENCODE_DB_PATH="${OPENCODE_DB_PATH:-${XDG_DATA_HOME:-$HOME/.local/share}/opencode/opencode.db}"
    fi
fi
printf '\n===== COLLECT HOST AGENTS AND USAGE METADATA =====\n'
PYTHONPATH="$REPO_DIR/backend${PYTHONPATH:+:$PYTHONPATH}" python3 -m collectors.host_snapshot > "$TEMP_FILE" || {
    rm -f -- "$TEMP_FILE"
    return 1
}
printf '\n===== INGEST SANITIZED SNAPSHOT OVER LOOPBACK =====\n'
curl --fail --silent --show-error --connect-timeout 5 --max-time 120 --retry 3 --retry-connrefused --retry-delay 2 \
    -H 'Content-Type: application/json' \
    --data-binary "@$TEMP_FILE" "$API_URL"
CURL_STATUS=$?
rm -f -- "$TEMP_FILE"
if [ "$CURL_STATUS" -ne 0 ]; then
    printf 'Host snapshot was not accepted. Verify the local API: %s\n' "$API_URL" >&2
    return "$CURL_STATUS"
fi
printf '\nHost snapshot submitted successfully. No credentials or message bodies were sent.\n'
return 0
}
main "$@"
EOF

write_file 'scripts/backup_db.sh' <<'EOF'
#!/usr/bin/env bash
# Use SQLite's online backup API; copying agents.db alone can omit committed WAL pages.
# SQLite WAL and backup API references: https://www.sqlite.org/wal.html and
# https://www.sqlite.org/backup.html
set -o pipefail
main() {
umask 077
PROJECT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJECT_DIR" || return 1
BACKUP_DIR="${1:-${PROJECT_DIR}/backups}"
mkdir -p -m 0700 "$BACKUP_DIR" || return 1
chmod 0700 "$BACKUP_DIR" || return 1
BACKUP_NAME="agents-$(date -u '+%Y%m%dT%H%M%S%NZ').db"
BACKUP_PATH="$BACKUP_DIR/$BACKUP_NAME"
CONTAINER_ID="$(docker compose ps -q api)"
if [ -z "$CONTAINER_ID" ]; then
    printf 'API container is not running; start it before backup.\n' >&2
    return 1
fi
docker compose exec -T api python - "$BACKUP_NAME" <<'PY'
import sqlite3, sqlite_vec, sys
name = sys.argv[1]
source = sqlite3.connect('/data/agents.db', timeout=8)
target = sqlite3.connect('/tmp/' + name)
try:
    for connection in (source, target):
        connection.enable_load_extension(True)
        try:
            sqlite_vec.load(connection)
        finally:
            connection.enable_load_extension(False)
    source.backup(target)
    result = target.execute('PRAGMA integrity_check').fetchone()[0]
    if result != 'ok':
        raise SystemExit(f'Backup integrity failure: {result}')
    target.execute('SELECT count(*) FROM documents_fts').fetchone()
    target.execute('SELECT count(*) FROM documents_vec').fetchone()
    print(f'Container backup verified with FTS5 and sqlite-vec: {name}')
finally:
    target.close()
    source.close()
PY
if [ "$?" -ne 0 ]; then return 1; fi
docker cp "${CONTAINER_ID}:/tmp/${BACKUP_NAME}" "$BACKUP_PATH" || return 1
chmod 0600 "$BACKUP_PATH" || return 1
if [ ! -s "$BACKUP_PATH" ]; then
    printf 'Backup copy is missing or empty: %s\n' "$BACKUP_PATH" >&2
    return 1
fi
BACKUP_HASH="$(sha256sum "$BACKUP_PATH" | awk '{print $1}')" || return 1
printf 'Backup copied. SHA-256: %s\nPath: %s\n' "$BACKUP_HASH" "$BACKUP_PATH"
    return 0
}
main "$@"
EOF

write_file 'scripts/validate.sh' <<'EOF'
#!/usr/bin/env bash
# Offline/static validation. Docker integration tests are a separate explicit phase.
set -o pipefail
main() {
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || return 1
printf '\n===== SHELL SYNTAX =====\n'
for script in build-fedora-ai-agents-explainer.sh install-fedora-ai-agents.sh uninstall-fedora-ai-agents.sh scripts/*.sh; do
    bash -n "$script" || return 1
    printf 'PASS %s\n' "$script"
done
printf '\n===== PYTHON BYTECODE VALIDATION =====\n'
python3 -m compileall -q backend || return 1
printf 'PASS Python compilation\n'
if [ -x .venv/bin/python ]; then
    PYTHONPATH=backend .venv/bin/python -m pytest -q backend/tests || return 1
else
    printf 'Python test dependencies are not installed; run the root build script first.\n'
fi
printf '\n===== FRONTEND PRODUCTION BUILD =====\n'
npm run build || return 1
printf '\n===== COMPOSE CONFIGURATION =====\n'
docker compose config --quiet || return 1
printf 'PASS Docker Compose configuration\n'
printf '\nValidation completed. Runtime integration tests require Docker.\n'
    return 0
}
main "$@"
EOF

write_file '.github/workflows/deploy.yml' <<'EOF'
# GitHub Pages workflow artifact/deploy pattern and required permissions:
# https://docs.github.com/en/pages/getting-started-with-github-pages/using-custom-workflows-with-github-pages
# Pinned major action contracts: https://github.com/actions/upload-pages-artifact and
# https://github.com/actions/deploy-pages
name: Deploy Fedora AI Agents explainer to GitHub Pages

on:
  push:
    branches: [main]
  workflow_dispatch:

permissions:
  contents: read
  pages: write
  id-token: write

concurrency:
  group: github-pages
  cancel-in-progress: true

jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - name: Check out source
        uses: actions/checkout@v4
      - name: Set up Node.js
        uses: actions/setup-node@v4
        with:
          node-version: 22
          cache: npm
      - name: Install dependencies
        run: npm ci
      - name: Build static site
        run: npm run build
      - name: Upload Pages artifact
        uses: actions/upload-pages-artifact@v4
        with:
          path: dist
  deploy:
    environment:
      name: github-pages
      url: ${{ steps.deployment.outputs.page_url }}
    runs-on: ubuntu-latest
    needs: build
    steps:
      - name: Deploy to GitHub Pages
        id: deployment
        uses: actions/deploy-pages@v4
EOF

write_file 'AUDIT.txt' <<'EOF'
CONVERSATION AND SOURCE AUDIT
=============================

PURPOSE
-------
This audit records the architectural corrections required before building the
Fedora-native Omarchy-inspired AI agents explainer.

CORRECTIONS TO THE EARLIER CHAT
-------------------------------
1. OpenCode is a first-class Omarchy agent. The current Omarchy manual lists
   its launcher, and the current Agents collector README documents OpenCode Go
   limits plus local usage from both the legacy message and V2 session_message
   stores. It also documents message-ID deduplication and exclusion of inherited
   fork history. The earlier answer's claim that OpenCode collection was not
   supported was inaccurate/outdated; the current manual and collector contract
   are the authoritative references.

2. The current official OpenCode CLI documentation explicitly documents
   `opencode stats --json`, `opencode auth list --format json`, and
   `opencode debug paths db`. The native CLI aggregate is an independent
   cross-check; this project's collector reads message/session tables directly
   because it needs per-message timestamps and a V2 cumulative-counter fallback.
   The V2 schema stores per-message model/cost/token/time metadata in assistant
   session_message.data and cumulative counters in session_v2. This project
   projects only metadata paths for per-message events and uses session
   aggregates only when message-level usage is absent. Fallback snapshots are
   converted into idempotent observation-time deltas.

3. Launching an agent, collecting local token usage, and querying provider
   subscription quotas are distinct capabilities. An installed executable
   does not prove authentication, provider quota access, or account identity.
   This implementation reports those states separately and does not infer a
   provider's subscription balance from local token counts.

4. GitHub Pages is static hosting. It cannot run Docker Compose, FastAPI, or a
   persistent SQLite database. The public site is the explainer/installer page;
   the local Vite UI proxies to a FastAPI service bound to host loopback.

5. A browser page served from HTTPS GitHub Pages cannot safely assume it may
   probe a local HTTP backend. Static mode does not make that mixed-content
   request. Full capability discovery occurs on the localhost instance.

6. SQLite WAL improves same-host reader/writer concurrency. It is not a
   multi-host network database. The active application database is a local
   Docker named volume and is never shared across hosts over NFS/SMB.

7. Copying only the main SQLite database file while WAL is active is not a
   reliable backup. The backup utility uses SQLite's online backup API and
   verifies the resulting database with PRAGMA integrity_check.

8. OpenCode stores provider credentials in its own SQLite database. The local
   collector must never select authentication tables, credential tokens, API keys,
   or OAuth credentials. It runs as the logged-in user, opens the source database
   read-only, and sends only normalized usage metadata over loopback. Docker never
   mounts the source database.

PUBLISHER AND INSTALLER DEFECTS FOUND AND CORRECTED IN THIS REVISION
---------------------------------------------------------------------
1. The first publisher enabled GitHub Pages AFTER pushing the workflow commit.
   That ordering could let the push-triggered deploy race Pages site creation.
   The revised builder configures Pages first, then pushes.
2. The first publisher polled `gh run list`, not the GitHub REST API, and did not
   tie the observed run to the exact commit/workflow path. The revised publisher
   polls `GET /repos/{owner}/{repo}/actions/runs?head_sha=...` through `gh api`,
   selects deploy.yml for the exact commit, and requires conclusion=success.
3. The first publisher accepted one HTTP 200 from the Pages URL and opened it
   without validating the returned site identity or built assets. The revised
   publisher checks the Pages REST representation, retries HTTP propagation,
   validates the expected HTML identity, fetches each Vite JS/CSS asset, then
   invokes xdg-open and checks its exit status.
4. The first Git staging allowlist omitted the root agent-launcher.sh and
   install-opencode.sh files. Both root files are now explicitly staged.
5. The first systemd dashboard unit depended on the interactive shell's Node
   PATH. systemd does not source shell startup files; the revised unit records
   absolute npm/Node locations and extends PATH for child scripts.
6. The first local installer checked the API but could open Vite before the
   frontend had answered. The revised installer waits for HTTP 200 and the app
   identity before calling xdg-open.
7. A non-empty remote main branch can be unrelated to a fresh local git init.
   The revised publisher only allows provable fast-forward history and refuses
   unrelated/divergent histories rather than force-pushing over existing work.
8. Updating an existing GitHub Pages site can return HTTP 204 with no JSON body.
   The revised publisher always performs a separate Pages GET after create/update
   and parses only that read-back representation.

USER-PROJECT PATTERNS REVIEWED
------------------------------
- pulumi-homelab-explainer README and setup-pulumi-explainer.sh: dual-plane
  static GitHub Pages plus local Docker/FastAPI/SQLite WAL/sqlite-vec/FTS5,
  one-shot heredoc generation, GitHub CLI publication and xdg-open.
- receipts-ocr README: backend health/readiness detection, CI/test gates and
  explicit fallback/status behavior. OCR engines and OCR data models are not
  reused.
- receipts-ocr-rag, receipts-ocr-rag-v2 and proxmox-orchestrator were supplied
  as additional architectural references; no OCR or Proxmox-specific code is
  copied into this agent dashboard.

CURRENT OMARCHY ARCHITECTURE USED AS REFERENCE
----------------------------------------------
- The panel is a display layer over independent usage collectors.
- Collectors emit a stable JSON record contract.
- Adding a collector does not require QML changes.
- OpenCode V1 and V2 assistant rows are projected to per-message usage metadata.
  V2 session_v2 (or newer session) cumulative counters are a fallback for
  sessions without per-message usage and are converted to deltas by the backend.
- Legacy V1 copied pre-fork history is filtered using session creation times.
- Session aggregate metadata and provider quota data are distinct from the UI;
  this Fedora implementation does not claim all Omarchy quota collectors.

FEDORA IMPLEMENTATION SCOPE
---------------------------
This repository implements:
- A standalone OpenCode collector module that emits a versioned JSON record contract.
- React/Vite static explainer with Three.js architecture topology and D3 usage chart.
- A Fedora Xfce-compatible desktop dashboard entry, fixed-allowlist agent menu,
  and systemd user timer for host-side snapshots.
- FastAPI local API and SQLite schema migrations.
- SQLite 3.54.1 built from the official upstream source archive with SHA-256
  verification, WAL, foreign keys, busy timeout, FTS5, sqlite-vec, and online backup.
- OpenCode legacy/V2 usage metadata projection through a host-side read-only collector; the source DB is never mounted into Docker.
- Optional local Ollama embeddings; no semantic vectors are fabricated when the
  embedding model is unavailable.
- Agent executable detection for OpenCode, Claude Code, Codex, Gemini CLI, Pi,
  and GitHub Copilot CLI. Detection is not a claim of usage-collector support.

NOT IMPLEMENTED OR NOT CLAIMED
------------------------------
- Provider-specific subscription quota APIs and account switching for every
  Omarchy collector.
- Full OpenCode Go, Z.ai, Ollama Cloud, MiniMax, OpenRouter, DeepSeek, Synthetic,
  or other provider quota/balance endpoints.
- Usage collectors for Claude, Codex, Gemini, Pi, or Copilot; those are detected
  for launch only in this first implementation.
- Multi-device aggregation and account-level deduplication across machines.
- A production authentication layer for a remotely exposed API. The API is
  deliberately loopback-only.

VALIDATION BOUNDARIES
---------------------
The one-shot builder runs shell syntax, Python compilation, npm production build,
Python tests, and Docker Compose validation when the relevant dependencies and
network are available. A source-only run with SKIP_DEPENDENCY_INSTALL=1 is not a
full build and must not be represented as one. The actual Fedora host must run
the builder with dependencies enabled before GitHub publication.

SOURCES
-------
User project pattern references (architecture only; no OCR code copied):
https://github.com/swipswaps/pulumi-homelab-explainer
https://github.com/swipswaps/pulumi-homelab-explainer/blob/main/setup-pulumi-explainer.sh
https://github.com/swipswaps/receipts-ocr
https://github.com/swipswaps/receipts-ocr-rag
https://github.com/swipswaps/receipts-ocr-rag-v2
https://github.com/swipswaps/proxmox-orchestrator

Omarchy current Agents README:
https://github.com/omacom/omarchy/blob/quattro/shell/plugins/agents/README.md

Omarchy collector contract:
https://github.com/omacom/omarchy/blob/quattro/docs/agent-usage-collectors.md

Omarchy shared OpenCode reader:
https://github.com/omacom/omarchy/blob/quattro/shell/plugins/agents/collectors.py

OpenCode official CLI and installation documentation:
https://opencode.ai/docs/

OpenCode CLI commands (stats --json and debug paths db):
https://opencode.ai/docs/cli/commands

OpenCode official provider authentication/database documentation:
https://opencode.ai/docs/cli/providers

SQLite 3.54.1 release:
https://sqlite.org/releaselog/3_54_1.html

Buildroot's reviewed upstream source archive SHA-256 update:
https://lists.busybox.net/pipermail/buildroot/2026-October/813774.html

SQLite WAL:
https://www.sqlite.org/wal.html

SQLite online backup API:
https://www.sqlite.org/backup.html

Python sqlite3 API:
https://docs.python.org/3/library/sqlite3.html

SQLite FTS5:
https://www.sqlite.org/fts5.html

sqlite-vec:
https://github.com/asg017/sqlite-vec

sqlite-vec Python binding:
https://alexgarcia.xyz/sqlite-vec/python.html

GitHub Pages workflow publishing and permissions:
https://docs.github.com/en/pages/getting-started-with-github-pages/using-custom-workflows-with-github-pages

GitHub Pages publishing source API:
https://docs.github.com/en/pages/getting-started-with-github-pages/configuring-a-publishing-source-for-your-github-pages-site

GitHub Actions workflow runs REST API:
https://docs.github.com/en/rest/actions/workflow-runs

GitHub Pages REST API:
https://docs.github.com/en/rest/pages

GitHub CLI authenticated API requests:
https://cli.github.com/manual/gh_api

Vite static deployment and project base paths:
https://vite.dev/guide/static-deploy

systemd execution environment and PATH:
https://www.freedesktop.org/software/systemd/man/latest/systemd.exec.html

xdg-utils project (xdg-open):
https://gitlab.freedesktop.org/xdg/xdg-utils
EOF

write_file 'README.txt' <<'EOF'
FEDORA AI AGENTS EXPLAINER
==========================

PROJECT PURPOSE
---------------
See AUDIT.txt for the conversation audit, source corrections, implementation scope, and explicit non-claims.
This repository contains an Omarchy-inspired, Fedora-native AI coding-agent
explainer and a local reference implementation. The public GitHub Pages site is
static. The local data plane is a separate FastAPI service running in Docker
Compose and backed by SQLite.

The project intentionally separates three capabilities:

1. Agent discovery and launching. An executable being present does not prove
   that the agent is authenticated or that its subscription usage is measurable.
2. Usage collection. Collectors are independent adapters that normalize local
   usage metadata into a stable usage-event contract.
3. Visualization and query. The React interface displays backend capabilities,
   token summaries, and local knowledge retrieval. It does not own agent secrets.

PUBLIC SITE
-----------
https://swipswaps.github.io/fedora-ai-agents-explainer/

SOURCE
------
https://github.com/swipswaps/fedora-ai-agents-explainer

ONE-SHOT BUILD AND PUBLISH
--------------------------
From the directory containing build-fedora-ai-agents-explainer.sh, run:

  bash build-fedora-ai-agents-explainer.sh

The builder preflights Node.js, npm, Python, Docker/Compose, Git, GitHub CLI
authentication and xdg-open. It writes every repository file through idempotent
heredoc writers, backs up replaced files, verifies generated-file SHA-256 values,
installs npm and Python dependencies, runs the Vite build and pytest suite,
validates/builds the Docker image, creates or reuses the public GitHub repository,
pushes main, configures GitHub Pages Actions deployment before the triggering
push, polls the GitHub REST API for a successful workflow run on the exact commit,
checks the Pages REST representation, verifies the deployed HTML and every Vite
JavaScript/CSS asset over HTTPS, and only then opens the site with xdg-open.

For source-generation inspection only (not a full build or publication):

  SKIP_DEPENDENCY_INSTALL=1 SKIP_PUBLISH=1 bash build-fedora-ai-agents-explainer.sh

A source-only run must not be described as a validated production build.

LOCAL DEVELOPMENT
-----------------
Requirements:
- Fedora 43 is the primary documented target.
- Xfce X11 is supported; no Wayland, GNOME, or Hyprland dependency is required.
- Node.js 20.19+ or 22.12+ and npm.
- Python 3.11 or newer for local tests and utilities.
- Docker Engine and Docker Compose v2 plugin.
- Git and curl.

From the repository directory, first install dependencies (this creates the lockfile on a fresh source archive):

  npm install --no-audit --no-fund

Then start the local backend and UI:

  docker compose up --build -d
  npm ci
  npm run dev

Open http://127.0.0.1:5173/ . The API is published only on
http://127.0.0.1:8000 and is not exposed to the LAN.

INSTALLER
---------
Run:

  bash install-fedora-ai-agents.sh

The installer checks prerequisites, starts the local Docker backend, creates a
user-level systemd service for the Vite development server, creates a 15-minute
systemd user timer for host agent detection and OpenCode usage collection, creates
Xfce-compatible dashboard and agent-launcher entries, validates the API, and
opens the local site.

The separate install-opencode.sh helper uses the current official OpenCode V2 installer and verifies opencode --version; it is opt-in and is not run by the dashboard installer. It is install-if-absent and deliberately leaves any existing V1 or V2 executable untouched. OpenCode V1 and V2 share the default opencode command and are not installed side by side by default. To upgrade an existing V1 installation, back up its configuration and follow https://opencode.ai/docs/migrate-v1/ explicitly. Inspect configured providers with opencode auth list; authenticate a provider with opencode auth login PROVIDER_ID (for example, anthropic). The official CLI also exposes opencode stats --json for native usage summaries. Omarchy's broader agent collectors provide additional provider-aware usage and quota integrations; this project deliberately implements a narrower local OpenCode usage projection and does not claim provider subscription quotas. The installer creates two desktop entries: the local dashboard and a coding-agent menu. The menu detects installed OpenCode, Claude Code, Codex, Gemini CLI, Pi, and Copilot executables; it launches only detected commands from a fixed allowlist. It does not install or authenticate those agents.

The installer does not overwrite ~/.config/opencode, edit OpenCode auth data,
modify the OpenCode SQLite database, or remove Docker volumes. The source
OpenCode data stays on the Fedora host. The collector runs as the logged-in user and sends only normalized usage metadata to the loopback API; no OpenCode directory is mounted into Docker.

OPENCODE USAGE COLLECTION
-------------------------
The standalone host adapter detects the actual OpenCode database schema rather
than inferring it from a CLI version. V1 message rows and V2 assistant
session_message.data rows are projected to per-message usage metadata using
SQLite JSON1. Only provider/model, time, token and cost paths are returned;
message content and tool output are not selected as result columns. V2
session_v2 (or newer session) cumulative counters are retained as a fallback
for sessions whose assistant rows do not expose usage counters. The API stores
those cumulative snapshots and computes positive deltas against the preceding
snapshot, avoiding repeated totals. The first fallback collection is a baseline:
it attributes existing session counters to the first observation time, not to
historical message dates. Later fallback deltas are timestamped at the 15-minute
observation time. If a cumulative counter decreases, the API records a reset
flag and treats the new counter value as a fresh positive delta; it never emits
negative token/cost usage. Per-message V2 model/provider attribution comes from each
assistant row; fallback attribution is session-level.

V1 and V2 assistant messages are filtered against their session creation
timestamp to avoid counting inherited pre-fork history. Message IDs are
idempotently deduplicated across the legacy and V2 stores. V2 assistant message
rows are projected without returning content arrays or tool output; session
aggregates are fallback metadata only. The source database is opened read-only by the logged-in
Fedora user. SQLite may read existing WAL/SHM sidecars as part of a read-only
WAL snapshot; the collector issues no writes or checkpoints and does not alter
the database's logical contents. The Docker container never mounts that database.

The host message scan is capped at 1,000,000 rows and normalized usage events at
100,000; schema mismatches fail explicitly rather than returning a partial result.

The dashboard displays reported input+output counters, with reasoning and cache
counters shown separately. Provider counter definitions can overlap, so the
application does not fabricate one billable-token total. Cost is OpenCode-reported;
zero cost does not establish that a provider supplied service for free. The
collector provides local usage accounting, not provider quota or subscription-
limit discovery. Provider-specific rate limits require separate, verified APIs.

DATABASE AND SEARCH
-------------------
The local database enables:
- SQLite Write-Ahead Logging (WAL), foreign keys and busy timeout.
- Explicit schema_migrations table.
- Usage event ledger with indexed time and agent/model fields.
- FTS5 full-text indexing for local knowledge documents.
- sqlite-vec vector index using 768-dimensional float vectors by default. sqlite-vec remains pre-1.0, so pinning and integration tests are important.
- Optional local embeddings from Ollama using nomic-embed-text.
- Hybrid lexical/vector result ranking when embeddings are available.
- SQLite online backup API and integrity checks.

Vector search is genuinely enabled by sqlite-vec. Semantic embeddings are not
fabricated: the backend requests them from a local Ollama server if reachable,
or accepts a caller-supplied vector of the configured dimension. Without an
embedding, the endpoint truthfully reports lexical-only search. To enable local
embedding generation, install Ollama, pull the model, and make its API reachable
from Docker:

  ollama pull nomic-embed-text

Then index a document (the API requests the embedding locally):

  curl -X POST http://127.0.0.1:8000/api/documents \
    -H 'Content-Type: application/json' \
    -d '{"title":"Local architecture note","body":"Agent collectors emit normalized usage events."}'

Without a reachable embedding model, the document is still indexed in FTS5 and
its response reports indexed_vector=false; no synthetic embedding is generated.

The default Compose URL is http://host.docker.internal:11434. On Fedora Docker
configurations where this host alias is unavailable, adjust the Compose host
mapping and verify /api/capabilities before relying on embeddings.

WAL is a same-host concurrency mechanism. Do not place the active SQLite database
on NFS/SMB or share the WAL database among different machines. Backups use the
SQLite online backup API; copying only the main database file while WAL is active
is not a reliable backup procedure.

GITHUB PAGES AND LOCAL BACKEND
------------------------------
GitHub Pages is static hosting. It cannot run Docker, FastAPI, or a persistent
SQLite database. The deployed HTTPS page does not attempt to probe an arbitrary
HTTP loopback endpoint because browser mixed-content restrictions prevent that
from being a reliable architecture.

For full runtime functionality, open the local instance at
http://127.0.0.1:5173/. The Vite development server proxies /api to the local
FastAPI service. The static Pages version remains an explainer and installer
landing page.

VALIDATION
----------
On a fresh source archive, create the dependency lock first:

  npm install --no-audit --no-fund

Then run repeatable validation:

  npm ci
  npm run build
  bash scripts/validate.sh
  python3 -m pip install -r requirements.txt
  PYTHONPATH=backend pytest -q backend/tests
  docker compose config --quiet

A full integration check additionally requires Docker to be running:

  docker compose up --build -d
  curl --fail http://127.0.0.1:8000/health
  curl --fail http://127.0.0.1:8000/api/capabilities

BACKUP AND RESTORE
------------------

Create a verified backup:

  bash scripts/backup_db.sh

Restore a previously verified backup:

  bash scripts/restore_db.sh /absolute/path/to/agents-backup.db

Backup uses SQLite's online backup API from inside the container, verifies
integrity, FTS5 and sqlite-vec, and copies the private backup to the host.
Restore creates a verified pre-restore backup, validates the incoming database,
stops the API, streams the file into a one-shot helper container, and atomically
replaces the database. It restarts and health-checks the API. If health fails,
it automatically restores the pre-restore database; a second host-side rollback
backup remains available. The supplied source backup is never modified.

SAFE UNINSTALL
--------------

  bash uninstall-fedora-ai-agents.sh

This stops/removes the user-level service and desktop entry. It deliberately
preserves the Docker volume. To destroy the database, first create and verify a
backup, then explicitly remove the named volume:

  docker volume rm fedora-ai-agents-data

Do not run that command unless permanent data deletion is intended.

BUILD AND PUBLISH
-----------------
The root build-fedora-ai-agents-explainer.sh is the one-shot, idempotent
heredoc-based repository generator. It performs preflight checks, writes files
atomically, backs up changed existing files outside the repository, validates
the frontend/backend/shell configuration, then uses GitHub CLI authentication
to create or update the public repository, push main, wait for the Pages
workflow, verify the deployed URL, and open it with xdg-open.

By default, the builder writes into the directory containing the builder itself;
there is no implicit ~/Documents project directory. Set PROJECT_DIR explicitly
only when you intentionally want a different target. Set SKIP_PUBLISH=1 only
when intentionally performing a local build without GitHub publication.
The script refuses to overwrite a dirty Git working tree or a repository whose
origin does not match the approved repository.

SECURITY BOUNDARIES
-------------------
- The API binds to 127.0.0.1 on the host.
- No provider secrets are copied into the frontend or database.
- The OpenCode source database is opened mode=ro/query_only on the host and is
  never mounted into Docker. SQLite may read normal WAL/SHM sidecars; no SQL
  writes or checkpoints are issued.
- The collector is usage-metadata-only and fails closed on schema errors.
- The uninstaller preserves persistent data.
- No Docker privileged mode, host PID namespace, or host root filesystem mount
  is required.

REFERENCES
----------
Omarchy AI manual:
https://omarchy.org/manual/ai/

Omarchy Agents plugin implementation:
https://github.com/omacom/omarchy/blob/quattro/shell/plugins/agents/README.md

OpenCode provider authentication:
https://opencode.ai/docs/cli/providers

OpenCode CLI commands (stats --json, auth list --format json, debug paths db):
https://opencode.ai/docs/cli/commands

OpenCode generated V2 SQLite schema:
https://github.com/anomalyco/opencode/blob/dev/packages/core/src/database/schema.gen.ts

OpenCode V2 per-message data guide (community implementation reference):
https://github.com/MaxAnderson95/my-opencode-setup/blob/main/skills/opencode-db-querying/SKILL.md

OpenCode upstream cost-reporting issue:
https://github.com/anomalyco/opencode/issues/60624

Current Omarchy OpenCode collector implementation:
https://github.com/omacom/omarchy/blob/quattro/shell/plugins/agents/collectors.py

SQLite 3.54.1 release:
https://sqlite.org/releaselog/3_54_1.html

SQLite official source archive and checksums:
https://sqlite.org/download.html

Buildroot SQLite 3.54.1 SHA-256 package-maintainer record:
https://lists.busybox.net/pipermail/buildroot/2026-October/813774.html

SQLite Write-Ahead Logging:
https://www.sqlite.org/wal.html

SQLite FTS5:
https://www.sqlite.org/fts5.html

SQLite online backup API:
https://www.sqlite.org/backup.html

SQLite 3.54.1 release:
https://sqlite.org/releaselog/3_54_1.html

sqlite-vec source and API:
https://github.com/asg017/sqlite-vec

Docker Compose startup ordering and health checks:
https://docs.docker.com/compose/how-tos/startup-order/

Vite GitHub Pages deployment:
https://vite.dev/guide/static-deploy

Python sqlite3:
https://docs.python.org/3/library/sqlite3.html

FastAPI:
https://fastapi.tiangolo.com/

React:
https://react.dev/

Three.js:
https://threejs.org/docs/

D3.js:
https://d3js.org/

GitHub Pages:
https://docs.github.com/en/pages/getting-started-with-github-pages/creating-a-github-pages-site

systemd timer units:
https://www.freedesktop.org/software/systemd/man/latest/systemd.timer.html

systemd service units:
https://www.freedesktop.org/software/systemd/man/latest/systemd.service.html

Kleppmann, Martin. Designing Data-Intensive Applications. O'Reilly, 2017.
ISBN 9781491903063 (first edition); ISBN 9781098119058 (second edition).
https://www.oreilly.com/library/view/designing-data-intensive-applications/9781491903063/

LIMITATIONS AND HONEST STATUS
-----------------------------
The OpenCode collector is implemented against the documented SQLite message
layout and must be tested against the actual installed OpenCode version before
being treated as production-compatible. The other listed agents are discovered
by executable name only; their usage collectors and provider quota APIs are not
claimed to be implemented. The frontend and database architecture are local-
first; GitHub Pages does not provide the runtime backend.
EOF

write_file 'quickstart.sh' <<'EOF'
#!/usr/bin/env bash
# Copyable quick-start commands for an already cloned repository.
set -o pipefail
main() {
cd "$(dirname -- "${BASH_SOURCE[0]}")" || return 1
docker compose up --build -d || return 1
npm install --no-audit --no-fund || return 1
npm run dev
    return 0
}
main "$@"
EOF

write_file 'public/.nojekyll' <<'EOF'

EOF

write_file '.gitignore' <<'EOF'
node_modules/
dist/
.venv/
__pycache__/
.pytest_cache/
.env
backups/
*.db
*.db-shm
*.db-wal
EOF

write_file 'LICENSE' <<'EOF'
MIT License

Copyright (c) 2026 swipswaps

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT.
EOF

# Publish static-download copies under public/. Vite only serves public assets.
sync_generated_file() {
    local source="$1" relative="$2" destination
    local parent temporary
    destination="${PROJECT_DIR}/${relative}"
    parent="$(dirname "$destination")"
    mkdir -p "$parent" || return 1
    temporary="$(mktemp "${parent}/.fedora-ai-agents.XXXXXX")" || return 1
    cp -a -- "$source" "$temporary" || return 1
    if [ -f "$destination" ] && cmp -s "$temporary" "$destination"; then
        rm -f -- "$temporary"
        printf 'UNCHANGED  %s\n' "$relative"
        return 0
    fi
    if [ -e "$destination" ]; then
        local backup_path="${BACKUP_ROOT}/${relative}"
        mkdir -p "$(dirname "$backup_path")" || return 1
        cp -a -- "$destination" "$backup_path" || return 1
        printf 'BACKUP     %s -> %s\n' "$relative" "$backup_path"
    fi
    chmod 0644 "$temporary" || return 1
    expected_hash="$(sha256sum "$temporary" | awk '{print $1}')" || return 1
    mv -f -- "$temporary" "$destination" || return 1
    actual_hash="$(sha256sum "$destination" | awk '{print $1}')" || return 1
    if [ "$expected_hash" != "$actual_hash" ]; then
        fail "Read-back SHA-256 verification failed for ${relative}."
        return 1
    fi
    printf 'WRITE      %s\n' "$relative"
}
mkdir -p "${PROJECT_DIR}/public"
sync_generated_file "${PROJECT_DIR}/install-fedora-ai-agents.sh" 'public/install-fedora-ai-agents.sh' || return 1
sync_generated_file "${PROJECT_DIR}/uninstall-fedora-ai-agents.sh" 'public/uninstall-fedora-ai-agents.sh' || return 1
sync_generated_file "${PROJECT_DIR}/quickstart.sh" 'public/quickstart.sh' || return 1
sync_generated_file "${PROJECT_DIR}/install-opencode.sh" 'public/install-opencode.sh' || return 1

# Copy this generator into the project so the repository contains its own reproducible builder.
if [ "${BASH_SOURCE[0]}" != "${PROJECT_DIR}/build-fedora-ai-agents-explainer.sh" ]; then
    sync_generated_file "${BASH_SOURCE[0]}" 'build-fedora-ai-agents-explainer.sh' || return 1
fi
sync_generated_file "$PROJECT_DIR/build-fedora-ai-agents-explainer.sh" 'public/build-fedora-ai-agents-explainer.sh' || return 1
chmod 0755 "$PROJECT_DIR/build-fedora-ai-agents-explainer.sh" "$PROJECT_DIR/install-fedora-ai-agents.sh" "$PROJECT_DIR/agent-launcher.sh" \
    "$PROJECT_DIR/uninstall-fedora-ai-agents.sh" "$PROJECT_DIR/quickstart.sh" "$PROJECT_DIR/install-opencode.sh" \
    "$PROJECT_DIR/scripts/backup_db.sh" "$PROJECT_DIR/scripts/restore_db.sh" "$PROJECT_DIR/scripts/validate.sh" "$PROJECT_DIR/scripts/refresh_host_snapshot.sh" "$PROJECT_DIR/backend/restore_db.py"

printf '\n===== READ-BACK FILE INVENTORY =====\n'
for required in README.txt AUDIT.txt package.json vite.config.js index.html src/main.jsx src/App.jsx src/architecture.js src/UsageChart.jsx backend/main.py backend/restore_db.py backend/collectors/opencode.py backend/Dockerfile backend/requirements.txt docker-compose.yml requirements.txt install-fedora-ai-agents.sh install-opencode.sh agent-launcher.sh scripts/backup_db.sh scripts/restore_db.sh scripts/validate.sh scripts/refresh_host_snapshot.sh backend/collectors/host_snapshot.py public/build-fedora-ai-agents-explainer.sh .github/workflows/deploy.yml; do
    if [ ! -s "$PROJECT_DIR/$required" ]; then
        fail "Required generated file is missing or empty: $required"
        return 1
    fi
    printf 'VERIFIED   %s\n' "$required"
done
printf '\n===== LOCAL VALIDATION =====\n'
cd "$PROJECT_DIR" || return 1
bash -n build-fedora-ai-agents-explainer.sh install-fedora-ai-agents.sh uninstall-fedora-ai-agents.sh scripts/*.sh quickstart.sh || return 1
python3 -m compileall -q backend || return 1
python3 -m json.tool package.json >/tmp/fedora-ai-agents-command-check.log || return 1

if [ "$SKIP_DEPENDENCY_INSTALL" != "1" ]; then
    printf '\n===== NPM INSTALL (GENERATE/UPDATE LOCKFILE) =====\n'
    npm install --no-audit --no-fund || return 1
    printf '\n===== VITE PRODUCTION BUILD =====\n'
    npm run build || return 1
    printf '\n===== PYTHON ENVIRONMENT AND BACKEND TESTS =====\n'
    python3 -m venv .venv || return 1
    . .venv/bin/activate
    python -m pip install --upgrade pip || return 1
    python -m pip install -r requirements.txt || return 1
    PYTHONPATH=backend python -m pytest -q backend/tests || return 1
    deactivate
    if command -v docker >/tmp/fedora-ai-agents-command-check.log 2>&1; then
        docker compose config --quiet || return 1
        docker compose build api || return 1
    else
        printf 'Docker is unavailable in this build environment; Compose validation deferred to Fedora installer.\n'
    fi
else
    printf 'SKIP_DEPENDENCY_INSTALL=1; npm/pip builds and runtime tests not run.\n'
    if [ "$SKIP_PUBLISH" != "1" ]; then
        fail 'Refusing to publish after skipping dependency/build validation.'
        return 1
    fi
fi

printf '\n===== GIT PREFLIGHT =====\n'
if [ "$SKIP_PUBLISH" != "1" ] && [ ! -s "$PROJECT_DIR/package-lock.json" ]; then
    fail 'package-lock.json is missing; refusing to publish a Pages workflow that uses npm ci.'
    return 1
fi
if [ "$SKIP_PUBLISH" = "1" ]; then
    printf 'SKIP_PUBLISH=1; GitHub publication intentionally skipped.\n'
else
    if ! command -v gh >/tmp/fedora-ai-agents-command-check.log; then
        fail 'GitHub CLI (gh) is required for automatic publication.'
        return 1
    fi
    gh auth status || { fail 'GitHub CLI is not authenticated. No push was attempted.'; return 1; }
    if [ ! -d .git ]; then
        git init -b main || return 1
    fi
    CURRENT_BRANCH="$(git branch --show-current)"
    if [ "$CURRENT_BRANCH" != "main" ]; then
        git branch -M main || return 1
    fi
    ORIGIN=""
    if git remote | awk '$0 == "origin" { found=1 } END { exit(found ? 0 : 1) }'; then ORIGIN="$(git remote get-url origin)"; fi
    if [ -n "$ORIGIN" ] && [ "$ORIGIN" != "$REPO_URL" ] && [ "$ORIGIN" != "https://github.com/${PROJECT_SLUG}" ]; then
        fail "Refusing to push to unexpected origin: $ORIGIN"
        return 1
    fi
    if [ -z "$ORIGIN" ]; then
        if gh repo view "$PROJECT_SLUG" >/tmp/fedora-ai-agents-command-check.log 2>&1; then
            git remote add origin "$REPO_URL" || return 1
        else
            gh repo create "$PROJECT_SLUG" --public --source="$PROJECT_DIR" --remote=origin || return 1
        fi
    fi
    gh repo edit --accept-visibility-change-consequences "$PROJECT_SLUG" --visibility public || return 1
    # Stage the complete, explicitly enumerated project. The two root-level
    # launch/install helpers were missing from the first publisher's allowlist;
    # they are now included as well as their public download copies.
    git add .github .gitignore LICENSE README.txt AUDIT.txt backend docker-compose.yml index.html \
        agent-launcher.sh install-fedora-ai-agents.sh install-opencode.sh package.json \
        quickstart.sh requirements.txt scripts src public uninstall-fedora-ai-agents.sh \
        vite.config.js build-fedora-ai-agents-explainer.sh
    if [ -f package-lock.json ]; then git add package-lock.json; fi
    if ! git diff --cached --quiet; then
        git commit -m "Build Fedora-native Omarchy-inspired AI agents explainer" || return 1
    else
        printf 'No staged content changes; repository already matches generated files.\n'
    fi

    # Refuse an unrelated or divergent pre-existing remote history. A first
    # publication to an empty repository is fine; an existing remote branch is
    # fetched and accepted only when a fast-forward relationship is provable.
    # This avoids force-pushing over README/license/work that already exists.
    git ls-remote --exit-code origin refs/heads/main >/tmp/fedora-ai-agents-remote-main.log 2>&1
    REMOTE_MAIN_STATUS=$?
    if [ "$REMOTE_MAIN_STATUS" -eq 0 ]; then
        git fetch origin main || return 1
        if git merge-base --is-ancestor origin/main HEAD; then
            printf 'Remote main is an ancestor of local main; safe fast-forward push.\n'
        elif git merge-base --is-ancestor HEAD origin/main; then
            printf 'Remote main is ahead; fast-forwarding local main before publication.\n'
            git merge --ff-only origin/main || return 1
        else
            fail 'Remote main and local main have unrelated/divergent histories. Refusing to force-push; reconcile the existing repository history first.'
            cat /tmp/fedora-ai-agents-remote-main.log
            return 1
        fi
    elif [ "$REMOTE_MAIN_STATUS" -eq 2 ]; then
        printf 'Remote main does not exist yet; first push will create it.\n'
    else
        fail 'Unable to inspect remote main (network/authentication/remote error). Refusing to assume the repository is empty.'
        cat /tmp/fedora-ai-agents-remote-main.log
        return 1
    fi

    # Configure Pages BEFORE the push that triggers deploy.yml. Otherwise the
    # first Actions run can race the Pages site-creation API and fail deployment.
    # GitHub documents the workflow publishing source here:
    # https://docs.github.com/en/pages/getting-started-with-github-pages/configuring-a-publishing-source-for-your-github-pages-site
    printf '\n===== ENABLE GITHUB PAGES WORKFLOW SOURCE BEFORE PUSH =====\n'
    gh api "repos/${PROJECT_SLUG}/pages" -X POST -f build_type=workflow >/tmp/fedora-ai-agents-pages-api-write.log 2>&1
    PAGES_WRITE_STATUS=$?
    if [ "$PAGES_WRITE_STATUS" -ne 0 ]; then
        # Updating an existing Pages site commonly returns HTTP 204 with an
        # EMPTY body. Never parse the write response as JSON; always GET the
        # canonical representation after the create/update request.
        gh api "repos/${PROJECT_SLUG}/pages" -X PUT -f build_type=workflow >/tmp/fedora-ai-agents-pages-api-write.log 2>&1
        PAGES_WRITE_STATUS=$?
    fi
    if [ "$PAGES_WRITE_STATUS" -ne 0 ]; then
        printf 'Pages create/update request failed; GitHub response follows.\n' >&2
        cat /tmp/fedora-ai-agents-pages-api-write.log >&2
        return 1
    fi
    if ! gh api "repos/${PROJECT_SLUG}/pages" >/tmp/fedora-ai-agents-pages-api.json 2>/tmp/fedora-ai-agents-pages-api-read.log; then
        printf 'Pages configuration could not be read back after create/update.\n' >&2
        cat /tmp/fedora-ai-agents-pages-api-read.log >&2
        return 1
    fi
    PAGES_BUILD_TYPE="$(python3 -c 'import json,sys; print(json.load(sys.stdin).get("build_type", ""))' < /tmp/fedora-ai-agents-pages-api.json)"
    if [ "$PAGES_BUILD_TYPE" != "workflow" ]; then
        fail "GitHub Pages is not configured for Actions workflow deployment (build_type=${PAGES_BUILD_TYPE:-missing})."
        cat /tmp/fedora-ai-agents-pages-api.json
        return 1
    fi
    git push -u origin main || return 1

    printf '\n===== MONITOR GITHUB ACTIONS THROUGH THE GITHUB REST API =====\n'
    # Use the authenticated GitHub REST API, not a branch-only CLI listing.
    # The exact commit SHA and workflow path prevent a stale successful run from
    # being mistaken for this publication. API contract:
    # https://docs.github.com/en/rest/actions/workflow-runs
    # `gh api` is GitHub CLI's supported authenticated REST interface:
    # https://cli.github.com/manual/gh_api
    COMMIT_SHA="$(git rev-parse HEAD)"
    RUNS_JSON="$(mktemp /tmp/fedora-ai-agents-runs.XXXXXX.json)" || return 1
    RUNS_ERROR="$(mktemp /tmp/fedora-ai-agents-runs.XXXXXX.log)" || return 1
    DEPLOYED=0
    RUN_ID=""
    for attempt in $(seq 1 60); do
        if gh api "repos/${PROJECT_SLUG}/actions/runs?head_sha=${COMMIT_SHA}&per_page=100" > "$RUNS_JSON" 2> "$RUNS_ERROR"; then
            RUN_INFO="$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); rs=[r for r in d.get("workflow_runs",[]) if r.get("head_sha")==sys.argv[2] and r.get("path","").split("@",1)[0]==".github/workflows/deploy.yml"]; rs.sort(key=lambda r:r.get("run_number",0), reverse=True); r=rs[0] if rs else {}; print("|".join(str(r.get(k, "")) for k in ("id","status","conclusion","html_url")))' "$RUNS_JSON" "$COMMIT_SHA")"
            if [ -n "$RUN_INFO" ]; then
                IFS="|" read -r RUN_ID RUN_STATUS RUN_CONCLUSION RUN_HTML_URL <<< "$RUN_INFO"
                printf 'GitHub API poll %s/60: run=%s status=%s conclusion=%s\n' "$attempt" "$RUN_ID" "$RUN_STATUS" "${RUN_CONCLUSION:-pending}"
                if [ "$RUN_STATUS" = "completed" ] && [ "$RUN_CONCLUSION" = "success" ]; then
                    DEPLOYED=1
                    printf 'Successful workflow: %s\n' "$RUN_HTML_URL"
                    break
                fi
                if [ "$RUN_STATUS" = "completed" ] && [ "$RUN_CONCLUSION" != "success" ]; then
                    printf 'GitHub Actions completed unsuccessfully (%s). Failed job logs follow.\n' "$RUN_CONCLUSION" >&2
                    gh run view "$RUN_ID" --repo "$PROJECT_SLUG" --log-failed
                    rm -f -- "$RUNS_JSON" "$RUNS_ERROR"
                    return 1
                fi
            else
                printf 'GitHub API poll %s/60: waiting for workflow run for commit %s.\n' "$attempt" "$COMMIT_SHA"
            fi
        else
            printf 'GitHub API poll %s/60: request failed; response follows.\n' "$attempt" >&2
            cat "$RUNS_ERROR" >&2
        fi
        sleep 10
    done
    rm -f -- "$RUNS_JSON" "$RUNS_ERROR"
    if [ "$DEPLOYED" -ne 1 ]; then
        fail 'GitHub Actions did not report a successful deploy.yml run for the exact pushed commit within 10 minutes.'
        return 1
    fi

    printf '\n===== VERIFY GITHUB PAGES API STATE =====\n'
    # Pages REST representation is the authority for the configured URL and
    # workflow publishing mode; a green Actions run alone is not enough.
    # https://docs.github.com/en/rest/pages#get-a-github-pages-site
    PAGES_API_JSON="$(mktemp /tmp/fedora-ai-agents-pages.XXXXXX.json)" || return 1
    if ! gh api "repos/${PROJECT_SLUG}/pages" > "$PAGES_API_JSON"; then
        printf 'Unable to read the GitHub Pages API representation.\n' >&2
        rm -f -- "$PAGES_API_JSON"
        return 1
    fi
    PAGES_API_INFO="$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print("|".join(str(d.get(k, "")) for k in ("build_type","html_url","status")))' "$PAGES_API_JSON")"
    IFS="|" read -r PAGES_BUILD_TYPE API_PAGES_URL PAGES_STATUS <<< "$PAGES_API_INFO"
    rm -f -- "$PAGES_API_JSON"
    printf 'Pages API: build_type=%s status=%s html_url=%s\n' "$PAGES_BUILD_TYPE" "$PAGES_STATUS" "$API_PAGES_URL"
    # GitHub's html_url may be normalized with or without a final slash.
    API_PAGES_URL_NORMALIZED="${API_PAGES_URL%/}/"
    if [ "$PAGES_BUILD_TYPE" != "workflow" ]; then
        fail "GitHub Pages API does not report build_type=workflow (reported: ${PAGES_BUILD_TYPE:-missing})."
        return 1
    fi
    if [ "$API_PAGES_URL_NORMALIZED" != "$PAGES_URL" ]; then
        fail "GitHub Pages API URL differs from the expected URL: ${API_PAGES_URL:-missing}"
        return 1
    fi

    printf '\n===== VERIFY DEPLOYED HTML AND STATIC ASSETS =====\n'
    PAGES_HTML="$(mktemp /tmp/fedora-ai-agents-pages.XXXXXX.html)" || return 1
    HTTP_STATUS=""
    for http_attempt in $(seq 1 12); do
        HTTP_STATUS="$(curl --location --silent --show-error --connect-timeout 10 --max-time 45 \
            --output "$PAGES_HTML" --write-out '%{http_code}' "$PAGES_URL")"
        printf 'Pages HTTP verification %s/12: status=%s\n' "$http_attempt" "$HTTP_STATUS"
        if [ "$HTTP_STATUS" = "200" ]; then break; fi
        sleep 10
    done
    printf 'Pages URL: %s\nHTTP status: %s\n' "$PAGES_URL" "$HTTP_STATUS"
    if [ "$HTTP_STATUS" != "200" ]; then
        rm -f -- "$PAGES_HTML"
        fail 'Deployed site did not return HTTP 200.'
        return 1
    fi
    if ! awk 'index($0, "Fedora AI Agents") { found=1 } END { exit(found ? 0 : 1) }' "$PAGES_HTML"; then
        rm -f -- "$PAGES_HTML"
        fail 'HTTP 200 response did not contain the expected Fedora AI Agents site identity.'
        return 1
    fi
    # Fetch the actual Vite JS/CSS bundles too. A 200 response for an HTML error
    # page or broken index is not a working deployment. Vite's project-site base
    # path is documented at https://vite.dev/guide/static-deploy.
    ASSET_PATHS="$(python3 -c 'import re,sys; s=open(sys.argv[1],encoding="utf-8").read(); xs=re.findall(r"(?:src|href)=\"([^\"]+)\"",s); print("\n".join(x for x in xs if "/assets/" in x and (x.endswith(".js") or x.endswith(".css"))))' "$PAGES_HTML")"
    rm -f -- "$PAGES_HTML"
    if [ -z "$ASSET_PATHS" ]; then
        fail 'No built JavaScript/CSS assets were found in the deployed HTML.'
        return 1
    fi
    while IFS= read -r ASSET_PATH; do
        [ -n "$ASSET_PATH" ] || continue
        case "$ASSET_PATH" in
            http://*|https://*) ASSET_URL="$ASSET_PATH" ;;
            /*) ASSET_URL="https://swipswaps.github.io${ASSET_PATH}" ;;
            *) ASSET_URL="${PAGES_URL}${ASSET_PATH}" ;;
        esac
        ASSET_BODY="$(mktemp /tmp/fedora-ai-agents-asset.XXXXXX)" || return 1
        ASSET_STATUS="$(curl --fail --location --silent --show-error --connect-timeout 10 --max-time 45 \
            --output "$ASSET_BODY" --write-out '%{http_code}' "$ASSET_URL")"
        printf 'Asset: %s -> HTTP %s\n' "$ASSET_URL" "$ASSET_STATUS"
        rm -f -- "$ASSET_BODY"
        if [ "$ASSET_STATUS" != "200" ]; then
            fail "Deployed asset did not return HTTP 200: ${ASSET_URL}"
            return 1
        fi
    done <<< "$ASSET_PATHS"

    printf '\n===== OPEN VERIFIED DEPLOYED SITE IN XFCE DESKTOP =====\n'
    # xdg-open is the freedesktop.org desktop URL-opening interface. It is
    # invoked only after REST, HTML identity, and bundle checks succeed.
    # https://gitlab.freedesktop.org/xdg/xdg-utils
    if [ -z "${DISPLAY:-}" ] && [ -z "${WAYLAND_DISPLAY:-}" ]; then
        printf 'No graphical display session detected. Site is verified; open manually: %s\n' "$PAGES_URL"
    else
        XDG_OPEN_LOG="$(mktemp /tmp/fedora-ai-agents-xdg-open.XXXXXX.log)" || return 1
        if xdg-open "$PAGES_URL" > "$XDG_OPEN_LOG" 2>&1; then
            printf 'xdg-open accepted the verified site URL: %s\n' "$PAGES_URL"
            if [ -s "$XDG_OPEN_LOG" ]; then cat "$XDG_OPEN_LOG"; fi
        else
            XDG_STATUS=$?
            printf 'xdg-open failed (exit %s). Output follows; site itself passed HTTP and asset checks.\n' "$XDG_STATUS" >&2
            cat "$XDG_OPEN_LOG" >&2
            rm -f -- "$XDG_OPEN_LOG"
            printf 'Open manually: %s\n' "$PAGES_URL" >&2
            return 1
        fi
        rm -f -- "$XDG_OPEN_LOG"
    fi
fi

printf '\n============================================================\n'
printf ' BUILD COMPLETE\n'
printf ' Project: %s\n' "$PROJECT_DIR"
printf ' Pages:   %s\n' "$PAGES_URL"
printf ' Backups: %s\n' "$BACKUP_ROOT"
printf '============================================================\n'
return 0
}

main "$@"
