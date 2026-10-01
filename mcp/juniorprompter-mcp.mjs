#!/usr/bin/env node
// This built-ins-only shim is copied into each app on purpose.
import { createInterface } from 'node:readline';
import { execFile } from 'node:child_process';
import { existsSync } from 'node:fs';
import { resolve, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
const bundled = resolve(dirname(fileURLToPath(import.meta.url)), '../../Helpers/juniorprompter');
const cli = process.env.JUNIORPROMPTER_CLI || (existsSync(bundled) ? bundled : 'juniorprompter');
const options = process.argv.slice(2);
const run = args => new Promise(resolve => execFile(cli, args, { timeout: 45000, maxBuffer: 20 * 1024 * 1024 }, (error, stdout, stderr) => resolve({ error, stdout, stderr })));
const start = await run(['mcp-manifest']);
let manifest;
try {
  if (start.error) throw start.error;
  manifest = JSON.parse(start.stdout);
  if (!Array.isArray(manifest.tools)) throw new Error('Manifest lacks tools');
} catch (error) { console.error(`Cannot read CLI manifest: ${error.message}`); process.exit(1); }
const send = value => process.stdout.write(JSON.stringify({ jsonrpc: '2.0', ...value }) + '\n');
async function handle(line) {
  let request;
  try { request = JSON.parse(line); } catch { send({ id: null, error: { code: -32700, message: 'Parse error' } }); return; }
  if (!request || request.jsonrpc !== '2.0' || typeof request.method !== 'string' || (Object.hasOwn(request, 'id') && !['string', 'number'].includes(typeof request.id))) { send({ id: null, error: { code: -32600, message: 'Invalid request' } }); return; }
  if (!Object.hasOwn(request, 'id')) return;
  const id = request.id;
  const result = value => send({ id, result: value });
  switch (request.method) {
    case 'initialize': result({ protocolVersion: '2025-06-18', capabilities: { tools: { listChanged: false } }, serverInfo: manifest.serverInfo }); break;
    case 'ping': result({}); break;
    case 'tools/list': result({ tools: manifest.tools.map(({ command, ...tool }) => tool) }); break;
    case 'tools/call': {
      const tool = manifest.tools.find(tool => tool.name === request.params?.name);
      if (!tool) { result({ content: [{ type: 'text', text: 'Unknown tool' }], isError: true }); break; }
      const args = request.params?.arguments ?? {};
      if (typeof args !== 'object' || args === null || Array.isArray(args) || Object.entries(args).some(([key, value]) => !Object.hasOwn(tool.inputSchema.properties, key) || !['string', 'number', 'boolean'].includes(typeof value))) {
        result({ content: [{ type: 'text', text: 'Invalid tool arguments' }], isError: true }); break;
      }
      const argv = [...options, ...tool.command];
      for (const [key, value] of Object.entries(args)) {
        if (typeof value === 'boolean') { if (value) argv.push(`--${key}`); }
        else argv.push(`--${key}=${String(value)}`);
      }
      const reply = await run([...argv, '--json']);
      result({ content: [{ type: 'text', text: reply.stdout.trim() || reply.stderr.trim() || reply.error?.message || '' }], isError: Boolean(reply.error) });
      break;
    }
    default: send({ id, error: { code: -32601, message: 'Method not found' } });
  }
}
// Keep creation requests in arrival order; app requestId handles deliberate retries.
const input = createInterface({ input: process.stdin, crlfDelay: Infinity });
for await (const line of input) { try { await handle(line); } catch (error) { console.error(error.message); send({ id: null, error: { code: -32603, message: 'Internal error' } }); } }
