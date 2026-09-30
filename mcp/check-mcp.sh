#!/bin/zsh
set -euo pipefail
ROOT="${0:A:h}"
WORK=$(mktemp -d /private/tmp/jpmcp.XXXXXX)
trap 'rm -rf "$WORK"' EXIT
cat > "$WORK/cli" <<'JS'
#!/usr/bin/env node
if (process.argv[2] === 'mcp-manifest') {
 console.log(JSON.stringify({serverInfo:{name:'fake',version:'1.0.0'},tools:[{name:'status',description:'Status',command:['status'],inputSchema:{type:'object',properties:{path:{type:'string'},show:{type:'boolean'}}}},{name:'fail',description:'Fail',command:['fail'],inputSchema:{type:'object',properties:{}}}]}));
} else { console.log(JSON.stringify(process.argv.slice(2))); if(process.argv.includes('fail')) process.exitCode=1; }
JS
chmod +x "$WORK/cli"
cat > "$WORK/input" <<'JSON'
{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18"}}
{"jsonrpc":"2.0","method":"notifications/initialized"}
{"jsonrpc":"2.0","id":2,"method":"tools/list"}
{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"status","arguments":{"path":"a b;$(touch unwanted)","show":true}}}
{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"fail"}}
{"jsonrpc":"2.0","id":5,"method":"ping"}
JSON
JUNIORPROMPTER_CLI="$WORK/cli" node "$ROOT/juniorprompter-mcp.mjs" --data-directory /tmp/isolated < "$WORK/input" > "$WORK/output"
node --input-type=module - "$WORK/output" <<'JS'
import assert from 'node:assert/strict'; import fs from 'node:fs';
const r=fs.readFileSync(process.argv[2],'utf8').trim().split('\n').map(JSON.parse);
assert.deepEqual(r.map(x=>x.id),[1,2,3,4,5]);
assert.equal(r[0].result.protocolVersion,'2025-06-18');
assert.deepEqual(r[1].result.tools.map(t=>t.name),['status','fail']);
assert.ok(r[1].result.tools.every(t=>!('command' in t)));
assert.deepEqual(JSON.parse(r[2].result.content[0].text),['--data-directory','/tmp/isolated','status','--path','a b;$(touch unwanted)','--show','--json']);
assert.equal(r[2].result.isError,false); assert.equal(r[3].result.isError,true); assert.deepEqual(r[4].result,{});
console.log('MCP check passed (initialize, list, argv, failures, ping).');
JS
