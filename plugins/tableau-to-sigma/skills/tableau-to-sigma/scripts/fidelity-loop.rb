#!/usr/bin/env ruby
# frozen_string_literal: true
#
# fidelity-loop.rb — Phase 5g Render-Compare-Fix (RCF) loop MECHANICS.
#
# The exemplar hand migrations reached near-exact parity by iterating a
# render → compare → classify → fix loop that the one-shot builder never runs.
# This script is the mechanical spine of that loop; the JUDGMENT stays with the
# agent (it reads the render vs the source and decides what's wrong). Per pass:
#
#   RENDER   `fidelity-loop.rb render`   → export the live page to rcf-pass-N.png,
#            bump the pass counter, print the scored rubric (refs/fidelity-rubric.md)
#            + the source image path for the agent to compare against, enforce the
#            pass budget.
#   COMPARE  (agent) Reads rcf-pass-N.png against the source dashboard PNG, scores
#            each rubric dimension.
#   CLASSIFY (agent) `fidelity-loop.rb record` each delta as
#            spec-fixable | ui-only | sigma-capability | data.
#   FIX      `fidelity-loop.rb apply-patch` → a SINGLE layout-preserving PUT (GET
#            the full live spec, deep-merge the agent's patch, PUT the whole spec
#            back so the layout is never wiped — the PUT-wipes-layout trap), then
#            re-run the column-type guard + layout/control lint. Marks the resolved
#            deltas.
#   LOOP     until zero unresolved spec-fixable deltas remain, or max_passes.
#   EXIT     the ledger (fidelity-ledger.json) is the gate input: assert-phase6-ran.rb
#            --require-fidelity-ledger blocks GREEN while any spec-fixable delta is
#            unresolved and not named in --accept-residuals.
#
# DATA-CLASS deltas are special: `data` means the rendered VALUES diverge from
# the source — the numbers are wrong. Unresolved data-class entries block the
# gate whenever the ledger exists (no --require-fidelity-ledger needed), and
# --accept-residuals does NOT apply to them. Fix the spec/data and `resolve`
# the entry, or — only after PROVING the values match — re-record it under its
# true class with the evidence.
#
# Recipes for each delta→fix live in refs/fidelity-recipes.md. See SKILL.md Phase 5g.
#
# Subcommands
#   init        --workdir DIR --workbook-id ID [--page-id ID] [--source-image PNG]
#               [--max-passes N (default 5)]
#               --page-id omitted → auto-pick the page with the most VISIBLE
#               (non-hidden) elements from <workdir>/wb-ids.json + wb-spec.json
#               (#422: first-by-order picked a helper-table data page); ties
#               warn. An explicit --page-id also OVERRIDES the page on an
#               existing same-workbook ledger (entries preserved).
#   render      --workdir DIR [--width 1920 --height 1500]   (needs a live workbook)
#   record      --workdir DIR --dimension D --delta "..." --class C
#               [--fix "..."] [--resolved]
#   resolve     --workdir DIR (--entry N | --dimension D)    mark entry(ies) resolved
#   apply-patch --workdir DIR --patch patch.json             GET→merge→normalize→PUT→guard→lint
#               ALSO deep-merges the patch into <workdir>/wb-spec.json (when it
#               exists and parses) so a re-entry full-spec PUT carries the fix
#               instead of reverting it (#422: live-only patches were wiped).
#               [--full-spec spec.json]  replace the whole spec instead of merging
#               [--skip-style-normalize REASON]  waive the v5.1 style contract (named)
#               [--resolves 0,2,3]       mark these ledger entries resolved on success
#               [--dry-run --live-spec f.json --out merged.json]  no network (tests)
#   status      --workdir DIR [--accept-residuals id,id]     print ledger + gate verdict
#
# Exit codes: 0 ok; 2 usage; 3 pass budget exhausted; 4 apply/PUT failed;
#             5 post-fix guard/lint failed; 6 status: unresolved spec-fixable remain.

require 'json'
require_relative 'lib/cli_encoding'
require_relative 'lib/code_rep'
require_relative 'lib/workbook_code'
require 'optparse'

# ---------------------------------------------------------------------------
# Pure, IO-free core — unit-tested in test-fidelity-loop.rb.
# ---------------------------------------------------------------------------
module FidelityLoop
  CLASSES = %w[spec-fixable ui-only sigma-capability data].freeze
  # Keys tried, in order, to merge two arrays of Hashes element-by-element
  # rather than replacing the whole array. Covers Sigma spec shapes (pages have
  # `id`; elements `elementId`/`id`; controls `id`).
  MERGE_KEYS = %w[elementId id nodeId name].freeze

  module_function

  def new_ledger(workbook_id:, page_id:, source_image: nil, max_passes: 5)
    {
      'workbook_id'  => workbook_id,
      'page_id'      => page_id,
      'source_image' => source_image,
      'max_passes'   => max_passes,
      'pass'         => 0,
      'renders'      => [],
      'entries'      => []
    }
  end

  # Deep-merge `patch` INTO `base`, returning a new object. Hashes merge
  # recursively; arrays-of-hashes that share a stable id key merge per-element
  # (so an agent can patch one element's style without re-listing the array);
  # everything else (scalars, keyless arrays) is REPLACED by the patch value.
  def deep_merge(base, patch)
    return patch unless base.is_a?(Hash) && patch.is_a?(Hash)
    out = base.dup
    patch.each do |k, v|
      out[k] = if out.key?(k) && out[k].is_a?(Hash) && v.is_a?(Hash)
                 deep_merge(out[k], v)
               elsif out.key?(k) && out[k].is_a?(Array) && v.is_a?(Array)
                 merge_arrays(out[k], v)
               else
                 v
               end
    end
    out
  end

  def merge_arrays(base, patch)
    key = MERGE_KEYS.find { |mk| base.all? { |e| e.is_a?(Hash) && e.key?(mk) } && patch.all? { |e| e.is_a?(Hash) && e.key?(mk) } }
    return patch.dup unless key # keyless / mixed arrays → replace wholesale
    merged = base.map(&:dup)
    index = {}
    merged.each_with_index { |e, i| index[e[key]] = i }
    patch.each do |pe|
      if (i = index[pe[key]])
        merged[i] = deep_merge(merged[i], pe)
      else
        index[pe[key]] = merged.length
        merged << pe
      end
    end
    merged
  end

  # Entries that still BLOCK the gate: spec-fixable, not resolved, not named in
  # `accepted` (residual ids the operator explicitly waived).
  def unresolved_specfixable(ledger, accepted = [])
    accepted = Array(accepted).map(&:to_s)
    (ledger['entries'] || []).each_with_index.select do |e, i|
      e['cls'] == 'spec-fixable' && !e['resolved'] &&
        !accepted.include?(i.to_s) && !accepted.include?(e['id'].to_s)
    end.map(&:last)
  end

  # Unresolved data-class entries — the numbers are wrong. These block the
  # gate UNCONDITIONALLY: no accepted-residual list applies (see file header).
  def unresolved_data(ledger)
    (ledger['entries'] || []).each_with_index
                             .select { |e, _i| e['cls'] == 'data' && !e['resolved'] }
                             .map(&:last)
  end

  def ledger_ok?(ledger, accepted = [])
    unresolved_specfixable(ledger, accepted).empty?
  end

  def add_entry(ledger, dimension:, delta:, cls:, fix: nil, resolved: false, pass: nil, evidence: nil)
    raise ArgumentError, "class must be one of #{CLASSES.join('/')}" unless CLASSES.include?(cls)
    entry = {
      'id'        => "e#{(ledger['entries'] || []).length}",
      'pass'      => pass || ledger['pass'],
      'dimension' => dimension,
      'delta'     => delta,
      'cls'       => cls,
      'fix'       => fix,
      'resolved'  => !!resolved
    }
    entry['evidence'] = evidence if evidence
    (ledger['entries'] ||= []) << entry
    entry
  end

  # A delta describing a chart that renders no data / is empty. Such a delta means
  # the ROWS ARE MISSING — a data-class defect — and must NEVER be laundered as
  # a cosmetic (sigma-capability / ui-only) residual to dodge the data-class hard
  # block. (2026-07 field failure: exactly this delta was classed sigma-capability
  # on the FALSE theory "Sigma's export API doesn't run queries," and a dataless
  # dashboard shipped GREEN.)
  #
  # Match the rendered-EMPTY state precisely, NOT any mention of "data"/"blank"
  # (review-caught false positives: "no data LABELS", "no data-label PADDING",
  # "no data TICKS", "BLANK CHART BACKGROUND color" are cosmetic, not empty-state).
  # A viz noun that can carry data (so "legend"/"axis"/"background" don't trigger).
  _NOUN = '(?:chart|charts|tile|tiles|dashboard|panel|viz|pivot|table|render|element)'
  NO_DATA_RX = Regexp.new(
    '\bno[\s-]?data\b(?![\s-]*(?:label|point|tick|marker|mark|pad|value|ink|axis|grid|legend|colou?r|background|border|title))' \
    "|\\b#{_NOUN}s?\\s+(?:is|are|was|were|came\\s+back|comes?\\s+back|returned?|renders?|shows?|displays?)\\s+(?:empty|blank|no\\s+data)\\b" \
    '|\bempty\s+(?:data\s+)?(?:export|result)s?\b' \
    '|\b(?:zero|no)\s+rows?\b' \
    '|renders?\s+nothing',
    Regexp::IGNORECASE)
  def no_data_delta?(delta)
    delta.to_s =~ NO_DATA_RX ? true : false
  end

  # ---- RCF page picking (#422) ---------------------------------------------
  # Elements that actually RENDER content on the page: hidden helpers carry
  # visibleAsSource:false (the master + LOD/window helper tables), and a
  # hidden:true element/page never renders. Everything else counts.
  def visible_count(page)
    (page['elements'] || []).count do |e|
      e.is_a?(Hash) && e['visibleAsSource'] != false && e['hidden'] != true
    end
  end

  # Pick the RCF page from an array of page hashes ({'id','name','elements'}):
  # the page with the MOST visible elements — not first-by-order, which picked
  # a second data page carrying only hidden helper tables (#422 live run).
  # Returns [picked_page_or_nil, tied_pages] — tied_pages has >1 entry when
  # several pages share the top count (caller warns; pick is first-by-order
  # among the ties, deterministic).
  def pick_rcf_page(pages)
    cands = Array(pages).select { |p| p.is_a?(Hash) && p['id'] }
    return [nil, []] if cands.empty?
    scored = cands.map { |p| [visible_count(p), p] }
    best = scored.map { |s, _| s }.max
    top = scored.select { |s, _| s == best }.map { |_, p| p }
    [top.first, top]
  end
end

# ---------------------------------------------------------------------------
# CLI (IO / REST / subprocess) — thin wrapper around the pure core above.
# ---------------------------------------------------------------------------
return if $PROGRAM_NAME != __FILE__ && !ENV['FIDELITY_LOOP_CLI'] # allow `require` in tests

HERE = __dir__
LEDGER_NAME = 'fidelity-ledger.json'
EXHAUSTED_NAME = 'rcf-exhausted.json'

def die(msg, code = 2)
  warn "FATAL: #{msg}"
  exit code
end

def ledger_path(dir)
  File.join(dir, LEDGER_NAME)
end

def exhausted_path(dir)
  File.join(dir, EXHAUSTED_NAME)
end

def write_exhausted(dir, ledger)
  latest = Array(ledger['renders']).last
  File.write(
    exhausted_path(dir),
    JSON.pretty_generate(
      'status' => 'exhausted',
      'workbook_id' => ledger['workbook_id'],
      'page_id' => ledger['page_id'],
      'pass' => ledger['pass'],
      'max_passes' => ledger['max_passes'],
      'latest_render' => latest,
      'recorded_at' => Time.now.utc.strftime('%Y-%m-%dT%H:%M:%SZ')
    )
  )
end

def load_ledger(dir)
  p = ledger_path(dir)
  die "no #{p} — run `fidelity-loop.rb init` first", 2 unless File.exist?(p)
  JSON.parse(File.read(p))
end

def save_ledger(dir, ledger)
  File.write(ledger_path(dir), JSON.pretty_generate(ledger))
end

# #422: --page-id omitted at init → pick the page with the most VISIBLE
# (non-hidden) elements. Live page ids come from wb-ids.json (the readback);
# element visibility (visibleAsSource:false hidden helpers) only lives in
# wb-spec.json — join the two by page name. Dies (usage) when neither file
# yields a page.
def auto_pick_rcf_page(dir)
  wb_ids  = (JSON.parse(File.read(File.join(dir, 'wb-ids.json'))) rescue nil)
  wb_spec = (JSON.parse(File.read(File.join(dir, 'wb-spec.json'))) rescue nil)
  wb_ids = WorkbookCode.legacy_view(wb_ids) if wb_ids
  wb_spec = WorkbookCode.legacy_view(wb_spec) if wb_spec
  spec_by_name = {}
  ((wb_spec && wb_spec['pages']) || []).each { |p| spec_by_name[p['name']] = p if p.is_a?(Hash) }
  pages = (((wb_ids && wb_ids['pages']) || (wb_spec && wb_spec['pages'])) || []).map do |p|
    next nil unless p.is_a?(Hash) && p['id']
    sp = spec_by_name[p['name']]
    { 'id' => p['id'], 'name' => p['name'],
      'elements' => ((sp && sp['elements']) || p['elements']) || [] }
  end.compact
  pick, top = FidelityLoop.pick_rcf_page(pages)
  die 'no --page-id given and no pages found in <workdir>/wb-ids.json or wb-spec.json to auto-pick from', 2 unless pick
  if top.length > 1
    warn "WARN: #{top.length} pages tie at #{FidelityLoop.visible_count(pick)} visible element(s) " \
         "(#{top.map { |p| p['name'] || p['id'] }.join(', ')}) — picked #{pick['name'] || pick['id']} " \
         '(first-by-order); pass --page-id to override'
  end
  puts "auto-picked RCF page #{(pick['name'] || pick['id']).inspect} (#{pick['id']}) — " \
       "most visible elements (#{FidelityLoop.visible_count(pick)}); --page-id overrides"
  pick['id']
end

def print_rubric
  rubric = File.join(HERE, '..', 'refs', 'fidelity-rubric.md')
  puts
  if File.exist?(rubric)
    puts "───── SCORE THIS PASS against refs/fidelity-rubric.md ─────"
    # Print just the dimension headers so the agent has the checklist inline.
    File.foreach(rubric, encoding: 'UTF-8') do |l|
      puts "  #{l.rstrip}" if l =~ /^\s*[-*]\s*\*\*/ || l =~ /^#{'#'}{2,4}\s/
    end
  else
    puts '───── SCORE THIS PASS (rubric dimensions) ─────'
    %w[layout/containers typography/text palette/theme chart-kinds+marks
       labels/number-formats controls/parameters filters-wired
       KPI/table-values accuracy].each { |d| puts "  - #{d}" }
  end
  puts '───────────────────────────────────────────────────────────'
end

# #422: a live-only apply-patch was REVERTED by the next re-entry full-spec
# PUT (post-and-readback PUTs the workdir wb-spec.json wholesale) — the
# operator had to hand-persist every RCF fix. Deep-merge the SAME patch into
# <workdir>/wb-spec.json so re-entry carries prior fixes. Guard: only when
# wb-spec.json exists and parses; never fails the apply.
def persist_patch_to_wb_spec(dir, patch)
  path = File.join(dir, 'wb-spec.json')
  unless File.exist?(path)
    puts "     (no #{path} — patch applied live only; a re-entry full-spec PUT will not carry it)"
    return
  end
  begin
    spec = JSON.parse(File.read(path))
  rescue JSON::ParserError => e
    warn "WARN: #{path} does not parse (#{e.message}) — patch NOT persisted; a re-entry full-spec PUT will revert this fix"
    return
  end
  merged = FidelityLoop.deep_merge(WorkbookCode.legacy_view(WorkbookCode.canonicalize(spec)), patch)
  File.write(path, JSON.pretty_generate(WorkbookCode.canonicalize(merged)) + "\n")
  puts "[OK] patch persisted into #{path} (re-entry full-spec PUTs carry this fix)"
rescue StandardError => e
  warn "WARN: could not persist patch into #{path}: #{e.class}: #{e.message}"
end

cmd = ARGV.shift
opts = { width: 1920, height: 1500 }
parser = OptionParser.new do |p|
  p.on('--workdir DIR')       { |v| opts[:dir] = v }
  p.on('--workbook-id ID')    { |v| opts[:wb] = v }
  p.on('--page-id ID')        { |v| opts[:page] = v }
  p.on('--source-image PNG')  { |v| opts[:src] = v }
  p.on('--max-passes N', Integer) { |v| opts[:max] = v }
  p.on('--width N', Integer)  { |v| opts[:width] = v }
  p.on('--height N', Integer) { |v| opts[:height] = v }
  p.on('--dimension D')       { |v| opts[:dim] = v }
  p.on('--delta S')           { |v| opts[:delta] = v }
  p.on('--class C')           { |v| opts[:cls] = v }
  p.on('--probe PATH', 'a "no data / empty" delta may only be classed sigma-capability/ui-only WITH a probe artifact (JSON) proving the emptiness is a genuine platform-render issue and the element export DOES return rows — never to launder a broken data path') { |v| opts[:probe] = v }
  p.on('--fix S')             { |v| opts[:fix] = v }
  p.on('--resolved')          { opts[:resolved] = true }
  p.on('--entry N', Integer)  { |v| opts[:entry] = v }
  p.on('--patch P')           { |v| opts[:patch] = v }
  p.on('--full-spec P')       { |v| opts[:full] = v }
  p.on('--resolves LIST')     { |v| opts[:resolves] = v.split(',').map(&:strip) }
  p.on('--accept-residuals L'){ |v| opts[:accept] = v.split(',').map(&:strip) }
  p.on('--dry-run')           { opts[:dry] = true }
  p.on('--live-spec P')       { |v| opts[:live] = v }
  p.on('--out P')             { |v| opts[:out] = v }
  p.on('--skip-style-normalize REASON', 'skip the v5.1 style contract on apply-patch (quality waiver — name it in your report)') { |v| opts[:skip_style_normalize] = v }
end
parser.parse!(ARGV)
die 'missing --workdir' unless opts[:dir]

case cmd
when 'init'
  die '--workbook-id required for init' unless opts[:wb]
  # PRESERVE an existing ledger for the same workbook (field-caught: every
  # FAST PATH orchestrator re-entry re-ran init and WIPED the recorded deltas
  # — the natural fix-and-re-run loop destroyed its own audit trail). Only a
  # DIFFERENT workbook id starts fresh; same-workbook re-init is a no-op —
  # except an explicit --page-id, which OVERRIDES the recorded page in place
  # (#422: init used to offer no way to repoint an existing ledger at the
  # right page). (direct file check — load_ledger die()s with SystemExit on a
  # missing file, which `rescue nil` does NOT catch; a fresh init would exit 2)
  existing = File.exist?(ledger_path(opts[:dir])) ? (JSON.parse(File.read(ledger_path(opts[:dir]))) rescue nil) : nil
  if existing.is_a?(Hash) && existing['workbook_id'] == opts[:wb]
    if opts[:page] && existing['page_id'] != opts[:page]
      old = existing['page_id']
      existing['page_id'] = opts[:page]
      existing['source_image'] = opts[:src] if opts[:src]
      save_ledger(opts[:dir], existing)
      puts "[OK] fidelity ledger page OVERRIDDEN: #{old} → #{opts[:page]} " \
           "(#{(existing['entries'] || []).length} entries preserved, pass #{existing['pass']}/#{existing['max_passes']})"
    else
      puts "[OK] fidelity ledger already initialized for #{opts[:wb]} " \
           "(#{(existing['entries'] || []).length} entries, pass #{existing['pass']}/#{existing['max_passes']}) — preserved."
    end
  else
    page = opts[:page] || auto_pick_rcf_page(opts[:dir])
    ledger = FidelityLoop.new_ledger(
      workbook_id: opts[:wb], page_id: page,
      source_image: opts[:src], max_passes: opts[:max] || 5
    )
    save_ledger(opts[:dir], ledger)
    File.delete(exhausted_path(opts[:dir])) if File.exist?(exhausted_path(opts[:dir]))
    puts "[OK] initialized #{ledger_path(opts[:dir])} (page #{page}, max_passes=#{ledger['max_passes']})"
  end

when 'render'
  ledger = load_ledger(opts[:dir])
  max = ledger['max_passes'].to_i
  if ledger['pass'] >= max && max.positive?
    write_exhausted(opts[:dir], ledger)
    warn "[STOP] pass budget exhausted (#{ledger['pass']}/#{max} passes run)."
    warn '       Record any remaining deltas as ui-only / sigma-capability / accepted residuals'
    warn '       and exit — do not keep rendering. See refs/fidelity-rubric.md.'
    exit 3
  end
  ledger['pass'] += 1
  n = ledger['pass']
  out_png = File.join(opts[:dir], "rcf-pass-#{n}.png")
  renderer = File.join(HERE, 'sigma-export-png.py')
  require_relative 'lib/py_resolve' # real-Python resolver (Windows Store-stub safe)
  cmd_r = [*PyResolve.argv, PyResolve.winpath(renderer), '--workbook', ledger['workbook_id'],
           '--page', ledger['page_id'], '--out', PyResolve.winpath(out_png),
           '--w', opts[:width].to_s, '--h', opts[:height].to_s]
  ok = system(*cmd_r)
  unless ok && File.exist?(out_png) && File.size(out_png) > 5_000
    die "render failed — sigma-export-png.py did not produce a valid #{out_png}", 4
  end
  ledger['renders'] << { 'pass' => n, 'path' => out_png }
  save_ledger(opts[:dir], ledger)
  exhausted = max.positive? && n >= max
  write_exhausted(opts[:dir], ledger) if exhausted
  puts "[OK] pass #{n}/#{max}: rendered #{out_png} (#{(File.size(out_png) / 1024.0).round} KB)"
  puts "     SOURCE to compare against: #{ledger['source_image'] || '(set --source-image at init; else use visual-qa/<dash>.source.png)'}"
  print_rubric
  if exhausted
    warn "[STOP] this was the final budgeted render (#{n}/#{max}). #{EXHAUSTED_NAME} written."
    warn '       Record residuals and stop; do not patch or export another fidelity render.'
  else
    puts "NEXT: Read both PNGs, then `record` each delta (classify spec-fixable/ui-only/sigma-capability/data),"
    puts "      `apply-patch` the spec-fixable ones (recipes: refs/fidelity-recipes.md), then `render` again."
  end

when 'record'
  die '--dimension, --delta, --class required' unless opts[:dim] && opts[:delta] && opts[:cls]
  die "--class must be one of #{FidelityLoop::CLASSES.join('/')}" unless FidelityLoop::CLASSES.include?(opts[:cls])
  # W1.5: a "no data / empty" delta is a data-class defect. It may not be recorded
  # as a cosmetic residual (sigma-capability / ui-only) unless a probe artifact
  # proves the emptiness is a genuine platform-render issue AND the data is present.
  if FidelityLoop.no_data_delta?(opts[:delta]) && %w[sigma-capability ui-only].include?(opts[:cls])
    probe_ok = opts[:probe] && File.exist?(opts[:probe]) && File.size(opts[:probe]).to_i.positive?
    unless probe_ok
      die <<~MSG, 6
        --class #{opts[:cls]} REJECTED for a "no data / empty" delta:
          #{opts[:delta]}
        A chart that renders no data means the ROWS ARE MISSING — a data-class defect
        (the numbers are wrong), not a cosmetic gap. Record it as --class data (which
        blocks the gate unconditionally) and FIX the data path.
        PRODUCT FACT: Sigma's export endpoints DO execute live warehouse queries. An
        empty export is empty DATA — never "the export doesn't run queries." (Field-
        proven 2026-07: that exact false theory laundered a dataless dashboard to GREEN.)
        Only if you can PROVE the element export returns rows while the RENDER is blank
        (a real platform-render artifact) may you keep this class — attach the proof:
          --probe <workdir>/render-vs-export-<element>.json   (must exist and be non-empty)
      MSG
    end
  end
  ledger = load_ledger(opts[:dir])
  e = FidelityLoop.add_entry(ledger, dimension: opts[:dim], delta: opts[:delta],
                             cls: opts[:cls], fix: opts[:fix], resolved: !!opts[:resolved],
                             evidence: opts[:probe])
  save_ledger(opts[:dir], ledger)
  puts "[OK] recorded #{e['id']} pass=#{e['pass']} [#{e['cls']}] #{e['dimension']}: #{e['delta']}"
  puts "     (spec-fixable + unresolved → blocks the gate until apply-patch/resolve)" if e['cls'] == 'spec-fixable' && !e['resolved']
  if e['cls'] == 'data' && !e['resolved']
    puts '     (data-class = the NUMBERS are wrong → blocks the gate unconditionally; no'
    puts '      --accept-residuals waiver exists. Fix + resolve, or reclassify with evidence.)'
  end

when 'resolve'
  ledger = load_ledger(opts[:dir])
  entries = ledger['entries'] || []
  targets =
    if opts[:entry]
      [entries[opts[:entry]]].compact
    elsif opts[:dim]
      entries.select { |x| x['dimension'] == opts[:dim] }
    else
      die '--entry N or --dimension D required'
    end
  die 'no matching ledger entry', 2 if targets.empty?
  targets.each { |x| x['resolved'] = true }
  save_ledger(opts[:dir], ledger)
  puts "[OK] resolved #{targets.length} entr#{targets.length == 1 ? 'y' : 'ies'}"

when 'apply-patch'
  ledger = load_ledger(opts[:dir])
  if File.exist?(exhausted_path(opts[:dir]))
    die "RCF pass budget is exhausted (#{ledger['pass']}/#{ledger['max_passes']}); " \
        "#{EXHAUSTED_NAME} blocks further patches. Record residuals and stop.", 3
  end
  wb = ledger['workbook_id']
  die '--patch or --full-spec required' unless opts[:patch] || opts[:full]

  merged =
    if opts[:full]
      JSON.parse(File.read(opts[:full]))
    else
      patch = JSON.parse(File.read(opts[:patch]))
      # GET the FULL live spec (or --live-spec in dry-run) and deep-merge the
      # patch into it so the layout — part of that spec — is carried through the
      # PUT untouched. This is the single-PUT that avoids the PUT-wipes-layout trap.
      live =
        if opts[:dry]
          die '--dry-run needs --live-spec', 2 unless opts[:live]
          JSON.parse(File.read(opts[:live]))
        else
          require_relative 'lib/sigma_rest'
          body = Sigma.request(:get, "/v2/workbooks/#{wb}/spec", accept: 'text/yaml')
          begin
            JSON.parse(body)
          rescue JSON::ParserError
            require 'yaml'; require 'date'
            YAML.safe_load(body, permitted_classes: [Date, Time]) || {}
          end
        end
      # Workbook code-rep GETs carry flat document.elements. Keep that canonical
      # flat shape while merging a partial fidelity patch: converting the live
      # spec to pages[].elements first would make a flat patch.elements array a
      # second namespace, and canonicalize() would let those partial records
      # (id/style but no kind) shadow the complete page-owned records.
      canonical_live = WorkbookCode.canonicalize(live)
      live = WorkbookCode.metadata(canonical_live).merge(WorkbookCode.document(canonical_live))
      unless live['pages'].is_a?(Array) && live['pages'].any?
        die 'live spec has no `pages` — refusing to PUT a spec that would blank the workbook', 4
      end
      FidelityLoop.deep_merge(live, patch)
    end

  # RCF transforms still use a transient page-assigned view. Every artifact and
  # PUT crosses back through the release representation: metadata outside,
  # flat document.elements, metadata-only pages, and authoritative layout.
  merged = WorkbookCode.legacy_view(WorkbookCode.canonicalize(merged))
  die 'merged spec has no `pages`', 4 unless merged['pages'].is_a?(Array) && merged['pages'].any?

  # v5.1.1: the SAME style contract post-and-readback enforces (pivot totals,
  # format grammar, scheme defaults) — a fidelity patch PUT was the one write
  # path that bypassed it (review-caught), so a patch could silently
  # reintroduce what style-normalize had repaired. --skip-style-normalize
  # waives (named), matching the post-and-readback flag.
  if opts[:skip_style_normalize]
    warn "WARN: style-normalize SKIPPED (--skip-style-normalize: #{opts[:skip_style_normalize]}) — quality waiver."
    # PR-14: every honored --skip-* leaves a record on the off-ramp trail.
    begin
      require_relative 'lib/offramp'
      Offramp.log(opts[:dir], kind: 'skip-flag-waived', reason: opts[:skip_style_normalize],
                  detail: '--skip-style-normalize')
    rescue LoadError
      warn 'WARN: lib/offramp.rb not vendored — the waiver could not be recorded to offramps.jsonl.'
    end
  else
    begin
      require_relative 'lib/style_normalize'
      changes = StyleNormalize.normalize!(merged)
      if changes.any?
        File.write(File.join(opts[:dir], 'style-normalize.json'), JSON.pretty_generate(changes)) rescue nil
        puts "style-normalize: #{changes.size} change(s) applied (#{changes.map { |c| c['rule'] }.uniq.join(', ')}) — style-normalize.json"
      end
    rescue LoadError
      warn 'WARN: lib/style_normalize unavailable — patch PUT proceeds un-normalized.'
    end
  end

  if opts[:dry]
    out = opts[:out] || File.join(opts[:dir], 'rcf-merged-spec.json')
    File.write(out, JSON.pretty_generate(WorkbookCode.canonicalize(merged)))
    puts "[DRY] merged spec → #{out} (no PUT, no lint)"
    persist_patch_to_wb_spec(opts[:dir], patch) if opts[:patch] && patch
  else
    require_relative 'lib/sigma_rest'
    layout_was = merged['layout'].to_s
    begin
      put_body = WorkbookCode.canonicalize(merged)
      shape_errors = WorkbookCode.validate(put_body)
      die "merged workbook code representation is invalid: #{shape_errors.join('; ')}", 4 if shape_errors.any?
      Sigma.request(:put, "/v2/workbooks/#{wb}/spec", body: JSON.generate(put_body))
    rescue StandardError => e
      die "PUT /v2/workbooks/#{wb}/spec failed (atomic — nothing written): #{e.message}", 4
    end
    puts "[OK] PUT merged spec to #{wb} (layout preserved: #{layout_was.empty? ? 'NONE' : "#{layout_was.scan(/<Element\b/).length} elements"})"
    # Persist BEFORE the post-PUT guards: the fix is live either way, and an
    # exit-5 guard failure must not leave wb-spec.json behind the live state.
    persist_patch_to_wb_spec(opts[:dir], patch) if opts[:patch] && patch

    # Re-run the same guards post-and-readback runs on the initial POST.
    # PAGINATED: re-runs the same error-column guard post-and-readback runs on the
    # initial POST, so it needs the same exhaustive read — otherwise a wide
    # workbook's error columns past 50 pass this guard too.
    cols = (Sigma.list_entries("/v2/workbooks/#{wb}/columns") rescue nil)
    # A nil read means the guard never ran. Track it so the success message below
    # cannot claim "no type=error columns" on a check that did not happen — the
    # same hardening post-and-readback.rb applies to its census.
    cols_unread = cols.nil?
    err = (cols || []).select { |c| c.dig('type', 'type') == 'error' }
    if err.any?
      warn "[FAIL] column-type guard: #{err.length} column(s) compiled to type=error after the patch:"
      err.first(10).each { |c| warn "         element=#{c['elementId']} col=#{c['columnId']} #{c['formula']}" }
      exit 5
    elsif cols_unread
      warn '[WARN] column-type guard: live columns could not be read — the type=error check did NOT run.'
    end
    fresh = Sigma.request(:get, "/v2/workbooks/#{wb}/spec", accept: 'text/yaml')
    spec =
      begin
        JSON.parse(fresh)
      rescue JSON::ParserError
        require 'yaml'; require 'date'
        YAML.safe_load(fresh, permitted_classes: [Date, Time]) || {}
      end
    # Same nested-`document` unwrap as the live GET above — the post-patch
    # lints below need flat `pages`/`layout`.
    spec = Sigma::CodeRep.metadata(spec).merge(Sigma::CodeRep.document(spec))
    lint_fail = false
    begin
      require_relative 'lib/layout_lint'
      v = LayoutLint.lint(spec)
      if v.any?
        warn "[FAIL] layout lint after patch: #{v.length} violation(s):"; v.each { |x| warn "         - #{x}" }
        lint_fail = true
      end
    rescue LoadError; end
    begin
      require_relative 'lib/control_lint'
      scope = (JSON.parse(File.read(File.join(opts[:dir], 'control-scope.json'))) rescue nil)
      v = ControlLint.lint(spec, scope: scope)
      if v.any?
        warn "[FAIL] control lint after patch: #{v.length} violation(s):"; v.each { |x| warn "         - #{x}" }
        lint_fail = true
      end
    rescue LoadError; end
    exit 5 if lint_fail
    puts(cols_unread ?
      '[OK] post-patch guards clean (layout + control lint pass; column-type check SKIPPED — live columns unreadable)' :
      '[OK] post-patch guards clean (no type=error columns; layout + control lint pass)')
  end

  # Mark resolved entries (safe in dry-run too, so tests exercise the codepath).
  if opts[:resolves]
    entries = ledger['entries'] || []
    opts[:resolves].each do |ref|
      idx = (ref =~ /\A\d+\z/ ? ref.to_i : entries.index { |x| x['id'] == ref })
      entries[idx]['resolved'] = true if idx && entries[idx]
    end
    save_ledger(opts[:dir], ledger)
    puts "[OK] marked resolved: #{opts[:resolves].join(', ')}"
  end

when 'status'
  ledger = load_ledger(opts[:dir])
  entries = ledger['entries'] || []
  by_class = entries.group_by { |e| e['cls'] }
  puts "fidelity-ledger.json — workbook #{ledger['workbook_id']} page #{ledger['page_id']}"
  puts "  passes run: #{ledger['pass']}/#{ledger['max_passes']}   entries: #{entries.length}"
  FidelityLoop::CLASSES.each do |c|
    grp = by_class[c] || []
    next if grp.empty?
    unresolved = grp.count { |e| !e['resolved'] }
    puts "  #{c}: #{grp.length} (#{unresolved} unresolved)"
  end
  blocking = FidelityLoop.unresolved_specfixable(ledger, opts[:accept] || [])
  data_blocking = FidelityLoop.unresolved_data(ledger)
  if blocking.empty? && data_blocking.empty?
    puts '[OK] no unresolved spec-fixable or data-class deltas — RCF ledger satisfies the gate.'
    exit 0
  else
    if data_blocking.any?
      warn "[BLOCK] #{data_blocking.length} unresolved DATA-class delta(s) — the numbers are wrong:"
      data_blocking.each do |i|
        e = entries[i]
        warn "         #{e['id']} [#{e['dimension']}] #{e['delta']}"
      end
      warn '       data-class residuals can never be waved through (--accept-residuals does not apply).'
      warn '       Fix + resolve, or reclassify with evidence.'
    end
    if blocking.any?
      warn "[BLOCK] #{blocking.length} unresolved spec-fixable delta(s) remain:"
      blocking.each do |i|
        e = entries[i]
        warn "         #{e['id']} [#{e['dimension']}] #{e['delta']}  (fix: #{e['fix'] || 'see refs/fidelity-recipes.md'})"
      end
      warn '       apply-patch/resolve them, or waive with --accept-residuals <id,id> and NAME them in the report.'
    end
    exit 6
  end

else
  warn "usage: fidelity-loop.rb {init|render|record|resolve|apply-patch|status} --workdir DIR ..."
  warn '(run with no subcommand shows this; see the file header for full flags)'
  exit 2
end
