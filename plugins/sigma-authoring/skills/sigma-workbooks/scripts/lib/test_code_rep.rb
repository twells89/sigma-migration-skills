# frozen_string_literal: true
# test_code_rep.rb — run directly: ruby scripts/lib/test_code_rep.rb (from sigma-workbooks/)
#
# Pure-function unit test (no network) for Sigma::CodeRep, the adapter every
# workbook-spec read/write path in wb-rep.rb (and custom-sql-to-data-model's
# scan-workbooks.rb/audit-formulas.rb) routes through to handle the
# document-wrapper wire change.
#
# lib/code_rep.rb mirrors the workbook-only contract maintained in
# sigma-migration-skills/shared/lib/code_rep.rb. Keep behavior aligned when
# either repository changes; the migration repo fans its canonical copy out to
# every vendored plugin.
#
# Canonical contract (differs from the first draft of this adapter):
#   document(r) NARROWS to the live document keys — it does NOT carry metadata.
#   metadata(r) is everything else, minus the removed themeName/themeOverrides.
#   wrap(doc, extra:) takes an ALREADY-BUILT document hash and does not narrow.
# So a caller wanting the flat on-disk shape composes them:
#   metadata(r).merge(document(r))
require_relative 'code_rep'

$f = 0
def check(d)
  ok = yield
  puts(ok ? "[ok] #{d}" : "[FAIL] #{d}")
  $f += 1 unless ok
rescue StandardError => e
  puts "[FAIL] #{d}  [#{e.class}: #{e.message}]"
  $f += 1
end

# A live GET response carrying EVERY document field, including the two the
# first adapter draft omitted (settings, agents).
NESTED_RESPONSE = {
  'name' => 'Demo', 'folderId' => 'fld1', 'workbookId' => 'wb1', 'url' => 'https://x/wb1',
  'document' => {
    'schemaVersion' => 1, 'kind' => 'workbook',
    'elements' => [{ 'id' => 'e1', 'kind' => 'text', 'body' => 'Hello' }],
    'pages' => [{ 'id' => 'p1', 'name' => 'Page 1' }],
    'overlays' => [{ 'id' => 'o1', 'name' => 'Details', 'type' => 'modal' }],
    'panels' => [{ 'id' => 'panel1', 'name' => 'Filters' }],
    'layout' => '<Page id="p1"><Element elementId="e1"/></Page>',
    'settings' => { 'theme' => { 'name' => 'Dark', 'overrides' => { 'hasCards' => 'shown' } },
                    'navigation' => { 'pageHeader' => 'enabled' } },
    'agents' => [{ 'id' => 'a1', 'instructions' => 'help' }]
  }
}.freeze

FLAT_SPEC = {
  'name' => 'Demo', 'folderId' => 'fld1',
  'schemaVersion' => 1,
  'elements' => [{ 'id' => 'e1', 'kind' => 'text', 'body' => 'Hello' }],
  'pages' => [{ 'id' => 'p1', 'name' => 'Page 1' }],
  'overlays' => [], 'panels' => [],
  'layout' => '<Layout/>',
  'settings' => { 'theme' => { 'name' => 'Dark' } },
  'agents' => [{ 'id' => 'a1', 'instructions' => 'help' }]
}.freeze

# A spec written before the theme moved. Still on disk in user repos.
LEGACY_THEME_SPEC = {
  'name' => 'Demo', 'folderId' => 'fld1', 'schemaVersion' => 1,
  'elements' => [], 'pages' => [],
  'themeName' => 'Light',
  'themeOverrides' => { 'categoricalScheme' => %w[#111 #222] }
}.freeze

def flatten_spec(resp)
  Sigma::CodeRep.metadata(resp).merge(Sigma::CodeRep.document(resp))
end

def wrap_for_wire(flat, extra: {})
  doc = Sigma::CodeRep.document(flat)
  doc = doc.merge('kind' => 'workbook') unless doc['kind']
  Sigma::CodeRep.wrap(doc, extra: extra)
end

# --- read path -------------------------------------------------------------

check('document() narrows a nested response to the document payload') do
  d = Sigma::CodeRep.document(NESTED_RESPONSE)
  d['pages'] == NESTED_RESPONSE['document']['pages'] && d['schemaVersion'] == 1
end

check('flatten_spec() gives call sites the flat shape they read (name/url survive)') do
  f = flatten_spec(NESTED_RESPONSE)
  f['name'] == 'Demo' && f['url'] == 'https://x/wb1' && f['pages'].is_a?(Array)
end

# THE regression this suite exists for: the first draft listed only
# schemaVersion/kind/pages/layout, so settings and agents fell through to
# metadata() and were wrapped OUTSIDE `document` — silently dropping the
# workbook's theme and agents on every write.
check('settings survives the read path') do
  Sigma::CodeRep.document(NESTED_RESPONSE).dig('settings', 'theme', 'name') == 'Dark'
end

check('agents survives the read path') do
  Sigma::CodeRep.document(NESTED_RESPONSE)['agents'] == [{ 'id' => 'a1', 'instructions' => 'help' }]
end

check('settings/agents are NOT metadata (they must not leak to the top level)') do
  m = Sigma::CodeRep.metadata(NESTED_RESPONSE)
  !m.key?('settings') && !m.key?('agents')
end

check('elements/overlays/panels survive inside document and never become metadata') do
  d = Sigma::CodeRep.document(NESTED_RESPONSE)
  m = Sigma::CodeRep.metadata(NESTED_RESPONSE)
  d['elements'].size == 1 && d['overlays'].size == 1 && d['panels'].size == 1 &&
    %w[elements overlays panels].none? { |key| m.key?(key) }
end

check('page membership is derived from layout, not nested page elements') do
  element, page = Sigma::CodeRep.workbook_elements_with_pages(NESTED_RESPONSE).first
  element['id'] == 'e1' && page['id'] == 'p1' &&
    !Sigma::CodeRep.document(NESTED_RESPONSE)['pages'].first.key?('elements')
end

check('ownership parser reads canonical Element/Container/TabbedContainer nodes') do
  spec = Marshal.load(Marshal.dump(NESTED_RESPONSE))
  spec['document']['layout'] = <<~XML
    <Page id="p1">
      <Container elementId="container"><Element elementId="child"/></Container>
      <TabbedContainer elementId="tabs"><Tab><Element elementId="tab-child"/></Tab></TabbedContainer>
    </Page>
  XML
  Sigma::CodeRep.workbook_page_element_ids(spec) == {
    'p1' => %w[container child tabs tab-child]
  }
end

check('ownership parser accepts legacy layout aliases for old snapshots only') do
  spec = Marshal.load(Marshal.dump(NESTED_RESPONSE))
  spec['document']['layout'] =
    '<Page id="p1"><GridContainer elementId="old-container">' \
    '<LayoutElement elementId="old-child"/></GridContainer></Page>'
  Sigma::CodeRep.workbook_page_element_ids(spec) == {
    'p1' => %w[old-container old-child]
  }
end

check('ownership parser ignores unknown tags with elementId attributes') do
  spec = Marshal.load(Marshal.dump(NESTED_RESPONSE))
  spec['document']['layout'] =
    '<Page id="p1"><Unknown elementId="not-owned"/><Element elementId="owned"/></Page>'
  Sigma::CodeRep.workbook_page_element_ids(spec) == { 'p1' => ['owned'] }
end

check('ownership parser attributes <Panel>/<Overlay> region blocks by their own id') do
  # Live GET specs emit distinct <Panel> (header/sidebar) and <Overlay> tags,
  # not <Page id="panel-id"> — a panel body must be owned by the panel, never
  # folded into the preceding page (live-confirmed 2026-08-10).
  spec = Marshal.load(Marshal.dump(NESTED_RESPONSE))
  spec['document']['layout'] = <<~XML
    <Page id="p1"><Element elementId="page-el"/></Page>
    <Panel id="hdr"><Element elementId="header-el"/></Panel>
    <Overlay id="ov"><Element elementId="overlay-el"/></Overlay>
  XML
  Sigma::CodeRep.workbook_page_element_ids(spec) == {
    'p1' => ['page-el'], 'hdr' => ['header-el'], 'ov' => ['overlay-el']
  }
end

check('wrap migrates legacy page-nested elements to the current API shape') do
  legacy = {
    'schemaVersion' => 1,
    'pages' => [{ 'id' => 'p1', 'elements' => [{ 'id' => 'old', 'kind' => 'text' }] }]
  }
  wrapped = Sigma::CodeRep.wrap(legacy).fetch('document')
  wrapped['elements'].map { |element| element['id'] } == ['old'] &&
    wrapped['pages'].none? { |page| page.key?('elements') }
end

check('metadata() still returns the real metadata') do
  Sigma::CodeRep.metadata(NESTED_RESPONSE).keys.sort == %w[folderId name url workbookId]
end

# --- write path ------------------------------------------------------------

check('PUT body is {document} only — no name/folderId siblings') do
  wrap_for_wire(FLAT_SPEC).keys == ['document']
end

check('PUT body keeps settings AND agents inside document') do
  d = wrap_for_wire(FLAT_SPEC)['document']
  d.dig('settings', 'theme', 'name') == 'Dark' && d['agents'].is_a?(Array)
end

check('POST top level is exactly name/folderId/document — no settings/agents siblings') do
  body = wrap_for_wire(FLAT_SPEC, extra: Sigma::CodeRep.metadata(FLAT_SPEC))
  body.keys.sort == %w[document folderId name]
end

check('POST body keeps settings AND agents inside document') do
  body = wrap_for_wire(FLAT_SPEC, extra: Sigma::CodeRep.metadata(FLAT_SPEC))
  body.dig('document', 'settings', 'theme', 'name') == 'Dark' &&
    body.dig('document', 'agents').is_a?(Array)
end

check('kind defaults to "workbook" when the on-disk spec omits it') do
  wrap_for_wire(FLAT_SPEC)['document']['kind'] == 'workbook'
end

check('round trip: document(wrap(document(live))) reproduces the document payload') do
  d = Sigma::CodeRep.document(NESTED_RESPONSE)
  Sigma::CodeRep.document(Sigma::CodeRep.wrap(d)) == d
end

# --- legacy theme fold -----------------------------------------------------
# themeName/themeOverrides were REMOVED from the API. Specs written before the
# move are still on disk, so the read path folds them forward rather than
# dropping the theme.

check('legacy themeName folds to settings.theme.name') do
  Sigma::CodeRep.document(LEGACY_THEME_SPEC).dig('settings', 'theme', 'name') == 'Light'
end

check('legacy themeOverrides folds to settings.theme.overrides') do
  Sigma::CodeRep.document(LEGACY_THEME_SPEC)
                .dig('settings', 'theme', 'overrides', 'categoricalScheme') == %w[#111 #222]
end

check('the removed theme keys never survive into the document') do
  d = Sigma::CodeRep.document(LEGACY_THEME_SPEC)
  !d.key?('themeName') && !d.key?('themeOverrides')
end

check('metadata() never returns the removed theme keys') do
  m = Sigma::CodeRep.metadata(LEGACY_THEME_SPEC)
  !m.key?('themeName') && !m.key?('themeOverrides')
end

check('a legacy spec still produces a valid POST body with the theme nested') do
  body = wrap_for_wire(LEGACY_THEME_SPEC, extra: Sigma::CodeRep.metadata(LEGACY_THEME_SPEC))
  body.keys.sort == %w[document folderId name] &&
    body.dig('document', 'settings', 'theme', 'name') == 'Light'
end

# --- emitter helpers -------------------------------------------------------

check('set_theme() writes the current shape and merges overrides') do
  doc = { 'schemaVersion' => 1, 'kind' => 'workbook', 'elements' => [], 'pages' => [] }
  Sigma::CodeRep.set_theme(doc, name: 'Light', overrides: { 'hasCards' => 'shown' })
  Sigma::CodeRep.set_theme(doc, overrides: { 'borderRadius' => 'round' })
  doc.dig('settings', 'theme', 'name') == 'Light' &&
    doc.dig('settings', 'theme', 'overrides').keys.sort == %w[borderRadius hasCards]
end

check('theme() reads the theme from either shape') do
  Sigma::CodeRep.theme(LEGACY_THEME_SPEC)['name'] == 'Light' &&
    Sigma::CodeRep.theme(NESTED_RESPONSE)['name'] == 'Dark'
end

# --- data-model guard ------------------------------------------------------
# The DM code-rep surface is confirmed NOT changing. This adapter is
# workbook-only; wrapping a DM body breaks it.

check('adapter is documented workbook-only (DM callers must not use it)') do
  File.read(File.join(__dir__, 'code_rep.rb')).include?('dataModels')
end

puts($f.zero? ? "\nPASS — all checks" : "\nFAIL — #{$f} check(s) failed")
exit($f.zero? ? 0 : 1)
