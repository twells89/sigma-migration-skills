#!/usr/bin/env ruby
# Scan a customer's Tableau .twb (or .twbx after unzip) and emit a markdown gap
# report listing every workbook feature the skill currently handles vs. doesn't.
#
# This is the FIRST thing a customer should run when starting a migration:
# it sets expectations up front (rather than discovering gaps mid-conversion)
# and gives the agent a concrete plan for what to translate auto vs. by hand
# vs. defer.
#
# Usage:
#   ruby scripts/scan-workbook-gaps.rb /path/to/workbook.twb [out.md]
#
# Output: a markdown file (default: <name>-gaps-report.md) with:
#   - Workbook summary (worksheets, dashboards, datasource count)
#   - Auto-handled features (with count)
#   - Hint-only features (count + brief translation guidance)
#   - Unhandled features (count + escalation path)
#   - Manual-setup features (action filters, ref-marks etc. that need
#     post-publish UI work)
#
# The same data is also written as <name>-gaps.json so the gap-scout subagent
# and other downstream tools can consume it programmatically.

require 'json'
# Nokogiri-backed REXML drop-in — REXML is O(n^2) on large .twb files. See lib/twb_xml.rb.
$LOAD_PATH.unshift File.expand_path('lib', __dir__)
require 'twb_xml'

# --- Feature inventory: what the skill handles today ----------------------
# Each entry: { pattern: regex_or_lambda, name: "feature", status: :auto |
# :hint | :manual | :unhandled, blurb: "..." }
INVENTORY = [
  # AUTO — fully translated end-to-end, no manual step needed
  { name: 'Bar / line / area / pie / scatter chart',  pat: /<mark class='(Bar|Line|Area|Pie|Circle|Shape)'/,
    status: :auto, blurb: 'Translated to Sigma bar/line/area/pie/scatter chart with the right marker.' },
  { name: 'Region / filled map',                       pat: /<mark class='(Multipolygon|Polygon|Filled|Map)'/,
    status: :auto, blurb: 'Translated to Sigma region-map.' },
  { name: 'Point / symbol map',                        pat: /<column[^>]+caption='Latitude'/i,
    status: :auto, blurb: 'Translated to Sigma point-map when lat+long both present.' },
  { name: 'Column aliases (value→display)',            pat: /<column[^>]+(?:caption='[^']+')?[^>]*>\s*<aliases>\s*<alias key=/,
    status: :auto, blurb: 'Aliased dim columns get a Switch() formula on the chart.' },
  { name: 'Tableau format strings',                    pat: /<format\s[^>]*attr='text-format'/,
    status: :auto, blurb: 'p0.0% / C1033% / $#,##0;(...) etc. translated to Sigma d3-format with paren-negative.' },
  { name: 'Shared-view dashboard filters',             pat: /<shared-view[^>]*>\s*<datasources>/,
    status: :auto, blurb: 'List/relative-date/quantitative shared filters become Sigma controls per page.' },
  { name: 'Per-worksheet sort',                        pat: /<sort\s+[^>]*direction=/,
    status: :auto, blurb: "Tableau's sort direction carries into the chart's xAxis.sort." },
  { name: 'Parameter (list domain) + CASE-on-param',   pat: /param-domain-type='list'/,
    status: :auto, blurb: "List parameters become segmented controls; CASE/IF-on-param calcs translate to Sigma Switch()." },
  { name: 'Parameter (numeric range)',                 pat: /param-domain-type='range'/,
    status: :auto, blurb: 'Numeric range parameters become number-range controls. Skips orphan params not referenced by any worksheet calc.' },
  { name: 'Dual-axis (synchronized) combo charts',     pat: /synchronized='true'/,
    status: :auto, blurb: 'Synchronized-axis worksheets emit Sigma combo-chart with two yAxis groups.' },
  { name: 'Custom SQL data source',                    pat: /<relation\s[^>]*\btype='text'/,
    status: :auto, blurb: 'Custom SQL becomes a Sigma data-model element with source.kind="sql".' },
  { name: 'Hyper / Tableau extract',                   pat: /<connection\s[^>]*\bclass='hyper'|<extract\s/,
    status: :hint, blurb: 'Workbook has a .hyper extract — Sigma uses live warehouse data. Phase 6 runs in --extract-mode (structural compare) instead of strict-value.' },
  { name: 'Cross-extract drift (live warehouse newer than extract)', pat: /<connection\s[^>]*\bclass='hyper'|<extract\s/,
    status: :manual, blurb: "Tableau extract data range typically lags the live warehouse by months/years (extract has 2023-2024, live warehouse has 2024-2027). Chart actuals WILL diverge on date axes — this is expected, not a converter bug. Tier as YELLOW with error_summary 'extract-vs-live drift'; document the extract refresh date alongside the live warehouse range." },
  { name: 'Table-calc INDEX/LOOKUP/TOTAL/RANK(_UNIQUE/_DENSE/_PERCENTILE)/ZN/IIF', pat: /\b(INDEX\(\)|LOOKUP\(|TOTAL\(|RANK_UNIQUE|RANK_DENSE|RANK_PERCENTILE|RANK\b|\bZN\(|\bIIF\(|\bCOUNTD\()/,
    status: :auto, blurb: 'Auto-translated when plotted (WINPROBE-validated, bead 427; refs/window-functions.md): RANK family → Rank/RankDense/RankPercentile(agg, "desc" — Tableau default direction); RANK_UNIQUE(expr) → RowNumber() (unique rank; verify the element is sorted by the ranked expr); INDEX() → RowNumber(); LOOKUP(agg, ±n) → Lag/Lead(agg, n); standalone TOTAL(agg) → hidden two-level grouped helper; pareto RUNNING_SUM/TOTAL → CumulativeSum(PercentOfTotal(agg, "grand_total")); ZN/IIF/COUNTD → Coalesce/If/CountDistinct. Tableau <computed-sort> carries into xAxis.sort (cumulative/rank follow it).' },
  { name: 'Negative number format (parens)',           pat: /;\s*\([^)]*\)/,
    status: :auto, blurb: 'Parens-on-negative segment translates to Sigma d3-format with ( prefix.' },
  { name: 'Axis range / scale override (log, fixed min/max)', pat: /<encoding\s+attr='space'[^>]*(?:scale='log'|range-type='fixed')/,
    status: :auto, blurb: 'Per-axis log scale and fixed min/max translate to Sigma xAxis/yAxis format.scale (type / domain).' },
  { name: 'Show Mark Labels worksheet toggle',         pat: /<format\s+attr='mark-labels-show'\s+value='true'/,
    status: :auto, blurb: "Worksheet-level Show Mark Labels toggle emits Sigma dataLabel:{labels:shown}." },
  { name: 'FIXED LOD calc (incl. nested)',             pat: /\{\s*FIXED\b/i,
    status: :auto, blurb: 'Auto-translated when plotted. Single-level {FIXED dims : AGG(m)}: hidden two-level grouped helper element (visibleAsSource:false; inner grouping = FIXED dims computing the LOD aggregate, outer = chart dims computing the 2nd-stage aggregate; chart Max()es the outer calc). Nested {FIXED ... {FIXED ...}}: auto-decomposed into a helper-element chain (innermost first; outer levels source the inner WITH groupingId) via build-charts-from-signals.rb → -lod-chains.json sidecar. ⚠ single-level helper is exact iff carried chart dims are functionally dependent on the FIXED dims — the build emits a per-chart verify warning. Never SumOver/CountOver in master/DM calc columns (silent error).' },

  # HINT — surfaces a translated formula or setup note as a WARN; agent acts
  { name: 'IF/ELSEIF chain calc',                      pat: /\bIF\b[^']+\bELSEIF\b[^']+\bEND\b/i,
    status: :hint, blurb: 'WARN with suggested Sigma If(...) chain or Switch(). Agent adds to master.' },
  { name: 'Ratio calc (SUM/SUM, SUM/COUNT)',           pat: /SUM\s*\([^)]+\)\s*\/\s*(?:SUM|COUNT)\s*\(/i,
    status: :hint, blurb: 'WARN suggests Sum(x) / NullIf(Sum(y), 0) — agent wires on master.' },
  { name: 'INCLUDE/EXCLUDE LOD',                       pat: /\{\s*(INCLUDE|EXCLUDE)\b/i,
    status: :manual, blurb: 'Needs the chart-grouping context: INCLUDE = add the dim to the chart grouping and use the plain aggregate; EXCLUDE = remove it (or OVER(PARTITION BY view-dims-minus-excluded) via Custom SQL). The skill surfaces the formula + suggestion; customer wires it post-publish.' },
  { name: 'Reference lines / bands / trendlines',      pat: /<(reference-line|reference-band|reference-distribution|trendline-model)\b/,
    status: :hint, blurb: 'WARN per chart; agent adds Sigma referenceMarks manually post-publish (see beads-sigma-7ak).' },
  { name: 'Color encoding on measure',                 pat: /<encoding attr='color'[^>]+field-type='quantitative'/,
    status: :hint, blurb: 'WARN; agent adds Sigma colorBy on chart with palette manually (see beads-sigma-0b5).' },

  # MANUAL — non-translatable today; needs customer to do post-publish work
  { name: 'Dashboard filter / highlight / nav actions', pat: /command='tsc:tsl-(filter|highlight|navigate|set-action|parameter-action|url)'/,
    status: :manual, blurb: 'Skill writes actions.md listing each action; customer wires Sigma cross-element filtering after publish.' },
  { name: 'Forecast / trendline model',                pat: /<forecast\b/,
    status: :manual, blurb: 'No Sigma forecast primitive; agent emits a note + Custom SQL option (beads-sigma-yi0).' },
  { name: 'Story points (sequential narrative)',       pat: /<story\b/,
    status: :hint, blurb: 'Each story point becomes a separate Sigma page: parse-twb-layout.rb writes story-plan.json, then scripts/build-story-pages.rb emits caption-named pages with the annotation atop (refs/story-points.md, beads-sigma-y6b).' },
  { name: 'Drill hierarchies',                         pat: /<drill-paths>|<drill-path /,
    status: :manual, blurb: 'Hierarchies map to pivot rowsBy OR a segmented drill-level control (beads-sigma-jbw).' },

  # UNHANDLED — feature actively used in real workbooks but not surfaced yet
  # (numeric-range param moved to auto in commit 1d3445d — scout discovered the
  # number-range controlType is correct)
  { name: 'WINDOW_* aggregates (SUM/AVG/MIN/MAX/COUNT/STDEV/VAR)', pat: /\bWINDOW_(SUM|AVG|MIN|MAX|COUNT|STDEV|VAR)\b(?!P)/,
    status: :auto, blurb: 'Auto-translated when plotted (WINPROBE-validated, bead 427; refs/window-functions.md): bounded WINDOW_*(agg, -n[, m]) → Moving*(agg, n[, m]) as a chart yAxis viz formula (WINDOW_STDEV→MovingStdDev, WINDOW_VAR→MovingVariance — SAMPLE variants; the population forms WINDOW_STDEVP/VARP stay manual); agg/WINDOW_SUM(agg) share → PercentOfTotal(agg, "grand_total"); unbounded WINDOW_MAX/MIN/SUM → hidden two-level grouped helper (consumer re-aggregates Max/Min, NEVER Sum). One DM base element, zero Custom SQL. Compute-using/addressing overrides beyond Table(Across)/simple partitions stay manual (flagged).' },
  { name: 'RUNNING_* totals',                          pat: /\bRUNNING_(SUM|AVG|COUNT|MIN|MAX)\b/,
    status: :auto, blurb: 'Auto-translated when plotted: RUNNING_* → Sigma Cumulative* as a chart yAxis viz formula (follows the xAxis sort; auto-partitions by chart color/series). Pareto RUNNING_SUM/TOTAL → CumulativeSum(PercentOfTotal(agg, "grand_total")). WINPROBE-validated (bead 427).' },
  { name: 'Window calcs with NO validated Sigma mapping', pat: /\b(WINDOW_(MEDIAN|PERCENTILE|CORR|COVARP?|VARP|STDEVP)|PREVIOUS_VALUE|RANK_MODIFIED)\s*\(|\bSIZE\s*\(\s*\)/,
    status: :manual, blurb: 'WINDOW_MEDIAN/PERCENTILE/CORR/COVAR(P)/VARP/STDEVP (population var/stdev), PREVIOUS_VALUE, SIZE(), RANK_MODIFIED — no validated Sigma chart-formula equivalent; port via a Custom SQL DM element (ANSI OVER(...)) or re-author in Sigma. build-charts flags these, never guesses. (RANK_UNIQUE and sample WINDOW_VAR/STDEV ARE auto — see the table-calc / WINDOW_* rows above.)' },
  { name: 'Tableau SCRIPT_* (R/Python)',               pat: /\bSCRIPT_(REAL|STR|INT|BOOL)\b/,
    status: :unhandled, blurb: 'No Sigma equivalent. Customer rewrites in SQL/Python via Custom SQL or external prep.' },
  { name: 'Phone / mobile-specific layout',            pat: /<device-layout\b|<phone-layout\b/,
    status: :unhandled, blurb: 'Sigma has no separate mobile layout; one responsive layout applies.' },
  { name: 'Show/hide containers',                      pat: /show-hide-container|is-modal='true'/,
    status: :unhandled, blurb: 'Sigma containers can be conditionally hidden via a control; needs manual wiring.' },
  { name: 'Sets (computed / manual)',                  pat: /<groupfilter function='set'|<set\s/,
    status: :unhandled, blurb: 'No Sigma direct equivalent. Approximate with a calculated boolean column.' }
].freeze

def categorize(content)
  results = INVENTORY.map do |entry|
    matches = content.scan(entry[:pat]).length
    entry.merge(count: matches)
  end
  results.select { |r| r[:count] > 0 }
end

# Detect point-map worksheets that declare geo-role latitude/longitude on a
# column but where the underlying datasource's column-instance set doesn't
# include both. In practice this surfaces as: a Tableau sheet with `<mark
# class='Circle'/>` and a `<column geo_role='latitude'>` calc, but the warehouse
# table has no LAT/LON columns and the calc was a `MAKEPOINT(...)` derivation
# the conversion skill doesn't translate yet. The chart silently degrades to a
# bar (the build-charts default fallback when geo channels can't be wired) and
# users only notice in Phase 6f.
def detect_point_map_geo_role_gaps(content)
  has_lat = content =~ /geo_role='latitude'/i
  has_lon = content =~ /geo_role='longitude'/i
  has_circle_mark = content =~ /<mark class='(Circle|Shape)'/
  return [] unless has_circle_mark
  # If lat XOR lon is present, point-map cannot render — emit a manual gap.
  return [] if has_lat && has_lon
  return [] unless has_lat || has_lon
  [{
    name:   'Point-map missing lat/long column',
    status: :manual,
    count:  1,
    blurb:  'Tableau declares geo_role=latitude or =longitude but not both. Sigma point-map needs both lat and lon — the chart will silently degrade to a bar. Add the missing column to the warehouse / DM, or accept the bar substitution.'
  }]
end

# ---- Data-blend detection (beads-sigma-iq8) --------------------------------
# A worksheet BLENDS (vs joins) when it pulls fields from 2+ real datasources:
# the worksheet's <view> lists multiple <datasource> refs and carries a
# <datasource-dependencies datasource='<secondary>'> block naming the fields it
# pulls from the secondary. Linking fields are approximated as the captions
# that appear in BOTH the primary's and the secondary's dependency blocks
# (Tableau links blends on same-named fields by default). A <join> inside ONE
# <datasource> is a join, not a blend — it never produces a secondary
# datasource-dependencies block, so it never matches here.
#
# Output: blend-plan.json next to the gaps report + one gap-report row, with a
# per-blend ROUTE picked by comparing the primary/secondary <connection>
# blocks (decision tree in refs/blending.md):
#   same-warehouse-repoint   — same warehouse: ONE DM, two elements + a
#                              relationship on the linking fields; repoint
#                              connectionId by DEEP-WALKING the DM spec
#                              (joins[].left/right nest sources recursively —
#                              a top-level-only swap misses them)
#   materialize-via-vds      — secondary is a file / extract / published
#                              source: land it in the primary's warehouse with
#                              the tableau-vds-to-cdw skill FIRST, then treat
#                              as same-warehouse-repoint
#   flag-unreachable         — secondary is a different live system we can
#                              neither repoint nor land: surface the linking-
#                              field report and leave the blend manual
WAREHOUSE_CONN_CLASSES = %w[
  snowflake redshift bigquery postgres greenplum sqlserver mysql oracle
  databricks azure-sql synapse vertica teradata presto trino athena saphana
].freeze
FILE_CONN_CLASSES = %w[
  textscan csv msexcel excel-direct hyper webdata-direct google-sheets
  googlesheets salesforce sqlproxy
].freeze

def datasource_connections(xml)
  out = {}
  xml.elements.each('/workbook/datasources/datasource') do |ds|
    name = ds.attributes['name'].to_s
    next if name.empty? || name == 'Parameters' || name.start_with?('Parameters ')
    conns = []
    ds.elements.each('.//connection') do |c|
      a = c.attributes
      cls = a['class'].to_s
      next if cls.empty? || cls == 'federated' # wrapper; real conns are nested
      conns << {
        'class'    => cls,
        'server'   => a['server'],
        'dbname'   => a['dbname'],
        'schema'   => a['schema'],
        'filename' => a['filename']
      }.compact
    end
    out[name] = {
      'name'        => name,
      'caption'     => ds.attributes['caption'] || name,
      'connections' => conns.uniq
    }
  end
  out
end

def route_blend(primary_conns, secondary_conns)
  same = primary_conns.any? do |pc|
    secondary_conns.any? do |sc|
      pc['class'] == sc['class'] && pc['server'].to_s == sc['server'].to_s &&
        (pc['dbname'].nil? || sc['dbname'].nil? || pc['dbname'] == sc['dbname'] ||
         pc['dbname'].to_s.casecmp(sc['dbname'].to_s).zero?)
    end
  end
  return 'same-warehouse-repoint' if same
  s_classes = secondary_conns.map { |c| c['class'] }
  return 'materialize-via-vds' if s_classes.any? { |c| FILE_CONN_CLASSES.include?(c) } ||
                                  s_classes.empty?
  return 'materialize-via-vds' unless s_classes.any? { |c| WAREHOUSE_CONN_CLASSES.include?(c) }
  'flag-unreachable'
end

ROUTE_BLURB = {
  'same-warehouse-repoint' => 'both sources resolve to the SAME warehouse — emit ONE DM with both '                               'sources as elements + a relationship on the linking fields; repoint '                               'connectionId by deep-walking the spec (incl. joins[].left/right nesting)',
  'materialize-via-vds'    => 'secondary is not in the warehouse — run the tableau-vds-to-cdw skill '                               'to land it in the primary\'s warehouse FIRST, then convert as a '                               'same-warehouse blend',
  'flag-unreachable'       => 'secondary lives in a different live system — blend stays MANUAL; '                               'use the linking-field report in blend-plan.json to wire it post-publish'
}.freeze

def detect_blends(xml)
  return [[], nil] if xml.nil?
  ds_info = datasource_connections(xml)
  blends = []
  xml.elements.each('//worksheet') do |ws|
    ws_name = ws.attributes['name']
    used = ws.elements.to_a('.//view/datasources/datasource')
             .map { |d| d.attributes['name'] }.compact
             .select { |n| ds_info.key?(n) }
    next unless used.length >= 2
    deps = {}
    ws.elements.each('.//datasource-dependencies') do |dd|
      dsn = dd.attributes['datasource']
      next unless dsn
      caps = dd.elements.to_a('.//column').map do |c|
        c.attributes['caption'] || c.attributes['name'].to_s.gsub(/^\[|\]$/, '')
      end
      deps[dsn] = ((deps[dsn] || []) + caps).uniq
    end
    primary = used.first
    used[1..].each do |sec|
      next unless deps.key?(sec) && !deps[sec].empty? # must pull fields from it
      linking = (deps[primary] || []) & (deps[sec] || [])
      route = route_blend(ds_info[primary]['connections'], ds_info[sec]['connections'])
      blends << {
        'worksheet'        => ws_name,
        'primary'          => primary,
        'primary_caption'  => ds_info[primary]['caption'],
        'secondary'        => sec,
        'secondary_caption'=> ds_info[sec]['caption'],
        'linking_fields'   => linking,
        'secondary_fields' => deps[sec],
        'route'            => route,
        'recommendation'   => ROUTE_BLURB[route]
      }
    end
  end
  return [[], nil] if blends.empty?
  features = blends.group_by { |b| b['route'] }.map do |route, rs|
    {
      name:   "Data blending (#{route})",
      status: route == 'same-warehouse-repoint' ? :hint : :manual,
      count:  rs.length,
      blurb:  "#{ROUTE_BLURB[route]}. Worksheets: #{rs.map { |b| b['worksheet'] }.uniq.join(', ')}. "               'Full linking-field report in blend-plan.json; decision tree in refs/blending.md (beads-sigma-iq8).'
    }
  end
  [features, { 'datasources' => ds_info.values, 'blends' => blends }]
end

def render_md(wb_name, summary, results)
  by_status = results.group_by { |r| r[:status] }
  md = String.new
  md << "# Tableau→Sigma gap report — `#{wb_name}`\n\n"
  md << "Generated by `scan-workbook-gaps.rb`. Run BEFORE conversion to set expectations.\n\n"
  md << "## Workbook summary\n\n"
  summary.each { |k, v| md << "- **#{k}:** #{v}\n" }
  md << "\n"

  emit = lambda do |status, label, header|
    rows = by_status[status] || []
    md << "## #{header} (#{rows.length})\n\n"
    if rows.empty?
      md << "_None detected._\n\n"
      return
    end
    md << "| Feature | Count | What the skill does |\n|---|---|---|\n"
    rows.sort_by { |r| -r[:count] }.each do |r|
      md << "| #{r[:name]} | #{r[:count]} | #{r[:blurb]} |\n"
    end
    md << "\n"
  end

  emit.call(:auto,      'Auto', '✅ Fully auto-translated')
  emit.call(:hint,      'Hint', '⚠️ Translation suggested, agent action required')
  emit.call(:manual,    'Manual','🛠 Post-publish manual setup required')
  emit.call(:unhandled, 'Unhandled','❌ Not yet handled — escalation path')

  md << "## Suggested next steps\n\n"
  if (by_status[:unhandled] || []).any?
    md << "1. Review the **Unhandled** features above. For each, the agent will either:\n"
    md << "   - Attempt translation via the `gap-scout` subagent (validates against Sigma API)\n"
    md << "   - File an issue at github.com/twells89/sigma-migration-skills if no translation is possible\n"
  end
  if (by_status[:manual] || []).any?
    md << "2. The **Manual** features need post-publish work. See `<workbook>-actions.md` after conversion for action-filter mappings.\n"
  end
  if (by_status[:hint] || []).any?
    md << "3. The **Hint** features will show as `WARN` lines during conversion with copy-paste-ready Sigma formulas — review each before publishing.\n"
  end
  md << "\n_Generated by tableau-to-sigma skill. Issues: https://github.com/twells89/sigma-migration-skills/issues_\n"
  md
end

def main
  inp = ARGV[0] || abort('usage: scan-workbook-gaps.rb <workbook.twb> [out.md]')
  out = ARGV[1] || inp.sub(/\.(twbx?|xml)$/i, '-gaps-report.md')
  abort("not found: #{inp}") unless File.exist?(inp)

  content = File.read(inp, encoding: 'utf-8', invalid: :replace)

  # Workbook summary via REXML
  xml = nil
  begin
    xml = TwbXml.parse(content)
    n_dash = xml.elements.to_a('//dashboard').count
    n_ws   = xml.elements.to_a('//worksheet').count
    # Count REAL datasource definitions only — at /workbook/datasources/datasource.
    # The same `<datasource>` tag also appears inside every `<worksheet>` as a
    # REFERENCE to that worksheet's source — counting `//datasource` would
    # multiply by ~(worksheets × datasource-refs-per-worksheet) and over-
    # report by orders of magnitude (one customer saw 482 reported for 28
    # actual sources). Also exclude the synthetic `Parameters` source.
    n_ds = xml.elements.to_a('/workbook/datasources/datasource').count { |d|
      d.attributes['name'] != 'Parameters' && !d.attributes['name'].to_s.start_with?('Parameters ')
    }
  rescue StandardError
    n_dash = n_ws = n_ds = '?'
  end

  summary = {
    'Workbook' => File.basename(inp),
    'Worksheets' => n_ws,
    'Dashboards' => n_dash,
    'Datasources' => n_ds,
    '.twb size' => "#{(File.size(inp) / 1024.0).round(1)} KB"
  }

  results = categorize(content)
  results.concat(detect_point_map_geo_role_gaps(content))
  blend_features, blend_plan = detect_blends(xml)
  results.concat(blend_features)
  md_path = out
  json_path = out.sub(/\.md$/, '.json')

  if blend_plan
    blend_plan_path = File.join(File.dirname(File.expand_path(out)), 'blend-plan.json')
    blend_plan['workbook'] = File.basename(inp)
    File.write(blend_plan_path, JSON.pretty_generate(blend_plan))
    warn "wrote #{blend_plan_path} (#{blend_plan['blends'].length} blend(s): " +
         blend_plan['blends'].map { |b| "#{b['worksheet']}→#{b['route']}" }.join(', ') + ')'
  end

  File.write(md_path, render_md(File.basename(inp), summary, results))
  File.write(json_path, JSON.pretty_generate({
    'workbook' => summary,
    'detected_features' => results.map { |r| r.transform_keys(&:to_s) }
  }))

  warn "wrote #{md_path}"
  warn "wrote #{json_path}"
  warn ""
  warn "Summary: " + results.group_by { |r| r[:status] }.map { |s, rs| "#{rs.length} #{s}" }.join(', ')
end

main if $PROGRAM_NAME == __FILE__
