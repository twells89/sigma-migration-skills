# frozen_string_literal: true

# Domo-specific semantic rewrites that the generic SQL converter cannot infer.
# Every automatic rule is intentionally narrow and source-shape matched. Unknown
# FIXED/window/residual SQL stays blocked rather than shipping plausible output.
module DomoSigma
  module BeastModeSemantics
    module_function

    def translate(entry, sigma_formula)
      original = entry['originalSql'].to_s.strip
      sigma = sigma_formula.to_s

      return translated(rewrite_window(original)) if rewrite_window(original)

      case original
      when /\A\s*APPROXIMATE_COUNT_DISTINCT\s*\(\s*`?([^`)]+)`?\s*\)\s*\z/i
        return translated("CountDistinct([#{Regexp.last_match(1).strip}])")
      when /\A\s*SQRT\s*\(/i
        return translated(sigma.sub(/\ASqrt\s*\(/i, 'Power(').sub(/\)\s*\z/, ', 0.5)'))
      when /\A\s*CONVERT_TZ\s*\(/i
        if (match = sigma.match(/\AConvert_tz\s*\((.+?),\s*("[^"]+"),\s*("[^"]+")\)\s*\z/i))
          return translated("ConvertTimezone(#{match[1]}, #{match[3]}, #{match[2]})")
        end
      when /\A\s*MICROSECOND\s*\(/i
        return blocked('Domo marks MICROSECOND as illegal and card-data/render fails')
      when /\A\s*SUM\s*\(\s*DISTINCT\s+`?([^`)]+)`?\s*\)\s*\z/i
        field = Regexp.last_match(1).strip
        return translated(
          "Sum([#{field}])",
          'kind' => 'sum-distinct',
          'field' => field,
        )
      when /\A\s*PERCENT_RANK\s*\(/i
        return blocked('Domo rejected PERCENT_RANK as an invalid analytic function in the live acceptance matrix')
      end

      rewritten = rewrite_like(sigma)
      rewritten = rewrite_between(rewritten)
      rewritten = rewrite_date_functions(rewritten)
      rewritten = rewrite_mixed_if(rewritten)
      return translated(rewritten) if rewritten != sigma

      return blocked('untranslated FIXED/LOD shape requires an explicit workbook placement') if original.match?(/\bFIXED\s*\(/i)
      return blocked('untranslated window OVER(...) shape requires an explicit workbook placement') if original.match?(/\bOVER\s*\(/i)
      return blocked('residual LIKE/BETWEEN SQL remains after conversion') if rewritten.match?(/\b(?:LIKE|BETWEEN)\b/i)

      nil
    end

    def rewrite_window(original)
      field = '(`?[^`)]+`?)'
      order = '`?[^`)]+`?'
      if (match = original.match(/\A\s*SUM\s*\(\s*SUM\s*\(\s*#{field}\s*\)\s*\)\s*OVER\s*\(\s*ORDER\s+BY\s+#{order}(?:\s+(ASC|DESC))?\s*\)\s*\z/i))
        return "CumulativeSum(Sum([#{unquote(match[1])}]))"
      end
      if (match = original.match(/\A\s*RANK\s*\(\s*\)\s*OVER\s*\(\s*ORDER\s+BY\s+SUM\s*\(\s*#{field}\s*\)\s*(ASC|DESC)?\s*\)\s*\z/i))
        direction = (match[2] || 'ASC').downcase
        return "Rank(Sum([#{unquote(match[1])}]), \"#{direction}\")"
      end
      if (match = original.match(/\A\s*(LAG|LEAD)\s*\(\s*SUM\s*\(\s*#{field}\s*\)\s*,\s*(\d+)\s*\)\s*OVER\s*\(\s*ORDER\s+BY\s+#{order}(?:\s+(ASC|DESC))?\s*\)\s*\z/i))
        return "#{match[1].capitalize}(Sum([#{unquote(match[2])}]), #{match[3]})"
      end
      if (match = original.match(/\A\s*NTILE\s*\(\s*(\d+)\s*\)\s*OVER\s*\(\s*ORDER\s+BY\s+SUM\s*\(\s*#{field}\s*\)\s*(ASC|DESC)?\s*\)\s*\z/i))
        direction = (match[3] || 'ASC').downcase
        return "Ntile(#{match[1]}, Sum([#{unquote(match[2])}]), \"#{direction}\")"
      end
      nil
    end

    def rewrite_like(formula)
      formula.gsub(/((?:[A-Za-z][A-Za-z0-9_]*\(\[[^\]]+\]\)|\[[^\]]+\]))\s+(NOT\s+)?LIKE\s+"([^"]*)"/i) do
        expression = like_expression(Regexp.last_match(1), Regexp.last_match(3))
        Regexp.last_match(2) ? "not (#{expression})" : expression
      end
    end

    def like_expression(column, pattern)
      if pattern.start_with?('%') && pattern.end_with?('%') &&
         pattern.count('%') == 2 && !pattern.include?('_')
        %(Contains(#{column}, "#{pattern[1...-1]}"))
      elsif pattern.end_with?('%') && pattern.count('%') == 1 && !pattern.include?('_')
        %(StartsWith(#{column}, "#{pattern[0...-1]}"))
      elsif pattern.start_with?('%') && pattern.count('%') == 1 && !pattern.include?('_')
        %(EndsWith(#{column}, "#{pattern[1..]}"))
      elsif !pattern.include?('%') && !pattern.include?('_')
        %(#{column} = "#{pattern}")
      else
        escaped = Regexp.escape(pattern).gsub('%', '.*').gsub('_', '.')
        %(RegexpMatch(#{column}, "^#{escaped}$"))
      end
    end

    def rewrite_between(formula)
      formula.gsub(/(\[[^\]]+\])\s+BETWEEN\s+([^,\s)]+)\s+AND\s+([^,\s)]+)/i) do
        column = Regexp.last_match(1)
        "(#{column} >= #{Regexp.last_match(2)} and #{column} <= #{Regexp.last_match(3)})"
      end
    end

    def rewrite_date_functions(formula)
      rewritten = formula.dup
      rewritten.gsub!(/\bMonthname\s*\(/i, 'MonthName(')
      rewritten.gsub!(/\bDayofweek\s*\(/i, 'Weekday(')
      rewritten.gsub!(/\bLast_day\s*\(\s*([^)]+)\)/i, 'LastDay(\1, "month")')
      rewritten.gsub!(/\bDate_format\s*\(\s*([^,]+),\s*"([^"]+)"\s*\)/i) do
        %(DateFormat(#{Regexp.last_match(1)}, "#{translate_date_format(Regexp.last_match(2))}"))
      end
      rewritten.gsub!(/\bStr_to_date\s*\(\s*([^,]+),\s*"([^"]+)"\s*\)/i) do
        %(DateParse(#{Regexp.last_match(1)}, "#{translate_date_format(Regexp.last_match(2))}"))
      end
      rewritten
    end

    def rewrite_mixed_if(formula)
      formula.gsub(/\AIf\((.+),\s*(-?\d+(?:\.\d+)?),\s*("[^"]*")\)\z/) do
        "If(#{Regexp.last_match(1)}, Text(#{Regexp.last_match(2)}), #{Regexp.last_match(3)})"
      end
    end

    def translate_date_format(source)
      source.to_s
    end

    def unquote(identifier)
      identifier.to_s.strip.sub(/\A`/, '').sub(/`\z/, '')
    end

    def translated(formula, placement = nil)
      result = { 'status' => 'translated', 'formula' => formula }
      result['placement'] = placement if placement
      result
    end

    def blocked(reason)
      { 'status' => 'blocked', 'reason' => reason }
    end
  end
end
