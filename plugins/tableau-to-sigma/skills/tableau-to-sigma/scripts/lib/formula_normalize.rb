# Case-normalization of Sigma function-name tokens inside spec formulas.
#
# WHY: Sigma's formula language is CASE-SENSITIVE. A converter that emits
# `round(...)`, `DATETRUNC(...)`, or `left(...)` produces a spec whose columns
# either 400 at POST or silently compile to type "error" — a live migration
# shipped exactly this class of leak (lowercase / Tableau-case function names).
#
# CONTRACT (fix-workstream G — wired by migrate-tableau.rb; do not change the
# shape without updating the orchestrator):
#
#   spec, rewrites = FormulaNormalize.normalize_spec!(spec_hash)
#
#   - Mutates spec_hash in place (every String value under a "formula" key)
#     and returns [spec_hash, rewrites].
#   - rewrites is an Array of { from:, to:, path: } hashes, e.g.
#     { from: "round", to: "Round", path: "pages[0].elements[2].columns[1].formula" }
#
# SCOPE — pure CASE normalization only:
#   - A token is rewritten iff it (a) is immediately followed by "(", (b)
#     case-insensitively matches a KNOWN Sigma function name, and (c) does not
#     exactly match any known spelling. `round(` -> `Round(`, `dateTrunc(` ->
#     `DateTrunc(`; `Round(` is left alone and produces NO rewrite entry.
#   - NEVER touches column-reference text inside [brackets] or string literals
#     inside quotes — the tokenizer consumes those spans first.
#   - NEVER does semantic rewrites. DATENAME -> MonthName/WeekdayName,
#     IIF -> If, COUNTD -> CountDistinct etc. are converter territory
#     (converter/tableau.mjs + refs/coverage-matrix.md), not this module's.

require 'set'
require_relative 'sigma_functions'

module FormulaNormalize
  # Sigma functions named across the skill's refs that are missing from the
  # canonical whitelist in sigma_functions.rb:
  #   - Week, Datetime — refs/coverage-matrix.md (`WEEK` -> `Week`,
  #     `DATETIME` -> `Datetime`, both marked verified).
  #   - Ltrim, Rtrim — the spelling refs/coverage-matrix.md documents and
  #     converter/tableau.mjs emits (`LTRIM` -> `Ltrim`). sigma_functions.rb
  #     lists `LTrim`/`RTrim`; both spellings are treated as KNOWN (neither is
  #     ever rewritten), but pure case-variants (`LTRIM(`, `ltrim(`) normalize
  #     to the converter's spelling so normalized output matches what the
  #     converter path has posted successfully.
  EXTRA_FUNCTIONS = %w[Week Datetime Ltrim Rtrim].freeze

  KNOWN_FUNCTIONS = (SigmaFunctions::ALL + EXTRA_FUNCTIONS).uniq.freeze
  KNOWN_EXACT = KNOWN_FUNCTIONS.to_set.freeze

  # downcased name -> canonical spelling. On a case-insensitive collision the
  # converter/coverage-matrix spelling wins (see EXTRA_FUNCTIONS note).
  CANONICAL_BY_DOWNCASE = begin
    h = {}
    KNOWN_FUNCTIONS.each { |n| h[n.downcase] ||= n }
    h['ltrim'] = 'Ltrim'
    h['rtrim'] = 'Rtrim'
    h.freeze
  end

  # Tokenizer: bracketed column refs and quoted string literals are matched
  # FIRST (and passed through verbatim), so an identifier inside them can never
  # be treated as a function token. A function token is an identifier followed
  # (allowing whitespace) by an opening paren.
  TOKEN_RE = /
      \[[^\]]*\]                          # [column ref]            — immune
    | "(?:\\.|[^"\\])*"                   # "string literal"        — immune
    | '(?:\\.|[^'\\])*'                   # 'string literal'        — immune
    | [A-Za-z_][A-Za-z0-9_]*(?=\s*\()     # candidate function name
  /x

  # Tableau→Sigma NAME-ONLY function renames (deterministic, same signature):
  # auto-rewrite the leaked spelling to its Sigma equivalent so the mechanical
  # path never ships it as a type=error column. Only unambiguous 1:1 renames go
  # here (STR→Text, CurrentDate→Today); anything needing arg reshaping stays a
  # hard leak in sigma_functions.rb TABLEAU_LEAKS (validate-spec errors it).
  # downcased Tableau spelling => canonical Sigma spelling.
  TABLEAU_RENAMES = {
    'str' => 'Text',
    'currentdate' => 'Today',
    'current_date' => 'Today',
  }.freeze

  module_function

  # Canonical Sigma spelling for a Tableau name-only leak (STR→Text,
  # CurrentDate→Today); nil when +name+ isn't such a rename.
  def tableau_rename_of(name)
    TABLEAU_RENAMES[name.to_s.downcase]
  end

  # True when +name+ exactly matches a known Sigma function spelling.
  def known_exact?(name)
    KNOWN_EXACT.include?(name)
  end

  # Canonical spelling when +name+ case-insensitively matches a known Sigma
  # function but is NOT an exact known spelling (i.e., a pure case-variant);
  # nil otherwise.
  def case_variant_of(name)
    return nil if known_exact?(name)
    CANONICAL_BY_DOWNCASE[name.downcase]
  end

  # Normalize a single formula string. Appends { from:, to:, path: } entries
  # to +rewrites+ (when given) for every token changed. Returns the (possibly
  # unchanged) normalized string; never mutates its input.
  def normalize_formula(formula, path: nil, rewrites: nil)
    return formula unless formula.is_a?(String)
    formula.gsub(TOKEN_RE) do |tok|
      if tok.start_with?('[', '"', "'")
        tok # bracketed ref or string literal — pass through untouched
      elsif (canon = case_variant_of(tok))
        rewrites << { from: tok, to: canon, path: path } if rewrites
        canon
      elsif (sig = tableau_rename_of(tok))
        rewrites << { from: tok, to: sig, path: path } if rewrites
        sig # Tableau name-only leak (STR/CurrentDate) → Sigma equivalent
      else
        tok # exact known spelling, or not a known function — leave alone
      end
    end
  end

  # Walk an entire (already-parsed) spec hash, normalizing every String value
  # stored under a "formula" key at any depth. Mutates spec_hash in place.
  # Returns [spec_hash, rewrites].
  def normalize_spec!(spec_hash)
    rewrites = []
    walk!(spec_hash, '', rewrites)
    [spec_hash, rewrites]
  end

  def walk!(node, path, rewrites)
    case node
    when Hash
      node.each do |k, v|
        child = path.empty? ? k.to_s : "#{path}.#{k}"
        if k.to_s == 'formula' && v.is_a?(String)
          node[k] = normalize_formula(v, path: child, rewrites: rewrites)
        else
          walk!(v, child, rewrites)
        end
      end
    when Array
      node.each_with_index { |v, i| walk!(v, "#{path}[#{i}]", rewrites) }
    end
    node
  end
end
