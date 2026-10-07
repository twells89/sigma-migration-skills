import { randomBytes } from 'node:crypto';

// Build the missing semantic-source layer from verified warehouse metadata.
// Report query joins/calculations remain converter work, never silently flattened.
export async function buildReportDataModel(inventory, mapping, connectionId, api) {
  if (!inventory.subjects?.length) throw new Error('report has no resolved model subjects; obtain the Cognos semantic-model export');
  if (mapping.sourceModelReviewed !== true) throw new Error('sourceModelReviewed must confirm the mapping preserves model calculations, joins and security; request the semantic-model export if unknown');
  if (typeof connectionId !== 'string' || !connectionId || !Array.isArray(mapping.subjects)) throw new Error('need a connection and subject mapping');
  const id = () => randomBytes(8).toString('hex');
  const request = async (method, path, body) => {
    const response = await api(method, path, body);
    if (!response.ok || !response.json) throw new Error(`warehouse verification failed: ${method} ${path} (HTTP ${response.status})`);
    return response.json;
  };
  const elements = [], cache = new Map(), names = new Set();
  const connection = await request('GET', `/v2/connections/${encodeURIComponent(connectionId)}`);
  if (connection.friendlyName !== true && connection.friendlyName !== false) throw new Error('connection did not report its column naming mode');
  for (const subject of inventory.subjects) {
    const matches = mapping.subjects.filter((candidate) => candidate.ref === subject.ref);
    if (matches.length !== 1) throw new Error(`need exactly one warehouse mapping for ${subject.ref}`);
    const match = matches[0];
    if (!Array.isArray(match.path) || !match.path.length || match.path.some((p) => typeof p !== 'string' || !p)) throw new Error(`missing physical path for ${subject.ref}`);
    if (names.has(subject.name.toLowerCase())) throw new Error(`ambiguous subject display name: ${subject.name}; use a semantic-model export to disambiguate`);
    names.add(subject.name.toLowerCase());
    const key = JSON.stringify(match.path);
    if (!cache.has(key)) {
      const table = await request('POST', `/v2/connection/${encodeURIComponent(connectionId)}/lookup`, { path: match.path });
      if (table.kind !== 'table' || !table.inodeId) throw new Error(`warehouse path is not a table for ${subject.ref}`);
      const columns = [], seen = new Set();
      let token;
      do {
        const params = new URLSearchParams({ pageSize: '500', ...(token ? { pageToken: token } : {}) });
        const page = await request('GET', `/v2/connections/tables/${encodeURIComponent(table.inodeId)}/columns?${params}`);
        if (!Array.isArray(page.entries)) throw new Error('warehouse column inventory is incomplete');
        columns.push(...page.entries);
        token = page.nextPageToken;
        if (token && seen.has(token)) throw new Error('warehouse column pagination did not advance');
        if (token) seen.add(token);
      } while (token);
      cache.set(key, columns);
    }
    const columns = [], columnNames = new Set();
    for (const column of subject.columns) {
      const physical = match.columns?.[column.name];
      if (typeof physical !== 'string' || cache.get(key).filter((c) => c.name === physical).length !== 1) throw new Error(`warehouse column mapping missing or not found: ${subject.ref}.[${column.name}]`);
      if (columnNames.has(column.sigmaName.toLowerCase())) throw new Error(`ambiguous logical column name: ${column.sigmaName}`);
      columnNames.add(column.sigmaName.toLowerCase());
      if (/[\[\]\/]/.test(physical) || /[\[\]\/]/.test(match.path.at(-1))) throw new Error('special-character physical references need an explicit SQL/source-model mapping');
      // The catalog's exact physical name is accepted on creation; retain the
      // logical display name explicitly even when friendly naming is disabled.
      columns.push({ id: id(), name: column.sigmaName, formula: `[${match.path.at(-1)}/${physical}]` });
    }
    elements.push({ id: id(), kind: 'table', name: subject.name,
      source: { kind: 'warehouse-table', connectionId, path: match.path }, columns, order: columns.map((c) => c.id) });
  }
  return { name: mapping.modelName || 'Cognos report sources', schemaVersion: 1,
    pages: [{ id: id(), name: 'Report sources', elements }] };
}
