# frozen_string_literal: true
# Omni field SQL → Sigma formulas for the v0 subset:
#   ${view.field} refs, aggregate_type, CONCAT, NULLIF, quoted identifiers.
# Mustache attributes and omni_dimensionalize fail closed (nil + reason).

module OmniFormula
  AGG = {
    'sum' => 'Sum',
    'count' => 'Count',
    'count_distinct' => 'CountDistinct',
    'average' => 'Avg',
    'avg' => 'Avg',
    'min' => 'Min',
    'max' => 'Max',
    'median' => 'Median'
  }.freeze

  module_function

  def display_name(field, label = nil)
    text = label.to_s.strip
    return text unless text.empty?
    field.to_s.split('_').reject(&:empty?).map { |w| w[0].upcase + w[1..].to_s }.join(' ')
  end

  def untranslatable?(sql)
    s = sql.to_s
    return 'omni_dimensionalize has no Sigma equivalent' if s =~ /omni_dimensionalize/i
    return 'Mustache user-attribute SQL is not translated' if s.include?('{{') || s =~ /omni_attributes/i
    return 'DO NOT PARSE dialect escape is not translated' if s =~ /DO NOT PARSE/
    nil
  end

  def warehouse_sql?(sql, field_name)
    s = sql.to_s.strip
    return true if s.empty?
    return true if s =~ /\A"[A-Za-z0-9_ ]+"\z/
    return true if s =~ /\A\$\{[A-Za-z0-9_]+\.#{Regexp.escape(field_name)}\}\z/
    false
  end

  def sigma_format(fmt)
    f = fmt.to_s.downcase
    return nil if f.empty?
    if f.include?('usd') || f.include?('currency')
      return { 'kind' => 'number', 'formatString' => '$,.2f', 'currencySymbol' => '$' }
    end
    if f.include?('percent')
      return { 'kind' => 'number', 'formatString' => '.0%' }
    end
    nil
  end

  # resolver.call(view, field) => Sigma ref string including brackets, or nil.
  def translate_expr(sql, resolver)
    reason = untranslatable?(sql)
    return [nil, reason] if reason
    out = sql.to_s.strip
    out = out.gsub(/\$\{([A-Za-z0-9_]+)\.([A-Za-z0-9_]+)\}/) do
      ref = resolver.call($1, $2)
      return [nil, "unresolved field ${#{$1}.#{$2}}"] if ref.nil?
      ref
    end
    out = out.gsub(/\bCONCAT\s*\(/i, 'Concat(')
    out = out.gsub(/\bnullif\s*\(/i, 'NullIf(')
    out = out.gsub(/'([^']*)'/, '"\1"')
    [out, nil]
  end

  def aggregate_formula(measure, view_name, local_display)
    agg = measure['aggregate_type'].to_s.downcase
    sql = measure['sql'].to_s.strip
    reason = untranslatable?(sql)
    return [nil, reason] if reason
    fn = AGG[agg]
    return [nil, "aggregate_type #{agg.inspect} is not mapped"] if !agg.empty? && fn.nil? && agg != 'list'
    return [nil, 'aggregate_type list is not mapped'] if agg == 'list'
    if agg == 'count' && (sql.empty? || sql =~ /\Acount\s*\(\s*\*\s*\)\z/i)
      return ['Count()', nil]
    end
    if fn && !sql.empty?
      ref = sql[/\$\{[A-Za-z0-9_]+\.([A-Za-z0-9_]+)\}/, 1]
      disp = local_display.call(ref || sql)
      return [nil, "measure sql #{sql.inspect} is not a single field ref"] if disp.nil?
      return ["#{fn}([#{disp}])", nil]
    end
    if fn && sql.empty?
      return ["#{fn}()", nil]
    end
    [nil, 'measure has no aggregate_type']
  end
end
