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

    def normalized_name(value)
      value.to_s.downcase.gsub(/[^a-z0-9]/, '')
    end
  end
end
