// Decode Sigma's per-element exports into the numeric parity keys the Cognos
// orchestrator checks. Pivots with `totals` can 500 on CSV export; JSON uses
// long-form row objects instead.
export function parseCsv(text) {
  const rows = [];
  let row = [], field = '', inQ = false;
  for (let i = 0; i < text.length; i++) {
    const c = text[i];
    if (inQ) {
      if (c === '"') { if (text[i + 1] === '"') { field += '"'; i++; } else inQ = false; }
      else field += c;
    } else if (c === '"') inQ = true;
    else if (c === ',') { row.push(field); field = ''; }
    else if (c === '\n') { row.push(field); rows.push(row); row = []; field = ''; }
    else if (c !== '\r') field += c;
  }
  if (field !== '' || row.length) { row.push(field); rows.push(row); }
  return rows.filter((r) => r.length > 1 || (r.length === 1 && r[0] !== ''));
}

export function exportRows(body, format) {
  if (format === 'csv') {
    const [headers, ...data] = parseCsv(body);
    if (!headers?.length) throw new Error('CSV export has no header row');
    return { headers, data: data.map((row) => Object.fromEntries(headers.map((h, i) => [h, row[i]]))) };
  }
  let parsed;
  try { parsed = JSON.parse(body); }
  catch {
    try { parsed = body.trim().split(/\r?\n/).filter(Boolean).map((row) => JSON.parse(row)); }
    catch { throw new Error('JSON export was neither a row array nor NDJSON'); }
  }
  const data = Array.isArray(parsed) ? parsed : parsed?.rows || parsed?.data;
  if (!Array.isArray(data) || data.some((row) => !row || Array.isArray(row) || typeof row !== 'object')) {
    throw new Error('JSON export must contain an array of row objects');
  }
  return { headers: [...new Set(data.flatMap((row) => Object.keys(row)))], data };
}

const numish = (value) => {
  if (value == null) return null;
  if (typeof value === 'number') return Number.isFinite(value) ? value : null;
  const text = String(value).replace(/[$,%\s]/g, '');
  return /^-?\d+(\.\d+)?$/.test(text) ? Number(text) : null;
};

export function parityActuals(body, format, elementKey) {
  const { headers, data } = exportRows(body, format);
  const actuals = { [`${elementKey}/rows`]: data.length };
  for (const header of headers) {
    const values = data.map((row) => numish(row[header]));
    if (values.length && values.every((value) => value != null)) {
      actuals[`${elementKey}/${header}`] = Number(values.reduce((sum, value) => sum + value, 0).toFixed(6));
    }
  }
  return { actuals, rows: data.length, columns: headers.length };
}
