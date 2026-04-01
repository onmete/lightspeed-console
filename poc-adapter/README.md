# OLS → Ambient Adapter (POC)

Proof-of-concept that uses the OpenShift Lightspeed console plugin as a UI
frontend for the Ambient Code Platform. An adapter service translates between
the OLS SSE protocol and Ambient's AG-UI protocol.

## Quick start

### 1. Deploy to an OpenShift cluster (one-time)

```bash
oc login <cluster-url>          # cluster-admin required
./setup-cluster.sh              # deploys Ambient + MCP server + creates session
```

This deploys:
- Ambient Code Platform (backend, operator, MinIO, PostgreSQL)
- Kubernetes MCP server (read-only cluster access for the AI agent)
- A project and agentic session

### 2. Launch the local UI stack

```bash
./start-all.sh                  # auto-loads .env.session from setup
```

Open `http://localhost:9000` and use the Lightspeed chat — queries are handled
by Claude running in the Ambient runner pod, with access to OpenShift cluster
data via the Kubernetes MCP server.

### Mock mode (no cluster needed)

```bash
MOCK_MODE=true ./start-all.sh
```

## What works

| Feature | Status |
|---------|--------|
| Streaming chat (text tokens) | Yes |
| Tool calls (name + result) | Yes |
| Reasoning/thinking display | Yes |
| Kubernetes MCP (cluster read) | Yes |
| Conversation continuity | Yes |
| OLS attachments → context | Yes (appended as text) |
| Stream cancel (abort) | Yes |
| Feedback | Disabled (no-op) |

## Event mapping

| AG-UI Event | OLS Event |
|---|---|
| `TEXT_MESSAGE_CONTENT` | `token` |
| `TOOL_CALL_START` | `tool_call` |
| `TOOL_CALL_ARGS` | (accumulated) |
| `TOOL_CALL_END` | `tool_result` |
| `REASONING_MESSAGE_CONTENT` | `reasoning` |
| `RUN_FINISHED` | `end` |
| `RUN_ERROR` | `error` |

## Architecture

```
┌─────────────┐     ┌──────────────┐     ┌──────────────┐     ┌────────────┐
│  OLS Plugin │────>│ Console Proxy│────>│   Adapter    │────>│  Ambient   │
│  (browser)  │<────│  (:9000)     │<────│   (:8080)    │<────│  Backend   │
└─────────────┘ OLS └──────────────┘ OLS └──────────────┘AGUI└────────────┘
                SSE                  SSE   POST /agui/run       ┌──────────┐
                                          GET  /agui/events     │  Runner  │
                                                                │ (Claude) │
                                                                └────┬─────┘
                                                                     │ MCP
                                                                ┌────┴─────┐
                                                                │ K8s MCP  │
                                                                │ Server   │
                                                                └──────────┘
```

## Scripts

| Script | Purpose |
|--------|---------|
| `setup-cluster.sh` | Deploys Ambient + K8s MCP server to OpenShift, creates session |
| `start-all.sh` | Launches adapter + plugin + console locally |
| `adapter.js` | OLS → AG-UI protocol translator |

## Environment variables

| Variable | Default | Description |
|----------|---------|-------------|
| `AMBIENT_SESSION` | (required) | Name of a running agentic session |
| `AMBIENT_PROJECT` | `poc-test` | Ambient project (K8s namespace) |
| `AMBIENT_API_URL` | auto-detect | Backend URL (Route or port-forward) |
| `AMBIENT_TOKEN` | auto-detect | Bearer token for Ambient API |
| `MOCK_MODE` | `false` | `true` for simulated responses |
| `ADAPTER_PORT` | `8080` | Adapter listen port |
| `CONSOLE_PORT` | `9000` | Console listen port |

## Prerequisites

- OpenShift cluster with cluster-admin access
- `oc` and `kubectl` CLI tools
- Node.js >= 18, npm
- podman or docker (for the console container)
- Ambient platform repo at `~/projects/ambient` (configurable via `AMBIENT_REPO`)
- GCP Vertex AI credentials at `~/.config/gcloud/application_default_credentials.json`
  (or set `ANTHROPIC_API_KEY` env var)
