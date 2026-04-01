'use strict';

const express = require('express');
const crypto = require('crypto');
const https = require('https');
const http = require('http');
const { execFile } = require('child_process');

const app = express();
app.use(express.json({ limit: '2mb' }));

// ── Configuration (env vars) ────────────────────────────────────────
const AMBIENT_API_URL = process.env.AMBIENT_API_URL || 'http://localhost:8443';
const AMBIENT_PROJECT = process.env.AMBIENT_PROJECT || 'default';
const AMBIENT_SESSION = process.env.AMBIENT_SESSION || '';
const AMBIENT_TOKEN = process.env.AMBIENT_TOKEN || '';
const MOCK_MODE = process.env.MOCK_MODE === 'true';
const PORT = process.env.PORT || 8080;

const conversationSessionMap = new Map();

function ambientHeaders() {
  const headers = {
    'Content-Type': 'application/json',
    'X-Forwarded-User': 'cluster-admin',
  };
  if (AMBIENT_TOKEN) {
    headers['X-Forwarded-Access-Token'] = AMBIENT_TOKEN;
  }
  return headers;
}

function sessionUrl(sessionName, path = '') {
  return `${AMBIENT_API_URL}/api/projects/${AMBIENT_PROJECT}/agentic-sessions/${sessionName}${path}`;
}

let pendingSessionPromise = null;

function runnerTypeForModel(model) {
  if (model?.startsWith('gemini-')) return 'gemini-cli';
  return 'claude-agent-sdk';
}

async function resolveSession(conversationId, model) {
  if (AMBIENT_SESSION) {
    return AMBIENT_SESSION;
  }

  if (conversationId && conversationSessionMap.has(conversationId)) {
    return conversationSessionMap.get(conversationId);
  }

  if (conversationId?.startsWith('session-')) {
    try {
      const session = await jsonRequest(
        'GET',
        `${AMBIENT_API_URL}/api/projects/${AMBIENT_PROJECT}/agentic-sessions/${conversationId}`,
      );
      if (session?.status?.phase === 'Running') {
        console.log(`[session] Reattached to existing session: ${conversationId}`);
        conversationSessionMap.set(conversationId, conversationId);
        return conversationId;
      }
    } catch { /* session doesn't exist or not accessible */ }
  }

  if (pendingSessionPromise) {
    console.log('[session] Waiting for in-flight session creation...');
    return pendingSessionPromise;
  }

  pendingSessionPromise = createSession(conversationId, model).finally(() => {
    pendingSessionPromise = null;
  });
  return pendingSessionPromise;
}

async function createSession(conversationId, model) {
  const runnerType = runnerTypeForModel(model);
  console.log(`[session] Creating new agentic session (model=${model || 'default'}, runner=${runnerType})...`);
  const sessionBody = { displayName: `ols-${Date.now()}`, runnerType };
  if (model) {
    sessionBody.llmSettings = { model };
  }
  const result = await jsonRequest(
    'POST',
    `${AMBIENT_API_URL}/api/projects/${AMBIENT_PROJECT}/agentic-sessions`,
    sessionBody,
  );
  const sessionName = result.name;
  console.log(`[session] Created: ${sessionName}. Waiting for runner...`);

  for (let i = 0; i < 60; i++) {
    await sleep(3000);
    try {
      const session = await jsonRequest(
        'GET',
        `${AMBIENT_API_URL}/api/projects/${AMBIENT_PROJECT}/agentic-sessions/${sessionName}`,
      );
      const phase = session?.status?.phase;
      if (phase === 'Running') {
        console.log(`[session] ${sessionName} is Running.`);
        await writeSessionFiles(sessionName);
        if (conversationId) {
          conversationSessionMap.set(conversationId, sessionName);
        }
        return sessionName;
      }
      if (phase === 'Failed') {
        throw new Error(`Session ${sessionName} failed to start`);
      }
    } catch (err) {
      if (err.message?.includes('failed to start')) throw err;
    }
  }
  throw new Error('Session did not reach Running state within 3 minutes');
}

const MCP_CONFIG = JSON.stringify({
  mcpServers: {
    kubernetes: { type: 'http', url: 'http://kubernetes-mcp-server.ambient-code.svc:8008/mcp' },
    context7: { type: 'http', url: 'https://mcp.context7.com/mcp' },
    deepwiki: { type: 'http', url: 'https://mcp.deepwiki.com/mcp' },
    webfetch: { command: 'uvx', args: ['mcp-server-fetch'] },
  },
});

const CLAUDE_MD = `# MANDATORY Identity Override

IMPORTANT: In this deployment you are branded as **OpenShift Lightspeed**.
When users ask who you are, ALWAYS say "I am OpenShift Lightspeed, an AI assistant
for the Red Hat OpenShift platform." NEVER say "Claude Code" or "Anthropic CLI".
This is a hard requirement from the deployment configuration.

Use the Kubernetes MCP tools to inspect the cluster when relevant.
Be concise and direct.
`;

const AMBIENT_JSON = JSON.stringify({
  systemPrompt:
    'CRITICAL IDENTITY RULE: You are deployed as "OpenShift Lightspeed", an AI assistant ' +
    'for Red Hat OpenShift. When asked who you are, ALWAYS respond that you are ' +
    '"OpenShift Lightspeed". NEVER mention "Claude Code" or "Anthropic". ' +
    'This overrides any other identity instructions. ' +
    'Help users with OpenShift cluster operations, troubleshooting, and configuration.',
}, null, 2);

const PROMPTS_PY = [
  '"""Patched for OLS POC."""',
  'from ambient_runner.platform.prompts import resolve_workspace_prompt',
  '',
  'OLS_IDENTITY = (',
  '    "You are OpenShift Lightspeed Agent, an AI assistant integrated into the "',
  '    "Red Hat OpenShift web console. "',
  '    "When greeting users or asked who you are, always say I am OpenShift Lightspeed Agent. "',
  '    "Help users with cluster operations, troubleshooting, configuration, and Kubernetes concepts. "',
  '    "Use the Kubernetes MCP tools to inspect the cluster when relevant. "',
  '    "Be concise and direct. Do not use emojis unless the user explicitly requests them.\\n"',
  ')',
  '',
  'def build_sdk_system_prompt(workspace_path: str, cwd_path: str) -> str:',
  '    workspace_context = resolve_workspace_prompt(workspace_path, cwd_path)',
  '    return OLS_IDENTITY + workspace_context',
].join('\n');

function writeSessionFiles(sessionName) {
  const pod = `${sessionName}-runner`;
  const ns = AMBIENT_PROJECT;
  const b64mcp = Buffer.from(MCP_CONFIG).toString('base64');
  const b64py = Buffer.from(PROMPTS_PY).toString('base64');

  const fixPerms = `chmod 777 /workspace/artifacts && mkdir -p /workspace/artifacts/.gemini /workspace/artifacts/.claude && chmod 777 /workspace/artifacts/.gemini /workspace/artifacts/.claude`;
  const writeFiles = `echo '${b64mcp}' | base64 -d > /workspace/.mcp.json && echo '${b64py}' | base64 -d > /app/ambient-runner/ambient_runner/bridges/claude/prompts.py`;

  return new Promise((resolve) => {
    execFile('kubectl', ['exec', pod, '-n', ns, '-c', 'state-sync', '--', 'sh', '-c', fixPerms],
      { timeout: 10000 },
      (permErr) => {
        if (permErr) {
          console.warn(`[session] Failed to fix permissions on ${pod}: ${permErr.message}`);
        } else {
          console.log(`[session] Fixed workspace permissions on ${pod}`);
        }
        execFile('kubectl', ['exec', pod, '-n', ns, '-c', 'ambient-code-runner', '--', 'sh', '-c', writeFiles],
          { timeout: 10000 },
          (err) => {
            if (err) {
              console.warn(`[session] Failed to write session files to ${pod}: ${err.message}`);
            } else {
              console.log(`[session] Session files written to ${pod}`);
            }
            resolve();
          },
        );
      },
    );
  });
}

// ── OLS-compatible endpoints ────────────────────────────────────────

app.post('/authorized', (_req, res) => {
  res.json({ user_id: 'poc-user', username: 'poc-user' });
});

app.get('/readiness', async (_req, res) => {
  if (MOCK_MODE) {
    res.json({ ready: true });
    return;
  }
  try {
    const resp = await fetch(`${AMBIENT_API_URL}/health`, {
      headers: ambientHeaders(),
      signal: AbortSignal.timeout(5000),
    });
    res.json({ ready: resp.ok });
  } catch {
    res.json({ ready: false, reason: 'Ambient backend unreachable' });
  }
});

app.get('/v1/feedback/status', (_req, res) => {
  res.json({ status: { enabled: false } });
});

app.post('/v1/feedback', (_req, res) => {
  res.json({});
});

// ── Main streaming query ─────────────────────────────────────────────

app.post('/v1/streaming_query', async (req, res) => {
  if (MOCK_MODE) {
    return handleMockQuery(req, res);
  }
  return handleRealQuery(req, res);
});

// ── Real mode: OLS → AG-UI translation ──────────────────────────────

async function handleRealQuery(req, res) {
  const { query, conversation_id: conversationId, attachments, model } = req.body;

  let content = query || '';
  if (Array.isArray(attachments) && attachments.length > 0) {
    const parts = attachments.map(
      (a) => `\n\n--- ${a.attachment_type} (${a.content_type}) ---\n${a.content}`,
    );
    content += parts.join('');
  }

  res.setHeader('Content-Type', 'text/event-stream');
  res.setHeader('Cache-Control', 'no-cache');
  res.setHeader('Connection', 'keep-alive');
  res.flushHeaders();

  try {
    const activeSession = await resolveSession(conversationId, model);
    const threadId = conversationId || activeSession;
    const runId = crypto.randomUUID();
    const messages = [{ id: `msg-${crypto.randomUUID()}`, role: 'user', content }];
    const runInput = { threadId, runId, messages };

    sendOLS(res, 'start', { conversation_id: threadId });

    // Subscribe to events BEFORE posting the run so we don't miss fast responses
    const eventsReq = sseRequest(sessionUrl(activeSession, '/agui/events'));

    req.on('close', () => {
      eventsReq.destroy();
      jsonRequest('POST', sessionUrl(activeSession, '/agui/interrupt'), {}).catch(() => {});
      console.log(`[run] interrupted runId=${runId}`);
    });

    await new Promise((resolve, reject) => {
      let buffer = '';
      const toolArgsBuf = {};
      let reasoningRound = 0;
      let runPosted = false;

      eventsReq.on('response', (eventsResp) => {
        if (eventsResp.statusCode !== 200) {
          sendOLS(res, 'error', `Events returned ${eventsResp.statusCode}`);
          res.end();
          resolve();
          return;
        }

        // Once the events stream is connected, post the run
        if (!runPosted) {
          runPosted = true;
          jsonRequest('POST', sessionUrl(activeSession, '/agui/run'), runInput)
            .then((runData) => {
              console.log(`[run] runId=${runId} threadId=${threadId} (server=${runData.runId})`);
            })
            .catch((err) => {
              console.error('[adapter] run POST error:', err.message);
              sendOLS(res, 'error', err.message);
              eventsReq.destroy();
              res.end();
              resolve();
            });
        }

        eventsResp.setEncoding('utf-8');
        eventsResp.on('data', (chunk) => {
          buffer += chunk;
          const lines = buffer.split('\n');
          buffer = lines.pop() ?? '';

          for (const raw of lines) {
            const trimmed = raw.trim();
            if (!trimmed.startsWith('data: ')) continue;

            let evt;
            try {
              evt = JSON.parse(trimmed.slice(6));
            } catch {
              continue;
            }

            // Only process events for our run; skip replayed history from other runs
            const evtRunId = evt.runId || evt.run_id;
            if (evtRunId && evtRunId !== runId) continue;

            const finished = translateEvent(res, evt, toolArgsBuf, reasoningRound);
            if (evt.type === 'REASONING_MESSAGE_START') reasoningRound++;
            if (finished) {
              eventsReq.destroy();
              res.end();
              resolve();
              return;
            }
          }
        });

        eventsResp.on('end', () => {
          res.end();
          resolve();
        });
      });

      eventsReq.on('error', (err) => {
        console.error('[adapter] events error:', err.message);
        reject(err);
      });

      eventsReq.end();
    });
  } catch (err) {
    if (err.code === 'ECONNRESET' || err.message?.includes('aborted')) return;
    console.error('[adapter] streaming error:', err);
    sendOLS(res, 'error', err.message);
    res.end();
  }
}

function jsonRequest(method, url, body) {
  return new Promise((resolve, reject) => {
    const parsed = new URL(url);
    const mod = parsed.protocol === 'https:' ? https : http;
    const opts = {
      hostname: parsed.hostname,
      port: parsed.port,
      path: parsed.pathname + parsed.search,
      method,
      headers: ambientHeaders(),
      rejectAuthorized: false,
    };

    const req = mod.request(opts, (resp) => {
      let data = '';
      resp.on('data', (c) => (data += c));
      resp.on('end', () => {
        if (resp.statusCode >= 400) {
          reject(new Error(`HTTP ${resp.statusCode}: ${data}`));
          return;
        }
        try {
          resolve(JSON.parse(data));
        } catch {
          resolve(data);
        }
      });
    });
    req.on('error', reject);
    if (body) req.write(JSON.stringify(body));
    req.end();
  });
}

function sseRequest(url) {
  const parsed = new URL(url);
  const mod = parsed.protocol === 'https:' ? https : http;
  return mod.request({
    hostname: parsed.hostname,
    port: parsed.port,
    path: parsed.pathname + parsed.search,
    method: 'GET',
    headers: { ...ambientHeaders(), Accept: 'text/event-stream' },
    rejectAuthorized: false,
  });
}

// ── Mock mode: simulates AG-UI event flow ────────────────────────────

async function handleMockQuery(req, res) {
  const { query } = req.body;
  const threadId = `mock-${Date.now()}`;

  res.setHeader('Content-Type', 'text/event-stream');
  res.setHeader('Cache-Control', 'no-cache');
  res.setHeader('Connection', 'keep-alive');
  res.flushHeaders();

  const aborted = { value: false };
  req.on('close', () => {
    aborted.value = true;
  });

  console.log(`[mock] query="${(query || '').slice(0, 60)}..."`);

  sendOLS(res, 'start', { conversation_id: threadId });

  // Simulate reasoning
  const reasoning = `The user asked: "${query}". Let me think about this using the Ambient platform capabilities...`;
  for (const chunk of splitIntoChunks(reasoning, 8)) {
    if (aborted.value) return;
    sendOLS(res, 'reasoning', { round: 1, reasoning: chunk });
    await sleep(30);
  }

  // Simulate a tool call
  if (aborted.value) return;
  const toolId = `tool-${crypto.randomUUID().slice(0, 8)}`;
  sendOLS(res, 'tool_call', { id: toolId, name: 'Read', args: { path: 'cluster-info.yaml' } });
  await sleep(200);
  sendOLS(res, 'tool_result', {
    id: toolId,
    content: 'apiVersion: v1\nkind: ConfigMap\nmetadata:\n  name: cluster-info\ndata:\n  platform: OpenShift\n  version: "4.16"',
    status: 'success',
  });
  await sleep(100);

  // Simulate streaming response
  const response =
    `This is a **mock response** from the Ambient adapter, demonstrating the OLS UI ` +
    `rendering streamed AG-UI events translated into OLS format.\n\n` +
    `Your query was: *"${query}"*\n\n` +
    `### What this proves\n\n` +
    `1. The **OLS console plugin** can render responses from the Ambient backend\n` +
    `2. **Token streaming** works — each word arrived incrementally\n` +
    `3. **Tool calls** are displayed (see the Read tool call above)\n` +
    `4. **Reasoning/thinking** is captured and shown\n` +
    `5. The **conversation thread** is maintained via \`conversation_id\`\n\n` +
    `In production, this adapter translates between the OLS SSE protocol ` +
    `(\`start\`/\`token\`/\`end\` events) and Ambient's AG-UI protocol ` +
    `(\`TEXT_MESSAGE_CONTENT\`/\`TOOL_CALL_*\`/\`RUN_FINISHED\` events).`;

  for (const chunk of splitIntoChunks(response, 5)) {
    if (aborted.value) return;
    sendOLS(res, 'token', { token: chunk });
    await sleep(25);
  }

  sendOLS(res, 'end', { truncated: false, referenced_documents: [] });
  res.end();
}

// ── AG-UI → OLS event translation ───────────────────────────────────

function translateEvent(res, evt, toolArgsBuf, reasoningRound) {
  switch (evt.type) {
    case 'TEXT_MESSAGE_CONTENT':
      sendOLS(res, 'token', { token: evt.delta });
      break;

    case 'TOOL_CALL_START':
      sendOLS(res, 'tool_call', {
        id: evt.toolCallId,
        name: evt.toolCallName,
        args: {},
      });
      toolArgsBuf[evt.toolCallId] = '';
      break;

    case 'TOOL_CALL_ARGS':
      if (evt.toolCallId in toolArgsBuf) {
        toolArgsBuf[evt.toolCallId] += evt.delta;
      }
      break;

    case 'TOOL_CALL_END': {
      const status = evt.error ? 'error' : 'success';
      const content = evt.error || evt.result || toolArgsBuf[evt.toolCallId] || '';
      sendOLS(res, 'tool_result', {
        id: evt.toolCallId,
        content,
        status,
      });
      delete toolArgsBuf[evt.toolCallId];
      break;
    }

    case 'REASONING_MESSAGE_START':
      break;

    case 'REASONING_MESSAGE_CONTENT':
      sendOLS(res, 'reasoning', {
        round: reasoningRound,
        reasoning: evt.delta,
      });
      break;

    case 'RUN_ERROR':
      sendOLS(res, 'error', {
        response: evt.error || evt.message || 'Unknown error',
        cause: evt.details || '',
      });
      return true;

    case 'RUN_FINISHED':
      sendOLS(res, 'end', {
        truncated: false,
        referenced_documents: [],
      });
      return true;

    default:
      break;
  }
  return false;
}

// ── Helpers ──────────────────────────────────────────────────────────

function sendOLS(res, event, data) {
  const payload = typeof data === 'string' ? { detail: data } : data;
  res.write(`data: ${JSON.stringify({ event, data: payload })}\n\n`);
}

function splitIntoChunks(text, wordsPerChunk) {
  const words = text.split(/(\s+)/);
  const chunks = [];
  for (let i = 0; i < words.length; i += wordsPerChunk) {
    chunks.push(words.slice(i, i + wordsPerChunk).join(''));
  }
  return chunks;
}

function sleep(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

// ── Startup ─────────────────────────────────────────────────────────

app.listen(PORT, () => {
  console.log(`\nOLS → Ambient adapter listening on http://localhost:${PORT}`);
  if (MOCK_MODE) {
    console.log('  Mode:         MOCK (simulated AG-UI responses)');
  } else {
    console.log(`  Ambient API:  ${AMBIENT_API_URL}`);
    console.log(`  Project:      ${AMBIENT_PROJECT}`);
    if (AMBIENT_SESSION) {
      console.log(`  Session:      ${AMBIENT_SESSION} (fixed)`);
    } else {
      console.log('  Session:      auto-create on first message');
    }
  }
  console.log(`\nRun the OLS console plugin with OLS_PORT=${PORT} to connect.\n`);
});
