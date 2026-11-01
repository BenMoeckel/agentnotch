const { test } = require('node:test');
const assert = require('node:assert/strict');
const vm = require('node:vm');
const fs = require('node:fs');
const path = require('node:path');

function fixture() {
  const calls = [];
  const activations = [];
  const commands = new Set(['claude-vscode.editor.open', 'claude-vscode.primaryEditor.open']);
  const failures = new Set();
  const window = { state: { focused: true }, terminals: [], activeTerminal: undefined };
  const terminal = pid => ({ name: 'same project', processId: Promise.resolve(pid), show(preserveFocus) {
    calls.push(['terminal', pid, preserveFocus]); window.activeTerminal = this;
  } });
  window.terminals = [terminal(10), terminal(20)];
  window.activeTerminal = window.terminals[0];
  const extensions = {
    'openai.chatgpt': { activate: async () => { activations.push('openai.chatgpt'); } },
    'anthropic.claude-code': { activate: async () => { activations.push('anthropic.claude-code'); } },
  };
  const vscode = { window, workspace: { workspaceFolders: [{ uri: { fsPath: '/same/project' } }] },
    commands: {
      getCommands: async () => [...commands],
      executeCommand: async (...args) => {
        calls.push(args);
        if (failures.has(args[0])) throw new Error(`${args[0]} failed`);
      },
    },
    extensions: { getExtension: id => extensions[id] },
    Uri: { parse: text => text } };
  const sandbox = { module: { exports: {} }, process, console, setTimeout,
    require: name => name === 'vscode' ? vscode : require(name) };
  vm.runInNewContext(fs.readFileSync(path.join(__dirname, '../integrations/vscode/extension.js'), 'utf8'), sandbox);
  return { ...sandbox.module.exports, calls, activations, commands, failures, extensions, window };
}

test('repeated discovery reads existing terminal metadata without executing commands', async () => {
  const f = fixture();
  for (let i = 0; i < 5; i++) {
    const result = await f.handle({ method: 'snapshot' });
    assert.deepEqual(Array.from(result.terminals, t => t.pid), [10, 20]);
    assert.equal(result.terminals[0].focused, true);
  }
  assert.equal(f.calls.length, 0);
});

test('focus selects the exact existing terminal despite identical project names', async () => {
  const f = fixture();
  assert.equal((await f.handle({ method: 'focus', terminalPID: 20 })).selected, true);
  assert.equal(f.window.activeTerminal, f.window.terminals[1]);
  assert.deepEqual(f.calls, [['workbench.action.focusWindow'], ['terminal', 20, false]]);
  f.window.terminals.pop();
  await assert.rejects(f.handle({ method: 'focus', terminalPID: 20 }), /no longer available/);
});

test('only the active Codex conversation in the foreground window is reported as read', async () => {
  const f = fixture();
  const sessionID = '01a15a77-f597-73c0-9fb1-e49b712cb123';
  const tab = { isActive: true, input: { viewType: 'chatgpt.conversationEditor', uri: {
    scheme: 'openai-codex', authority: 'route', path: `/local/${sessionID}`,
  } } };
  f.window.tabGroups = { activeTabGroup: { activeTab: tab } };
  assert.equal((await f.handle({ method: 'snapshot' })).focusedCodexSessionID, sessionID);
  f.window.state.focused = false;
  assert.equal((await f.handle({ method: 'snapshot' })).focusedCodexSessionID, null);
  f.window.state.focused = true;
  tab.isActive = false;
  assert.equal((await f.handle({ method: 'snapshot' })).focusedCodexSessionID, null);
  tab.isActive = true;
  for (const input of [undefined, { viewType: 'other', uri: tab.input.uri },
    { ...tab.input, uri: { ...tab.input.uri, path: '/local/invalid' } },
    { ...tab.input, uri: { ...tab.input.uri, authority: 'other' } }]) {
    const original = tab.input;
    tab.input = input;
    assert.equal((await f.handle({ method: 'snapshot' })).focusedCodexSessionID, null);
    tab.input = original;
  }
  assert.equal(f.calls.length, 0, 'Visibility checks must never select a conversation');
});

test('Codex navigation addresses the existing conversation editor', async () => {
  const f = fixture();
  const sessionID = '01a15a77-f597-73c0-9fb1-e49b712cb123';
  assert.equal((await f.handle({ method: 'focus', kind: 'codex', sessionID })).selected, true);
  assert.equal(f.calls[1][0], 'vscode.openWith');
  assert.equal(f.calls[1][1], `openai-codex://route/local/${sessionID}`);
  assert.equal(f.calls[1][2], 'chatgpt.conversationEditor');
});

test('Claude navigation opens the exact conversation in this window', async () => {
  const f = fixture();
  const sessionID = '0c09116a-0e23-42ae-94dd-109cdd919e99';
  assert.equal((await f.handle({ method: 'focus', kind: 'claude', sessionID })).selected, true);
  assert.deepEqual(f.activations, ['anthropic.claude-code']);
  assert.equal(f.calls[0][0], 'workbench.action.focusWindow');
  assert.equal(f.calls[1][0], 'claude-vscode.editor.open');
  assert.equal(f.calls[1][1], sessionID);
  assert.equal(f.calls[1][6].programmatic, 'honor-preferred-location');
});

test('Claude navigation falls back to the primary editor command', async () => {
  const f = fixture();
  f.commands.delete('claude-vscode.editor.open');
  const sessionID = '0c09116a-0e23-42ae-94dd-109cdd919e99';
  assert.equal((await f.handle({ method: 'focus', kind: 'claude', sessionID })).selected, true);
  assert.equal(f.calls[1][0], 'claude-vscode.primaryEditor.open');
  assert.equal(f.calls[1][1], sessionID);
});

test('the bridge rejects arbitrary commands and malformed session targets', async () => {
  const f = fixture();
  await assert.rejects(f.handle({ method: 'executeCommand', command: 'anything' }), /Unsupported/);
  await assert.rejects(f.handle({ method: 'focus', kind: 'codex', sessionID: '../other' }), /no exact session/);
  await assert.rejects(f.handle({ method: 'focus', kind: 'claude' }), /no exact session/);
  await assert.rejects(f.handle({ method: 'focus', kind: 'claude', sessionID: '../other' }), /no exact session/);
  delete f.extensions['anthropic.claude-code'];
  await assert.rejects(f.handle({ method: 'focus', kind: 'claude', sessionID: '0c09116a-0e23-42ae-94dd-109cdd919e99' }),
    /not installed/);
  assert.equal(f.calls.length, 0);
});
