/* Desktop navigation and approval companion; uses the native DSH approval owner. */
window.__ModuleLoader__.load({
  id: 'dsh-island-bridge',
  factory: function () {
    return {
      inject: ['uiWorkspace', 'uiSession'],
      apply: function (ctx) {
        if (window.location.protocol !== 'dsh-app:') return;
        ctx.effect(function () {
          var controller = new AbortController();
          var lastOpened = null;
          var workspace = ctx.get('uiWorkspace');
          async function revealMessage(command) {
            if (!command.nodeKey) return true;
            var selector = '[data-chat-node-key="' + CSS.escape(command.nodeKey) + '"]';
            var deadline = performance.now() + 2400;
            var expandedButtons = new Set();
            while (!controller.signal.aborted && performance.now() < deadline) {
              if (workspace.selection?.getSnapshot().sessionId !== command.sessionId) return false;
              var nodes = document.querySelectorAll(selector);
              var node = Array.from(nodes).find(el => !el.closest('[hidden], [inert], [data-turn-process-hidden]') &&
                el.getBoundingClientRect().height > 0);
              if (node) {
                node.scrollIntoView({ block: 'center', behavior: 'smooth' });
                return true;
              }
              var hidden = Array.from(nodes).find(el => el.closest('[data-turn-process-hidden]'));
              var turn = hidden?.closest('[data-chat-turn]')?.getAttribute('data-chat-turn');
              if (turn) {
                var toggle = document.querySelector('button[data-turn-process="' + CSS.escape(turn) + '"][aria-expanded="false"]:not(:disabled)');
                if (toggle && !expandedButtons.has(toggle)) { expandedButtons.add(toggle); toggle.click(); }
              }
              await new Promise(resolve => setTimeout(resolve, 65));
            }
            return false;
          }
          async function run() {
            while (!controller.signal.aborted) {
              try {
                var response = await fetch('/api/island-navigation/wait', {
                  signal: controller.signal, credentials: 'same-origin', cache: 'no-store'
                });
                if (!response.ok) throw new Error('navigation HTTP ' + response.status);
                var data = await response.json();
                var command = data && data.open;
                if (!command) continue;
                var result = { id: command.id, sessionId: command.sessionId, ok: false };
                try {
                  if (lastOpened !== command.id) {
                    await Promise.resolve(workspace.openSession(command.sessionId));
                    var selected = workspace.selection && workspace.selection.getSnapshot();
                    if (selected && selected.sessionId !== command.sessionId) throw new Error('session was not selected');
                    lastOpened = command.id;
                    if (!await revealMessage(command)) result.reason = 'message-node-unavailable';
                  }
                  result.ok = true;
                } catch (error) { result.reason = String(error); }
                var ack = await fetch('/api/island-navigation/ack', {
                  method: 'POST', signal: controller.signal, credentials: 'same-origin', cache: 'no-store',
                  headers: { 'content-type':'application/json' }, body: JSON.stringify(result)
                });
                if (!ack.ok) throw new Error('navigation acknowledgement HTTP ' + ack.status);
                if (!result.ok) console.warn('[island-bridge] could not open conversation:', result.reason);
              } catch (error) {
                if (controller.signal.aborted) break;
                console.warn('[island-bridge] navigation reconnect:', String(error));
                await new Promise(function (resolve) {
                  var done = function () { clearTimeout(timer); controller.signal.removeEventListener('abort',done); resolve(); };
                  var timer = setTimeout(done,1000);
                  controller.signal.addEventListener('abort',done,{once:true});
                });
              }
            }
          }
          void run();
          return function () { controller.abort(); };
        }, 'island-bridge: desktop conversation navigation');
        var uiSession = ctx.get('uiSession');
        if (!uiSession?.sessionStatus) return;
        ctx.effect(function () {
          var controller = new AbortController();
          var prepared = new Map();
          function pendingFor(command) {
            return uiSession.sessionStatus.getSnapshot().get(command.sessionId)?.pendingInteraction;
          }
          function matchesPending(command, pending) {
            if (!pending || pending.callId !== command.callId) return false;
            if (command.kind === 'ask_user_question') {
              var state = pending.getSnapshot?.();
              return ['question', 'plan-review'].includes(pending.kind) && state && !state.closed && state.channel === 'waterfall' &&
                JSON.stringify(pending.questions.map(q => [q.id, q.question, (q.options ?? []).map(option => option.label)]))
                  === command.questionIdentity;
            }
            return pending.kind === 'approval' && pending.answerable && pending.toolName === command.toolName &&
              (pending.reason || '') === (command.reason || '');
          }
          async function runApprovals() {
            while (!controller.signal.aborted) {
              try {
                var response = await fetch('/api/island-approval/wait', {
                  signal: controller.signal, credentials: 'same-origin', cache: 'no-store'
                });
                if (!response.ok) throw new Error('approval relay HTTP ' + response.status);
                var command = (await response.json()).command;
                if (!command) continue;
                var result = { id: command.id, phase: command.phase, ok: false };
                var pending = pendingFor(command);
                if (!Number.isFinite(command.expiresAt) || Date.now() >= command.expiresAt) {
                  prepared.delete(command.id);
                } else if (command.phase === 'prepare') {
                  if (matchesPending(command, pending)) {
                    prepared.set(command.id, { pending: pending, answered: false });
                    if (prepared.size > 128) prepared.delete(prepared.keys().next().value);
                    result.key = pending.key; result.ok = true;
                  }
                } else if (command.phase === 'commit') {
                  var binding = prepared.get(command.id);
                  if (binding?.answered) result.ok = true;
                  else if (binding && binding.pending === pending && pending.key === command.key && matchesPending(command, pending)) {
                    await pending.answer(command.kind === 'ask_user_question' ? command.answer : command.outcome);
                    binding.answered = true;
                    result.ok = true;
                  }
                }
                var ack = await fetch('/api/island-approval/ack', {
                  method: 'POST', signal: controller.signal, credentials: 'same-origin', cache: 'no-store',
                  headers: { 'content-type': 'application/json' }, body: JSON.stringify(result)
                });
                if (!ack.ok) throw new Error('approval acknowledgement HTTP ' + ack.status);
              } catch (error) {
                if (controller.signal.aborted) break;
                console.warn('[island-bridge] approval relay reconnect:', String(error));
                await new Promise(function (resolve) {
                  var done = function () { clearTimeout(timer); controller.signal.removeEventListener('abort',done); resolve(); };
                  var timer = setTimeout(done,1000);
                  controller.signal.addEventListener('abort',done,{once:true});
                });
              }
            }
          }
          void runApprovals();
          return function () { controller.abort(); prepared.clear(); };
        }, 'island-bridge: shared DSH approval owner');

      }
    };
  }
});
