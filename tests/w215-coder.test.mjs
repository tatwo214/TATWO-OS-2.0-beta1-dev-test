import test from 'node:test';
import { runNativeW215 } from './helpers/w215-native.mjs';

test('W219-1: Coder artifacts start collapsed, open through the logo, and collapse again in both themes', { timeout: 120_000 }, t => {
  runNativeW215(t, 1);
});

test('W215: Coder logo column, turn details, approvals, centered history and live progress', { timeout: 120_000 }, t => {
  runNativeW215(t);
});
