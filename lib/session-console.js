const UNKNOWN_TITLE = '未命名会话';
const MESSAGE_PREVIEW_LIMIT = 640;
const HISTORY_MESSAGE_LIMIT = 16000;
const HISTORY_PAGE_SIZE = 14;

function consoleMessage(event, limit) {
  if (event?.type !== 'user/message' && event?.type !== 'assistant/message') return null;
  const fromUser = event.type === 'user/message';
  const message = fromUser ? event.data : event.data.message;
  if (fromUser && !['user', 'user-question-reply'].includes(message?.source?.kind)) return null;
  const text = message?.content?.filter(part => part.type === 'text')
    .map(part => part.text).join('\n').trim();
  if (!text) return null;
  const kind = fromUser ? 'input-message' : 'assistant-step';
  const id = fromUser ? message.id : `${event.data.turn}:${event.data.step}`;
  const nodeKey = id == null ? undefined : `${kind.length}:${kind}${id}`;
  const preview = text.length <= limit ? text : text.slice(0, limit).replace(/[\uD800-\uDBFF]$/u, '') + '…';
  return { seq: event.seq, role: fromUser ? 'user' : 'assistant', text: preview, nodeKey };
}

const hasToolCall = event => event?.type === 'assistant/message'
  && event.data.message?.content?.some(block => block.type === 'tool-call');

export function historyMessages(records, newest) {
  const events = records.map(record => record.event);
  const latestStep = new Map();
  const ended = new Set();
  const toolSteps = new Set();
  const results = new Map();
  for (const event of events) {
    const { turn, step } = event?.data ?? {};
    if (Number.isSafeInteger(turn) && Number.isSafeInteger(step)) {
      latestStep.set(turn, Math.max(latestStep.get(turn) ?? 0, step));
    }
    if (event?.type === 'turn/end') ended.add(turn);
    if (event?.type === 'tool/call' || hasToolCall(event)) toolSteps.add(`${turn}:${step}`);
    if (event?.type === 'tool/result') {
      const message = event.data.message;
      results.set(message?.source?.callId, message?.isError ? 'error' : 'done');
    }
  }
  return events.flatMap(event => {
    const { turn, step } = event?.data ?? {};
    if (event?.type === 'tool/call' && typeof event.data.name === 'string') {
      return [{ seq: event.seq, role: 'assistant', kind: 'tool', turn,
        text: event.data.name.slice(0, 100), outcome: results.get(event.data.callId) }];
    }
    if (event?.surfaceOp && event.surfaceOp !== 'append') return [];
    const message = consoleMessage(event, HISTORY_MESSAGE_LIMIT);
    if (!message) return [];
    const inProcess = event.type === 'assistant/message' && (
      toolSteps.has(`${turn}:${step}`) ||
      (Number.isSafeInteger(turn) && (!newest && !ended.has(turn) || step < latestStep.get(turn)))
    );
    return [{ ...message, ...(inProcess ? { kind: 'process', turn } : {}) }];
  });
}

export function readConsoleDetail(session, projections) {
  const messages = [];
  const nodes = session.surface?.nodes ?? [];
  let lastActivityAt = 0;
  for (let index = nodes.length - 1; index >= 0 && messages.length < 2; index--) {
    const event = session.eventAt(nodes[index]);
    const message = consoleMessage(event, MESSAGE_PREVIEW_LIMIT);
    if (message && Number.isFinite(event.time)) lastActivityAt = Math.max(lastActivityAt, event.time);
    if (message && !hasToolCall(event)) messages.push(message);
  }
  const state = key => {
    try { return projections?.stateOf?.(session, key); } catch { return undefined; }
  };
  const usage = state('tokenUsage')?.totals;
  const buckets = usage && [usage.uncachedInputTokens, usage.outputTokens, usage.cacheReadTokens, usage.cacheWriteTokens];
  const tokens = buckets?.every(Number.isFinite) ? buckets.reduce((sum, value) => sum + value, 0) : undefined;
  const pressure = state('contextPressure');
  const used = pressure?.projectedTokens ?? pressure?.pressureTokens;
  const limit = pressure?.contextWindow;
  const remaining = Number.isFinite(used) && Number.isFinite(limit) && limit > 0
    ? 100 - Math.max(0, Math.min(100, Math.round(used / limit * 100))) : undefined;
  const first = state('titleInput')?.first?.text;
  return { messages: messages.reverse(), tokens, remaining, first, lastActivityAt };
}

export function selectRecent(active, catalog) {
  const rows = new Map();
  for (const item of catalog) {
    if (item.blank || item.origin === 'subagent' || item.parentSessionId != null || item.formatStatus === 'migration-required') continue;
    rows.set(item.sessionId, {
      id: item.sessionId, running: item.running === true, updatedAt: item.updatedAt ?? 0,
    });
  }
  for (const row of active) rows.set(row.id, { ...rows.get(row.id), ...row });
  return [...rows.values()]
    .sort((a, b) => Number(Boolean(b.pending)) - Number(Boolean(a.pending))
      || Number(Boolean(b.running)) - Number(Boolean(a.running))
      || (b.updatedAt ?? 0) - (a.updatedAt ?? 0) || a.id.localeCompare(b.id))
    .slice(0, 3);
}

export function createSessionConsole(ctx, enrichTitles) {
  let catalog = [];
  let catalogAt = -Infinity;
  let catalogReady = false;
  const shownIds = new Set();
  const cards = new Map();
  let refreshing = false;
  const prompts = new Map();

  async function snapshot(active, onUpdate = () => {}) {
    if (refreshing) return;
    refreshing = true;
    try {
      const sessions = ctx.get('sessions');
      const query = ctx.get('sessionQuery');
      const projections = ctx.get('sessionProjections');
      const liveRows = sessions.list?.().flatMap(session => {
        const header = session.header;
        if (!header?.id || header.origin === 'subagent' || header.parentSession != null) return [];
        try {
          const metadata = projections.stateOf(session, 'sessionListMetadata');
          if (!metadata || metadata.blank) return [];
          return [{ sessionId: header.id, updatedAt: metadata.lastPromptAt ?? header.createdAt ?? 0 }];
        } catch { return []; }
      }) ?? [];
      const listRows = () => {
        const known = new Map(catalog.map(row => [row.sessionId, row]));
        for (const row of liveRows) {
          const existing = known.get(row.sessionId);
          known.set(row.sessionId, { ...existing, ...row, updatedAt: Math.max(existing?.updatedAt ?? 0, row.updatedAt) });
        }
        return selectRecent(active, [...known.values()]);
      };
      const emit = (rows, state) => {
        const output = rows.map(row => {
          const card = cards.get(row.id) ?? {};
          const { first, title, ...detail } = card;
          return { ...row, ...detail, title: title || row.title || first?.slice(0, 140) || UNKNOWN_TITLE,
            lastActivityAt: Math.max(row.updatedAt ?? 0, detail.lastActivityAt ?? 0) };
        });
        for (const { id } of output) {
          shownIds.delete(id);
          shownIds.add(id);
        }
        while (shownIds.size > 24) shownIds.delete(shownIds.values().next().value);
        onUpdate(output, state);
        return output;
      };
      const needsCatalog = Date.now() - catalogAt >= 2500;
      if (needsCatalog) {
        emit(listRows(), catalogReady ? 'ready' : 'loading');
        try {
          const controller = ctx.get('sessionController');
          if (typeof controller?.list === 'function') {
            const result = await controller.list({}, AbortSignal.timeout(3500));
            catalog = Array.isArray(result?.items) ? result.items : [];
          }
          catalogReady = true;
        } catch { /* Retain the last available catalog. */ }
        catalogAt = Date.now();
      }
      const rows = listRows();
      const state = catalogReady || rows.length > 0 ? 'ready' : 'unavailable';
      emit(rows, state);

      const titles = rows.map(row => ({ ...row, title: '' }));
      const signal = AbortSignal.timeout(5000);
      const titleUpdate = Promise.resolve().then(() => enrichTitles(ctx, titles, signal)).then(() => {
        for (const { id, title } of titles) {
          if (title) cards.set(id, { ...cards.get(id), title });
        }
        emit(rows, state);
      }).catch(() => {});
      await Promise.all([titleUpdate, ...rows.map(async row => {
        try {
          const live = sessions.get(row.id);
          const read = session => readConsoleDetail(session, projections);
          const detail = live ? read(live) : await query.inspectSession(row.id, read, signal);
          cards.set(row.id, { ...detail, title: cards.get(row.id)?.title });
          emit(rows, state);
        } catch { /* Previously loaded metadata remains visible. */ }
      })]);
      for (const id of cards.keys()) if (!shownIds.has(id)) cards.delete(id);
      return emit(rows, state);
    } finally {
      refreshing = false;
    }
  }

  async function history({ sessionId, beforeSeq }) {
    if (!shownIds.has(sessionId) ||
        (beforeSeq !== undefined && (!Number.isSafeInteger(beforeSeq) || beforeSeq <= 0))) return null;
    const controller = ctx.get('sessionController');
    if (typeof controller?.events !== 'function') return null;
    const signal = AbortSignal.timeout(6500);
    try {
      const page = await controller.events({
        address: { kind: 'session', sessionId },
        maxMessages: HISTORY_PAGE_SIZE,
        ...(beforeSeq === undefined ? {} : { beforeSeq }),
      }, signal);
      const records = page.records ?? [];
      const messages = historyMessages(records, beforeSeq === undefined);
      const first = records[0]?.event?.seq;
      const nextBefore = page.hasMore && Number.isSafeInteger(first) && first > 0 &&
        (beforeSeq === undefined || first < beforeSeq) ? first : null;
      return { messages, nextBefore };
    } catch {
      return null;
    }
  }

  async function send({ requestId, sessionId, text }) {
    if (typeof requestId !== 'string' || !/^[\da-f-]{36}$/i.test(requestId) ||
      typeof text !== 'string' || !text.trim() || text.length > 4000) return false;
    const known = prompts.get(requestId);
    if (known) return known.sessionId === sessionId && known.result;
    if (!shownIds.has(sessionId)) return false;
    const controller = ctx.get('sessionController');
    if (typeof controller?.prompt !== 'function') return false;
    const result = Promise.resolve().then(async () => {
      try {
        const response = await controller.prompt({ sessionId, requestId, mode: 'queue',
          content: [{ type: 'text', text: text.trim() }] }, AbortSignal.timeout(12000));
        return response?.accepted === true;
      } catch { return false; }
    });
    prompts.set(requestId, { sessionId, result });
    if (prompts.size > 128) prompts.delete(prompts.keys().next().value);
    return result;
  }

  return { snapshot, send, history };
}
