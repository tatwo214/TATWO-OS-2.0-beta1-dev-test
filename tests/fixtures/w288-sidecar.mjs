// In-memory native-engine surrogate. Keeps a real turn open until Stop.
import readline from 'node:readline';
const sdk = msg => console.log(JSON.stringify({ev: 'sdk', msg}));
let turn;
readline.createInterface({input: process.stdin}).on('line', line => {
  const command = JSON.parse(line);
  if (command.op === 'send') {
    turn = command.uuid;
    sdk({type: 'system', subtype: 'init', session_id: 'w288-fixture', model: 'fixture'});
    sdk({type: 'system', subtype: 'turn_accepted', client_turn_id: turn});
    sdk({type: 'stream_event', client_turn_id: turn,
      event: {type: 'content_block_delta', delta: {type: 'text_delta', text: '隔離測試回覆'}}});
  } else if (command.op === 'interrupt') {
    sdk({type: 'result', client_turn_id: turn, subtype: 'cancelled', is_error: false, result: ''});
  } else if (command.op === 'close') process.exit(0);
}).on('close', () => process.exit(0));
