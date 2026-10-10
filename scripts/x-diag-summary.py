#!/usr/bin/env python3
"""Numeric X diagnostics: one row per minute/browser/document. '-' means unavailable.
Gauges/median/pressure: mean; cumulative deltas/counts/time: sum; max delay: max.
Image median is the mean of interval medians, not a pooled per-image median.
"""
import argparse
import collections
import re
import statistics

FIELDS = ('JSHeapUsedSize JSHeapTotalSize Nodes JSHeapUsedSizeDelta JSHeapTotalSizeDelta NodesDelta LayoutCount LayoutDuration RecalcStyleCount '
          'RecalcStyleDuration ScriptDuration TaskDuration documents nodes jsEventListeners '
          'loafCount loafMs imageCount imageMedianMs imageMaxMs adImageCount adImageMedianMs adImageMaxMs postImageCount postImageMedianMs postImageMaxMs videoWaiting videoStalled '
          'rendererPID rendererFootprintBytes rendererCPUSeconds gpuPID gpuFootprintBytes '
          'gpuCPUSeconds swapBytes memoryPressure sampleSeconds').split()
SUM = set('JSHeapUsedSizeDelta JSHeapTotalSizeDelta NodesDelta LayoutCount LayoutDuration RecalcStyleCount RecalcStyleDuration ScriptDuration '
          'TaskDuration loafCount loafMs imageCount adImageCount postImageCount videoWaiting videoStalled '
          'rendererCPUSeconds gpuCPUSeconds sampleSeconds'.split())
p = argparse.ArgumentParser(description=__doc__)
p.add_argument('telemetry', nargs='+')
a = p.parse_args()
groups = collections.defaultdict(list)
starts = {}
for filename in a.telemetry:
    with open(filename) as stream:
        for line in stream:
            if 'phase=x_diag ' not in line:
                continue
            row = {k: float(v) for k, v in re.findall(r'(\w+)=(-?\d+(?:\.\d+)?(?:e[+-]?\d+)?)\b', line)}
            if 'monoMs' not in row:
                continue
            identity = (filename, int(row.get('browserID', 0)), int(row.get('generation', 0)))
            start = starts.setdefault(identity, row['monoMs'])
            groups[identity + (int((row['monoMs'] - start) // 60000) + 1,)].append(row)
print('| run | browser | generation | minute | samples | ' + ' | '.join(FIELDS) + ' |')
print('|' + ' --- |' * (5 + len(FIELDS)))
for key, rows in sorted(groups.items()):
    values = []
    for field in FIELDS:
        nums = [r[field] for r in rows if field in r]
        value = ('-' if not nums else f'{(sum(nums) if field in SUM else max(nums) if field in ("imageMaxMs", "adImageMaxMs", "postImageMaxMs", "memoryPressure") else statistics.mean(nums)):.3f}')
        values.append(value)
    print('| ' + ' | '.join([str(a.telemetry.index(key[0])+1), *(str(v) for v in key[1:]), str(len(rows)), *values]) + ' |')
