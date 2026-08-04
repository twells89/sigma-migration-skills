// Shape adapter for the Sigma WORKBOOK code representation.
// Verified live 2026-08-03/04: nested `document` required on write (including
// /v2/workbooks/spec/verify); flat bodies 400. The DATA-MODEL code-rep surface is
// NOT changing — do not use this on /v2/dataModels/.../spec payloads.

export const DOC_KEYS = ['schemaVersion', 'pages', 'kind', 'layout'];

const isObj = (v) => v !== null && typeof v === 'object' && !Array.isArray(v);

export function document(response) {
  if (!isObj(response)) return {};
  if (isObj(response.document)) return response.document;
  return Object.fromEntries(Object.entries(response).filter(([k]) => DOC_KEYS.includes(k)));
}

export function metadata(response) {
  if (!isObj(response)) return {};
  return Object.fromEntries(
    Object.entries(response).filter(([k]) => k !== 'document' && !DOC_KEYS.includes(k)),
  );
}

export function wrap(doc, extra = {}) {
  return { ...extra, document: doc };
}
