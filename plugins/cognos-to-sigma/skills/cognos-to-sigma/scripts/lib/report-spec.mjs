// Cheap offline checks before Sigma's definitive Reports dry-run API. The
// public-beta Reports representation currently rejects workbook pivot-table.
export function reportSpecErrors(spec) {
  const errors = [];
  if (spec?.kind !== 'report' || spec.schemaVersion !== 1 || !Array.isArray(spec.pages) || !Array.isArray(spec.elements)) {
    errors.push('need Report contents with schemaVersion 1, pages and elements arrays');
    return errors;
  }
  if (!spec.pages.length || !spec.layout) errors.push('need at least one page and pixel layout');
  const data = spec.elements.filter((e) => e.source?.kind);
  if (!data.some((e) => e.kind !== 'image')) errors.push('a Report needs at least one data-bearing element');
  const unsupported = spec.elements.filter((e) => ['pivot-table', 'waterfall-chart', 'progress', 'repeated-container'].includes(e.kind));
  if (unsupported.length) errors.push(`Report code API does not support workbook kinds: ${unsupported.map((e) => e.kind).join(', ')}`);
  for (const e of spec.elements) {
    if (!e.id || !spec.layout.includes(`elementId="${e.id}"`)) errors.push(`unplaced Report element: ${e.name || e.id || '(missing id)'}`);
  }
  for (const element of data) {
    if (element.kind === 'pivot-table') continue;
    if (element.source.kind === 'data-model' && (!element.source.dataModelId || !element.source.elementId)) errors.push(`unbound data model source: ${element.name || element.id}`);
  }
  for (const page of spec.pages) {
    if (!page?.id || !spec.layout.includes(`id="${page.id}"`)) errors.push(`Report page missing from layout: ${page?.name || page?.id || '(missing id)'}`);
  }
  return errors;
}
