// metric-binding.ts — bind a workbook measure to a governed DM metric.
//
// Cognos-local TypeScript port of the shared Python/Ruby binder
// (shared/lib/metric_binding.{py,rb}; see beads-sigma-7bun). The shared helper is
// Python + Ruby only; cognos is the sole TS consumer, so this ports the same two
// pure functions rather than vendoring a shared file. Keep the semantics in
// lockstep with the shared copies.
//
// - metricRefOrInline(inline, masterName, metrics): returns "[Metrics/<name>]" when
//   `inline` matches a metric by FORMULA EQUIVALENCE (strip the master prefix so
//   `Sum([Sheet 1/Revenue])` equals a metric's `Sum([Revenue])`, then compare
//   ignoring whitespace); otherwise returns `inline` unchanged. SAFE: empty
//   metrics / non-matching / a metric in a different representation all fall back
//   to inline.
// - availableMetrics(elementId, elementsById): metrics referenceable on an element
//   = its own + those inherited through the `source.elementId` chain, deduped by
//   name. (Cognos hosts metrics as OWN on each query-subject element, so the chain
//   is usually length 1; included for parity with the shared helper.)
//
// The reference form is the literal namespace `[Metrics/<Metric Name>]`.

export interface BindMetric { name: string; formula: string; }

const canon = (f: string | undefined): string => (f || '').replace(/\s+/g, '');

export function metricRefOrInline(
  inline: string,
  masterName: string,
  metrics: BindMetric[] | undefined,
): string {
  if (typeof inline !== 'string' || !metrics || metrics.length === 0) return inline;
  // split/join replaces EVERY master prefix (matches Python str.replace):
  // Sum([M/a])/Sum([M/b]) -> Sum([a])/Sum([b]).
  const want = canon(inline.split(`[${masterName}/`).join('['));
  for (const m of metrics) {
    if (m && m.name && m.formula && canon(m.formula) === want) return `[Metrics/${m.name}]`;
  }
  return inline;
}

export function availableMetrics(
  elementId: string | undefined,
  elementsById: Record<string, any>,
): BindMetric[] {
  const seen = new Set<string>();
  const chain: BindMetric[] = [];
  let eid = elementId;
  while (eid && !seen.has(eid)) {
    seen.add(eid);
    const el = elementsById[eid];
    if (!el) break;
    for (const m of (el.metrics || [])) {
      if (m && m.name && m.formula) chain.push({ name: m.name, formula: m.formula });
    }
    eid = el.source && el.source.elementId;
  }
  const out: BindMetric[] = [];
  const names = new Set<string>();
  for (const m of chain) {
    if (!names.has(m.name)) { names.add(m.name); out.push(m); }
  }
  return out;
}
