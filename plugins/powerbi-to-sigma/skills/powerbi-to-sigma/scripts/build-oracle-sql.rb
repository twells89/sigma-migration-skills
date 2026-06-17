#!/usr/bin/env ruby
# build-oracle-sql.rb — transpile aggregate Power BI DAX measures into warehouse
# SQL so Phase 6 parity can use the SOURCE WAREHOUSE as the oracle instead of the
# live Power BI service (executeQueries). The warehouse is what BOTH Power BI and
# Sigma read, so for warehouse-backed models the aggregate computed directly in
# SQL is a valid, independent "expected" value — no api.powerbi.com, no Entra
# app, no workspace/dataset id required.
#
# The agent runs each emitted SQL via `mcp__sigma-mcp-v2__query` (type:connection,
# the SAME connectionId the data model uses) to produce parity-expected.json, then
# feeds it to `phase6-parity-pbi.rb --local-sql --expected ...`.
#
# SCOPE: the common aggregate grammar — SUM / AVERAGE / MIN / MAX / COUNT /
# DISTINCTCOUNT / COUNTROWS over Table[Col], and DIVIDE(<agg>,<agg>) — with an
# optional single GROUP BY dimension. Anything outside it (RANKX, CALCULATE with
# filter context, time-intelligence, iterators) is marked supported:false so the
# caller falls back to the online DAX path (--emit-dax) or the waiver. We FLAG,
# never silently approximate.
#
# Usage:
#   ruby build-oracle-sql.rb --in <oracle-input.json> --out <chart-oracle-sql.json>
#
# oracle-input.json:
#   {
#     "connectionId": "<sigma connection uuid>",      # echoed for the agent's MCP call
#     "column_map": { "Order Id": "ORDER_ID", ... },   # OPTIONAL display->warehouse col.
#                                                       # REQUIRED for PromoteHeaders /
#                                                       # renamed columns (see --dm-spec).
#     "charts": {
#       "Total Sales":     { "fqn": "DB.SCH.TBL", "dax": "SUM(Orders[Sales])" },
#       "Sales by Region": { "fqn": "DB.SCH.TBL", "dax": "SUM(Orders[Sales])", "dim": "Region" }
#     }
#   }
#
# Optionally pass --dm-spec <dm-spec.json> to auto-derive a default fqn from the
# data model's warehouse-table element(s).

require 'json'

module OracleSql
  AGG = { 'SUM' => 'SUM', 'AVERAGE' => 'AVG', 'MIN' => 'MIN', 'MAX' => 'MAX',
          'COUNT' => 'COUNT', 'DISTINCTCOUNT' => 'COUNT', 'COUNTROWS' => 'COUNT' }.freeze

  # display name -> warehouse column. Explicit map wins; else Sigma's normal
  # transform inverse: "Order Id" -> ORDER_ID. NOT safe for PromoteHeaders /
  # renamed columns — those MUST be supplied via column_map (caller warns).
  def self.normalize_col(display)
    display.to_s.strip.gsub(/[^A-Za-z0-9]+/, '_').upcase.gsub(/^_+|_+$/, '')
  end

  def self.wh_col(display, col_map, fallback)
    return col_map[display] if col_map.key?(display)
    fallback << display
    normalize_col(display)
  end

  # Transpile a DAX measure body to a SQL select-expression, or nil if unsupported.
  # `fallback` (optional array) collects display names that used the heuristic.
  def self.transpile(dax, col_map = {}, fallback = [])
    d = dax.to_s.strip
    if (m = d.match(/\ADIVIDE\s*\(\s*(.+?)\s*,\s*(.+?)\s*\)\z/i))
      a = transpile(m[1], col_map, fallback)
      b = transpile(m[2], col_map, fallback)
      return (a && b) ? "#{a} / NULLIF(#{b},0)" : nil
    end
    return 'COUNT(*)' if d =~ /\ACOUNTROWS\s*\(\s*'?[^'\[\)]+'?\s*\)\z/i
    if (m = d.match(/\A([A-Za-z]+)\s*\(\s*'?[^'\[]+'?\s*\[\s*([^\]]+?)\s*\]\s*\)\z/))
      fn = m[1].upcase
      return nil unless AGG.key?(fn)
      col = wh_col(m[2], col_map, fallback)
      return "COUNT(DISTINCT #{col})" if fn == 'DISTINCTCOUNT'
      return "#{AGG[fn]}(#{col})"
    end
    nil
  end

  # Build the per-chart oracle descriptor. Returns a hash with supported:true +
  # sql/dim_col/val_col, or supported:false + reason.
  def self.chart_sql(name, dax, fqn, dim: nil, col_map: {}, fallback: [])
    return { 'supported' => false, 'reason' => 'no fqn (pass per-chart fqn or --dm-spec)' } unless fqn
    expr = transpile(dax, col_map, fallback)
    return { 'supported' => false, 'reason' => "unsupported DAX (outside aggregate grammar): #{dax}" } if expr.nil?
    if dim
      dcol = wh_col(dim, col_map, fallback)
      sql = %(SELECT #{dcol} AS "#{dim}", #{expr} AS "#{name}" FROM #{fqn} GROUP BY #{dcol} ORDER BY 2 DESC)
      { 'supported' => true, 'sql' => sql, 'dim_col' => dim, 'val_col' => name }
    else
      { 'supported' => true, 'sql' => %(SELECT #{expr} AS "#{name}" FROM #{fqn}), 'dim_col' => nil, 'val_col' => name }
    end
  end
end

# --------------------------------------------------------------------------- CLI
if __FILE__ == $PROGRAM_NAME
  require 'optparse'
  opts = {}
  OptionParser.new do |p|
    p.on('--in PATH')  { |v| opts[:in] = v }
    p.on('--out PATH') { |v| opts[:out] = v }
    p.on('--dm-spec PATH', 'optional DM spec — derive a default fqn from warehouse-table elements') { |v| opts[:dm] = v }
  end.parse!
  %i[in out].each { |k| abort("missing --#{k}") unless opts[k] }

  input = JSON.parse(File.read(opts[:in]))
  col_map = input['column_map'] || {}

  default_fqn = nil
  if opts[:dm]
    dm = JSON.parse(File.read(opts[:dm]))
    (dm['pages'] || []).each do |pg|
      (pg['elements'] || []).each do |el|
        src = el['source'] || {}
        default_fqn ||= src['path'].join('.') if src['kind'] == 'warehouse-table' && src['path']
      end
    end
  end

  fallback = []
  charts = {}
  input.fetch('charts', {}).each do |name, c|
    charts[name] = OracleSql.chart_sql(name, c['dax'], c['fqn'] || default_fqn,
                                       dim: c['dim'], col_map: col_map, fallback: fallback)
  end
  out = { '_connectionId' => input['connectionId'], '_charts' => charts }
  File.write(opts[:out], JSON.pretty_generate(out))

  supported = charts.values.count { |v| v['supported'] }
  unsupported = charts.reject { |_, v| v['supported'] }
  warn "[build-oracle-sql] #{supported}/#{charts.size} chart(s) -> warehouse SQL; " \
       "#{unsupported.size} need the online DAX fallback."
  unsupported.each { |n, v| warn "  [fallback] #{n}: #{v['reason']}" }
  unless fallback.uniq.empty?
    warn "[build-oracle-sql] WARNING: no explicit column_map for #{fallback.uniq.size} column(s) " \
         "(#{fallback.uniq.join(', ')}) — used the NAME->UPPER_SNAKE heuristic. If the warehouse " \
         "columns are renamed/auto-named (Table.PromoteHeaders -> C1/C2, see pbi-dm-signature.py), pass " \
         'an explicit column_map or the oracle SQL will reference columns that do not exist.'
  end
  warn "[build-oracle-sql] wrote #{opts[:out]} — run each `sql` via mcp__sigma-mcp-v2__query " \
       "{type:connection, connectionId:#{input['connectionId'].inspect}}, save rows to parity-expected.json, " \
       'then: phase6-parity-pbi.rb --local-sql --expected parity-expected.json --workbook-id <id> --out plan.json'
end
