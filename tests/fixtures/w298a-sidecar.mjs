import readline from 'node:readline';
import { writeFileSync } from 'node:fs';
import { join } from 'node:path';
const sdk = msg => console.log(JSON.stringify({ev:'sdk', msg}));
readline.createInterface({input:process.stdin}).on('line', line => {
  const command = JSON.parse(line);
  if (command.op === 'send') {
    writeFileSync(join(process.env.TATWO2_SELFTEST_ARTIFACTS, 'w298a-command.json'), JSON.stringify(command));
    sdk({type:'system', subtype:'init', session_id:'w298a-fixture', model:command.model});
    sdk({type:'system', subtype:'turn_accepted', client_turn_id:command.uuid});
  }
  if (command.op === 'close') process.exit(0);
}).on('close', () => process.exit(0));
