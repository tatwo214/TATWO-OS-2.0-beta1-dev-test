import { readFileSync, writeFileSync } from 'node:fs';
import { basename, join } from 'node:path';
import assert from 'node:assert/strict';
// Copy only compiler inputs. Source assertions still inspect unchanged production files.
export function keychainFixtureFiles(directory, files) {
  const trap = new URL('../fixtures/w255b-keychain-trap.swift', import.meta.url).pathname;
  const result = files.map(file => {
    const source = readFileSync(file, 'utf8');
    if (!/\bSec(?:Item|Keychain)\w+\b/.test(source)) return file;
    const fake = source.replace(/\bSec(?:Item(?:Add|Delete|Update|CopyMatching)|Keychain(?:Get|Set)UserInteractionAllowed)\b/g, 'w255bRefuse$&');
    assert.doesNotMatch(fake, /\bSec(?:Item|Keychain)\w+\b/, 'unknown native Keychain API must not compile into a fixture');
    const target = join(directory, 'w255b-' + basename(file));
    writeFileSync(target, fake);
    return target;
  });
  return [...result, trap];
}
