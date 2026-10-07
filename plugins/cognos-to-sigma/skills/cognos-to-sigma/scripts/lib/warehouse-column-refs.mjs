const norm = (value) => String(value ?? '').toLowerCase().replace(/[^a-z0-9]/g, '');

function catalogMatch(entries, candidates) {
  const names = entries.map((entry) => String(entry.name || '')).filter(Boolean);
  for (const candidate of candidates.filter(Boolean).map(String)) {
    if (names.includes(candidate)) return candidate;
    const folded = names.filter((name) => name.toLowerCase() === candidate.toLowerCase());
    if (folded.length === 1) return folded[0];
    const normalized = names.filter((name) => norm(name) === norm(candidate));
    if (normalized.length === 1) return normalized[0];
  }
  return null;
}

async function jsonApi(api, method, path, body) {
  const response = await api(method, path, body);
  if (!response.ok || !response.json) throw new Error(`${method} ${path} failed (HTTP ${response.status}): ${response.text.slice(0, 300)}`);
  return response.json;
}

async function listColumns(api, tableId) {
  const entries = [];
  let token = null;
  do {
    const query = new URLSearchParams({ pageSize: '500' });
    if (token) query.set('pageToken', token);
    const page = await jsonApi(api, 'GET', `/v2/connections/tables/${tableId}/columns?${query}`);
    entries.push(...(page.entries || []));
    token = page.nextPageToken || null;
  } while (token);
  return entries;
}

export async function groundWarehouseRefs(spec, api, { preserveElementNames = false } = {}) {
  const modes = new Map(), cache = new Map(), aliases = new Map(), prefixes = new Set(), idMap = new Map();
  const unresolved = [];
  let rewritten = 0, rekeyed = 0, reprefixed = 0;
  const elements = (spec.pages || []).flatMap((page) => page.elements || []);
  for (const element of elements) {
    const source = element.source || {};
    if (source.kind !== 'warehouse-table') continue;
    const connection = String(source.connectionId || ''), path = source.path;
    if (!connection || !Array.isArray(path) || !path.length) continue;
    if (!modes.has(connection)) {
      const details = await jsonApi(api, 'GET', `/v2/connections/${connection}`);
      modes.set(connection, details.friendlyName);
    }
    const friendly = modes.get(connection);
    if (friendly !== true && friendly !== false) throw new Error(`connection ${connection} did not report friendlyName`);
    if (friendly) continue;

    const oldName = String(element.name || ''), physicalName = String(path.at(-1));
    if (!preserveElementNames) {
      if (oldName && oldName !== physicalName) aliases.set(oldName, physicalName);
      element.name = physicalName;
    }
    const cacheKey = `${connection}\0${JSON.stringify(path)}`;
    if (!cache.has(cacheKey)) {
      const table = await jsonApi(api, 'POST', `/v2/connection/${connection}/lookup`, { path });
      if (table.kind !== 'table' || !table.inodeId) throw new Error(`${path.join('.')} did not resolve to a table`);
      cache.set(cacheKey, await listColumns(api, table.inodeId));
    }
    const entries = cache.get(cacheKey);
    const refs = new Map(entries.filter((entry) => entry.name).map((entry) => [norm(entry.name), String(entry.name)]));
    prefixes.add(oldName); prefixes.add(physicalName);

    for (const column of element.columns || []) {
      const match = String(column.formula || '').match(/^\[([^\]/]+)\/([^\]/]+)\]$/);
      if (!match) continue;
      const [, prefix, leaf] = match;
      const cid = String(column.id || ''), idLeaf = cid.includes('/') ? cid.split('/', 2)[1] : null;
      const physical = catalogMatch(entries, [leaf, column.name, idLeaf]);
      if (!physical) {
        if (cid.startsWith('inode-')) unresolved.push(`${path.join('.')}: ${prefix}/${leaf}`);
        continue;
      }
      if (!column.name) column.name = leaf;
      if (cid.startsWith('inode-') && idLeaf !== physical) {
        const newId = `${cid.split('/', 1)[0]}/${physical}`;
        idMap.set(cid, newId); column.id = newId; rekeyed++;
      }
      const grounded = `[${physicalName}/${physical}]`;
      if (column.formula !== grounded) { column.formula = grounded; rewritten++; }
    }

    const sameElement = (node) => {
      if (Array.isArray(node)) return node.forEach(sameElement);
      if (!node || typeof node !== 'object') return;
      let display = null;
      if (typeof node.formula === 'string') {
        node.formula = node.formula.replace(/\[([^\]/]+)(\/[^\]]+)\]/g, (whole, prefix, suffix) => {
          const leaf = suffix.slice(1);
          if (leaf.includes('/') || ![oldName, physicalName].includes(prefix) || !refs.has(norm(leaf))) return whole;
          display ||= leaf;
          const grounded = `[${physicalName}/${refs.get(norm(leaf))}]`;
          if (grounded !== whole) rewritten++;
          return grounded;
        });
      }
      if (display && !node.name) node.name = display;
      for (const [key, value] of Object.entries(node)) if (key !== 'formula') sameElement(value);
    };
    sameElement(element);
  }

  const replaceIds = (node) => {
    if (Array.isArray(node)) return node.map(replaceIds);
    if (node && typeof node === 'object') {
      for (const [key, value] of Object.entries(node)) node[key] = replaceIds(value);
      return node;
    }
    return typeof node === 'string' ? (idMap.get(node) || node) : node;
  };
  replaceIds(spec);

  const derived = (node) => {
    if (Array.isArray(node)) return node.forEach(derived);
    if (!node || typeof node !== 'object') return;
    let display = null;
    if (typeof node.formula === 'string') {
      node.formula = node.formula.replace(/\[([^\]/]+)(\/[^\]]+)\]/g, (_whole, prefix, suffix) => {
        const replacement = aliases.get(prefix) || prefix;
        if (replacement !== prefix) reprefixed++;
        if (!suffix.slice(1).includes('/') && (prefixes.has(prefix) || prefixes.has(replacement))) display ||= suffix.slice(1);
        return `[${replacement}${suffix}]`;
      });
    }
    if (display && !node.name) node.name = display;
    for (const [key, value] of Object.entries(node)) if (key !== 'formula') derived(value);
  };
  derived(spec);
  if (unresolved.length) throw new Error(`warehouse columns not found in catalog: ${[...new Set(unresolved)].join(', ')}`);
  return { rewritten, rekeyed, reprefixed, connectionModes: Object.fromEntries(modes) };
}
