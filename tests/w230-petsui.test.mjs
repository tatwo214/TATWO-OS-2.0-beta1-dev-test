import test from 'node:test';
import assert from 'node:assert/strict';
import {readFileSync, readdirSync, mkdirSync, writeFileSync, existsSync, realpathSync} from 'node:fs';
import {spawnSync, execFileSync} from 'node:child_process';
import {fileURLToPath} from 'node:url';
import path from 'node:path';
import {testScratch} from './helpers/test-scratch.mjs';

const checkout = fileURLToPath(new URL('..', import.meta.url));
const read = file => readFileSync(path.join(checkout,file),'utf8');
const src = 'App/Sources/Tatwo2/';
const ui = src+'Pets/UI/';
test('W230b replaceable PetSkin owns colors and visual measurements', () => {
  const skin = read(ui+'PetSkin.swift');
  for(const token of ['canvas','card','ink','muted','accent','radius','avatarRadius','shadowRadius','gap','inset','title','detail']) assert.ok(skin.includes(token),token);
  assert.match(skin,/TatwoActivePalette.current/);
  for(const file of readdirSync(path.join(checkout,ui)).filter(f=>f!=='PetSkin.swift')) {
    const text = read(ui+file);
    assert.doesNotMatch(text,/Color\s*\(|Color\.(?:red|blue|green|black|white)|\.(?:foregroundStyle|background|tint)\(\.(?:red|blue|green|black|white|primary|secondary)/,file);
    assert.doesNotMatch(text,/\.(?:padding|frame|font|opacity|cornerRadius|shadow)\([^\n)]*\b\d+(?:\.\d+)?\b/,file);
  }
  assert.match(read(ui+'PetsRootView.swift'),/@ObservedObject private var theme = TatwoThemeStore.shared/);
});
test('W230b UI uses only public pet APIs and shared transcript; no Coder selection changes', () => {
  const text = readdirSync(path.join(checkout,ui)).map(f=>read(ui+f)).join('\n');
  assert.doesNotMatch(text,/pets\.json|teams\.json|hall-of-fame\.json|document\.json|PetStore\.(?:write|directory|safe)|FileManager|OSEventLog|localLiveForBridge/);
  assert.doesNotMatch(text,/selectedThreadID\s*=|model\.select\(|newProject\(|newThread\(|URLSession|SecItem/);
  for(const api of ['saveTeams','move','saveHall','avatarPNG','chooseAvatar','uploadAvatar','updatePersonality','chat.export','chat.send','chat.profile','chat.sessions']) assert.ok(text.includes(api),api);
  assert.match(text,/GlobalDMMessageList/); assert.match(text,/model.dmTranscript/);
  const before = execFileSync('git',['ls-tree','-r','--name-only','a22eab36',src+'Bot'],{cwd:checkout,encoding:'utf8'}).trim().split('\n').filter(Boolean);
  assert.ok(before.length > 0);
  for(const file of before) { assert.ok(existsSync(path.join(checkout,file)),file); assert.equal(read(file),execFileSync('git',['show',`a22eab36:${file}`],{cwd:checkout,encoding:'utf8'})); }
  for(const match of text.matchAll(/accessibilityIdentifier\("([^"\n]+)/g)) assert.ok(match[1].startsWith('tatwo.pets.'),match[1]);
});
test('W230b w230petsui native acceptance and all screens in supported theme appearances', {timeout:180000}, () => {
  const binary = process.env.TATWO2_TEST_BINARY; assert.ok(binary && existsSync(binary),'TATWO2_TEST_BINARY is required');
  const root = realpathSync(testScratch('w230-ui-native-'));
  for(const dir of ['home','live','engines/codex','engines/claude','os','docs','artifacts']) mkdirSync(path.join(root,dir),{recursive:true});
  const env = {...process.env, HOME:`${root}/home`, CFFIXED_USER_HOME:`${root}/home`, TATWO_STAGING_SCRATCH_HOME:`${root}/home`, TATWO_STAGING_ROOT:root,
    TATWO2_LIVE_ROOT:`${root}/live`,TATWO2_ENGINES_ROOT:`${root}/engines`, CODEX_HOME:`${root}/engines/codex`,TATWO2_CODEX_SOURCE_HOME:`${root}/engines/codex`,
    CLAUDE_CONFIG_DIR:`${root}/engines/claude`,CLAUDE_SECURESTORAGE_CONFIG_DIR:`${root}/engines/claude`,TATWO2_OS_SOCKET:`${root}/o.sock`,TATWO2_BROWSER_SOCKET:`${root}/b.sock`,
    TATWO2_OS_ROOT:`${root}/os`,TATWO2_DOCS_ROOT:`${root}/docs`,TATWO2_OS_UPSTREAM_PATH:`${root}/os/os-upstream.md`,TATWO2_SKILLET_PATH:`${root}/os/skillet.md`,
    TATWO2_SELFTEST:'w230petsui',TATWO2_SELFTEST_ARTIFACTS:`${root}/artifacts`};
  const run = spawnSync(binary,[],{env,encoding:'utf8',timeout:170000,maxBuffer:8*1024*1024});
  const output = (run.stdout??'')+(run.stderr??''); writeFileSync(`${root}/result.log`,output);
  console.log(`W230b native evidence: ${root}`);
  assert.equal(run.status,0,output || String(run.error)); assert.match(output,/W230PETSUI SUMMARY failures=0 passed=[1-9]\d*/);
  assert.doesNotMatch(output, /\bSKIP\b/);
  assert.ok(output.includes('PASS 10 fable5 always uses light App appearance'));
  assert.ok(readdirSync(`${root}/artifacts`).every(file => !file.endsWith('-fable5-dark.png')));
  for(const theme of ['aurora','fable5']) for(const scheme of theme === 'fable5' ? ['light'] : ['light','dark']) for(const screen of ['teams','stage','sessions','profile','exchange','backpack','hall','empty','new-stage','avatars','rename']) {
    const file = `${root}/artifacts/${screen}-${theme}-${scheme}.png`; assert.ok(existsSync(file),file);
    assert.equal(readFileSync(file).subarray(0,8).toString('hex'),'89504e470d0a1a0a',file);
  }
});


test('W230c new sessions and polish preserve the room boundary and production budget', () => {
  const root = read(ui+'PetsRootView.swift');
  for (const token of ['ChatComposerTextView','chatGlassChip(isSelected: pets.page == page','onExitCommand','menuIndicator(.hidden)','ChatChipTextField','petDropHighlight','LazyVGrid','TextEditor','newConversation(id)']) assert.ok(root.includes(token),token);
  assert.doesNotMatch(root, /Menu\("連線部門"\)|TextField\("(?:部門名稱|隊伍名稱|對寵物說話)"/);
  const changed = execFileSync('git',['diff','--numstat','3b2f6e15','--',src+'Pets/',src+'SelfTest.swift','tests/w230-*.test.mjs','tests/fixtures/w230c-room-allow.txt'],{cwd:checkout,encoding:'utf8'}).trim().split('\n').filter(Boolean);
  let net = 0;
  for(const row of changed) {
    const [a,d,file] = row.split('\t');
    assert.ok(file.startsWith(src+'Pets/') || file === src+'SelfTest.swift' || /^tests\/w230-.*\.test\.mjs$/.test(file) || file === 'tests/fixtures/w230c-room-allow.txt',file);
    if(!file.startsWith('tests/') && !file.endsWith('Acceptance.swift')) net += Number(a)-Number(d);
  }
  assert.ok(net <= 500, `W230c production net ${net}`);
});
