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
# Recipes for each delta→fix live in refs/fidelity-recipes.md. See SKILL.md Phase 5g.
#
# Subcommands
#   init        --workdir DIR --workbook-id ID --page-id ID [--source-image PNG]
#               [--max-passes N (default 5)]
#   render      --workdir DIR [--width 1920 --height 1500]   (needs a live workbook)
#   record      --workdir DIR --dimension D --delta "..." --class C
#               [--fix "..."] [--resolved]
#   resolve     --workdir DIR (--entry N | --dimension D)    mark entry(ies) resolved
#   apply-patch --workdir DIR --patch patch.json             GET→merge→PUT→guard→lint
#               [--full-spec spec.json]  replace the whole spec instead of merging
#               [--resolves 0,2,3]       mark these ledger entries resolved on success
#               [--dry-run --live-spec f.json --out merged.json]  no network (tests)
#   status      --workdir DIR [--accept-residuals id,id]     print ledger + gate verdict
#
# Exit codes: 0 ok; 2 usage; 3 pass budget exhausted; 4 apply/PUT failed;
#             5 post-fix guard/lint failed; 6 status: unresolved spec-fixable remain.

require 'json'
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

  def ledger_ok?(ledger, accepted = [])
    unresolved_specfixable(ledger, accepted).empty?
  end

  def add_entry(ledger, dimension:, delta:, cls:, fix: nil, resolved: false, pass: nil)
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
    (ledger['entries'] ||= []) << entry
    entry
  end
end

# ---------------------------------------------------------------------------
# CLI (IO / REST / subprocess) — thin wrapper around the pure core above.
# ---------------------------------------------------------------------------
return if $PROGRAM_NAME != __FILE__ && !ENV['FIDELITY_LOOP_CLI'] # allow `require` in tests

HERE = __dir__
LEDGER_NAME = 'fidelity-ledger.json'

def die(msg, code = 2)
  warn "FATAL: #{msg}"
  exit code
end

def ledger_path(dir)
  File.join(dir, LEDGER_NAME)
end

def load_ledger(dir)
  p = ledger_path(dir)
  die "no #{p} — run `fidelity-loop.rb init` first", 2 unless File.exist?(p)
  JSON.parse(File.read(p))
end

def save_ledger(dir, ledger)
  File.write(ledger_path(dir), JSON.pretty_generate(ledger))
end

def print_rubric
  rubric = File.join(HERE, '..', 'refs', 'fidelity-rubric.md')
  puts
  if File.exist?(rubric)
    puts "───── SCORE THIS PASS against refs/fidelity-rubric.md ─────"
    # Print just the dimension headers so the agent has the checklist inline.
    File.foreach(rubric) do |l|
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
end
parser.parse!(ARGV)
die 'missing --workdir' unless opts[:dir]

case cmd
when 'init'
  die '--workbook-id and --page-id required for init' unless opts[:wb] && opts[:page]
  ledger = FidelityLoop.new_ledger(
    workbook_id: opts[:wb], page_id: opts[:page],
    source_image: opts[:src], max_passes: opts[:max] || 5
  )
  save_ledger(opts[:dir], ledger)
  puts "[OK] initialized #{ledger_path(opts[:dir])} (max_passes=#{ledger['max_passes']})"

when 'render'
  ledger = load_ledger(opts[:dir])
  max = ledger['max_passes'].to_i
  if ledger['pass'] >= max && max.positive?
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
  cmd_r = [*PyResolve.argv, renderer, '--workbook', ledger['workbook_id'],
           '--page', ledger['page_id'], '--out', out_png,
           '--w', opts[:width].to_s, '--h', opts[:height].to_s]
  ok = system(*cmd_r)
  unless ok && File.exist?(out_png) && File.size(out_png) > 5_000
    die "render failed — sigma-export-png.py did not produce a valid #{out_png}", 4
  end
  ledger['renders'] << { 'pass' => n, 'path' => out_png }
  save_ledger(opts[:dir], ledger)
  puts "[OK] pass #{n}/#{max}: rendered #{out_png} (#{(File.size(out_png) / 1024.0).round} KB)"
  puts "     SOURCE to compare against: #{ledger['source_image'] || '(set --source-image at init; else use visual-qa/<dash>.source.png)'}"
  print_rubric
  puts "NEXT: Read both PNGs, then `record` each delta (classify spec-fixable/ui-only/sigma-capability/data),"
  puts "      `apply-patch` the spec-fixable ones (recipes: refs/fidelity-recipes.md), then `render` again."

when 'record'
  die '--dimension, --delta, --class required' unless opts[:dim] && opts[:delta] && opts[:cls]
  die "--class must be one of #{FidelityLoop::CLASSES.join('/')}" unless FidelityLoop::CLASSES.include?(opts[:cls])
  ledger = load_ledger(opts[:dir])
  e = FidelityLoop.add_entry(ledger, dimension: opts[:dim], delta: opts[:delta],
                             cls: opts[:cls], fix: opts[:fix], resolved: !!opts[:resolved])
  save_ledger(opts[:dir], ledger)
  puts "[OK] recorded #{e['id']} pass=#{e['pass']} [#{e['cls']}] #{e['dimension']}: #{e['delta']}"
  puts "     (spec-fixable + unresolved → blocks the gate until apply-patch/resolve)" if e['cls'] == 'spec-fixable' && !e['resolved']

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
      die 'live spec has no `pages` — refusing to PUT a spec that would blank the workbook', 4 unless live['pages']
      FidelityLoop.deep_merge(live, patch)
    end

  die 'merged spec has no `pages`', 4 unless merged['pages']

  if opts[:dry]
    out = opts[:out] || File.join(opts[:dir], 'rcf-merged-spec.json')
    File.write(out, JSON.pretty_generate(merged))
    puts "[DRY] merged spec → #{out} (no PUT, no lint)"
  else
    require_relative 'lib/sigma_rest'
    layout_was = merged['layout'].to_s
    begin
      Sigma.request(:put, "/v2/workbooks/#{wb}/spec", body: merged.to_json)
    rescue StandardError => e
      die "PUT /v2/workbooks/#{wb}/spec failed (atomic — nothing written): #{e.message}", 4
    end
    puts "[OK] PUT merged spec to #{wb} (layout preserved: #{layout_was.empty? ? 'NONE' : "#{layout_was.scan(/<LayoutElement\b/).length} elements"})"

    # Re-run the same guards post-and-readback runs on the initial POST.
    cols = Sigma.request(:get, "/v2/workbooks/#{wb}/columns") rescue nil
    err = ((cols && cols['entries']) || []).select { |c| c.dig('type', 'type') == 'error' }
    if err.any?
      warn "[FAIL] column-type guard: #{err.length} column(s) compiled to type=error after the patch:"
      err.first(10).each { |c| warn "         element=#{c['elementId']} col=#{c['columnId']} #{c['formula']}" }
      exit 5
    end
    fresh = Sigma.request(:get, "/v2/workbooks/#{wb}/spec", accept: 'text/yaml')
    spec =
      begin
        JSON.parse(fresh)
      rescue JSON::ParserError
        require 'yaml'; require 'date'
        YAML.safe_load(fresh, permitted_classes: [Date, Time]) || {}
      end
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
    puts '[OK] post-patch guards clean (no type=error columns; layout + control lint pass)'
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
  if blocking.empty?
    puts '[OK] no unresolved spec-fixable deltas — RCF ledger satisfies the gate.'
    exit 0
  else
    warn "[BLOCK] #{blocking.length} unresolved spec-fixable delta(s) remain:"
    blocking.each do |i|
      e = entries[i]
      warn "         #{e['id']} [#{e['dimension']}] #{e['delta']}  (fix: #{e['fix'] || 'see refs/fidelity-recipes.md'})"
    end
    warn '       apply-patch/resolve them, or waive with --accept-residuals <id,id> and NAME them in the report.'
    exit 6
  end

else
  warn "usage: fidelity-loop.rb {init|render|record|resolve|apply-patch|status} --workdir DIR ..."
  warn '(run with no subcommand shows this; see the file header for full flags)'
  exit 2
end
