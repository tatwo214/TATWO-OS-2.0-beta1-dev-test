// Normalize only capabilities reported by the runtime; do not guess effort levels.
const unique = values => [...new Set(values.filter(v => typeof v === 'string'))];
const speed = value => ({priority:'fast', default:'standard', fast:'fast', standard:'standard'})[value];
export function codexModels(rows) {
  return rows.filter(row => !row.hidden && typeof row.model === 'string').map(row => {
    const speeds = unique([...(row.serviceTiers ?? []).map(t => speed(t.id)), ...(row.additionalSpeedTiers ?? []).map(speed)]);
    return {model:row.model, displayName:row.displayName || row.model,
      efforts:unique((row.supportedReasoningEfforts ?? []).map(e => e.reasoningEffort)),
      defaultEffort:row.defaultReasoningEffort ?? '', speeds,
      defaultSpeed:speed(row.defaultServiceTier) ?? (speeds.includes('standard') ? 'standard' : speeds[0] ?? ''),
      images:(row.inputModalities ?? []).includes('image')};
  });
}
export function claudeModels(rows) {
  return rows.filter(row => typeof row.value === 'string').map(row => {
    const efforts = row.supportsEffort === false ? [] : unique(row.supportedEffortLevels ?? []);
    return {model:row.resolvedModel || row.value,displayName:row.displayName || row.value,efforts,
      defaultEffort:efforts.includes('high') ? 'high' : efforts.includes('medium') ? 'medium' : efforts[0] ?? '',
      speeds:row.supportsFastMode ? ['fast','standard'] : [], defaultSpeed:row.supportsFastMode ? 'standard' : '', images:true};
  });
}
