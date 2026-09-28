# frozen_string_literal: true
#
# sql_ident_check — Custom-SQL identifier preflight for kind:"sql" DM elements.
#
# WHY (hackathon field report, F2 class): the converter historically emitted
# Custom SQL referencing UPPER_SNAKE identifiers (CUSTOMER_SFDC_ID) when the
# actual warehouse column is spaced/mixed-case ("Customer SFDC ID") — a
# Snowflake "invalid identifier" compile error that only surfaces at DM POST,
# after minutes of pipeline. This module checks a statement's column
# identifiers against the LIVE catalog columns (the caller fetches those, e.g.
# via scripts/discover-columns.rb) BEFORE the POST, and proposes the quoted
# fix: CUSTOMER_SFDC_ID → "Customer SFDC ID".
#
# SCOPE (deliberate): this is a tokenizer good enough for the converter's
# emission patterns — bare identifiers, double-quoted identifiers, and
# table-alias prefixes (__f."Deal Value", d.STAGE_NAME) across SELECT / WHERE /
# GROUP BY / HAVING / ON / ORDER BY / QUALIFY / OVER clauses, WITH CTEs and
# derived-table subqueries. It is NOT a SQL parser; exotic SQL should go
# through the warehouse's own EXPLAIN.
#
# Matching semantics (Snowflake resolution rules):
#   - quoted "X"  → OK iff an actual column equals X CASE-EXACTLY.
#   - bare   X    → OK iff an actual column equals X or upcase(X) exactly
#                   (unquoted identifiers fold to upper case).
#   - otherwise   → unknown; if an actual column NORMALIZES to the same
#                   upper-snake key (non-alphanumerics → _), suggest the
#                   double-quoted exact name.
#
# ALSO here (W2.9): the emission-side identifier LEGALITY oracle
# (legal_bare? / sql_ident / illegal_reason / guid_shaped?) — the single
# authority on whether a name may be interpolated into live warehouse SQL at
# all. lib/join_plan.rb (derivation) and scripts/probe-join-keys.rb (emission)
# call it; no second legality regex may exist anywhere.
#
# Pure Ruby, stdlib only, no network. Callers: scripts/check-sql-idents.rb
# (CLI), scripts/probe-join-keys.rb, lib/join_plan.rb, and offline tests
# (scripts/test-sql-ident-check.rb).
module SqlIdentCheck
  module_function

  # ---- Emission-side identifier legality (W2.9) -----------------------------
  # THE single legality oracle for interpolating an identifier into LIVE
  # warehouse SQL (probe-join-keys.rb dup/totals probes; any future emitter
  # calls here too — no second legality regex may exist elsewhere). Distinct
  # from `check` below, which validates identifiers against a fetched catalog:
  # this layer decides whether a name may be SENT at all, catalog unseen.
  #
  #   sql_ident(name) → "NAME"          legal bare — emitted byte-identically
  #                   → %("Some Name")  legal only quoted (spaced/mixed-case)
  #                   → nil             REFUSED — not a credible physical
  #                                     identifier; the caller records a clean
  #                                     'error' and routes to its resolve path,
  #                                     never guesses into live SQL
  #
  # Refusal classes (refuse-don't-guess, the field-measured garbled-join class):
  # empty; control characters; an embedded double quote; parenthesis residue
  # of a Tableau role-disambiguation label folded into an identifier
  # ('PRODUCT_KEY_(PRODUCT_DIM)' — quoting it would only trade a clean local
  # error for a guaranteed live "invalid identifier" 400); a GUID-shaped
  # Tableau field id (an internal field id, never a physical column).
  BARE_IDENT_RE = /\A[A-Za-z_][A-Za-z0-9_$]*\z/

  # GUID-shaped Tableau internal field ids: canonical hex 8-4-4-4-12, plus the
  # looser long hex-hyphen inode-tail shape. lib/join_plan.rb's guid_like?
  # DELEGATES here — keep this the only copy of the shape.
  GUID_SHAPE_RE = /\A[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}\z/

  def guid_shaped?(name)
    s = name.to_s
    return true if s =~ GUID_SHAPE_RE
    !!(s =~ /\A[0-9A-Fa-f-]{20,}\z/ && s.include?('-'))
  end

  # Legal to interpolate BARE (also byte-identical: an unquoted legal
  # identifier is emitted exactly as recorded — the no-false-trip pin).
  def legal_bare?(name)
    !!(name.to_s =~ BARE_IDENT_RE)
  end

  # Why `name` may not be sent to the warehouse, or nil when it is emit-able
  # (bare or quoted). The caller puts this string in its recorded error.
  def illegal_reason(name)
    s = name.to_s
    return nil if legal_bare?(s)
    return 'empty identifier' if s.strip.empty?
    return 'contains control characters' if s =~ /[\x00-\x1F\x7F]/
    return 'contains a double quote' if s.include?('"')
    if s =~ /[()]/
      return 'parenthesis residue — a Tableau role-disambiguation display label folded into the identifier ' \
             '(re-derive the ledger: join_plan strips the trailing parenthetical)'
    end
    return 'GUID-shaped Tableau field id, not a physical column (caption resolution failed)' if guid_shaped?(s)
    nil
  end

  # Emission form of `name` for live SQL, or nil when refused (see above).
  def sql_ident(name)
    s = name.to_s
    return s if legal_bare?(s)
    illegal_reason(s) ? nil : %("#{s}")
  end

  # Words that can appear in identifier position but are never warehouse
  # columns. Function names are excluded structurally (token followed by "(") —
  # this list covers keywords and argument-position soup (DATE_TRUNC parts
  # arrive as string literals, already stripped).
  KEYWORDS = %w[
    SELECT FROM WHERE GROUP BY HAVING ORDER ASC DESC LIMIT OFFSET FETCH FIRST
    NEXT ROWS ROW ONLY AS ON USING JOIN INNER LEFT RIGHT FULL OUTER CROSS
    NATURAL LATERAL AND OR NOT IN IS NULL TRUE FALSE CASE WHEN THEN ELSE END
    DISTINCT ALL UNION EXCEPT INTERSECT WITH OVER PARTITION QUALIFY WINDOW
    BETWEEN LIKE ILIKE RLIKE SIMILAR TO EXISTS ANY SOME CAST INTERVAL
    CURRENT_DATE CURRENT_TIME CURRENT_TIMESTAMP LOCALTIME LOCALTIMESTAMP
    PRECEDING FOLLOWING UNBOUNDED CURRENT RANGE GROUPS EXCLUDE TIES OTHERS
    ASOF MATCH_CONDITION PIVOT UNPIVOT SAMPLE TABLESAMPLE TOP ESCAPE VALUES
  ].to_h { |k| [k, true] }.freeze

  # Upper-snake normalization matching the converter's alias scheme
  # ("Customer SFDC ID" → CUSTOMER_SFDC_ID).
  def normalize(name)
    name.to_s.gsub(/[^A-Za-z0-9]+/, '_').gsub(/\A_+|_+\z/, '').upcase
  end

  Token = Struct.new(:kind, :value) # kind: :word | :quoted | :punct

  # Tokenize a statement: strips line/block comments and single-quoted string
  # literals; yields double-quoted identifiers (:quoted, inner value with ""
  # unescaped), bare words (:word), and single-char punctuation (:punct).
  # Numbers are dropped (GROUP BY 1 ordinals are never column refs).
  def tokenize(sql)
    s = sql.to_s.dup
    s = s.gsub(/--[^\n]*/, ' ').gsub(%r{/\*.*?\*/}m, ' ')
    tokens = []
    i = 0
    while i < s.length
      c = s[i]
      case c
      when '"'
        j = i + 1
        buf = +''
        while j < s.length
          if s[j] == '"' && s[j + 1] == '"'
            buf << '"'
            j += 2
          elsif s[j] == '"'
            break
          else
            buf << s[j]
            j += 1
          end
        end
        tokens << Token.new(:quoted, buf)
        i = j + 1
      when "'"
        j = i + 1
        j += (s[j] == "'" && s[j + 1] == "'" ? 2 : 1) while j < s.length && !(s[j] == "'" && s[j + 1] != "'")
        i = j + 1
      when /[A-Za-z_]/
        j = i
        j += 1 while j < s.length && s[j] =~ /[A-Za-z0-9_$]/
        tokens << Token.new(:word, s[i...j])
        i = j
      when /[0-9]/
        j = i
        j += 1 while j < s.length && s[j] =~ /[0-9.eE+\-]/ && !(s[j] =~ /[+\-]/ && s[j - 1] !~ /[eE]/)
        i = j
      when /\s/
        i += 1
      else
        tokens << Token.new(:punct, c)
        i += 1
      end
    end
    tokens
  end

  # Structural scan → {
  #   idents:      [{name:, quoted:, alias: <tbl-alias|nil>}, ...]  candidate COLUMN refs
  #   aliases:     { "OUTPUT_ALIAS" => true, ... }   names defined by AS / CTEs (upcased)
  #   tables:      [{name:, alias:}]                 FROM/JOIN base tables (last path part)
  #   bad_aliases: [{raw:}, ...]  (#693) `AS <name>` clauses whose alias was
  #                NOT a single legal bare/quoted identifier — see below.
  # }
  def scan(sql)
    tokens = tokenize(sql)
    idents  = []
    defined = {}
    ctes = {}
    tables  = []
    bad_aliases = []
    # (#693) An `AS <name>` alias legally spans exactly ONE token — either a
    # whole :word or a whole :quoted. `AS SUB-CATEGORY` tokenizes as
    # word(SUB), punct(-), word(CATEGORY) — three tokens. The OLD scan took
    # only the first ("SUB") as "the" alias and left "- CATEGORY" to re-enter
    # the stream as spurious candidate column refs, which is exactly how the
    # live #693 failure printed "OK ... identifiers resolve" for the element
    # that then failed compilation: "CATEGORY" happened to be a real,
    # unrelated column, so the stray fragment silently passed catalog
    # resolution.
    #
    # extend_alias_run walks past a completed word/quoted token and decides
    # whether the run continues:
    #   - a hard-stop punct (`,` or `)`) or EOF always ends it.
    #   - any OTHER punct (`-`, `.`, `+`, ...) immediately glued onto the
    #     alias can ONLY be part of a genuine SQL clause when it is itself
    #     followed by another word/quoted token (a real compound-looking
    #     identifier) — never on its own after a complete alias — so it is
    #     consumed together with that next token and the run continues. This
    #     is what correctly reconstructs "YEAR-OVER-YEAR" as ONE alias even
    #     though its middle fragment ("OVER") happens to spell the real SQL
    #     keyword OVER: the keyword-ness of a word never matters when it
    #     arrives glued on through a connecting punct, only when it arrives
    #     bare (see next bullet).
    #   - a bare word with NO connecting punct before it (the source had a
    #     plain space, or nothing) is ambiguous: it is either the next SQL
    #     clause (`AS N FROM ...` — stop, do not consume) or the second word
    #     of an illegal unquoted multi-word alias (`AS ORDER DATE` — keep
    #     going, it's illegal either way and the whole run gets reported).
    #     KEYWORDS is exactly that dividing line: any name that only ever
    #     appears in SOURCE data as a business word (not a SQL keyword) will
    #     never appear here by accident, and even a false stop just leaves
    #     the remainder to the ordinary candidate-identifier scan below —
    #     never a false PASS.
    extend_alias_run = lambda do |alias_run, tokens, j|
      tok = tokens[j]
      return [alias_run, j] if tok.nil?
      if tok.kind == :punct
        return [alias_run, j] if %w[, )].include?(tok.value)
        following = tokens[j + 1]
        return [alias_run, j] unless following && (following.kind == :word || following.kind == :quoted)
        return [alias_run + [tok, following], j + 2]
      end
      return [alias_run, j] if KEYWORDS[tok.value.upcase]
      [alias_run + [tok], j + 1]
    end
    i = 0
    while i < tokens.length
      t = tokens[i]
      nxt = tokens[i + 1]
      up = t.kind == :word ? t.value.upcase : nil

      # WITH <cte> AS (   /   ), <cte> AS (
      if up == 'WITH' || (t.kind == :punct && t.value == ',' && nxt && tokens[i + 2] && tokens[i + 2].kind == :word && tokens[i + 2].value.upcase == 'AS' && tokens[i + 3] && tokens[i + 3].value == '(')
        cte = up == 'WITH' ? nxt : nxt
        if cte && (cte.kind == :word || cte.kind == :quoted) &&
           tokens[i + 2] && tokens[i + 2].kind == :word && tokens[i + 2].value.upcase == 'AS'
          defined[cte.value.upcase] = true
          ctes[cte.value.upcase] = true
          i += 3
          next
        end
      end

      # AS <name> — output alias / derived-table alias: defined, never checked
      # as a source ref. But first confirm <name> really IS a single legal
      # identifier (see extend_alias_run above) — a fragmented/illegal alias
      # is recorded in bad_aliases instead of silently defining its first
      # fragment.
      if up == 'AS' && nxt && (nxt.kind == :word || nxt.kind == :quoted)
        alias_run = [nxt]
        j = i + 2
        loop do
          new_run, new_j = extend_alias_run.call(alias_run, tokens, j)
          break if new_j == j # no progress — this IS the boundary
          alias_run, j = new_run, new_j
        end
        if alias_run.size > 1
          raw = alias_run.map(&:value).join
          bad_aliases << { raw: raw }
          defined[raw.upcase] = true
        else
          defined[nxt.value.upcase] = true
        end
        i = j
        next
      end

      # FROM/JOIN <table-ref> [alias] — capture the base table + its alias,
      # skip the path tokens entirely. FROM ( → derived table; its trailing
      # alias is caught by the ") word" rule below.
      if %w[FROM JOIN].include?(up)
        j = i + 1
        if tokens[j] && tokens[j].kind == :punct && tokens[j].value == '('
          i = j # fall through; subquery scanned as part of the stream
          next
        end
        parts = []
        while tokens[j] && (tokens[j].kind == :word || tokens[j].kind == :quoted)
          parts << tokens[j].value
          break unless tokens[j + 1] && tokens[j + 1].kind == :punct && tokens[j + 1].value == '.'
          j += 2
        end
        if parts.any?
          tbl = { name: parts.last, alias: nil }
          k = j + 1
          if tokens[k] && tokens[k].kind == :word && tokens[k].value.upcase == 'AS' && tokens[k + 1]
            tbl[:alias] = tokens[k + 1].value
            k += 2
          elsif tokens[k] && tokens[k].kind == :word && !KEYWORDS[tokens[k].value.upcase]
            tbl[:alias] = tokens[k].value
            k += 1
          end
          defined[tbl[:alias].upcase] = true if tbl[:alias]
          tables << tbl
          i = k
          next
        end
      end

      # ") <word>" — derived-table alias (e.g. ") __base", ") t"): defined.
      if t.kind == :punct && t.value == ')' && nxt && nxt.kind == :word &&
         !KEYWORDS[nxt.value.upcase] && !(tokens[i + 2] && tokens[i + 2].kind == :punct && tokens[i + 2].value == '(')
        defined[nxt.value.upcase] = true
        i += 2
        next
      end

      # <alias> . <ident>  — table-qualified column ref.
      if (t.kind == :word || t.kind == :quoted) && nxt && nxt.kind == :punct && nxt.value == '.' &&
         tokens[i + 2] && (tokens[i + 2].kind == :word || tokens[i + 2].kind == :quoted)
        col = tokens[i + 2]
        after = tokens[i + 3]
        source_pos = after && after.kind == :word && after.value.upcase == 'AS'
        # function call like alias.fn( never occurs in emitted SQL; treat as column
        idents << { name: col.value, quoted: col.kind == :quoted, alias: t.value,
                    source_pos: source_pos }
        i += 3
        next
      end

      # bare word: keyword? function (followed by "(")? else candidate column.
      # `X AS ...` marks X as SOURCE-position: it must be checked even when an
      # output alias shares its name (the `CUSTOMER_SFDC_ID AS CUSTOMER_SFDC_ID`
      # bug shape must not self-whitelist).
      if t.kind == :word
        if KEYWORDS[up] || (nxt && nxt.kind == :punct && nxt.value == '(')
          i += 1
          next
        end
        idents << { name: t.value, quoted: false, alias: nil,
                    source_pos: nxt && nxt.kind == :word && nxt.value.upcase == 'AS' }
        i += 1
        next
      end

      # standalone quoted ident: candidate column (unless followed by "(").
      if t.kind == :quoted
        unless nxt && nxt.kind == :punct && nxt.value == '('
          idents << { name: t.value, quoted: true, alias: nil,
                      source_pos: nxt && nxt.kind == :word && nxt.value.upcase == 'AS' }
        end
        i += 1
        next
      end

      i += 1
    end
    base_tables = tables.reject { |table| ctes[table[:name].to_s.upcase] }
    { idents: idents, aliases: defined, ctes: ctes, tables: base_tables, bad_aliases: bad_aliases }
  end

  # Check one statement against catalog columns.
  #
  #   statement        — the kind:"sql" element's SQL text
  #   columns_by_table — { "DEAL_FACTS" => ["Customer Ref ID", ...], ... }
  #                      (table keys matched case-insensitively on the LAST
  #                      path segment; values are the LIVE column names)
  #
  # Returns { ok:, unknown: [{identifier:, quoted:, table:, suggestion:}], tables: [...] }
  #   suggestion is the ready-to-paste fix, e.g. %q{"Customer Ref ID"}, or nil.
  #   (#693) unknown[] also carries emitted-ALIAS legality findings —
  #   `illegal_alias: true`, `table: nil` (a syntax defect, not a catalog
  #   miss) — so a statement whose SOURCE identifiers all resolve but whose
  #   `AS <alias>` is not legal SQL (e.g. `AS SUB-CATEGORY`, unquoted) still
  #   flips `ok` to false. This check needs NO catalog: it is independent of
  #   columns_by_table and runs even when the catalog for this element's
  #   table was never supplied.
  def check(statement, columns_by_table)
    scanned = scan(statement)
    norm_tables = {}
    (columns_by_table || {}).each { |t, cols| norm_tables[t.to_s.split('.').last.upcase] = Array(cols).map(&:to_s) }
    all_cols = norm_tables.values.flatten
    alias_to_table = {}
    scanned[:tables].each do |t|
      key = t[:name].to_s.upcase
      alias_to_table[t[:alias].to_s.upcase] = key if t[:alias] && norm_tables.key?(key)
    end

    unknown = []
    seen = {}
    (scanned[:bad_aliases] || []).each do |ba|
      raw = ba[:raw]
      key = "ALIAS:#{raw}"
      next if seen[key]
      seen[key] = true
      fixed = sql_ident(raw)
      unknown << { identifier: raw, quoted: false, table: nil,
                   suggestion: fixed, illegal_alias: true,
                   reason: fixed.nil? ? illegal_reason(raw) : nil }
    end
    scanned[:idents].each do |ref|
      name = ref[:name]
      next if name.empty?
      qualified_to_catalog = ref[:alias] && alias_to_table.key?(ref[:alias].to_s.upcase)
      # An output alias / CTE / derived-table name may be REFERENCED later
      # (outer SELECT, GROUP BY) — skip those occurrences. But an identifier in
      # SOURCE position (left of AS) or qualified to a real catalog table is a
      # column read and is always checked.
      next if scanned[:aliases][name.upcase] && !ref[:source_pos] && !qualified_to_catalog
      cols =
        if qualified_to_catalog
          norm_tables[alias_to_table[ref[:alias].to_s.upcase]]
        else
          all_cols
        end
      next if cols.empty? # no catalog supplied for this scope — can't judge
      ok =
        if ref[:quoted]
          cols.include?(name) # case-exact
        else
          cols.include?(name) || cols.include?(name.upcase)
        end
      next if ok
      key = "#{ref[:quoted] ? '"' : ''}#{name}"
      next if seen[key]
      seen[key] = true
      suggestion = nil
      if ref[:quoted]
        exact_ci = cols.find { |c| c.casecmp?(name) }
        suggestion = %("#{exact_ci}") if exact_ci
      end
      suggestion ||= begin
        n = normalize(name)
        hit = cols.find { |c| normalize(c) == n }
        hit ? %("#{hit}") : nil
      end
      unknown << { identifier: name, quoted: ref[:quoted],
                   table: ref[:alias] ? alias_to_table[ref[:alias].to_s.upcase] : nil,
                   suggestion: suggestion }
    end
    { ok: unknown.empty?, unknown: unknown, tables: scanned[:tables].map { |t| t[:name] } }
  end

  # All kind:"sql" elements of a DM spec → [{page:, name:, id:, statement:}].
  def sql_elements(dm_spec)
    out = []
    (dm_spec['pages'] || []).each do |pg|
      (pg['elements'] || []).each do |el|
        next unless el.dig('source', 'kind') == 'sql'
        out << { 'page' => pg['name'] || pg['id'], 'name' => el['name'] || el['id'],
                 'id' => el['id'], 'statement' => el.dig('source', 'statement').to_s }
      end
    end
    out
  end

  # Base tables referenced by every kind:"sql" element (last path segment,
  # upcased, deduped) — what the caller must supply --columns for.
  def referenced_tables(dm_spec)
    sql_elements(dm_spec).flat_map { |e| scan(e['statement'])[:tables].map { |t| t[:name].to_s.upcase } }
                         .reject { |t| t.start_with?('__') }.uniq
  end
end
