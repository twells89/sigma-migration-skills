// Shape adapter for the Sigma WORKBOOK code representation.
// Verified live 2026-08-03/04: nested `document` required on write (including
// /v2/workbooks/spec/verify); flat bodies 400. The DATA-MODEL code-rep surface is
// NOT changing — do not use this on /v2/dataModels/.../spec payloads.

// Workbook elements are flat document collections; `overlays` and `panels` live
// beside them. `settings` (theme/navigation) and `agents` belong inside
// `document` too. Omitting any of these sweeps it onto the metadata envelope,
// where it is invalid and silently dropped on write.
export const DOC_KEYS = [
  'schemaVersion', 'pages', 'elements', 'overlays', 'panels',
  'kind', 'layout', 'settings', 'agents',
];

// REMOVED from the API. The workbook theme is now settings.theme.name /
// settings.theme.overrides (published OpenAPI: createWorkbookSpec has zero
// occurrences of themeName/themeOverrides). The individual override keys are
// unchanged - only the container path moved. document() folds the legacy pair
// forward so specs and fixtures written before the move still produce a valid body.
export const LEGACY_THEME_KEYS = ['themeName', 'themeOverrides'];
export const LEGACY_HORIZONTAL_ALIGN = { start: 'left', middle: 'center', end: 'right' };
export const LEGACY_VERTICAL_ALIGN = { start: 'top', middle: 'center', end: 'bottom' };

const isObj = (v) => v !== null && typeof v === 'object' && !Array.isArray(v);

export function document(response) {
  if (!isObj(response)) return {};
  const doc = isObj(response.document)
    ? response.document
    : Object.fromEntries(Object.entries(response).filter(([k]) => DOC_KEYS.includes(k)));
  return foldLegacyTheme(doc, response);
}

// themeName/themeOverrides -> settings.theme.{name,overrides}. Returns the input
// untouched when no legacy key is present (the common, already-correct path).
function foldLegacyTheme(doc, source) {
  const name = doc.themeName || source.themeName;
  const overrides = doc.themeOverrides || source.themeOverrides;
  const hasOv = isObj(overrides) && Object.keys(overrides).length > 0;
  const hasLegacyKey = LEGACY_THEME_KEYS.some((k) => k in doc);
  if (!name && !hasOv && !hasLegacyKey) return doc;

  const out = Object.fromEntries(
    Object.entries(doc).filter(([k]) => !LEGACY_THEME_KEYS.includes(k)),
  );
  const settings = { ...(out.settings || {}) };
  const theme = { ...(settings.theme || {}) };
  if (name && !theme.name) theme.name = name;
  if (hasOv) theme.overrides = { ...(theme.overrides || {}), ...overrides };
  if (Object.keys(theme).length === 0) return out;
  settings.theme = theme;
  out.settings = settings;
  return out;
}

// Emitter helper - set the workbook theme in the CURRENT shape. Builders should
// call this instead of assigning the removed themeName/themeOverrides pair.
export function setTheme(doc, { name = null, overrides = null } = {}) {
  const hasOv = isObj(overrides) && Object.keys(overrides).length > 0;
  if (!name && !hasOv) return doc;
  doc.settings = doc.settings || {};
  doc.settings.theme = doc.settings.theme || {};
  if (name) doc.settings.theme.name = name;
  if (hasOv) {
    doc.settings.theme.overrides = { ...(doc.settings.theme.overrides || {}), ...overrides };
  }
  return doc;
}

// Read the theme from either shape.
export function theme(spec) {
  const t = (document(spec).settings || {}).theme || {};
  return { name: t.name ?? null, overrides: t.overrides || {} };
}

export function metadata(response) {
  if (!isObj(response)) return {};
  return Object.fromEntries(
    Object.entries(response).filter(
      ([k]) => k !== 'document' && !DOC_KEYS.includes(k) && !LEGACY_THEME_KEYS.includes(k),
    ),
  );
}

export function workbookElements(spec) {
  const doc = document(spec);
  if (Array.isArray(doc.elements)) return doc.elements.filter(isObj);
  return (Array.isArray(doc.pages) ? doc.pages : [])
    .filter(isObj)
    .flatMap((page) => (Array.isArray(page.elements) ? page.elements.filter(isObj) : []));
}

export function workbookPageElementIds(spec) {
  const result = {};
  const layout = String(document(spec).layout || '');
  const pagePattern = /<Page\b[^>]*\bid="([^"]*)"[^>]*>(.*?)<\/Page>/gs;
  for (const match of layout.matchAll(pagePattern)) {
    result[match[1]] = [...new Set(
      [...match[2].matchAll(
        /<(?:Element|Container|TabbedContainer|LayoutElement|GridContainer)\b[^>]*\belementId="([^"]*)"/g,
      )].map((element) => element[1]),
    )];
  }
  return result;
}

export function workbookPageByElement(spec) {
  const doc = document(spec);
  const pages = Array.isArray(doc.pages) ? doc.pages.filter(isObj) : [];
  const pagesById = Object.fromEntries(pages.filter((page) => page.id).map((page) => [page.id, page]));
  const result = {};
  for (const [pageId, elementIds] of Object.entries(workbookPageElementIds(doc))) {
    const page = pagesById[pageId] || { id: pageId, name: pageId };
    for (const elementId of elementIds) result[elementId] ||= page;
  }
  return result;
}

export function workbookElementsWithPages(spec) {
  const pageByElement = workbookPageByElement(spec);
  return workbookElements(spec).map((element) => [
    element,
    pageByElement[element.id || element.elementId],
  ]);
}

function flattenElements(doc) {
  if (!isObj(doc) || !Array.isArray(doc.pages)) return doc;
  const nested = [];
  const pages = doc.pages.map((page) => {
    const copy = { ...page };
    if (Array.isArray(copy.elements)) nested.push(...copy.elements);
    delete copy.elements;
    return copy;
  });
  const elements = [];
  const seen = new Set();
  for (const element of [...(Array.isArray(doc.elements) ? doc.elements : []), ...nested]) {
    const id = isObj(element) ? element.id : null;
    if (id && seen.has(id)) continue;
    if (id) seen.add(id);
    elements.push(element);
  }
  return { ...doc, pages, elements };
}

export function canonicalizeLayout(layoutXml) {
  return String(layoutXml || '')
    .replace(/<([/]?)LayoutElement\b/g, '<$1Element')
    .replace(/<([/]?)GridContainer\b/g, '<$1Container');
}

function canonicalizeElement(element) {
  if (!isObj(element)) return element;
  if (element.kind === 'text' && element.verticalAlign in LEGACY_VERTICAL_ALIGN) {
    return { ...element, verticalAlign: LEGACY_VERTICAL_ALIGN[element.verticalAlign] };
  }
  if (element.kind === 'kpi-chart' && isObj(element.layout)) {
    const layout = { ...element.layout };
    if (layout.anchor in LEGACY_HORIZONTAL_ALIGN) {
      layout.anchor = LEGACY_HORIZONTAL_ALIGN[layout.anchor];
    }
    if (layout.verticalAnchor in LEGACY_VERTICAL_ALIGN) {
      layout.verticalAnchor = LEGACY_VERTICAL_ALIGN[layout.verticalAnchor];
    }
    return { ...element, layout };
  }
  if (element.kind === 'tabbed-container' && isObj(element.tabBar)
      && element.tabBar.alignment in LEGACY_HORIZONTAL_ALIGN) {
    return {
      ...element,
      tabBar: {
        ...element.tabBar,
        alignment: LEGACY_HORIZONTAL_ALIGN[element.tabBar.alignment],
      },
    };
  }
  if (element.kind === 'divider' && element.align in LEGACY_VERTICAL_ALIGN) {
    const mapping = element.direction === 'vertical'
      ? LEGACY_HORIZONTAL_ALIGN
      : LEGACY_VERTICAL_ALIGN;
    return { ...element, align: mapping[element.align] };
  }
  return element;
}

function canonicalizeOverlay(overlay) {
  if (!isObj(overlay) || !isObj(overlay.drawer) || !('position' in overlay.drawer)) {
    return overlay;
  }
  const { position: _removed, ...drawer } = overlay.drawer;
  return { ...overlay, drawer };
}

export function wrap(doc, extra = {}) {
  const flattened = flattenElements(doc);
  let canonical = flattened;
  if (isObj(flattened)) {
    canonical = { ...flattened };
    if (Array.isArray(flattened.elements)) {
      canonical.elements = flattened.elements.map(canonicalizeElement);
    }
    if (Array.isArray(flattened.overlays)) {
      canonical.overlays = flattened.overlays.map(canonicalizeOverlay);
    }
    if ('layout' in flattened) canonical.layout = canonicalizeLayout(flattened.layout);
  }
  return { ...extra, document: canonical };
}
