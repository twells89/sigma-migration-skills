#!/usr/bin/env ruby
# Validate a DM or workbook spec before POST/PUT.
# Encapsulates the embedded Python validator from SKILL.md (in Ruby), and adds
# cross-source ref support for workbook specs that reference DM elements.
#
# Usage:
#   ruby validate-spec.rb --type datamodel <spec.json>
#   ruby validate-spec.rb --type workbook  --dm-context <dm-id-map.json> <spec.json>
#
#   <dm-id-map.json> is the output of post-and-readback.rb for the DM:
#     { dataModelId: "...", pages: [{ id, name, elements: [{id, name}] }] }

require 'json'
require 'optparse'
require 'set'
$LOAD_PATH.unshift File.expand_path('lib', __dir__)
require 'sigma_functions'

opts = { type: nil, dm_context: nil }
op = OptionParser.new do |p|
  p.on('--type T', %w[datamodel workbook]) { |v| opts[:type] = v }
  p.on('--dm-context PATH')                { |v| opts[:dm_context] = v }
end
op.parse!
abort('--type required (datamodel|workbook)') unless opts[:type]
abort('usage: validate-spec.rb --type T [--dm-context P] <spec.json>') if ARGV.empty?

spec = JSON.parse(File.read(ARGV[0]))

# Known prefixes the validator considers valid for cross-element refs
external_names = []  # element names that are sources OUTSIDE this spec (e.g., DM elements when validating a workbook)
if opts[:type] == 'workbook' && opts[:dm_context]
  ctx = JSON.parse(File.read(opts[:dm_context]))
  # Accept both shapes:
  #   - post-and-readback.rb output: { pages: [{ elements: [...] }] }
  #   - flat element list:           { elements: [...] }   (legacy / hand-written)
  if ctx['pages'].is_a?(Array)
    external_names.concat(ctx['pages'].flat_map { |p| p.fetch('elements', []).map { |e| e['name'] } }.compact)
  elsif ctx['elements'].is_a?(Array)
    external_names.concat(ctx['elements'].map { |e| e['name'] }.compact)
  end
  if external_names.empty?
    abort "validate-spec.rb: --dm-context loaded 0 element names from #{opts[:dm_context]}. " \
          "Expected either {pages:[{elements:[...]}]} (post-and-readback output) or {elements:[...]} (flat). " \
          "Re-run post-and-readback.rb --type datamodel and pass its --out file."
  end
end

errors = []
all_element_names = []
spec.fetch('pages', []).each do |page|
  page.fetch('elements', []).each { |el| all_element_names << el['name'] if el['name'] }
end
all_known_prefixes = (all_element_names + external_names).to_set rescue (all_element_names + external_names)
require 'set' rescue nil
all_known_set = all_known_prefixes.is_a?(Set) ? all_known_prefixes : Set.new(all_known_prefixes)

errors << 'spec contains rgb(...) color strings (Cloudflare WAF blocks)' if JSON.generate(spec).include?('rgb(')

spec.fetch('pages', []).each do |page|
  page.fetch('elements', []).each do |el|
    kind = el['kind'] || ''
    name = el['name'] || el['id'] || '?'
    cols = (el['columns'] || []) + (el['metrics'] || [])
    sibling_names = Set.new(cols.map { |c| c['name'] }.compact)

    src = el['source'] || {}
    own_prefixes = Set.new
    if src['kind'] == 'warehouse-table' && src['path']
      own_prefixes << src['path'].last
    end
    own_prefixes << 'Custom SQL' if src['kind'] == 'sql'
    # bead 1t6c: a master sourcing a DM element (kind: data-model) carries
    # pass-through column formulas like [EMPLOYEES/Department] whose prefix is the
    # DM element's source-table name — that lives INSIDE the data model, not this
    # spec, so it can't be cross-checked here and was false-flagged "unknown
    # prefix". The DM post already validated these columns; trust the prefixes the
    # element's own formulas use.
    if src['kind'] == 'data-model'
      cols.each do |c|
        (c['formula'] || '').to_s.scan(/\[([^\]\/]+)\//).flatten.each { |p| own_prefixes << p }
      end
    end

    cols.each do |col|
      f = (col['formula'] || '').to_s

      # ---- Whitelist enforcement: every function call name must be in the
      # canonical Sigma function library. Anything else is a Tableau-syntax
      # leak, an imagined helper (IsIn / ToText), or a typo. Rewrite using a
      # documented function OR move the logic into a Custom SQL element.
      unknown = SigmaFunctions.unknown_functions(f) - [name, col['name']].compact
      # Tableau formula refs use lots of identifiers that look like fn calls
      # but are bracket-delimited (e.g., `[ORDERS/Sales]`). The regex already
      # only matches identifiers followed by `(`, so this is the cleanup set.
      # Skip the IF chain on uppercase Tableau identifiers like `IF`, `THEN`,
      # `END`, `WHEN`, which the agent may slip through inadvertently.
      reserved_tableau = %w[IF THEN ELSE ELSEIF END WHEN CASE AND OR NOT]
      unknown.reject! { |n| reserved_tableau.include?(n.upcase) }
      unless unknown.empty?
        errors << "#{name}.#{col['name']}: formula references function(s) not in Sigma's library: #{unknown.join(', ')}. Either rewrite using a documented function (see scripts/lib/sigma_functions.rb) OR move the logic into a Custom SQL data-model element (kind: \"sql\")."
      end
      # ---- Tableau-syntax leak detection. Catches IIF / COUNTD / WINDOW_* /
      # RUNNING_* / RANK_* / LOD braces / IsIn / ToText / etc. with explicit
      # translation hints.
      SigmaFunctions.tableau_leaks(f).each do |hint|
        errors << "#{name}.#{col['name']}: #{hint}"
      end

      f.scan(/\[([^\]]+)\]/).flatten.each do |ref|
        if ref.include?('/')
          prefix = ref.split('/', 1)[0] # bug-fix: split with limit 2
          prefix = ref.split('/', 2)[0]
          unless own_prefixes.include?(prefix) || all_known_set.include?(prefix)
            errors << "#{name}.#{col['name']}: ref [#{ref}] — prefix \"#{prefix}\" unknown " \
                      "(known: #{(own_prefixes + all_known_set).to_a.sort.join(', ')})"
          end
        else
          # In a Custom SQL element a bare [X] resolves against the SQL statement's
          # `AS "X"` output alias (which this validator can't see) — Sigma
          # fuzzy-matches case/underscore variants. So a bare ref that isn't a
          # named sibling is still valid here; don't flag it (Bug E: SQL-output
          # columns are intentionally nameless, binding to their alias).
          if src['kind'] != 'sql' && !sibling_names.include?(ref)
            errors << "#{name}.#{col['name']}: bare ref [#{ref}] not a sibling column"
          end
        end
      end

      if f =~ /\b(Weekday|Month|Year|Quarter|Day|Hour|Minute)\s*\(/i
        if f.include?('If(') && !f.include?('IsNull(') && !f.include?('Coalesce(')
          errors << "#{name}.#{col['name']}: nested-If on date function without IsNull/Coalesce guard"
        end
      end
    end

    errors << "#{name}: invalid kind \"kpi\" — must be \"kpi-chart\"" if kind == 'kpi'
    errors << "#{name}: invalid kind \"pie\" — must be \"pie-chart\"" if kind == 'pie'
    errors << "#{name}: invalid kind \"donut\" — must be \"donut-chart\"" if kind == 'donut'
    errors << "#{name}: kpi-chart missing value" if kind == 'kpi-chart' && !el['value']

    if %w[pie-chart donut-chart].include?(kind)
      errors << "#{name}: #{kind} missing color" unless el['color']
      errors << "#{name}: #{kind} missing value" unless el['value']
    end

    if kind == 'donut-chart' && el['holeValue']
      hv = el['holeValue']
      if !hv.is_a?(Hash) || !hv['id']
        errors << "#{name}: donut-chart holeValue must be {\"id\":...}"
      elsif hv['id'] == el.dig('value', 'id')
        errors << "#{name}: donut-chart holeValue.id equals value.id — element silently dropped"
      end
    end

    # --- Color-channel shape — cartesian + map charts use {by, column}, NOT {id}.
    # Pie/donut use {id}. Caught 2 of Superstore's HTTP 400s (area + region-map).
    if %w[bar-chart line-chart area-chart combo-chart scatter-chart region-map point-map].include?(kind)
      if (color = el['color']).is_a?(Hash) && color['id'] && !color['by'] && !color['column']
        errors << "#{name}: #{kind} color uses pie/donut shape {id: ...} — must be {by: \"category\"|\"scale\", column: \"...\"} for cartesian + map charts (API rejects with `Invalid value: object`)"
      end
    end

    # --- Axis sort direction — must be "ascending"/"descending", NOT "asc"/"desc".
    # Caught 1 of Superstore's HTTP 400s.
    %w[xAxis yAxis].each do |axis_key|
      ax = el[axis_key]
      ax = ax.first if ax.is_a?(Array) && ax.first.is_a?(Hash)
      next unless ax.is_a?(Hash)
      next unless (sort = ax['sort']).is_a?(Hash)
      dir = sort['direction']
      if %w[asc desc].include?(dir)
        errors << "#{name}: #{axis_key}.sort.direction \"#{dir}\" — must be \"ascending\" or \"descending\" (API rejects abbreviations)"
      end
    end

    if %w[bar-chart line-chart area-chart combo-chart scatter-chart].include?(kind)
      errors << "#{name}: use yAxis not measures for #{kind}" if el['measures']
      errors << "#{name}: #{kind} missing yAxis" unless el['yAxis']
      # Breaking-change-2026-05-21: xAxis / yAxis took new shape.
      # OLD (now rejected): xAxis: {id: ...}, yAxis: [{id: ...}]
      # NEW (required):     xAxis: {columnId: ...}, yAxis: {columnIds: [...]}
      if (xa = el['xAxis']).is_a?(Hash) && xa['id'] && !xa['columnId']
        errors << "#{name}: xAxis uses old shape {id: ...} — must be {columnId: ...} (breaking change 2026-05-21)"
      end
      if (ya = el['yAxis']).is_a?(Array)
        errors << "#{name}: yAxis uses old shape [{id: ...}] — must be {columnIds: [...]} (breaking change 2026-05-21)"
      elsif ya.is_a?(Hash) && !ya['columnIds']
        errors << "#{name}: yAxis missing columnIds array"
      end
    end

    if kind == 'pivot-table'
      errors << "#{name}: pivot-table must use rowsBy/columnsBy" if el['rows'] || el['columnGroups']
      errors << "#{name}: pivot-table without rowsBy renders only a grand-total row" if (el['rowsBy'] || []).empty?
      # Wrong-field-name: agents often write `valuesBy` because rowsBy/columnsBy
      # exist. The right field is bare `values`. Caught 1 of Superstore's HTTP 400s.
      if el['valuesBy'] && !el['values']
        errors << "#{name}: pivot-table field is `values` (bare string array), not `valuesBy` — rename `valuesBy` → `values`"
      end
      # Month-name string dimension on a pivot sorts alphabetically (Apr / Aug /
      # Dec / Feb...). Catch the common MonthName(...) formula on a rowsBy /
      # columnsBy column. Suggest Month(...) (returns 1-12) or a pre-computed
      # Month Num column.
      pivot_dim_ids = (el['rowsBy'].to_a + el['columnsBy'].to_a)
                      .select { |x| x.is_a?(Hash) }.map { |x| x['id'] }.compact.to_set
      cols.each do |col|
        next unless pivot_dim_ids.include?(col['id'])
        f = col['formula'].to_s
        if f =~ /\bMonthName\s*\(/i || f =~ /\bDayName\s*\(/i
          errors << "#{name}.#{col['name']}: pivot-table dim uses MonthName/DayName (string) — sorts alphabetically (Apr/Aug/Dec/Feb...). Use Month(...) (1-12) / Weekday(...) (1-7) for chronological order, then format the label downstream."
        end
      end
      # Shape: values is a flat string-array of column IDs; rowsBy/columnsBy are {id: "..."} object arrays.
      # Mixing these up costs multiple POST iterations because the API rejects with a generic Invalid array message.
      if (vals = el['values']).is_a?(Array)
        bad_val = vals.find { |v| v.is_a?(Hash) }
        errors << "#{name}: pivot-table values must be a flat string array like [\"col-id\"], not [{id:...}] (got #{bad_val.inspect})" if bad_val
      end
      %w[rowsBy columnsBy].each do |key|
        next unless (entries = el[key]).is_a?(Array)
        bad = entries.find { |e| e.is_a?(String) || (e.is_a?(Hash) && !e['id']) }
        if bad.is_a?(String)
          errors << "#{name}: pivot-table #{key} must be objects like [{id: \"col-id\"}], not bare strings (got #{bad.inspect})"
        elsif bad.is_a?(Hash) && bad['columnId']
          errors << "#{name}: pivot-table #{key} entries use {id: ...}, not {columnId: ...} (got #{bad.inspect})"
        elsif bad
          errors << "#{name}: pivot-table #{key} entry missing id key (got #{bad.inspect})"
        end
      end
    end
  end
end

if opts[:type] == 'workbook'
  spec.fetch('pages', []).each do |page|
    els = page.fetch('elements', [])
    masters = els.select do |e|
      e['kind'] == 'table' &&
        e['visibleAsSource'] == false &&
        e.dig('source', 'kind') == 'data-model'
    end
    next if masters.empty?

    others = els.reject { |e| masters.include?(e) }
    unless others.empty?
      master_names = masters.map { |m| m['name'] || m['id'] }.join(', ')
      kind_counts = Hash.new(0)
      others.each { |o| kind_counts[o['kind']] += 1 }
      other_kinds = kind_counts.map { |k, n| "#{n} #{k}" }.join(', ')
      errors << "page \"#{page['name'] || page['id']}\" mixes master table(s) [#{master_names}] with #{other_kinds}. Move the master to a dedicated \"Data\" page; charts on content pages reference it via cross-page elementId."
    end
  end
end

errors.each { |e| puts "ERROR: #{e}" }
puts "--- #{errors.size} errors"
exit(errors.empty? ? 0 : 1)
