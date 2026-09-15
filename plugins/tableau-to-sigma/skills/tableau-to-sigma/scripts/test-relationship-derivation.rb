#!/usr/bin/env ruby
# frozen_string_literal: true
#
# Contract test: object-graph relationships whose join key Tableau did NOT
# serialize must still be wired, and every derivation must be recorded.
#
# WHY: Tableau AUTO-MATCHES relationships by column name at query time, and can
# serialize a relationship whose only usable key is a computed expression Sigma
# cannot join on physically. That is how modern star schemas are built, so the
# converter saw a star and emitted disconnected tables — after which a parity
# gate with no relationships to satisfy it pushes the run into joined/
# aggregated Custom SQL. That is the "flattened star schema" a field report
# described.
#
# LIVE-VERIFIED CORRECTION (2026-08, logical-model-objectgraph fixture): a
# relationship with literally NO <expression> at all — this test's original
# model of "auto-matched, no serialized key" — does not survive a real Tableau
# Server publish (HTTP 400011, "The relationship/expression tag is missing or
# invalid"). Every relationship in genuine Tableau output carries SOME
# expression. The name-inference rung this test exercises is instead reached
# via a relationship whose serialized expression is present but not a usable
# PHYSICAL key (e.g. wrapped in IFNULL/DATETRUNC) — see case 4 (LMOG_DIM_STORE)
# below, now the sole name-inference case in this fixture.
#
# Inference is only safe because inferred keys are written into join-plan.json,
# where gate 16's warehouse uniqueness probe validates them before GREEN. A wrong
# inference becomes a fan-out FATAL, not a silently undercounting model.
#
# Creds-free and network-free: runs the vendored converter over a static .twb.
#
# HOW IT DRIVES THE CONVERTER: converter/tableau.mjs is a library module with no
# CLI entry point — `node converter/tableau.mjs <path>` does nothing (no argv
# handling, no stdout). This test instead follows the established pattern in
# scripts/mechanical-specs.rb's run_converter (see :776-810): write a small ESM
# shim into a throwaway temp dir that imports convertTableauToSigma by name,
# calls it, and writes its result to a JSON file this script then reads. The
# `bare = out.model || out.sigmaDataModel || out` idiom is lifted verbatim from
# that production path — it is what actually unwraps the model regardless of
# which key generation the converter returns it under.
#
# Usage: ruby scripts/test-relationship-derivation.rb
# Override the .twb for local sanity-checking the harness itself (never set in
# CI/production): TEST_RELATIONSHIP_DERIVATION_TWB=/path/to.twb ruby ...

require 'json'
require 'open3'
require 'tmpdir'
require 'set'
require_relative 'lib/join_plan'

HERE      = File.expand_path(__dir__)
FIXTURE   = File.expand_path('../../../../../corpus/tableau/logical-model-objectgraph', HERE)
TWB       = File.join(FIXTURE, 'workbook-content.twb')
CONVERTER = File.join(HERE, '..', 'converter', 'tableau.mjs')

fails = []
def check(cond, msg, fails)
  fails << msg unless cond
  puts "  #{cond ? 'PASS' : 'FAIL'}  #{msg}"
end

# Locate the elements array without assuming one fixed nesting depth: today the
# converter returns { model: { pages: [{ elements }] }, ... }, but a bare
# top-level `elements` key is also plausible for a future shape. Rather than
# crash the whole run on a shape change, record it as a diagnosable FAILURE (so
# every other assertion still reports) naming exactly what was found instead.
def locate_elements(model, fails)
  return model['elements'] if model.is_a?(Hash) && model['elements'].is_a?(Array)
  if model.is_a?(Hash) && model['pages'].is_a?(Array) &&
     model['pages'][0].is_a?(Hash) && model['pages'][0]['elements'].is_a?(Array)
    return model['pages'][0]['elements']
  end
  found = model.is_a?(Hash) ? "a Hash with keys #{model.keys.inspect}" : model.class.to_s
  msg = "cannot locate elements array on converter output model " \
        "(checked ['elements'] and ['pages'][0]['elements']; found #{found})"
  check(false, msg, fails)
  []
end

# Same normalization the converter's own candidateNames()/colIdMap keys apply
# (converter/tableau.mjs, PR2a derivation ladder): strip a trailing "(...)"
# annotation a metadata-record caption may carry (e.g. "Order Date (Order
# Date)"), collapse whitespace to underscore, uppercase. Applied identically
# to BOTH sides below (the .twb's declared names and the model's resolved
# display names) so the two are comparable.
def normalize_name(n)
  return nil if n.nil?
  n.to_s.sub(/\s*\([^)]*\)\s*\z/, '').strip.gsub(/\s+/, '_').upcase
end

# Finding 1 (review, 2026-07-30): the anti-fabrication check must NOT compare
# against element.columns, because ensureCol (converter/tableau.mjs) PUSHES
# whatever name it's given into element.columns as its very mechanism for
# supplying a serialized-but-not-yet-materialized physical key — a fabricated
# guess would appear there just as legitimately as a real column and the
# check would always pass. The .twb itself — its <metadata-record> captions
# and <column name="..."> attributes — is what Tableau actually declared; a
# fabricated name cannot appear there. This scans the fixture's raw XML
# (regex, not the full XML parser tableau.mjs uses) for both column-
# declaration shapes the converter's collection-branch column build loop
# reads from (converter/tableau.mjs ~4762-4792): metadata-record class="column"
# blocks (caption / remote-alias / local-name, in that fallback order — same
# as the converter) and plain <column name="..."> attributes (the no-
# metadata-records fallback path).
def declared_twb_column_names(twb_path)
  raw = File.read(twb_path, encoding: 'utf-8')
  names = []
  raw.scan(/<column\b[^>]*\bname=(["'])(.*?)\1/m) { |_, n| names << n }
  raw.scan(/<metadata-record\b[^>]*>.*?<\/metadata-record>/m).each do |block|
    next unless block =~ /\bclass=(["'])column\1/
    cap = block[/<caption>(.*?)<\/caption>/m, 1] ||
          block[/<remote-alias>(.*?)<\/remote-alias>/m, 1] ||
          block[/<local-name>(.*?)<\/local-name>/m, 1]
    names << cap if cap
  end
  names.map { |n| normalize_name(n) }.reject { |n| n.nil? || n.empty? }.to_set
end

def display_name_for(el, col_id)
  col = (el['columns'] || []).find { |c| c['id'] == col_id }
  return nil unless col
  col['name'] || (col['formula'].is_a?(String) && col['formula'][/\/([^\]]+)\]\z/, 1])
end

twb_path = ENV['TEST_RELATIONSHIP_DERIVATION_TWB'] || TWB
abort "fixture missing: #{twb_path}" unless File.exist?(twb_path)

# Run the vendored converter over a .twb and capture model + coverage. Same
# shim mechanics as before, factored out so the deny-list scenarios below can
# convert surgically-modified fixture variants.
def run_converter_capture(twb)
  doc = nil
  Dir.mktmpdir('relationship-derivation') do |dir|
    shim = File.join(dir, '_convert_tableau.mjs')
    out_path = File.join(dir, 'out.json')
    # Node ESM on Windows rejects a bare drive-letter specifier
    # (ERR_UNSUPPORTED_ESM_URL_SCHEME, protocol 'c:') — absolute paths must be
    # file:// URLs there. Same guard as mechanical-specs.rb's run_converter.
    import_specifier =
      if Gem.win_platform? && CONVERTER.match?(/\A[A-Za-z]:/)
        'file:///' + CONVERTER.gsub('\\', '/')
      else
        CONVERTER
      end
    File.write(shim, <<~JS)
      import { readFileSync, writeFileSync } from 'node:fs';
      import { convertTableauToSigma } from #{import_specifier.to_json};
      const xml = readFileSync(#{twb.to_json}, 'utf8');
      const out = convertTableauToSigma(xml, {
        connectionId: 'test-conn', database: 'TESTDB', schema: 'TESTSCHEMA', tableMapping: {},
      });
      const bare = out.model || out.sigmaDataModel || out;
      writeFileSync(#{out_path.to_json}, JSON.stringify({
        model: bare,
        relationshipCoverage: out.relationshipCoverage || null,
        warnings: out.warnings || []
      }, null, 2));
    JS
    o, e, st = Open3.capture3('node', shim)
    warn e unless e.empty?
    abort "converter failed (exit #{st.exitstatus}):\n#{e}#{o}" unless st.success?
    doc = JSON.parse(File.read(out_path))
  end
  doc
end

doc = run_converter_capture(twb_path)

puts 'test-relationship-derivation.rb — object-graph key derivation'

cov = doc['relationshipCoverage'] || {}
check(cov['serialized'].to_i == 5,
      "coverage reports all 5 serialized relationships (got #{cov['serialized'].inspect})", fails)
entries = cov['entries'] || []
by_target = entries.each_with_object({}) { |e, h| h[e['right']] = e }
# The plain-physical-key, mixed-key, computed-only-but-name-inferred, and
# 5th (new, plain physical) relationships MUST wire. The computed-only/
# no-shared-name one may legitimately stay unwired under the conservative rule
# (no key-shaped name match) — what matters is that it is RECORDED, never
# silently absent.
check(cov['wired'].to_i >= 4,
      "at least the plain-physical-key, mixed-key, computed-only-but-name-inferred, and 5th relationships " \
      "are WIRED (got #{cov['wired'].inspect}) — fewer means the star still becomes disconnected tables", fails)
check(entries.length == 5,
      "all 5 relationships appear in the ledger, wired or not (got #{entries.length})", fails)

entries = cov['entries'] || []
by_target = entries.each_with_object({}) { |e, h| h[e['right']] = e }

# 1. PLAIN PHYSICAL KEY (CUSTOMER_KEY = CUSTOMER_KEY). LIVE-VERIFIED CORRECTION
#    (see header note above): this fixture originally modeled this
#    relationship with NO serialized expression at all ("auto-matched, no
#    serialized key"), to exercise name-inference on a relationship Tableau
#    itself never wrote a key for. Publishing that shape to real Tableau
#    Server 400s — every relationship needs an expression — so this case is
#    now a plain serialized physical key instead. It still proves the
#    baseline "serialized physical key wires cleanly" rung; name-inference is
#    now exercised solely by case 4 (LMOG_DIM_STORE) below.
cust = by_target['LMOG_DIM_CUSTOMER'] || {}
check(cust['derivedVia'] == 'serialized',
      "plain-physical-key LMOG_FACT_WIDE->LMOG_DIM_CUSTOMER is derived as serialized (got #{cust['derivedVia'].inspect})",
      fails)
check(cust['partial'] != true, 'plain-physical-key relationship is not marked partial', fails)

# 2. MIXED keys: physical subset wired, computed condition recorded as dropped.
prod = by_target['LMOG_DIM_PRODUCT'] || {}
check(prod['derivedVia'] == 'serialized',
      "mixed-key LMOG_FACT_WIDE->LMOG_DIM_PRODUCT keeps its serialized physical key (got #{prod['derivedVia'].inspect})",
      fails)
check(prod['partial'] == true && prod['droppedConditions'].to_i >= 1,
      'mixed-key relationship is marked partial with a dropped-condition count', fails)

# 3. COMPUTED-ONLY key, inference fails (no shared key-shaped name): no physical
#    column to join on, so inference by name is the only route. Whatever the
#    outcome, it must be RECORDED, never silently absent.
date = by_target['LMOG_DIM_DATE'] || {}
check(!date.empty?, 'computed-key LMOG_FACT_WIDE->LMOG_DIM_DATE appears in the coverage ledger', fails)
check(%w[serialized name-inference unwired].include?(date['derivedVia']),
      "computed-key relationship records a known derivedVia (got #{date['derivedVia'].inspect})", fails)

# 4. COMPUTED-ONLY key, inference SUCCEEDS (review fix-wave, 2026-07-30,
#    Important finding 2 — this is now the fixture's SOLE name-inference case,
#    since case 1 above moved to a plain serialized key): FACT_WIDE/DIM_STORE's
#    sole condition (IFNULL([STORE_KEY],-1) = [STORE_KEY]) is computed on its
#    left operand, so no physical pair survives — but STORE_KEY is a shared
#    key-shaped column name on both sides, so name-inference wires it. Before
#    the fix this wired cleanly with no partial/droppedConditions, hiding that
#    the IFNULL condition Tableau required was dropped (a WIDER-than-Tableau
#    join). The ledger entry must now say so explicitly, exactly like the
#    mixed-key case.
store = by_target['LMOG_DIM_STORE'] || {}
check(store['derivedVia'] == 'name-inference',
      "computed-only-but-name-matched LMOG_FACT_WIDE->LMOG_DIM_STORE is derived by name-inference " \
      "(got #{store['derivedVia'].inspect})", fails)
check(store['partial'] == true && store['droppedConditions'].to_i >= 1,
      'computed-only-but-name-inferred relationship is marked partial with a dropped-condition count ' \
      '(a wider-than-Tableau join must never look clean)', fails)

# 5. NEW (live-fixture addition, orthogonal to the derivation ladder): a plain
#    serialized physical equality key with no complexity at all. Exists to
#    exercise gate 16's join-cardinality probe live (LMOG_DIM_REGION is
#    deliberately non-unique on REGION_KEY in the live warehouse fixture —
#    see MANIFEST.md's live validation section) — the offline converter
#    check here only proves the key wires; the non-uniqueness itself is a
#    live-warehouse-only behavior no offline check can exercise.
region = by_target['LMOG_DIM_REGION'] || {}
check(region['derivedVia'] == 'serialized',
      "plain-physical-key LMOG_FACT_WIDE->LMOG_DIM_REGION is derived as serialized (got #{region['derivedVia'].inspect})",
      fails)
check(region['partial'] != true, 'plain-physical-key LMOG_FACT_WIDE->LMOG_DIM_REGION relationship is not marked partial', fails)

# 5. Every wired relationship's keys must trace back to a column NAME the
#    .twb itself declared — not merely one present in element.columns, which
#    ensureCol will happily contain a fabricated name in (see
#    declared_twb_column_names above). This is the actual anti-fabrication
#    check; an inferred key resolving to a name absent from the .twb source
#    of truth is a fabrication regardless of what element.columns says.
declared_names = declared_twb_column_names(twb_path)
els = locate_elements(doc['model'] || {}, fails)
by_id = els.each_with_object({}) { |e, h| h[e['id']] = e }
bad = []
els.each do |el|
  (el['relationships'] || []).each do |rel|
    tgt = by_id[rel['targetElementId']]
    (rel['keys'] || []).each do |k|
      src_name = normalize_name(display_name_for(el, k['sourceColumnId']))
      tgt_name = tgt && normalize_name(display_name_for(tgt, k['targetColumnId']))
      ok = src_name && declared_names.include?(src_name) &&
           tgt_name && declared_names.include?(tgt_name)
      bad << "#{el['id']}->#{rel['targetElementId']} (src=#{src_name.inspect}, tgt=#{tgt_name.inspect})" unless ok
    end
  end
end
check(bad.empty?,
      "every wired key's column name is DECLARED in the .twb itself, not merely present in " \
      "element.columns post-ensureCol (offenders: #{bad.uniq.join(', ')})",
      fails)

# 6. The ledger gate 16 probes must carry the derivation, so an INFERRED key is
#    proven against the warehouse rather than trusted. This is the entire safety
#    argument for inference.
src = File.read(File.join(HERE, 'lib', 'join_plan.rb'))
check(src.include?('derived_via'),
      'join_plan.rb records derived_via on each entry so gate 16 probes inferred keys', fails)
check(src.include?('partial'),
      'join_plan.rb records partial for a mixed-key relationship (a wider join than Tableau\'s)',
      fails)

# 7. BEHAVIORAL pin (not a source grep): JoinPlan.derive must actually RECOVER
#    the name-inferred LMOG_FACT_WIDE->LMOG_DIM_STORE relationship — the .twb's
#    sole serialized condition for it (IFNULL([STORE_KEY],-1) = [STORE_KEY]) is
#    computed, not a bare physical key, so this only passes if join_plan.rb
#    reads the converter's dm-spec relationships (dm_object_graph_index), not
#    merely if it mentions the string "derived_via" somewhere. This is the
#    check that pins the recovery branch AND the dm-spec/.twb name-matching
#    together. (Pinned against LMOG_DIM_STORE, not LMOG_DIM_CUSTOMER, per the
#    header's live-verified correction: LMOG_DIM_CUSTOMER now carries a plain
#    serialized physical key, so it is derived as "serialized", not
#    "name-inference" — LMOG_DIM_STORE is this fixture's only remaining
#    name-inference case.)
jp_entries = JoinPlan.derive(doc['model'], File.read(twb_path, encoding: 'UTF-8'))
store_jp = jp_entries.find { |e| e['left'] == 'LMOG_FACT_WIDE' && e['right'] == 'LMOG_DIM_STORE' }
check(!store_jp.nil?,
      'JoinPlan.derive recovers a join-plan.json entry for the name-inferred LMOG_FACT_WIDE->LMOG_DIM_STORE ' \
      'relationship (absent before this task — nothing for gate 16 to probe)', fails)
check(store_jp && store_jp['derived_via'] == 'name-inference',
      "recovered entry's derived_via is name-inference (got #{(store_jp || {})['derived_via'].inspect})", fails)
check(store_jp && store_jp['probe_keys'] == ['STORE_KEY'],
      "recovered entry's probe_keys resolve to the physical inferred key (got #{(store_jp || {})['probe_keys'].inspect})",
      fails)

# 8. COMPOSITION (wave/2-integration merge of #569 + W2-OM): the derivation
#    ladder decides WHICH keys wire; the object-model passes decide HOW edges
#    attach (evidence-ranked fact election, pass-2 orientation). These are two
#    independently-authored rewrites of the same loop, so pin their composed
#    behavior at the ELEMENT level, not just in the coverage ledger:
#      - the name-INFERRED edge must ride pass 2 like a serialized one and
#        attach to the ELECTED fact (a doc-order attachment, or an inference
#        rung that bypasses orientation, both fail here);
#      - derivedVia and the partial/droppedConditions census must SURVIVE
#        pass-2 attachment onto the relationship object itself.
#    Table/relationship names below are this fixture's real LMOG_-prefixed
#    ones (see the header's live-verified correction), and the name-inference
#    edge checked is LMOG_DIM_STORE (this fixture's sole name-inference case
#    now — LMOG_DIM_CUSTOMER moved to a plain serialized key; see case 1's
#    comment above).
fact_el = els.find { |e| ((e['source'] || {})['path'] || []).last == 'LMOG_FACT_WIDE' }
check(!fact_el.nil?, 'composition: LMOG_FACT_WIDE element located by warehouse source path', fails)
rels_on_fact = fact_el ? (fact_el['relationships'] || []) : []
store_pass2_rel = rels_on_fact.find { |r| r['name'] == 'LMOG_DIM_STORE' }
check(!store_pass2_rel.nil?,
      'composition: the name-inferred LMOG_DIM_STORE edge attaches to the ELECTED fact via pass-2 ' \
      'orientation (not first-end-point document order)', fails)
check(store_pass2_rel && store_pass2_rel['derivedVia'] == 'name-inference',
      "composition: derivedVia survives pass-2 attachment on the element relationship " \
      "(got #{(store_pass2_rel || {})['derivedVia'].inspect})", fails)
check(store_pass2_rel && store_pass2_rel['partial'] == true && store_pass2_rel['droppedConditions'].to_i >= 1,
      'composition: partial/droppedConditions survive pass-2 attachment (wider-than-Tableau join ' \
      'stays visible on the wired relationship object)', fails)
check(!rels_on_fact.empty? && rels_on_fact.all? { |r| %w[serialized name-inference].include?(r['derivedVia']) },
      'composition: every relationship attached in pass 2 carries a known derivedVia', fails)
check((doc['warnings'] || []).any? { |w| w.include?('fact election') && w.include?('"LMOG_FACT_WIDE"') },
      'composition: evidence-ranked fact election ran and announced LMOG_FACT_WIDE', fails)

# ── deny-list: unique-on-right NON-keys never inferred as join keys ─────────
# TJ handoff §3+§6d (disclosed residual hole): EXTERNAL_ID / ROW_ID / GUID /
# HASH_KEY are key-shaped by suffix and often unique on the right — but they
# are lineage/tech columns, not the relationship key. Gate 16's probe proves
# UNIQUENESS, not CORRECTNESS, so a wired one silently returns wrong rows.
# Two directions pinned on surgically-modified fixture variants:
#   (a) deny blocks the wrong wire: the ONLY shared key-shaped name on the
#       store pair (the fixture's sole name-inference case) is EXTERNAL_ID →
#       unwired, reason names the deny-list;
#   (b) deny rescues a right wire: EXTERNAL_ID beside the genuine STORE_KEY
#       previously made 2 key-shaped candidates (ambiguous → refuse); denied
#       from candidacy, the genuine key wires alone.
puts ''
puts 'deny-list: unique-on-right non-keys'
raw_twb = File.read(TWB, encoding: 'utf-8')

Dir.mktmpdir('deny-a') do |dir|
  variant = raw_twb.gsub('store_key', 'external_id').gsub('Store Key', 'External Id')
  vp = File.join(dir, 'variant-a.twb')
  File.write(vp, variant)
  vdoc = run_converter_capture(vp)
  vcust = ((vdoc['relationshipCoverage'] || {})['entries'] || []).find { |e| e['right'] == 'LMOG_DIM_STORE' } || {}
  check(vcust['derivedVia'] == 'unwired',
        "sole shared key-shaped name EXTERNAL_ID → unwired, never guessed (got #{vcust['derivedVia'].inspect})", fails)
  check(vcust['reason'].to_s =~ /deny/i && vcust['reason'].to_s.include?('EXTERNAL_ID'),
        "unwired reason names the deny-list and the denied column (got #{vcust['reason'].inspect})", fails)
end

Dir.mktmpdir('deny-b') do |dir|
  # Twin every customer_key metadata-record (both parents) as external_id, so
  # BOTH sides share customer_key AND external_id.
  variant = raw_twb.gsub(/<metadata-record class='column'>\s*<remote-name>store_key<\/remote-name>.*?<\/metadata-record>/m) do |block|
    block + "\n" + block.gsub('store_key', 'external_id').gsub('Store Key', 'External Id')
  end
  vp = File.join(dir, 'variant-b.twb')
  File.write(vp, variant)
  vdoc = run_converter_capture(vp)
  vcust = ((vdoc['relationshipCoverage'] || {})['entries'] || []).find { |e| e['right'] == 'LMOG_DIM_STORE' } || {}
  check(vcust['derivedVia'] == 'name-inference',
        "genuine STORE_KEY beside denied EXTERNAL_ID still wires (no false ambiguity; got #{vcust['derivedVia'].inspect})", fails)
end

puts ''
puts 'normalized-name collision: never trust the last colIdMap write'
Dir.mktmpdir('collision') do |dir|
  # Add a second, distinct FACT column whose display name normalizes to the
  # same STORE_KEY inference key ("Store  Key" -> STORE_KEY). The converter's
  # legacy colIdMap assignment kept only the last writer and could wire a real
  # but wrong column id with no signal.
  variant = raw_twb.sub(
    /<metadata-record class='column'>\s*<remote-name>store_key<\/remote-name>.*?<parent-name>\[LMOG_FACT_WIDE\]<\/parent-name>.*?<\/metadata-record>/m
  ) do |block|
    shadow = block.gsub('store_key', 'store_key_shadow').gsub('Store Key', 'Store  Key')
    block + "\n" + shadow
  end
  vp = File.join(dir, 'variant-collision.twb')
  File.write(vp, variant)
  vdoc = run_converter_capture(vp)
  vstore = ((vdoc['relationshipCoverage'] || {})['entries'] || [])
           .find { |e| e['right'] == 'LMOG_DIM_STORE' } || {}
  check(vstore['derivedVia'] == 'unwired',
        "normalized STORE_KEY collision leaves the relationship unwired (got #{vstore['derivedVia'].inspect})", fails)
  check(Array(vstore['collisions']).include?('STORE_KEY') &&
        vstore['reason'].to_s.include?('normalized column name collision'),
        "coverage names STORE_KEY collision and the refusal reason (got #{vstore.inspect})", fails)
end

puts ''
if fails.empty?
  puts 'test-relationship-derivation.rb: ALL PASS'
  exit 0
else
  puts "test-relationship-derivation.rb: #{fails.size} FAILURE(S)"
  fails.each { |f| puts "  - #{f}" }
  exit 1
end
