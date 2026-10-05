#!/usr/bin/env node
// Add explicitly-authored print pages to a converted Sigma Report. The page
// blueprint is supplied by the caller; this never infers customer text from a
// PDF or invents an absent legal/financial statement. Works offline.
import { readFileSync, writeFileSync } from 'node:fs';
import { randomBytes } from 'node:crypto';
import { parseArgs } from './lib/sigma-rest.mjs';
import { reportSpecErrors } from './lib/report-spec.mjs';

const esc = (s) => String(s).replace(/&/g, '&amp;').replace(/"/g, '&quot;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
const id = () => randomBytes(8).toString('hex');
const number = (n, field) => {
  if (!Number.isFinite(n) || n < 0) throw new Error(`${field} must be a nonnegative number`);
  return n;
};
const clone = (x) => JSON.parse(JSON.stringify(x));
const svgData = (svg) => `data:image/svg+xml;base64,${Buffer.from(svg).toString('base64')}`;
const accentColor = (color) => {
  if (!/^#[0-9a-fA-F]{6}$/.test(color)) throw new Error('artwork accent must be a six-digit hex color');
  return color;
};
const emblemImage = ({ label, subtitle, accent = '#c93024' }, width, height) => {
  if (!/^[A-Za-z ]{1,25}$/.test(label) || !/^[A-Za-z ]{1,32}$/.test(subtitle)) throw new Error('emblem needs short alphabetic label and subtitle');
  const cx = width / 2, cy = height / 2, radius = Math.min(width, height) * 0.43;
  return svgData(`<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 ${width} ${height}"><circle cx="${cx}" cy="${cy}" r="${radius}" fill="#ffffff" stroke="${accentColor(accent)}" stroke-width="12"/><text x="${cx}" y="${cy - 24}" text-anchor="middle" font-family="Arial" font-size="40" font-weight="bold" fill="#575c64">${label}</text><text x="${cx}" y="${cy + 28}" text-anchor="middle" font-family="Arial" font-size="30" font-weight="bold" fill="#575c64">${subtitle}</text></svg>`);
};
const footerMark = ({ label, accent = '#c93024' }, width, height) => {
  if (!/^[A-Za-z ]{1,25}$/.test(label)) throw new Error('footer brand needs a short alphabetic label');
  return svgData(`<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 ${width} ${height}"><line x1="0" y1="1" x2="${width}" y2="1" stroke="#5b6069" stroke-width="1"/><circle cx="17" cy="${height / 2 + 3}" r="12" fill="${accentColor(accent)}"/><text x="43" y="${height / 2 + 9}" font-family="Arial" font-size="18" font-weight="bold" fill="#575c64">${label}</text></svg>`);
};
// Separate native paragraph elements avoid one large rich-text box's paragraph
// spacing without turning editable business copy into artwork. Estimated fit
// is conservative, not a substitute for inspecting Sigma's exported pages.
const denseTextBlocks = (body, width, height, fontSize, sampleFill = false) => {
  const clauses = body.split(/\n\s*\n/).map((s) => s.trim()).filter(Boolean);
  if (!clauses.length) throw new Error('dense text needs at least one paragraph');
  const samples = [
    'This paragraph is illustrative typesetting text. It repeats the page rhythm, line length and leading of a printed reference section without representing an approved policy or business term.',
    'Review the actual exported page for legibility, line wrapping and footer clearance. All content in this section is neutral placeholder copy for print-layout inspection.',
    'A page can be structurally valid yet look incomplete when a paragraph overflows or a font renders differently. Recheck the output after every intentional edit.',
  ];
  const lineHeight = Math.ceil(fontSize * 1.5), gap = Math.ceil(fontSize * 0.8);
  const maxChars = Math.max(1, Math.floor(width / (fontSize * 0.6)));
  const blocks = [];
  let used = 0;
  const append = (paragraph) => {
    let count = 0;
    for (const sourceLine of paragraph.split('\n')) {
      let length = 0;
      count++;
      for (const word of sourceLine.split(/\s+/).filter(Boolean)) {
        if (word.length > maxChars) throw new Error('dense text has a word too wide for its page');
        if (length && length + 1 + word.length > maxChars) { count++; length = word.length; }
        else length += (length ? 1 : 0) + word.length;
      }
    }
    const blockHeight = count * lineHeight + 8;
    if (used + blockHeight > height) return false;
    blocks.push({ body: paragraph, y: used, height: blockHeight });
    used += blockHeight + gap;
    return true;
  };
  for (const clause of clauses) {
    if (!append(clause)) throw new Error('dense text exceeds the allotted page; split the approved text across pages');
  }
  if (sampleFill) {
    for (let index = 0; ; index++) {
      if (!append(`Example note ${index + 1}. ${samples[index % samples.length]}`)) break;
    }
  }
  return blocks;
};
const watermarkImage = ({ text, color = '#e7e9f0', opacity = 0.22, angle = -35 }, width, height) => {
  if (!/^[A-Za-z ]{1,40}$/.test(text)) throw new Error('watermark text must contain 1–40 letters/spaces');
  if (!/^#[0-9a-fA-F]{6}$/.test(color) || !Number.isFinite(opacity) || opacity < 0 || opacity > 1 || !Number.isFinite(angle)) {
    throw new Error('watermark needs a hex color, opacity in [0,1], and finite angle');
  }
  const cx = Math.round(width / 2), cy = Math.round(height / 2);
  // Keep the rotated word inside the SVG viewBox. A fixed 155px font was
  // clipped into stray letters in small corner stamps.
  const fontSize = Math.max(1, Math.floor(Math.min(155, width / (text.length * 0.85), height * 0.48)));
  const svg = `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 ${width} ${height}"><text x="${cx}" y="${cy}" text-anchor="middle" dominant-baseline="central" transform="rotate(${angle} ${cx} ${cy})" fill="${color}" opacity="${opacity}" font-family="Arial" font-weight="bold" font-size="${fontSize}">${text}</text></svg>`;
  return svgData(svg);
};

export function composePrintLayout(input, manifest) {
  const spec = clone(input);
  const before = reportSpecErrors(spec);
  if (before.length) throw new Error(`invalid base report: ${before.join('; ')}`);
  if (!Array.isArray(manifest.pages) || !manifest.pages.length) throw new Error('blueprint must supply pages');
  const width = spec.config?.pageWidth ?? 816;
  const height = spec.config?.pageHeight ?? 1056;
  const margin = spec.config?.margin ?? 0;
  if (![width, height, margin].every(Number.isFinite) || width <= 2 * margin || height <= 2 * margin || margin < 0) throw new Error('invalid report page geometry');
  const fitsPrintablePage = (x, y, w, h) =>
    x >= margin && y >= margin && x + w <= width - margin && y + h <= height - margin;
  let layout = spec.layout;
  const created = [];
  const referenced = new Set();
  const removePanel = (panel) => {
    const fragment = layout.match(new RegExp(`<Panel\\b[^>]*\\bid="${panel.id}"[^>]*>[\\s\\S]*?<\/Panel>|<Panel\\b[^>]*\\bid="${panel.id}"[^>]*/>`, 'g')) || [];
    if (fragment.length !== 1) throw new Error(`panel ${panel.id} has no unique layout block`);
    const childIds = [...fragment[0].matchAll(/elementId="([^"]+)"/g)].map((match) => match[1]);
    if (childIds.some((elementId) => layout.split(`elementId="${elementId}"`).length !== 2)) throw new Error(`panel ${panel.id} shares an element with other layouts`);
    spec.panels = spec.panels.filter((item) => item.id !== panel.id);
    spec.elements = spec.elements.filter((element) => !childIds.includes(element.id));
    layout = layout.replace(fragment[0], '');
  };
  const add = (block, pageId) => {
    if (!block.body || typeof block.body !== 'string') throw new Error('every blueprint text block needs a body');
    const x = number(block.x, 'x'), y = number(block.y, 'y');
    const w = number(block.width, 'width'), h = number(block.height, 'height');
    if (!w || !h || !fitsPrintablePage(x, y, w, h)) {
      throw new Error(`text block on ${pageId} exceeds the page canvas`);
    }
    if (block.dense) {
      const font = block.fontSize ?? 9;
      if (!Number.isFinite(font) || font < 6 || font > 48) throw new Error('fontSize must be between 6 and 48');
      if (block.body.length > 10000) throw new Error('dense text is too long for one page');
      if (block.sampleFill != null && typeof block.sampleFill !== 'boolean') throw new Error('sampleFill must be boolean');
      return denseTextBlocks(block.body, w, h, font, block.sampleFill).map((paragraph) =>
        add({ x, y: y + paragraph.y, width: w, height: paragraph.height, body: paragraph.body, fontSize: font }, pageId));
    }
    const font = block.fontSize;
    if (font != null && (!Number.isFinite(font) || font < 6 || font > 48)) throw new Error('fontSize must be between 6 and 48');
    const body = font == null ? block.body : block.body.split('\n').map((line) => line ? `<span style="font-size: ${font}px">${esc(line)}</span>` : '').join('\n');
    const element = { id: id(), kind: 'text', body };
    spec.elements.push(element);
    const node = `<Element elementId="${element.id}" x="${x}" y="${y}" width="${w}" height="${h}"/>`;
    layout = layout.replace(new RegExp(`(<Page\\b[^>]*\\bid="${esc(pageId)}"[^>]*>)([\\s\\S]*?)(<\\/Page>)`),
      (_m, open, inner, close) => `${open}${inner}\n  ${node}\n${close}`);
    return element;
  };
  const backgrounds = [];
  for (const [index, cfg] of manifest.pages.entries()) {
    if (!cfg || typeof cfg !== 'object') throw new Error(`blueprint page ${index + 1} is not an object`);
    let page = cfg.sourcePage ? spec.pages.find((p) => p.name === cfg.sourcePage) : null;
    if (cfg.sourcePage && !page) throw new Error(`source page ${cfg.sourcePage} not found`);
    if (cfg.sourcePage && referenced.has(page.id)) throw new Error(`source page ${cfg.sourcePage} appears more than once`);
    if (cfg.sourcePage) referenced.add(page.id);
    if (!page) {
      page = { id: id(), name: cfg.name || `Page ${spec.pages.length + 1}` };
      if (cfg.position === 'first' || cfg.position === 'after') {
        const previous = cfg.position === 'after' ? spec.pages.findIndex((p) => p.name === cfg.afterPage) : -1;
        if (cfg.position === 'after' && previous < 0) throw new Error(`afterPage ${cfg.afterPage} not found`);
        spec.pages.splice(previous + 1, 0, page);
        const firstPage = layout.search(/<Page\b/);
        if (firstPage < 0) throw new Error('base report has no Page layout block');
        layout = `${layout.slice(0, firstPage)}<Page id="${page.id}"></Page>\n${layout.slice(firstPage)}`;
      } else {
        spec.pages.push(page);
        layout += `\n<Page id="${page.id}"></Page>`;
      }
    }
    if (cfg.name) page.name = cfg.name;
    if (cfg.emblem) {
      const box = cfg.emblem;
      const x = number(box.x, 'emblem x'), y = number(box.y, 'emblem y');
      const w = number(box.width, 'emblem width'), h = number(box.height, 'emblem height');
      if (!w || !h || !fitsPrintablePage(x, y, w, h)) throw new Error('emblem exceeds the printable page canvas');
      const image = { id: id(), kind: 'image', source: { kind: 'url', url: emblemImage(box, w, h) } };
      spec.elements.push(image);
      layout = layout.replace(new RegExp(`(<Page\\b[^>]*\\bid="${esc(page.id)}"[^>]*>)`),
        `$1\n  <Element elementId="${image.id}" x="${x}" y="${y}" width="${w}" height="${h}"/>`);
    }
    if (cfg.removeSourceHeader) {
      if (!cfg.sourcePage) throw new Error('removeSourceHeader requires sourcePage');
      for (const panel of (spec.panels || []).filter((item) => item.type === 'header' && item.pages?.includes(page.id))) {
        if (panel.pages.some((pageId) => pageId !== page.id)) throw new Error('cannot remove a source header shared with other pages');
        removePanel(panel);
      }
    }
    if (cfg.tableBox || cfg.tableTitle) {
      if (!cfg.sourcePage) throw new Error('table edits require an existing sourcePage');
      const pattern = new RegExp(`(<Page\\b[^>]*\\bid="${esc(page.id)}"[^>]*>)([\\s\\S]*?)(<\/Page>)`);
      const match = layout.match(pattern);
      const tables = (match?.[2].match(/<Element\b[^>]*flow="paginated"[^>]*\/>/g) || []);
      if (tables.length !== 1) throw new Error('table edits require exactly one paginated table on the source page');
      const tableId = tables[0].match(/elementId="([^"]+)"/)?.[1];
      const table = spec.elements.find((e) => e.id === tableId && e.kind === 'table');
      if (!table) throw new Error('source page paginated table is missing');
      if (cfg.tableTitle) {
        if (typeof cfg.tableTitle !== 'string') throw new Error('tableTitle must be text');
        table.name = cfg.tableTitle;
      }
      if (cfg.tableBox) {
        const box = cfg.tableBox;
        const x = number(box.x, 'table x'), y = number(box.y, 'table y');
        const w = number(box.width, 'table width'), h = number(box.height, 'table height');
        if (!w || !h || !fitsPrintablePage(x, y, w, h)) throw new Error('table exceeds the printable page canvas');
        const replacement = tables[0].replace(/\bx="[^"]+"/, `x="${x}"`).replace(/\by="[^"]+"/, `y="${y}"`)
          .replace(/\bwidth="[^"]+"/, `width="${w}"`).replace(/\bheight="[^"]+"/, `height="${h}"`);
        layout = layout.replace(tables[0], replacement);
      }
    }
    if (cfg.backgroundImageUrl || cfg.watermark) {
      if (cfg.backgroundImageUrl && cfg.watermark) throw new Error('choose one background image or watermark per page');
      const imageBox = cfg.imageBox || { x: 120, y: 300, width: width - 240, height: height - 600 };
      const bx = number(imageBox.x, 'image x'), by = number(imageBox.y, 'image y');
      const bw = number(imageBox.width, 'image width'), bh = number(imageBox.height, 'image height');
      if (!bw || !bh || !fitsPrintablePage(bx, by, bw, bh)) {
        throw new Error('image exceeds the printable page canvas');
      }
      const url = cfg.watermark ? watermarkImage(cfg.watermark, bw, bh) : cfg.backgroundImageUrl;
      if (!/^https:\/\//.test(url) && !/^data:image\/svg\+xml;base64,/.test(url)) throw new Error('page image must be HTTPS or a base64 SVG data URI');
      // Report code rejects page.backgroundImage. A bounded, first-in-layout
      // image layer renders in the PDF without creating spill pages.
      const image = { id: id(), kind: 'image', source: { kind: 'url', url } };
      spec.elements.unshift(image);
      const pagePattern = new RegExp(`(<Page\\b[^>]*\\bid="${esc(page.id)}"[^>]*>)([\\s\\S]*?)(<\\/Page>)`);
      layout = layout.replace(pagePattern, (_m, open, inner, close) =>
        `${open}\n  <Element elementId="${image.id}" x="${bx}" y="${by}" width="${bw}" height="${bh}"/>${inner}${close}`);
      backgrounds.push(page.name);
    }
    for (const block of cfg.blocks || []) add(block, page.id);
    created.push(page.name);
  }
  if (manifest.footer) {
    const footer = manifest.footer;
    if (typeof footer.body !== 'string' || !footer.body) throw new Error('footer needs a body');
    const pageIds = footer.pages?.length
      ? footer.pages.map((name) => {
          const page = spec.pages.find((p) => p.name === name);
          if (!page) throw new Error(`footer page ${name} not found`);
          return page.id;
        })
      : spec.pages.map((p) => p.id);
    if (new Set(pageIds).size !== pageIds.length) throw new Error('footer lists a page more than once');
    // Replace earlier converter-created per-page footer panels on the selected
    // pages. Leaving both assigned creates overlapping printed footers.
    const priorFooters = (spec.panels || []).filter((p) => p.type === 'footer' && p.pages?.some((id) => pageIds.includes(id)));
    if (priorFooters.some((p) => p.pages?.some((id) => !pageIds.includes(id)))) throw new Error('footer cannot replace a panel shared with unselected pages');
    for (const panel of priorFooters) removePanel(panel);
    const footerHeight = number(footer.height ?? 56, 'footer height');
    if (!footerHeight) throw new Error('footer height must be positive');
    const panel = { id: id(), type: 'footer', title: 'Print footer', pages: pageIds,
      config: { height: footerHeight } };
    spec.panels ||= [];
    spec.panels.push(panel);
    const text = { id: id(), kind: 'text', body: footer.body };
    spec.elements.push(text);
    const x = number(footer.x ?? 0, 'footer x');
    const y = number(footer.y ?? 0, 'footer y');
    const w = number(footer.width ?? width - 2 * margin, 'footer width');
    const h = number(footer.textHeight ?? 35, 'footer text height');
    if (x + w > width - 2 * margin || y + h > panel.config.height) throw new Error('footer text does not fit its panel');
    const brand = footer.brand;
    let brandNode = '';
    if (brand) {
      const imageWidth = number(brand.width ?? 340, 'footer brand width');
      if (!imageWidth || imageWidth > width - 2 * margin) throw new Error('footer brand exceeds the page canvas');
      const image = { id: id(), kind: 'image', source: { kind: 'url', url: footerMark(brand, imageWidth, footerHeight - 8) } };
      spec.elements.push(image);
      brandNode = `<Element elementId="${image.id}" x="0" y="4" width="${imageWidth}" height="${footerHeight - 8}"/>`;
    }
    layout += `\n<Panel id="${panel.id}" type="footer">${brandNode}<Element elementId="${text.id}" x="${x}" y="${y}" width="${w}" height="${h}"/></Panel>`;
  }
  // A Sigma Report render uses the order of pages[]; keep layout Page blocks
  // in that same order when cover pages are inserted at the start.
  const matches = [...layout.matchAll(/<Page\b[^>]*\bid="([^"]+)"[^>]*>[\s\S]*?<\/Page>/g)];
  const pageBlocks = new Map(matches.map((match) => [match[1], match[0]]));
  const panelBlocks = [...layout.matchAll(/<Panel\b[^>]*>[\s\S]*?<\/Panel>|<Panel\b[^>]*\/>/g)]
    .map((match) => match[0]);
  if (matches.length !== spec.pages.length || pageBlocks.size !== spec.pages.length || spec.pages.some((page) => !pageBlocks.has(page.id))) throw new Error('composed report has missing or duplicate Page layout blocks');
  layout = `<?xml version="1.0" encoding="utf-8"?>\n${spec.pages.map((page) => pageBlocks.get(page.id)).join('\n')}\n${panelBlocks.join('\n')}`;
  spec.layout = layout;
  const after = reportSpecErrors(spec);
  if (after.length) throw new Error(`composed report invalid: ${after.join('; ')}`);
  return { contents: spec, summary: { pages: created, backgrounds, textElements: spec.elements.filter((e) => e.kind === 'text').length - input.elements.filter((e) => e.kind === 'text').length } };
}

if (process.argv[1] && /(?:^|[\\/])compose-print-layout\.mjs$/.test(process.argv[1])) {
  const args = parseArgs(process.argv.slice(2));
  if (!args.spec || !args.blueprint || !args.out) {
    console.error('usage: node scripts/compose-print-layout.mjs --spec <converted-report.json> --blueprint <neutral-layout.json> --out <report.json>');
    process.exit(2);
  }
  const result = composePrintLayout(JSON.parse(readFileSync(args.spec, 'utf8')),
    JSON.parse(readFileSync(args.blueprint, 'utf8')));
  writeFileSync(args.out, JSON.stringify(result.contents, null, 2) + '\n');
  console.log(JSON.stringify(result.summary));
}
