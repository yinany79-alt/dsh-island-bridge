/**
 * dsh-island-bridge — 宿主半边。
 *
 * 职责：
 *   1. 以 answerer 身份加入 DSH 的两条审批瀑布（prepend + global），把待交互
 *      注册进注册表，交给 DSH 的原审批应答链处理；
 *   2. 采集会话状态（agents / sessions / sessionProjections / sessionQuery），
 *      组装全量快照，推送给 Swift 灵动岛面板（stdin JSON 行）；
 *   3. 面板回传的 decision → 桌面 PendingApproval.answer → DSH 链完成并清理两侧。
 *
 * 全部通信经 stdio 与回环，无网络、无云端、无遥测。
 */
import { spawn, execFile } from 'node:child_process';
import { createHash } from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { createRegistry } from './registry.js';
import { createHelperHost } from './helper-host.js';
import { createNavigation } from './navigation.js';
import { createApprovalRelay, questionIdentity, validateQuestionAnswer } from './approval-relay.js';
import { taskTitle } from './task-title.js';
import { createSessionConsole } from './session-console.js';

export const name = 'island-bridge';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const HELPER_SOURCE = path.join(__dirname, '..', 'helper', 'island-helper.swift');
const STATE_DIR = path.join(process.env.DSH_HOME ?? path.join(process.env.HOME ?? '', '.dsh'), 'dsh-island-bridge');
const BINARY = path.join(STATE_DIR, 'island-helper');
const HASH_FILE = BINARY + '.sha256';
const COMPILE_TIMEOUT_MS = 120_000;
const PUSH_DEBOUNCE_MS = 150;
const SAFETY_POLL_MS = 5000;
const MAX_FRAME_BYTES = 1_500_000;

/**
 * 诊断日志：默认关闭。设置 DSH_ISLAND_DEBUG=1 后写入
 * <DSH_HOME>/dsh-island-bridge/bridge-debug.log，不落仓库目录。
 */
const DEBUG = process.env.DSH_ISLAND_DEBUG === '1';
const DEBUG_LOG = path.join(STATE_DIR, 'bridge-debug.log');
function dbgLog(tag, obj) {
  if (!DEBUG) return;
  try {
    fs.appendFileSync(DEBUG_LOG, new Date().toISOString().slice(11, 23) + ' ' + tag + ' ' + JSON.stringify(obj).slice(0, 1500) + '\n');
  } catch (e) {}
}

const log = (...a) => console.log('[island-bridge]', ...a);

export function inject() { return ['approval', 'sessionQuery', 'sessions', 'agents', 'sessionProjections']; }

let registry = null;
let sessionConsole = null;
let lastRecentJson = '';
let approvalRelay = null;
let navigation = null;
let helperHost = null;
let helperReady = false;
let pushTimer = null;
let pushRevision = 0;
let lastPushAt = 0;
let lastPushJson = '';
let disposed = false;

export async function apply(ctx) {
  disposed = false;
  setBridgeContext(ctx);
  sessionConsole = createSessionConsole(ctx, enrichTitles);
  approvalRelay = createApprovalRelay({
    isPending: id => registry?.list().some(e => e.request.requestId === id),
    canBind: command => {
      const matches = registry.list().filter(({ request: r }) => r.kind === command.kind &&
        r.sessionId === command.sessionId && r.callId === command.callId &&
        (r.kind === 'permission' ? r.toolName === command.toolName && (r.reason || '') === (command.reason || '')
          : questionIdentity(r.questions) === command.questionIdentity));
      return matches.length === 1 && matches[0].request.requestId === command.requestId;
    }
  });
  navigation = createNavigation({ onResult: result => dbgLog('navigation-result', result), onConnected: () => dbgLog('navigation-client', { ready: true }) });
  ctx.inject(['connection'], navCtx => {
    for (const route of [...navigation.routes, ...approvalRelay.routes]) navCtx.connection.fetch.register(route);
  });
  registry = createRegistry({ onDismissed: () => schedulePush() });
  const unsubs = [];

  // ① 审批瀑布 answerer（prepend + global：必须先于 Web 远端应答器，且必须全局才收得到 agent 域分发）
  unsubs.push(ctx.effect(() => ctx.on('approval/request', async (req, next) => {
    const owner = registry;
    const relay = approvalRelay;
    let handle;
    try {
      handle = owner.ask({
        sessionId: req?.agent?.session?.header?.id ?? '', toolName: req?.toolName,
        reason: req?.reason, displayReason: req?.displayReason, callId: req?.callId,
        signal: req?.signal
      });
      schedulePush();
    } catch (error) {
      console.error('[island-bridge] approval mirror error:', String(error));
      return next();
    }
    // Both surfaces answer the same DSH PendingApproval. Do not mutate the
    // borrowed request or race the remote UI against a second approval owner.
    try { return await next(); }
    finally {
      owner.dismiss(handle.requestId);
      relay.cancel(handle.requestId);
    }
  }, { prepend: true, global: true }), 'island-bridge: approval mirror'));

  // ② 提问瀑布（ask_user_question）
  unsubs.push(ctx.effect(() => ctx.on('user-questions/request', async (request, next) => {
    const owner = registry;
    let handle;
    try {
      const sessionId = request?.agent?.session?.header?.id ?? '';
      handle = owner.askUser({
        sessionId: typeof sessionId === 'string' ? sessionId : '',
        questions: Array.isArray(request?.questions) ? request.questions : [],
        callId: request?.wait?.callId,
        signal: request?.signal
      });
      schedulePush();
    } catch (error) {
      console.error('[island-bridge] question mirror error:', String(error));
      return next();
    }
    // The desktop pending card owns settlement on both surfaces.
    try {
      return await next();
    } finally {
      owner.dismiss(handle.requestId);
      approvalRelay.cancel(handle.requestId);
    }
  }, { prepend: true, global: true }), 'island-bridge: question answerer'));

  // ③ 会话事件 → 状态推送（事件驱动 + 5s 安全兜底轮询）
  unsubs.push(ctx.effect(() => ctx.on('session/event', () => schedulePush(), { global: true }), 'island-bridge: session events'));
  const poll = setInterval(() => { if (!disposed) schedulePush(); }, SAFETY_POLL_MS);
  if (typeof poll.unref === 'function') poll.unref();

  unsubs.push(ctx.effect(() => () => {
    disposed = true;
    clearInterval(poll);
    registry.clear();
    if (pushTimer !== null) clearTimeout(pushTimer);
    pushTimer = null;
    navigation?.stop();
    approvalRelay?.stop();
    helperHost?.stop();
  }), 'island-bridge: shutdown');

  // ④ 拉起面板（构建失败不影响宿主：审批继续由 DSH 本地 UI 应答）
  try {
    await ensureHelperBinary();
  } catch (error) {
    console.error('[island-bridge] 无法构建原生面板：', String(error?.message ?? error));
    console.error('[island-bridge] 需要 macOS + Xcode Command Line Tools（swiftc）。面板未启动，审批仍在 DSH 本地 UI 正常出现。');
    return;
  }
  if (disposed) return;
  helperHost = createHelperHost({
    spawnChild: () => spawn(BINARY, [], { stdio: ['pipe', 'pipe', 'pipe'], env: { ...process.env } }),
    onStart: child => { dbgLog('helper-start', { pid: child.pid, version: 'v10-shared-approval' }); lastPushJson = ''; lastRecentJson = ''; helperReady = false; schedulePush(); },
    onLine: handleHelperLine,
    onError: error => console.error('[island-bridge] helper:', String(error)),
    onStderr: chunk => { if (chunk.trim()) console.warn('[island-helper]', chunk.trim().slice(0, 300)); },
  });
  helperHost.start();
}

async function ensureHelperBinary() {
  try {
    if (fs.readFileSync(HASH_FILE, 'utf8').trim() === sourceHash()) return;
  } catch (e) {}
  fs.mkdirSync(path.dirname(BINARY), { recursive: true });
  // 先编到临时文件再原子重命名：旧 helper 正在运行（或路径只读挂载）时也能顺利升级
  const staging = `${BINARY}.building-${process.pid}`;
  try {
    await new Promise((resolve, reject) => {
      const child = execFile('swiftc', ['-O', '-o', staging, HELPER_SOURCE], { timeout: COMPILE_TIMEOUT_MS }, (err) => {
        if (err) {
          reject(err.code === 'ENOENT' ? new Error('找不到 swiftc，请安装 Xcode Command Line Tools（xcode-select --install）') : err);
        } else resolve();
      });
      child.on('error', reject);
    });
    fs.renameSync(staging, BINARY);
  } finally {
    try { fs.unlinkSync(staging); } catch (e) {}
  }
  fs.writeFileSync(HASH_FILE, sourceHash() + '\n');
  console.log('[island-bridge] helper compiled →', BINARY);
}

function sourceHash() {
  return createHash('sha256').update(fs.readFileSync(HELPER_SOURCE)).digest('hex').slice(0, 32);
}

function wakeDshWindow() {
  try {
    execFile('osascript', ['-e', 'tell application "DeepSeek Harness" to activate'], { timeout: 5000 }, () => {});
  } catch (e) {}
}

function handleHelperLine(line) {
  let msg;
  try { msg = JSON.parse(line); } catch (e) { return; }
  if (msg.type === 'history') {
    if (typeof msg.requestId !== 'string' || msg.requestId.length > 64) return;
    const target = helperHost?.child;
    void sessionConsole.history(msg).then(page => {
      if (!target || disposed || helperHost?.child !== target) return;
      const envelope = { type: 'history-result', requestId: msg.requestId, sessionId: msg.sessionId, page };
      const payload = JSON.stringify(envelope);
      helperHost.send(Buffer.byteLength(payload) <= MAX_FRAME ? payload : JSON.stringify({ ...envelope, page: null }));
    });
    return;
  }
  if (msg.type === 'reply') {
    const target = helperHost?.child;
    void sessionConsole.send(msg).then(ok => {
      if (helperHost?.child === target) helperHost.send(JSON.stringify({
        type: 'reply-result', requestId: msg.requestId, sessionId: msg.sessionId, ok,
      }));
      if (ok) schedulePush();
    });
    return;
  }
  if (msg.type === 'open') {
    if (!navigation?.publish(msg.sessionId, msg.nodeKey)) return;
    wakeDshWindow();
    return;
  }
  if (msg.type === 'ready') { helperReady = true; schedulePush(); return; }
  if (msg.type === 'decision') {
    const entry = registry.list().find(e => e.request.requestId === msg.requestId);
    if (entry?.request.kind === 'permission') approvalRelay.publish(entry.request, msg.outcome);
    if (entry?.request.kind === QUESTION_KIND) {
      const answer = validateQuestionAnswer(entry.request.questions, msg.answers);
      if (answer) approvalRelay.publish(entry.request, answer);
    }

  }
}

const QUESTION_KIND = 'ask_user_question';

function schedulePush() {
  if (disposed || pushTimer !== null) return;
  pushTimer = setTimeout(() => {
    pushTimer = null;
    if (!disposed) void pushState();
  }, PUSH_DEBOUNCE_MS);
  pushTimer.unref?.();
}

const prevRunning = new Map();   // sessionId -> 上一次的 title（用于完成边沿检测）
const completedFlash = [];       // 待推送的完成事件（一次）
async function pushState() {
  lastPushAt = Date.now();
  const target = helperHost?.child;
  if (!target) return;
  const revision = ++pushRevision;
  let sessions = [];
    try { sessions = collectSessionsBase(bridgeCtx); } catch (error) {
    console.error('[island-bridge] collect failed:', String(error));
    return;
  }
  // 完成边沿：上一轮 running、这一轮不在 → 视为完成，附带标题
  const nowIds = new Set(sessions.map(x => x.id));
  const completed = [];
  for (const [id, info] of prevRunning) {
    if (!nowIds.has(id)) { completed.push({ id, title: info.title }); prevRunning.delete(id); }
  }
  for (const row of sessions) prevRunning.set(row.id, { title: row.title });
  void sessionConsole.snapshot(sessions, (recent, state) => {
    if (disposed || helperHost?.child !== target) return;
    const payload = JSON.stringify({ type: 'recent', sessions: recent, state });
    if (payload !== lastRecentJson && helperHost.send(payload)) lastRecentJson = payload;
  }).then(recent => {
    if (recent && !disposed && revision !== pushRevision) schedulePush();
  }).catch(() => {});
  // 标题异步补全：查询后如有变化再补推一次（不阻塞审批上岛）
  void (async () => {
    try {
      const before = JSON.stringify(sessions.map(x => x.title));
      await enrichTitles(bridgeCtx, sessions);
      if (disposed || revision !== pushRevision || helperHost?.child !== target) return;
      for (const row of sessions) prevRunning.set(row.id, { title: row.title });
      const after = JSON.stringify(sessions.map(x => x.title));
      if (before === after) return;
      const payload2 = { type: 'update', sessions, completed: [] };
      const json2 = JSON.stringify(payload2);
      if (json2 !== lastPushJson && helperHost.send(json2)) lastPushJson = json2;
    } catch (e) {}
  })();
  const payload = { type: 'update', sessions, completed };
  dbgLog('push', { sessions: sessions.map(x => ({ id: x.id, title: x.title, hasPending: !!x.pending, kind: x.pending?.kind })), completed, registrySize: registry.size(), registrySessionIds: [...(function*(){ try { for (const e of registry.list(undefined)) yield { pend: e.request.sessionId, kind: e.request.kind }; } catch (e) {} })()] });
  const json = JSON.stringify(payload);
  if (json === lastPushJson) return;
  if (json.length > MAX_FRAME) { console.error('[island-bridge] frame too large, dropped'); return; }
  if (helperHost.send(json)) lastPushJson = json;
}

const MAX_FRAME = 1_400_000;

function collectSessions() { return collectSessionsWith(bridgeCtx); }

let bridgeCtx = null;
export function setBridgeContext(c) { bridgeCtx = c; }

// [DEV] 无条件落盘的采集追踪，用于定位「面板为空」的真实原因
const TRACE = process.env.DSH_ISLAND_TRACE === '1';
const traceSink = (...args) => {
  if (!TRACE) return;
  try {
    fs.appendFileSync(path.join(STATE_DIR, 'collect-trace.log'),
      new Date().toISOString().slice(11, 23) + ' ' + args.map(a => typeof a === 'string' ? a : JSON.stringify(a)).join(' ') + '\n');
  } catch { /* ignore */ }
};

// 同步快速采集：会话行 + 待交互附加 + 缓存标题（审批 pending 零延迟上岛）
function collectSessionsBase(ctx) {
  if (typeof ctx?.get !== 'function') { traceSink('SKIP', 'no ctx.get'); return []; }
  const agents = ctx.get('agents');
  const sessions = ctx.get('sessions');
  const projections = ctx.get('sessionProjections');
  if (typeof agents?.list !== 'function' || typeof agents?.get !== 'function'
    || typeof sessions?.get !== 'function' || typeof projections?.snapshot !== 'function') { traceSink('SKIP', 'service shape'); return []; }
  const result = [];
  const all = agents.list();
  let sessionCount = -1;
  try { sessionCount = typeof sessions.list === 'function' ? sessions.list().length : -1; } catch { /* keep -1 */ }
  traceSink('AGENTS', {
    count: all.length,
    sessionRegistry: sessionCount,
    agents: all.map(a => ({ id: a?.id, status: a?.status, hasSession: !!a?.session })),
    runtime: { pid: process.pid, version: process.versions.electron ?? process.versions.node }
  });
  for (const agent of all) {
    if (agent?.status !== 'running') { traceSink('DROP', 'not running', { id: agent?.id, status: agent?.status }); continue; }
    const id = agent.id;
    if (agents.get(id) !== agent) { traceSink('DROP', 'identity agent', { id }); continue; }
    const session = sessions.get(id);
    if (!session || agent.session !== session) { traceSink('DROP', 'session link', { id, hasSession: !!session, same: agent.session === session }); continue; }
    const header = session.header;
    if (!header || header.id !== id || header.origin === 'subagent' || header.parentSession != null) {
      traceSink('DROP', 'header filter', { id, headerId: header?.id, origin: header?.origin, parentSession: header?.parentSession });
      continue;
    }
    let metadata;
    try {
      const snapshot = projections.snapshot(session, ['sessionListMetadata']);
      metadata = snapshot.values.sessionListMetadata;
      traceSink('SNAPSHOT', { id, seq: session.seq, keys: Object.keys(snapshot.values), blank: metadata?.blank });
    } catch (error) {
      traceSink('DROP', 'snapshot threw', { id, error: String(error?.message ?? error) });
      continue;
    }
    if ((metadata?.blank ?? session.seq === 0) === true) { traceSink('DROP', 'blank', { id, seq: session.seq }); continue; }
    if (agents.get(id) !== agent || agent.status !== 'running') continue;
    const row = { id, cwd: typeof header.cwd === 'string' ? header.cwd : '', running: true, pending: null, title: '' };
    // 待交互附加（同步）：审批卡零延迟上岛
    for (const entry of registry.list(row.id)) {
      const req = entry.request || {};
      row.pending = {
        requestId: req.requestId,
        kind: req.kind,
        toolName: req.toolName || '',
        reason: req.reason || '',
        displayReason: req.displayReason || '',
        questions: Array.isArray(req.questions) ? req.questions : []
      };
      break;
    }
    // 标题先用缓存：审批卡立即有名字
    if (prevRunning.has(row.id)) row.title = prevRunning.get(row.id).title || '';
    result.push(row);
  }
  return result;
}

// 异步标题补全：查询后原地更新，返回标题是否有变化
async function enrichTitles(ctx, rows, signal) {
  try {
    const ids = rows.map(r => r.id);
    if (typeof ctx.get('sessionQuery')?.readTitleSnapshots !== 'function' || ids.length === 0) return false;
    const results = await ctx.get('sessionQuery').readTitleSnapshots(ids, signal);
    const map = new Map();
    // 陷阱（cindy-host 同款）：文本在 value.title.title 两层之下
    for (const row of (Array.isArray(results) ? results : [])) {
      if (row === null || typeof row !== 'object' || row.status !== 'fulfilled') continue;
      let firstPrompt;
      try {
        const session = ctx.get('sessions')?.get(row.sessionId);
        if (session) firstPrompt = ctx.get('sessionProjections')?.stateOf?.(session, 'titleInput')?.first?.text;
      } catch { /* Older projection services still provide the logged title. */ }
      const text = taskTitle(row.value?.title, firstPrompt);
      if (typeof row.sessionId === 'string' && typeof text === 'string' && text.trim() !== '') {
        map.set(row.sessionId, text);
      }
    }
    let changed = false;
    for (const row of rows) {
      const t = map.get(row.id);
      if (t !== undefined && row.title !== t) { row.title = t; changed = true; }
    }
    return changed;
  } catch (e) { return false; }
}
