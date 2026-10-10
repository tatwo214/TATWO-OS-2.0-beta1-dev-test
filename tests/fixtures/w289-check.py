"""Assert real-CEF samples, numeric privacy, default-off CDP audit, A/B nulls and CPU cost."""
import json
import pathlib
import re
import sys
root = pathlib.Path(sys.argv[1])
required = ('JSHeapUsedSize JSHeapTotalSize Nodes JSHeapUsedSizeDelta JSHeapTotalSizeDelta NodesDelta '
    'LayoutCount LayoutDuration RecalcStyleCount RecalcStyleDuration ScriptDuration TaskDuration '
    'documents nodes jsEventListeners loafCount loafMs imageCount imageMedianMs imageMaxMs '
    'videoWaiting videoStalled rendererPID rendererFootprintBytes rendererCPUSeconds gpuPID '
    'gpuFootprintBytes gpuCPUSeconds swapBytes memoryPressure monoMs browserID generation sampleSeconds').split()
def samples(label):
    lines = (root / (label + '-cef-embedding-telemetry.log')).read_text().splitlines()
    result = []
    for line in lines:
        if not line.startswith('phase=x_diag '):
            continue
        assert not re.search(r'https?://|PRIVATE_SENTINEL|username|textContent|currentSrc|url=', line), 'privacy leak'
        row = dict(item.split('=', 1) for item in line.split()[1:])
        assert set(required) <= set(row), 'missing fields'
        assert all(value == 'null' or re.fullmatch(r'-?\d+(?:\.\d+)?(?:e[+-]?\d+)?', value) for value in row.values()), 'non-numeric payload'
        result.append(row)
    return result
stats = {label: json.loads((root / (label + '-host-stats.json')).read_text()) for label in ('off','on','no-inject','foreign','twitter')}
assert not samples('off') and stats['off']['devToolsReplies'] == 0, 'default-off must issue zero CDP commands'
assert not samples('foreign') and stats['foreign']['devToolsReplies'] == 0, 'foreign host sampled'
on = samples('on')
assert len(on) >= 24, 'need two real minutes'
assert stats['on']['devToolsReplies'] == 2 * len(on) + 1, 'enable once, then two commands each sample'
for row in on:
    for key in ('JSHeapUsedSize','JSHeapTotalSize','Nodes','documents','nodes','jsEventListeners','rendererFootprintBytes','gpuFootprintBytes'):
        assert float(row[key]) > 0, (key,row[key])
    assert row['swapBytes'] != 'null' and row['memoryPressure'] != 'null', 'system probes failed'
    if row['sampleSeconds'] != 'null':
        assert 4.5 < float(row['sampleSeconds']) < 5.5, 'sample cadence'
assert sum(float(r['imageCount']) for r in on) > 10, 'no decoded image observations'
assert max(float(r['imageMaxMs']) for r in on if r['imageMaxMs'] != 'null') > 50, 'delayed local image never observed'
assert sum(float(r['videoWaiting']) for r in on) > 0 and sum(float(r['videoStalled']) for r in on) > 0
noinject = samples('no-inject')
assert len(noinject) >= 6
for row in noinject:
    assert all(row[k] == 'null' for k in ('loafCount','loafMs','imageCount','imageMedianMs','imageMaxMs','videoWaiting','videoStalled')), 'page script injected in A/B mode'
    assert float(row['JSHeapUsedSize']) > 0 and float(row['rendererFootprintBytes']) > 0
assert samples('twitter'), 'twitter host gate failed'
for label in ('off','on','no-inject'):
    state = json.loads((root / (label + '-feed-state.json')).read_text())
    assert state['cards'] == state['maxCards'] == state['images'] == state['videos'] == 10 and state['decodedVideos'] >= 8, 'recycling real-video feed failed'
extra = stats['on']['cpuPercent'] - stats['off']['cpuPercent']
assert extra < 2, f'extra main CPU {extra:.3f} percentage points'
print(json.dumps({'samples': len(on), 'offCDP': stats['off']['devToolsReplies'], 'onCDP': stats['on']['devToolsReplies'], 'cpuOffPercent': stats['off']['cpuPercent'], 'cpuOnPercent': stats['on']['cpuPercent'], 'extraCPUPercentagePoints': extra}, indent=2))
