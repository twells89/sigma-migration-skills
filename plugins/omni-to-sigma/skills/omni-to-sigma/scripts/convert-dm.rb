#!/usr/bin/env ruby
# frozen_string_literal: true
# Topic-scoped Omni YAML → Sigma data-model spec (v0).
#
#   ruby scripts/convert-dm.rb --model-dir <dir> --topic <name> --out dm.json
#
# Plain views + relationships only. Query views, omni_dimensionalize, and
# Mustache attribute SQL are skipped with warnings (not guessed).
#
# Creds-free. Writes an envelope {sigmaDataModel, stats, warnings} plus an
# optional reuse signature for scripts/find-or-pick-dm.rb.

require 'json'
require 'optparse'
require_relative 'lib/omni_model'
require_relative 'lib/omni_formula'

def col_id(view, field)
  "col-#{view}-#{field}"
end

def metric_hash(view, field, label, formula, spec)
  metric = { 'id' => "met-#{view}-#{field}", 'name' => label, 'formula' => formula }
  fmt = OmniFormula.sigma_format(spec['format'])
  metric['format'] = fmt if fmt
  metric
end

def parse_on_sql(sql)
  m = sql.to_s.match(/\$\{([A-Za-z0-9_]+)\.([A-Za-z0-9_]+)\}\s*=\s*\$\{([A-Za-z0-9_]+)\.([A-Za-z0-9_]+)\}/)
  return nil unless m
  { 'left_view' => m[1], 'left_field' => m[2], 'right_view' => m[3], 'right_field' => m[4] }
end

def rel_type(raw)
  case raw.to_s
  when 'one_to_one' then '1:1'
  when 'one_to_many' then '1:N'
  when 'many_to_many' then 'N:N'
  else 'N:1' # many_to_one, assumed_many_to_one, default
  end
end

def build(model, topic_name, connection_id, folder_id)
  warnings = []
  topic = OmniModel.find_topic(model, topic_name)
  abort "topic not found: #{topic_name}" unless topic
  base_name = topic['base_view'].to_s
  abort "topic #{topic['_key']} has no base_view" if base_name.empty?
  base = model['views'][base_name]
  abort "base view #{base_name} not in model" unless base

  model['query_views'].each do |rel|
    warnings << "query view #{rel} skipped — query views are not converted in v0"
  end
  if topic['fields']
    warnings << "topic #{topic['_key']} fields: curation is not applied in v0 — all view fields are emitted"
  end
  if topic['access_filters'] || (model['model'].is_a?(Hash) && model['model']['default_topic_access_filters'])
    warnings << "access_filters on topic #{topic['_key']} — run detect-rls.rb; not applied on the DM"
  end
  if connection_id == '<CONNECTION_ID>'
    warnings << 'connection id placeholder <CONNECTION_ID> — pass --connection-id before POST'
  end

  scope = [base_name] + OmniModel.joined_views(topic)
  scope.uniq!
  missing = scope.reject { |n| model['views'][n] }
  missing.each { |n| warnings << "joined view #{n} missing from model — skipped" }
  scope -= missing

  displays = {} # [view, field] => display name
  elements = {}

  scope.each do |view_name|
    view = model['views'][view_name]
    schema = view['schema'].to_s
    table = view['table_name'].to_s
    if table.empty?
      warnings << "view #{view_name} has no table_name — skipped"
      next
    end
    el_name = table.upcase
    columns = []
    dim_specs = []
    (view['dimensions'] || {}).each do |field, spec|
      spec = {} unless spec.is_a?(Hash)
      next if spec['ignored']
      label = OmniFormula.display_name(field, spec['label'])
      displays[[view_name, field.to_s]] = label
      dim_specs << [field.to_s, spec, label]
    end
    dim_specs.each do |field, spec, label|
      sql = spec['sql'].to_s
      reason = OmniFormula.untranslatable?(sql)
      if reason
        warnings << "#{view_name}.#{field} skipped — #{reason}"
        next
      end
      if OmniFormula.warehouse_sql?(sql, field)
        formula = "[#{el_name}/#{label}]"
      else
        formula, err = OmniFormula.translate_expr(sql, lambda { |v, f|
          d = displays[[v, f]]
          d ? "[#{d}]" : nil
        })
        if err
          warnings << "#{view_name}.#{field} skipped — #{err}"
          next
        end
      end
      columns << { 'id' => col_id(view_name, field), 'name' => label, 'formula' => formula }
    end
    elements[view_name] = {
      'id' => "el-#{view_name}",
      'kind' => 'table',
      'name' => el_name,
      'source' => {
        'kind' => 'warehouse-table',
        'connectionId' => connection_id,
        'path' => schema.empty? ? [table] : [schema, table]
      },
      'columns' => columns
    }
  end

  # Measures on the base view only (topic grain).
  metrics = []
  base_view = model['views'][base_name]
  local_display = lambda do |field|
    return nil if field.nil?
    displays[[base_name, field]]
  end
  measure_formulas = {}
  pending_ratios = []
  (base_view['measures'] || {}).each do |field, spec|
    spec = {} unless spec.is_a?(Hash)
    next if spec['ignored']
    label = OmniFormula.display_name(field, spec['label'])
    formula, err = OmniFormula.aggregate_formula(spec, base_name, local_display)
    if formula.nil? && err == 'measure has no aggregate_type'
      pending_ratios << [field.to_s, spec, label]
      next
    end
    if formula.nil?
      warnings << "#{base_name}.#{field} skipped — #{err}"
      next
    end
    if spec['filters'].is_a?(Hash) && !spec['filters'].empty?
      warnings << "#{base_name}.#{field} measure filters are not applied — emitted the unfiltered aggregate"
    end
    measure_formulas[field.to_s] = formula
    metrics << metric_hash(base_name, field, label, formula, spec)
  end
  pending_ratios.each do |field, spec, label|
    formula, err = expand_ratio(spec['sql'].to_s, base_name, measure_formulas, displays)
    if formula.nil?
      warnings << "#{base_name}.#{field} skipped — #{err}"
      next
    end
    measure_formulas[field] = formula
    metrics << metric_hash(base_name, field, label, formula, spec)
  end

  base_el = elements[base_name]
  abort "base view #{base_name} produced no element" unless base_el

  rels = []
  Array(model['relationships']).each do |rel|
    next unless rel.is_a?(Hash)
    from = rel['join_from_view'].to_s
    to = rel['join_to_view'].to_s
    next unless scope.include?(from) && scope.include?(to)
    next unless elements[from] && elements[to]
    parsed = parse_on_sql(rel['on_sql'])
    unless parsed
      warnings << "relationship #{from} → #{to} skipped — on_sql is not a single equality"
      next
    end
    src_field = parsed['left_view'] == from ? parsed['left_field'] : parsed['right_field']
    tgt_field = parsed['left_view'] == to ? parsed['left_field'] : parsed['right_field']
    unless displays[[from, src_field]] && displays[[to, tgt_field]]
      warnings << "relationship #{from} → #{to} skipped — join keys are not converted columns"
      next
    end
    rels << {
      'id' => "rel-#{from}-#{to}",
      'name' => (rel['join_to_view_as'] || to).to_s,
      'targetElementId' => elements[to]['id'],
      'relationshipType' => rel_type(rel['relationship_type']),
      'keys' => [{
        'sourceColumnId' => col_id(from, src_field),
        'targetColumnId' => col_id(to, tgt_field)
      }]
    }
    if rel['reversible'] == false
      warnings << "relationship #{from} → #{to} is not reversible — Sigma relationship is one-directional"
    end
  end
  base_el['relationships'] = rels unless rels.empty?

  explore_cols = []
  base_el['columns'].each do |col|
    explore_cols << {
      'id' => "ex-#{col['id']}",
      'name' => col['name'],
      'formula' => "[#{base_el['name']}/#{col['name']}]"
    }
  end
  rels.each do |rel|
    target = elements.values.find { |el| el['id'] == rel['targetElementId'] }
    next unless target
    target['columns'].each do |col|
      explore_cols << {
        'id' => "ex-#{rel['name']}-#{col['id']}",
        'name' => col['name'],
        'formula' => "[#{base_el['name']}/#{rel['name']}/#{col['name']}]"
      }
    end
  end
  explore_metrics = metrics.map do |m|
    { 'id' => "ex-#{m['id']}", 'name' => m['name'], 'formula' => m['formula'] }.tap do |copy|
      copy['format'] = m['format'] if m['format']
    end
  end
  topic_label = topic['label'].to_s.empty? ? base_name : topic['label'].to_s
  explore = {
    'id' => "el-topic-#{topic['_key']}",
    'kind' => 'table',
    'name' => topic_label,
    'source' => { 'kind' => 'table', 'elementId' => base_el['id'] },
    'columns' => explore_cols,
    'metrics' => explore_metrics
  }

  ordered = scope.map { |n| elements[n] }.compact
  spec = {
    'name' => "#{topic_label} (Omni)",
    'schemaVersion' => 1,
    'pages' => [{
      'id' => 'page-data',
      'name' => 'Data',
      'elements' => ordered + [explore]
    }]
  }
  spec['folderId'] = folder_id if folder_id && !folder_id.empty?

  stats = {
    'views' => ordered.length,
    'topics' => 1,
    'elements' => ordered.length + 1,
    'columns' => (ordered + [explore]).sum { |el| (el['columns'] || []).length },
    'metrics' => (ordered + [explore]).sum { |el| (el['metrics'] || []).length },
    'relationships' => rels.length,
    'query_views_skipped' => model['query_views'].length
  }
  signature = {
    'tableau_workbook' => topic_label,
    'warehouse_tables' => ordered.map { |el| el['source']['path'].join('.') },
    'referenced_columns' => ordered.flat_map { |el| el['columns'].map { |c| c['name'] } }.uniq,
    'measures' => metrics.map { |m| m['name'] }
  }
  [{ 'sigmaDataModel' => spec, 'stats' => stats, 'warnings' => warnings }, signature, explore]
end

def expand_ratio(sql, view_name, measure_formulas, displays)
  reason = OmniFormula.untranslatable?(sql)
  return [nil, reason] if reason
  return [nil, 'empty ratio sql'] if sql.strip.empty?
  out = sql.dup
  out.gsub!(/\$\{([A-Za-z0-9_]+)\.([A-Za-z0-9_]+)\}/) do
    v, f = $1, $2
    if v == view_name && measure_formulas[f]
      "(#{measure_formulas[f]})"
    elsif displays[[v, f]]
      "[#{displays[[v, f]]}]"
    else
      return [nil, "unresolved ${#{v}.#{f}} in measure sql"]
    end
  end
  out.gsub!(/\bnullif\s*\(/i, 'NullIf(')
  [out, nil]
end

if __FILE__ == $PROGRAM_NAME
  opts = { connection_id: '<CONNECTION_ID>' }
  OptionParser.new do |o|
    o.on('--model-dir DIR') { |v| opts[:model_dir] = v }
    o.on('--topic NAME') { |v| opts[:topic] = v }
    o.on('--connection-id ID') { |v| opts[:connection_id] = v }
    o.on('--folder-id ID') { |v| opts[:folder_id] = v }
    o.on('--out PATH') { |v| opts[:out] = v }
    o.on('--signature-out PATH') { |v| opts[:signature_out] = v }
  end.parse!(ARGV)
  { model_dir: '--model-dir', topic: '--topic', out: '--out' }.each do |k, flag|
    abort "missing #{flag}" if opts[k].to_s.empty?
  end
  model = OmniModel.load(opts[:model_dir])
  envelope, signature, = build(model, opts[:topic], opts[:connection_id], opts[:folder_id])
  File.write(opts[:out], JSON.pretty_generate(envelope) + "\n")
  sig_path = opts[:signature_out] || File.join(File.dirname(opts[:out]), 'omni-signature.json')
  File.write(sig_path, JSON.pretty_generate(signature) + "\n")
  warn "wrote #{opts[:out]} (#{envelope['stats']['elements']} elements, #{envelope['warnings'].length} warnings)"
end
