# frozen_string_literal: true

# Domo-specific semantic rewrites that the generic SQL converter cannot infer.
# Every automatic rule is intentionally narrow and source-shape matched. Unknown
# FIXED/window/residual SQL stays blocked rather than shipping plausible output.
module DomoSigma
  module BeastModeSemantics
    module_function

    def translate(entry, sigma_formula)
      original, = strip_mysql_comments(entry['originalSql'])
      original = original.strip
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
      rewritten = rewrite_string_functions(rewritten)
      rewritten = rewrite_date_functions(rewritten)
      rewritten = rewrite_concat_arguments(rewritten)
      rewritten = rewrite_mixed_if(rewritten)
      rewritten = rewrite_integer_division(rewritten) if original.include?('/')
      return translated(rewritten) if rewritten != sigma

      return blocked('untranslated FIXED/LOD shape requires an explicit workbook placement') if original.match?(/\bFIXED\s*\(/i)
      return blocked('untranslated window OVER(...) shape requires an explicit workbook placement') if original.match?(/\bOVER\s*\(/i)
      return blocked('residual LIKE/BETWEEN SQL remains after conversion') if rewritten.match?(/\b(?:LIKE|BETWEEN)\b/i)

      nil
    end

    # Remove MySQL comments without touching comment-like text inside quoted
    # strings or backtick identifiers. `--` starts a MySQL line comment only
    # when followed by whitespace/end-of-input, so subtraction/negative-value
    # expressions such as `a--1` remain executable code.
    #
    # Returns [comment_free_sql, removed_count, unterminated_block_comment].
    def strip_mysql_comments(sql)
      source = sql.to_s
      output = +''
      state = :normal
      removed = 0
      index = 0

      while index < source.length
        char = source[index]
        following = source[index + 1]

        case state
        when :normal
          if char == "'" || char == '"' || char == '`'
            state = { "'" => :single_quote, '"' => :double_quote, '`' => :backtick }.fetch(char)
            output << char
            index += 1
          elsif char == '/' && following == '*'
            state = :block_comment
            removed += 1
            output << ' '
            index += 2
          elsif char == '#'
            state = :line_comment
            removed += 1
            output << ' '
            index += 1
          elsif char == '-' && following == '-' &&
                (index + 2 >= source.length || source[index + 2].match?(/\s/))
            state = :line_comment
            removed += 1
            output << ' '
            index += 2
          else
            output << char
            index += 1
          end
        when :single_quote, :double_quote, :backtick
          quote = { single_quote: "'", double_quote: '"', backtick: '`' }.fetch(state)
          output << char
          if char == '\\' && following
            output << following
            index += 2
          elsif char == quote && following == quote
            output << following
            index += 2
          elsif char == quote
            state = :normal
            index += 1
          else
            index += 1
          end
        when :line_comment
          if char == "\n"
            output << "\n"
            state = :normal
          end
          index += 1
        when :block_comment
          if char == '*' && following == '/'
            output << ' '
            state = :normal
            index += 2
          else
            output << "\n" if char == "\n"
            index += 1
          end
        end
      end

      [output, removed, state == :block_comment]
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

    def rewrite_string_functions(formula)
      rewrite_named_functions(
        formula,
        'LENGTH' => 'Len',
        'SUBSTRING' => 'Mid',
        'SUBSTR' => 'Mid',
      )
    end

    # Rename function-call identifiers without modifying the same words inside
    # string literals or [column references].
    def rewrite_named_functions(formula, mappings)
      source = formula.to_s
      output = +''
      quote = nil
      index = 0

      while index < source.length
        char = source[index]
        following = source[index + 1]
        if quote
          output << char
          if char == '\\' && following
            output << following
            index += 2
          elsif char == quote && following == quote
            output << following
            index += 2
          elsif char == quote
            quote = nil
            index += 1
          else
            index += 1
          end
        elsif char == "'" || char == '"'
          quote = char
          output << char
          index += 1
        elsif char == '[' && (closing = source.index(']', index + 1))
          output << source[index..closing]
          index = closing + 1
        elsif char.match?(/[A-Za-z_]/)
          finish = index + 1
          finish += 1 while finish < source.length && source[finish].match?(/[A-Za-z0-9_]/)
          name = source[index...finish]
          call_follows = source[finish..].to_s.match?(/\A\s*\(/)
          output << (call_follows ? mappings.fetch(name.upcase, name) : name)
          index = finish
        else
          output << char
          index += 1
        end
      end
      output
    end

    # MySQL CONCAT coerces every argument to text; Sigma Concat requires text
    # arguments. Wrap every non-literal argument in Text() so date/number
    # expressions (for example Day(Today())) compile without changing ordinary
    # text-column behavior.
    def rewrite_concat_arguments(formula)
      source = formula.to_s
      output = +''
      index = 0

      while index < source.length
        if source[index] == '"' || source[index] == "'"
          finish = quoted_segment_end(source, index)
          output << source[index...finish]
          index = finish
          next
        end
        if source[index] == '[' && (closing = source.index(']', index + 1))
          output << source[index..closing]
          index = closing + 1
          next
        end
        unless source[index].match?(/[A-Za-z_]/)
          output << source[index]
          index += 1
          next
        end

        finish = index + 1
        finish += 1 while finish < source.length && source[finish].match?(/[A-Za-z0-9_]/)
        name = source[index...finish]
        opening = finish
        opening += 1 while opening < source.length && source[opening].match?(/\s/)
        unless name.casecmp('Concat').zero? && source[opening] == '('
          output << name
          index = finish
          next
        end

        closing = matching_paren(source, opening)
        unless closing
          output << source[index..]
          break
        end
        arguments = split_formula_arguments(source[(opening + 1)...closing]).map do |argument|
          rewritten = rewrite_concat_arguments(argument).strip
          if rewritten.match?(/\A(?:"(?:[^"\\]|\\.)*"|'(?:[^'\\]|\\.)*')\z/) ||
             rewritten.match?(/\AText\s*\(/i)
            rewritten
          else
            "Text(#{rewritten})"
          end
        end
        output << "Concat(#{arguments.join(', ')})"
        index = closing + 1
      end
      output
    end

    def quoted_segment_end(source, opening)
      quote = source[opening]
      index = opening + 1
      while index < source.length
        if source[index] == '\\' && index + 1 < source.length
          index += 2
        elsif source[index] == quote && source[index + 1] == quote
          index += 2
        elsif source[index] == quote
          return index + 1
        else
          index += 1
        end
      end
      source.length
    end

    def matching_paren(source, opening)
      depth = 0
      index = opening
      while index < source.length
        char = source[index]
        if char == '"' || char == "'"
          index = quoted_segment_end(source, index)
          next
        elsif char == '[' && (closing = source.index(']', index + 1))
          index = closing + 1
          next
        elsif char == '('
          depth += 1
        elsif char == ')'
          depth -= 1
          return index if depth.zero?
        end
        index += 1
      end
      nil
    end

    def split_formula_arguments(source)
      arguments = []
      start = 0
      depth = 0
      index = 0
      while index < source.length
        char = source[index]
        if char == '"' || char == "'"
          index = quoted_segment_end(source, index)
          next
        elsif char == '[' && (closing = source.index(']', index + 1))
          index = closing + 1
          next
        elsif char == '('
          depth += 1
        elsif char == ')'
          depth -= 1
        elsif char == ',' && depth.zero?
          arguments << source[start...index]
          start = index + 1
        end
        index += 1
      end
      arguments << source[start..]
      arguments
    end

    def rewrite_date_functions(formula)
      rewritten = formula.dup
      rewritten.gsub!(/\b(?:Curdate|Current_date)\s*\(\s*\)/i, 'Today()')
      rewritten.gsub!(/\b(?:Curtime|Current_time|Current_timestamp|Sysdate)\s*\(\s*\)/i, 'Now()')
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

    def rewrite_integer_division(formula)
      formula.sub(
        /(\b(?:Sum|Count|Avg|Min|Max)\s*\([^()]+\))\s*\//i,
        '(1.0 * \1) /',
      )
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
