import fs from 'node:fs';
import path from 'node:path';

/**
 * W180 E4：跑 App 自測的執行檔。先看 TATWO2_TEST_BINARY；在主設備 staging 的建置工作副本
 * （rooms/build-<名>，lead-verify 的 node 步驟）裡跑時，用同名的建置快取（build-cache/<名>/debug/Tatwo2）。
 * 都找不到就回 null；呼叫端要明確失敗（整批驗收一定帶得到），不跳過。
 */
export function resolveBinary() {
  if (process.env.TATWO2_TEST_BINARY) return process.env.TATWO2_TEST_BINARY;
  const here = path.basename(process.cwd());
  if (!here.startsWith('build-')) return null;
  const candidate = path.resolve(process.cwd(), '../../build-cache', here.slice('build-'.length), 'debug/Tatwo2');
  return fs.existsSync(candidate) ? candidate : null;
}

/**
 * W180 E4：真 GBrain 往返要的 W80 helper。先看 W80B_GBRAIN_HELPER；在主設備 staging 的建置工作副本
 * （rooms/build-<名>）裡跑時，用 staging 的 tmp/w80/gbrain-probe-adhoc（跟 gate-template.sh 同一份）。
 * 找不到就回 null；呼叫端要明確失敗，不跳過。
 */
export function resolveGBrainHelper() {
  if (process.env.W80B_GBRAIN_HELPER) return process.env.W80B_GBRAIN_HELPER;
  if (!path.basename(process.cwd()).startsWith('build-')) return null;
  const candidate = path.resolve(process.cwd(), '../../tmp/w80/gbrain-probe-adhoc');
  return fs.existsSync(candidate) ? candidate : null;
}
