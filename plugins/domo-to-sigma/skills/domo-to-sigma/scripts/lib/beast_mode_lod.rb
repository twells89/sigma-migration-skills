# frozen_string_literal: true

# Narrow, source-grounded Domo FIXED/LOD translations. These helpers only
# recognize shapes whose Sigma placement is deterministic; unknown LODs remain
# deferred instead of being flattened into a plausible-but-wrong aggregate.
module DomoSigma
  module BeastModeLod
    module_function

    def fixed_percent_of_total_plan(sql)
      normalized = sql.to_s
                      .gsub(/`([^`]+)`/) { Regexp.last_match(1) }
                      .gsub(/\[([^\]]+)\]/) { Regexp.last_match(1) }
                      .gsub(/\s+/, ' ')
                      .strip
      match = normalized.match(%r{
        \A(?:\(\s*)?(?<scale>100(?:\.0+)?)\s*\*\s*\(\s*
        (?<num_fn>COUNT|SUM)\s*\(\s*(?<num_distinct>DISTINCT\s+)?
          (?<num_field>[A-Za-z_][A-Za-z0-9_. ]*?)\s*\)\s*\/\s*
        SUM\s*\(\s*(?<den_fn>COUNT|SUM)\s*\(\s*(?<den_distinct>DISTINCT\s+)?
          (?<den_field>[A-Za-z_][A-Za-z0-9_. ]*?)\s*\)\s*
        FIXED\s*\(\s*BY\s+(?<fixed>[A-Za-z_][A-Za-z0-9_. ]*?)\s*\)
        \s*\)\s*\)\s*\)?\z
      }ix)
      return nil unless match
      return nil unless match[:num_fn].casecmp?(match[:den_fn])
      return nil unless normalized_name(match[:num_field]) == normalized_name(match[:den_field])
      return nil unless !match[:num_distinct].nil? == !match[:den_distinct].nil?

      aggregate =
        if match[:num_fn].casecmp?('COUNT')
          match[:num_distinct] ? 'CountDistinct' : 'Count'
        else
          'Sum'
        end
      {
        'kind' => 'fixed-percent-of-total',
        'aggregate' => aggregate,
        'field' => match[:num_field].strip,
        'fixedBy' => [match[:fixed].strip],
        'scale' => match[:scale].to_f,
      }
    end

    def fixed_percent_formula(plan, mode: 'grand_total', qualify: nil)
      return nil unless plan.is_a?(Hash) && plan['kind'] == 'fixed-percent-of-total'

      field = plan['field'].to_s
      field = qualify.call(field) if qualify
      scale = plan['scale'].to_f
      scale_literal = scale == scale.to_i ? scale.to_i.to_s : scale.to_s
      "#{scale_literal} * PercentOfTotal(#{plan['aggregate']}([#{field}]), \"#{mode}\")"
    end

    def fixed_aggregate_plan(sql)
      normalized = sql.to_s.gsub(/\s+/, ' ').strip
      match = normalized.match(%r{
        \A(?<outer>SUM|AVG|MIN|MAX)\s*\(\s*
        (?<inner>SUM|AVG|MIN|MAX|COUNT)\s*\(\s*`?(?<field>[^`)]+)`?\s*\)\s*
        FIXED\s*\(\s*(?<clause>.*?)\s*\)\s*\)\z
      }ix)
      return nil unless match

      clause = match[:clause].to_s.strip
      mode = 'all'
      dimensions = []
      filter_mode = nil
      filter_dimensions = []
      unless clause.empty?
        clause_match = clause.match(/\A(BY|ADD|REMOVE)\s+(.+?)(?:\s+FILTER\s+(NONE|ALLOW|DENY)(?:\s+(.+))?)?\z/i)
        return nil unless clause_match
        mode = clause_match[1].downcase
        dimensions = parse_dimensions(clause_match[2])
        filter_mode = clause_match[3]&.downcase
        filter_dimensions = parse_dimensions(clause_match[4])
      end
      {
        'kind' => 'fixed-aggregate',
        'outerAggregate' => match[:outer].capitalize,
        'innerAggregate' => match[:inner].capitalize,
        'field' => match[:field].strip,
        'mode' => mode,
        'dimensions' => dimensions,
        'filterMode' => filter_mode,
        'filterDimensions' => filter_dimensions,
      }.compact
    end

    def fixed_aggregate_placeholder(plan)
      "#{plan['outerAggregate']}(#{plan['innerAggregate']}([#{plan['field']}]))"
    end

    def parse_dimensions(raw)
      raw.to_s.split(',').map { |value| unquote(value) }.reject(&:empty?)
    end

    def unquote(value)
      value.to_s.strip.sub(/\A`/, '').sub(/`\z/, '')
    end

    def normalized_name(value)
      value.to_s.downcase.gsub(/[^a-z0-9]/, '')
    end
  end
end
