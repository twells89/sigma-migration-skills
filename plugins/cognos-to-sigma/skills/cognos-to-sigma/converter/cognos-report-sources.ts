import { XMLParser, XMLValidator } from 'fast-xml-parser';
import { sigmaDisplayName } from './sigma-ids.js';

/** Logical source requirements, not invented warehouse paths or model policy. */
export function inventoryCognosReportSources(xml: string) {
  const validity = XMLValidator.validate(xml);
  if (validity !== true) throw new Error(`invalid Cognos report XML at line ${validity.err.line}, column ${validity.err.col}`);
  const report = new XMLParser({ ignoreAttributes: false, attributeNamePrefix: '@_' }).parse(xml).report;
  if (!report) throw new Error('source inventory requires a Cognos report XML');
  const subjects = new Map<string, { ref: string; name: string; columns: Array<{ name: string; sigmaName: string }> }>();
  const queries: Array<{ name: string; dependencies: string[] }> = [];
  const arr = (v: any): any[] => v == null ? [] : Array.isArray(v) ? v : [v];
  const queryNames = new Set(arr(report.queries?.query).map((q) => q['@_name']));
  const visit = (node: any, query?: { name: string; dependencies: string[] }) => {
    if (!node || typeof node !== 'object' || node['@_use'] === 'prohibited') return;
    for (const [key, value] of Object.entries(node)) {
      if (key === 'query') {
        for (const q of arr(value)) {
          const entry = { name: String(q['@_name'] || 'query'), dependencies: [] as string[] };
          queries.push(entry); visit(q, entry);
        }
        continue;
      }
      if (key === 'queryRef' && query) {
        for (const ref of arr(value)) if (ref['@_refQuery'] && !query.dependencies.includes(ref['@_refQuery'])) query.dependencies.push(ref['@_refQuery']);
      }
      if (['expression', 'filterExpression', 'reportExpression'].includes(key)) {
        const expression = typeof value === 'string' ? value : (value as any)?.['#text'] || '';
        if (/#\s*(?:prompt|sq|sb|sql)\s*\(/i.test(expression)) throw new Error('runtime macro source references require a semantic-model export and resolved runtime parameters');
        // Consume quoted strings first: a literal containing [X].[Y].[Z] is not a dependency.
        for (const token of expression.matchAll(/'(?:[^']|'')*'|"(?:[^"]|"")*"|\[[^\]]+\](?:\.\[[^\]]+\])+/g)) {
          if (!token[0].startsWith('[')) continue;
          const parts = [...token[0].matchAll(/\[([^\]]+)\]/g)].map((m) => m[1]);
          if (parts.length === 2) {
            if (!queryNames.has(parts[0])) throw new Error(`ambiguous two-part source reference ${token[0]}; obtain the semantic-model export`);
            continue;
          }
          if (parts.length > 4) throw new Error('model reference with more than four parts requires a semantic-model export');
          const ref = parts.slice(0, -1).map((p) => `[${p}]`).join('.');
          const name = parts[parts.length - 1];
          const subject = subjects.get(ref) || { ref, name: sigmaDisplayName(parts[parts.length - 2]), columns: [] };
          if (!subject.columns.some((column) => column.name === name)) subject.columns.push({ name, sigmaName: sigmaDisplayName(name) });
          subjects.set(ref, subject);
        }
      }
      arr(value).forEach((child) => visit(child, query));
    }
  };
  visit(report);
  return { schemaVersion: 1, subjects: [...subjects.values()], queries,
    limitations: ['Report XML does not establish physical table mappings, model-level joins, calculated model items, or security policies. Verify them against the source model/owner before creating a data model.'] };
}
