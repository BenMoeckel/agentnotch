const vscode = require('vscode');
const fs = require('node:fs');
const path = require('node:path');
const os = require('node:os');
const net = require('node:net');

async function snapshot() {
  const terminals = await Promise.all(vscode.window.terminals.map(async terminal => ({
    pid: await Promise.race([terminal.processId, new Promise(resolve => setTimeout(() => resolve(undefined), 500))]),
    name: terminal.name,
    focused: vscode.window.state.focused && vscode.window.activeTerminal === terminal,
  })));
  const tab = vscode.window.tabGroups?.activeTabGroup?.activeTab;
  const input = tab?.input;
  const uri = input?.uri;
  const match = vscode.window.state.focused && tab?.isActive &&
    input?.viewType === 'chatgpt.conversationEditor' && uri?.scheme === 'openai-codex' &&
    uri.authority === 'route' && /^\/local\/([a-zA-Z0-9-]{16,80})$/.exec(uri.path);
  return { pid: process.pid, folders: (vscode.workspace.workspaceFolders || []).map(folder => folder.uri.fsPath),
    focusedCodexSessionID: match ? match[1] : null,
    focused: vscode.window.state.focused, terminals: terminals.filter(terminal => terminal.pid) };
}

async function handle(request) {
  if (request.method === 'snapshot') return snapshot();
  if (request.method !== 'focus') throw new Error('Unsupported request');
  if (Number.isSafeInteger(request.terminalPID)) {
    const terminals = await Promise.all(vscode.window.terminals.map(async terminal => ({ terminal, pid: await terminal.processId })));
    const matches = terminals.filter(terminal => terminal.pid === request.terminalPID);
    if (matches.length !== 1) throw new Error('The terminal session is no longer available.');
    await vscode.commands.executeCommand('workbench.action.focusWindow');
    matches[0].terminal.show(false);
    if (vscode.window.activeTerminal !== matches[0].terminal) {
      await new Promise(resolve => setTimeout(resolve, 100));
      if (vscode.window.activeTerminal !== matches[0].terminal) throw new Error('The terminal could not be selected.');
    }
    return { selected: true };
  }
  if (typeof request.sessionID !== 'string' || !/^[a-zA-Z0-9-]{16,80}$/.test(request.sessionID)) {
    throw new Error('This agent has no exact session target.');
  }
  if (request.kind === 'codex') {
    const extension = vscode.extensions.getExtension('openai.chatgpt');
    if (!extension) throw new Error('The Codex extension is not installed in this window.');
    await extension.activate();
    await vscode.commands.executeCommand('workbench.action.focusWindow');
    await vscode.commands.executeCommand('vscode.openWith',
      vscode.Uri.parse(`openai-codex://route/local/${request.sessionID}`), 'chatgpt.conversationEditor',
      { preserveFocus: false, preview: false });
    return { selected: true };
  }
  if (request.kind === 'claude') {
    const extension = vscode.extensions.getExtension('anthropic.claude-code');
    if (!extension) throw new Error('The Claude Code extension is not installed in this window.');
    await extension.activate();
    const commands = await vscode.commands.getCommands(true);
    await vscode.commands.executeCommand('workbench.action.focusWindow');
    if (commands.includes('claude-vscode.editor.open')) {
      await vscode.commands.executeCommand('claude-vscode.editor.open', request.sessionID,
        undefined, undefined, undefined, false, { programmatic: 'honor-preferred-location' });
    } else if (commands.includes('claude-vscode.primaryEditor.open')) {
      await vscode.commands.executeCommand('claude-vscode.primaryEditor.open', request.sessionID);
    } else {
      throw new Error('The Claude Code extension cannot open conversations in this window.');
    }
    return { selected: true };
  }
  throw new Error('This agent has no exact session target.');
}

function activate(context) {
  if (process.platform !== 'darwin') return;
  const directory = path.join(os.homedir(), 'Library/Application Support/AgentNotch/editors');
  const socketDirectory = path.join(os.tmpdir(), `an-${process.getuid()}`);
  fs.mkdirSync(directory, { recursive: true, mode: 0o700 });
  fs.mkdirSync(socketDirectory, { recursive: true, mode: 0o700 });
  const socketPath = path.join(socketDirectory, `vscode-${process.pid}.sock`);
  const descriptor = path.join(directory, `${process.pid}.json`);
  const server = net.createServer(socket => {
    let buffer = '';
    socket.setTimeout(3000, () => socket.destroy());
    socket.on('error', () => {});
    socket.on('data', async chunk => {
      buffer += chunk.toString('utf8');
      if (buffer.length > 16384) { socket.destroy(); return; }
      const end = buffer.indexOf('\n');
      if (end === -1) return;
      socket.removeAllListeners('data');
      try { socket.end(JSON.stringify({ ok: true, result: await handle(JSON.parse(buffer.slice(0, end))) }) + '\n'); }
      catch (error) { socket.end(JSON.stringify({ ok: false, error: String(error.message || error) }) + '\n'); }
    });
  });
  server.on('error', error => console.error('AgentNotch bridge:', error.message));
  server.listen(socketPath, () => {
    fs.chmodSync(socketPath, 0o600);
    fs.writeFileSync(descriptor, JSON.stringify({ pid: process.pid, socketPath }), { mode: 0o600 });
  });
  context.subscriptions.push({ dispose() {
    server.close();
    for (const file of [descriptor, socketPath]) { try { fs.unlinkSync(file); } catch {} }
  }});
}
module.exports = { activate, handle };
