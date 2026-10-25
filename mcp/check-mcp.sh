#!/bin/zsh
set -euo pipefail
ROOT="${0:A:h}"
WORK=$(mktemp -d /private/tmp/vpmcp.XXXXXX)
trap 'rm -rf "$WORK"' EXIT
cat > "$WORK/cli" <<'JS'
#!/usr/bin/env node
if (process.argv[2] === 'mcp-manifest') {
 console.log(JSON.stringify({serverInfo:{name:'fake',version:'1.0.0'},tools:[{name:'status',description:'Status',command:['status'],inputSchema:{type:'object',properties:{path:{type:'string'},show:{type:'boolean'}}}},{name:'fail',description:'Fail',command:['fail'],inputSchema:{type:'object',properties:{}}},{name:'settings_set',description:'Settings',command:['settings','set'],inputSchema:{type:'object',properties:{speed:{type:'integer'},textSize:{type:'integer'}}}},{name:'record_start',description:'Record',command:['record','start'],inputSchema:{type:'object',properties:{yes:{type:'boolean'}},required:['yes']}}]}));
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
{"jsonrpc":"2.0","id":6,"method":"tools/call","params":{"name":"settings_set","arguments":{"speed":150,"textSize":60}}}
{"jsonrpc":"2.0","id":7,"method":"tools/call","params":{"name":"record_start","arguments":{"yes":false}}}
{"jsonrpc":"2.0","id":8,"method":"tools/call","params":{"name":"settings_set","arguments":{"colour":"#fff"}}}
{"jsonrpc":"2.0","id":{},"method":"ping"}
JSON
VIDEOPROMPTER_CLI="$WORK/cli" node "$ROOT/videoprompter-mcp.mjs" --data-directory /tmp/isolated < "$WORK/input" > "$WORK/output"
node --input-type=module - "$WORK/output" <<'JS'
import assert from 'node:assert/strict'; import fs from 'node:fs';
const r=fs.readFileSync(process.argv[2],'utf8').trim().split('\n').map(JSON.parse);
assert.deepEqual(r.map(x=>x.id),[1,2,3,4,5,6,7,8,null]);
assert.equal(r[0].result.protocolVersion,'2025-06-18');
assert.deepEqual(r[1].result.tools.map(t=>t.name),['status','fail','settings_set','record_start']);
assert.ok(r[1].result.tools.every(t=>!('command' in t)));
assert.deepEqual(JSON.parse(r[2].result.content[0].text),['--data-directory','/tmp/isolated','status','--path=a b;$(touch unwanted)','--show','--json']);
assert.equal(r[2].result.isError,false); assert.equal(r[3].result.isError,true); assert.deepEqual(r[4].result,{});
// Numbers pass as --name=value; a false boolean is left out, so the CLI itself refuses a missing --yes.
assert.deepEqual(JSON.parse(r[5].result.content[0].text),['--data-directory','/tmp/isolated','settings','set','--speed=150','--textSize=60','--json']);
assert.deepEqual(JSON.parse(r[6].result.content[0].text),['--data-directory','/tmp/isolated','record','start','--json']);
assert.equal(r[7].result.isError,true); assert.equal(r[7].result.content[0].text,'Invalid tool arguments');
assert.equal(r[8].error.code,-32600);
console.log('MCP check passed (initialize, list, argv, numbers, booleans, failures, ping, invalid id).');
JS
