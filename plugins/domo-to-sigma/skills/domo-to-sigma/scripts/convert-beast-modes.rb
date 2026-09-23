#!/usr/bin/env ruby
# Phase 2 — Beast Mode (MySQL SQL) → Sigma formula.
#
# Beast Mode is MySQL-dialect SQL. The actual translation runs LOCALLY via the
# vendored converter/sql.mjs bundle (esbuild-bundled from sigma-data-model-mcp's
# src/formulas.ts by `tools/vendor-converters.sh <checkout> domo` — see
# converter/PROVENANCE.json for the pinned source commit), invoked through
# `node`. No MCP call and no network in the automated path — see
# resolve_sql_converter's 3-tier ladder below: the vendored bundle is the
# default; --mcp-dir/DOMO_MCP_DIR is an explicit local-dev opt-in; a manual
# convert_sql_to_sigma_formula MCP call + --converter-out is the tier-3 last
# resort, reached only via the exit-10 GATE when neither of the first two
# resolves (e.g. no vendored bundle and no dev checkout, or `node` missing).
# This script does NOT reimplement translation itself. It adds the two layers
# the generic SQL converter can't know about:
#
#   PRE  — Domo-specific normalization (backtick identifiers → [Col], flag
#          unsupported fns, flag the WEEKDAY day-numbering mismatch (MySQL vs.
#          Sigma disagree on which int means which weekday) and the
#          CEILING/FLOOR-are-aggregates trap, flag window/LOD Beast Modes) —
#          see refs/beast-mode-to-sigma.md.
#   POST — Sigma-specific lint of the returned formula (leftover infix IN(/LIKE,
#          And()/Or()/Not() function-call forms that silently null, window-fn
#          workbook-master limits) — see refs/beast-mode-to-sigma.md +
#          feedback_sigma_window_functions.
#
# Three-step flow (SKILL.md's Phase 2 runs all three; no agent/MCP call in the
# middle step unless the exit-10 GATE fires):
#   ruby scripts/convert-beast-modes.rb            # normalize → discovery/formulas.pending.json
#   ruby scripts/convert-beast-modes.rb --convert  # local node + vendored converter/sql.mjs —
#                                                   #   fills sigmaFormula + converted (true/false) in place
#   ruby scripts/convert-beast-modes.rb --lint     # validate filled pending → discovery/formulas.json
#
# HAND-AUTHORED ESCAPE HATCH — discovery/formula-overrides.json
#
# UPDATE 2026-07-30: the shared `convert_sql_to_sigma_formula` DOES now
# translate `CASE WHEN` (→ `If(cond, then, else)`) and `COUNT(DISTINCT x)`
# (→ `CountDistinct(x)`) — fixed upstream in sigma-data-model-mcp PR #115
# (squashed as 2ba3ea8). Beads jva2 and sqp1 are closed.
#
# UPDATE 2026-07-30 (later same day): the double-bracketing collision this
# script's own step 1 used to trigger — handing the converter an
# ALREADY-bracketed, ALL-CAPS identifier (`SUM(\`NET_REVENUE\`)` → step 1 →
# `SUM([NET_REVENUE])`), which the converter's own bracket-wrapping pass used
# to wrap AGAIN into invalid `Sum([[Net Revenue]])` — is **also fixed**
# upstream, in sigma-data-model-mcp PR #116. Bead `qorq` is closed. Re-verified
# live against PR #116: all four Beast Modes that previously needed this
# sidecar (Margin Pct, Margin Pct 2, Avg Order Value, Return Rate) now convert
# to the hand-authored formula exactly (two of the four differ only by a
# semantically-inert wrapping paren — `(a / b)` vs `a / b`, the same formula in
# Sigma) and their override entries have been removed. See
# refs/live-validation-2026-07-30.md, "⛔ The formula layer is NOT 'nearly
# free'" — now annotated RESOLVED (all three bugs) with the corrected
# re-measurement.
#
# The sidecar mechanism STAYS: it is still the right escape hatch for whatever
# the shared converter cannot yet do next — e.g. the still-open gaps this
# script itself flags via `preWarnings` (CEILING/FLOOR-as-aggregate, unmapped
# functions, window/LOD Beast Modes) or a shape the corpus hasn't hit yet. It
# is simply no longer load-bearing for the CASE WHEN / COUNT(DISTINCT) /
# double-bracketing defect class.
#
# Track E (2026-08-03): this translation now runs vendored/local (see the
# 3-tier ladder above) instead of a live MCP call, so the PR #115/#116 fixes
# above are inherited automatically on each `tools/vendor-converters.sh domo`
# re-vendor — nothing in this script's own logic needed to change for that.
#
# discovery/formula-overrides.json is an OPERATOR-authored sidecar (same
# convention as discovery/kpi-overrides.json / dataset-map.json — this script
# only ever READS it, so re-running normalize or --lint never clobbers it).
# Keyed by the Beast Mode's stable `id` (`calculation_<uuid>`, survives
# re-runs) or its human-friendly `name` (accepted alternate key, since ids are
# opaque). Worked example — Beast Mode's `CEILING()` is an AGGREGATE (rounded
# MAX), not math rounding, which the generic SQL converter has no way to know
# (see the CEILING/FLOOR warning below); this is the kind of shape the sidecar
# still earns its keep on:
#
#   {
#     "calculation_4cd7e7c8-...": {
#       "sigmaFormula": "Round(Max([Net Revenue]), 0)",
#       "note": "hand-authored: CEILING() is a Beast Mode AGGREGATE (rounded MAX), not math rounding — the generic converter cannot know this"
#     },
#     "Avg Order Value": {
#       "sigmaFormula": "Sum([Net Revenue]) / CountDistinct([Order Id])"
#     }
#   }
#
# `Round`, `Max`, `Sum`, `CountDistinct` verified against
# plugins/sigma-authoring/skills/sigma-workbooks/reference/specification/formulas.md.
#
# Rules (enforced in resolve_entry / unmatched_override_keys below):
#   - An override SUPPLIES a MISSING sigmaFormula, OR SUPERSEDES one that
#     --convert filled in but flagged converted:false (still-broken machine
#     output) — widened 2026-08-03: --convert's mechanical fallback
#     (lookConvertExpression) is total and always produces SOME sigmaFormula,
#     so "missing" alone had become nearly unreachable in the orchestrated
#     pipeline. It never silently replaces a formula that converted CLEANLY
#     (converted:true, or a legacy entry with no `converted` key at all —
#     unaffected by this widening). When an override IS applied, the emitted
#     entry's `converted` is forced to `true` and any stale converted:false
#     "could not fully translate" note is cleared first — a human-authored
#     formula must never carry forward the discarded automated attempt's note.
#   - Every use is still POST-linted by lint_formula (raw IN(, And()/Or()/
#     Not() as calls, unbalanced brackets) — a hand-authored typo is a hard
#     lintError in formulas.json, never a silent pass.
#   - Every use emits a loud stderr warning naming the Beast Mode and stating
#     that the AUTOMATED conversion failed — so the upstream bug stays
#     visible and an override can never look machine-translated. The emitted
#     entry also carries `"_source": "formula-override"` (+ `note` if given).
#   - A formula-overrides.json key matching no pending entry's id/name warns
#     (typo'd key must not silently no-op).

require 'json'
require 'optparse'
require 'open3'
require 'tmpdir'
require 'digest'
require 'time'
require_relative 'lib/beast_mode_lod'
require_relative 'lib/beast_mode_semantics'

OUT = ENV['DOMO_DISCOVERY_DIR'] || File.expand_path('../discovery', __dir__)

# Track E — the vendored SQL-formula converter (tools/vendor-converters.sh domo).
VENDORED_SQL = File.expand_path('../converter/sql.mjs', __dir__)

# Converter resolution, same 3-tier ladder as powerbi-to-sigma's
# migrate-powerbi.rb#resolve_converter: the vendored bundle is the DEFAULT (byte-
# identical output on any machine); a local sigma-data-model-mcp build is used
# ONLY when explicitly opted into via --mcp-dir/DOMO_MCP_DIR — no silent ~/…
# auto-discovery (that's the "works in my checkout, differs for the customer"
# footgun powerbi's own comment names). If neither resolves, the caller's
# --convert branch takes the last-resort exit-10 path. Returns
# [conv_module_path_or_nil, dev_build_dir_or_nil, description_or_nil].
def resolve_sql_converter(mcp_dir, vendored)
  dev_module = (mcp_dir && File.exist?(File.join(mcp_dir, 'build', 'formulas.js'))) ?
    File.join(mcp_dir, 'build', 'formulas.js') : nil
  conv = dev_module || (File.exist?(vendored) ? vendored : nil)
  desc =
    if conv && conv == vendored
      prov = File.join(File.dirname(vendored), 'PROVENANCE.json')
      commit = (JSON.parse(File.read(prov))['source_commit'] rescue nil)
      "VENDORED converter/sql.mjs#{commit ? " (pinned #{commit})" : ''} — no data egress"
    elsif conv
      "DEV BUILD #{conv} (explicit opt-in via --mcp-dir/DOMO_MCP_DIR)"
    end
  [conv, dev_module, desc]
end

# Removed from Beast Mode / unsupported in Sigma — warn if seen.
UNSUPPORTED = %w[SQRT CONVERT_TZ MICROSECOND WEEKDAY].freeze

# Convert a raw Beast Mode string toward what convert_sql_to_sigma_formula expects,
# applying only the Domo-specific deltas. Returns [normalizedSql, warnings].
def normalize_bm(sql, klass = nil)
  warnings = []
  s = sql.to_s.dup

  # 1. Backtick / bracket MySQL identifier quoting → Sigma [Column Name].
  s = s.gsub(/`([^`]+)`/) { "[#{$1}]" }

  # 2. Domo's legacy WEEKDAY is NOT MySQL WEEKDAY semantics. Official Domo
  # docs say it is replaced by DAYOFWEEK, and the 2026-09-23 live acceptance
  # matrix proved both functions return the identical 1=Sunday..7=Saturday
  # values. Normalize to DAYOFWEEK, then the post-converter semantic pass maps
  # it to Sigma Weekday() (the same numbering).
  if s =~ /\bWEEKDAY\s*\(/i
    s.gsub!(/\bWEEKDAY\s*\(/i, 'DAYOFWEEK(')
    warnings << 'Domo legacy WEEKDAY() is normalized to DAYOFWEEK() (live-proven identical 1=Sunday..7=Saturday semantics).'
  end

  # 3. Unsupported functions.
  UNSUPPORTED.each do |fn|
    next if fn == 'WEEKDAY' # handled above
    warnings << "Unsupported function #{fn}() present — legacy formula; review (SQRT → Power([x],0.5))." if s =~ /\b#{fn}\s*\(/i
  end

  # 4. Class-driven flags.
  case klass
  when 'window'
    warnings << 'WINDOW/analytic Beast Mode → Sigma Rank/SumOver/CountOver; these SILENTLY error in workbook-master/DM calc cols (feedback_sigma_window_functions). Place carefully + verify.'
  when 'lod'
    warnings << 'FIXED/LOD Beast Mode → Sigma level-of-detail; do NOT flatten to a plain aggregate. Needs review.'
  end

  [s.strip, warnings]
end

NEEDS_REVIEW = %w[window lod].freeze
AGGREGATE_SQL_RE = /\b(?:SUM|COUNT|AVG|MIN|MAX|MEDIAN|STDDEV(?:_POP|_SAMP)?|
  VARIANCE|VAR_POP|VAR_SAMP|APPROXIMATE_COUNT_DISTINCT)\s*\(/ix
PROVENANCE_KEYS = %w[
  dataSourceId _dataSourceId cardId dataType persistedOnDataSource saveToDataSet
  sourceFormulaScope definitionConflict extractionError nameConflictIds
].freeze

def effective_formula_class(sql, recorded = nil)
  source = sql.to_s
  return 'lod' if source.match?(/\bFIXED\s*\(/i)
  return 'window' if source.match?(/\bOVER\s*\(|\b(?:RANK|DENSE_RANK|ROW_NUMBER|LAG|LEAD|NTILE|PERCENT_RANK|CUME_DIST)\s*\(/i)
  return 'aggregate' if source.match?(AGGREGATE_SQL_RE)
  return recorded if source.strip.empty? && !recorded.to_s.empty?
  'projection'
end

def formula_source_fingerprint(path)
  Digest::SHA256.file(path).hexdigest
end

# Is this `IN(`/`in(` occurrence a raw SQL INFIX construct (`x IN (a, b)`,
# unsupported by Sigma) rather than Sigma's own `In([col], "a", "b")`
# FUNCTION form (real, documented, must NOT be flagged — see
# plugins/sigma-authoring/skills/sigma-workbooks/reference/specification/formulas.md)?
#
# Shape, not substring: a genuine infix always has a VALUE EXPRESSION
# directly before the `IN` token (only whitespace between) — a `]`, a
# closing `)`, a quoted string, or a bare identifier/number. Sigma's
# function-call form instead sits in a function-NAME position: the very
# start of the formula, immediately after `(`, `,`, `and`, or `or`, or right
# after a comparison operator (`=`, `<>`, `!=`, `>`, `<`, `>=`, `<=` — the
# full set the vendored SQL-formula converter itself recognizes, converter/
# sql.mjs) used as In(...)'s left-hand operand, e.g. `[a] = In([b], "x")` —
# wherever a function name is syntactically expected.
#
# `not` is deliberately NOT treated as its own function-name-position marker
# here (unlike a natural first reading of that rule): `not` is itself a
# prefix operator in Sigma, so whatever precedes IT determines the shape —
# `not In([c], "a")` (legitimate: `not` prefixing a real function call) and
# `[c] not in (1, 2)` (a genuine, still-unsupported infix `NOT IN`) are
# lexically identical right at the `in(` token, and only resolvable by
# looking through the `not` to what's underneath it. So trailing `not`s are
# stripped and the position underneath is re-checked (iteratively — the
# `loop do` below walks back through as many chained `not`s as are present,
# so `not not In(...)` still resolves correctly) rather than treating `not`
# itself as a free pass.
def raw_infix_in_position?(prefix)
  s = prefix.rstrip
  loop do
    return false if s.empty? # formula start → function-name position
    return false if s =~ /(?:\(|,|>=|<=|!=|<>|[=<>]|\b(?:and|or)\b)\z/i # function-name position

    stripped = s.sub(/\bnot\z/i, '')
    return true if stripped == s # a real value sits directly before IN/In → infix

    s = stripped.rstrip # strip one trailing "not" and re-check what's under it
  end
end

# True if `f` contains at least one genuine infix `IN(`/`in(` occurrence
# (checked per-occurrence via raw_infix_in_position?, not a single formula-wide
# substring test — a formula can legitimately mix a real In(...) call with
# other text elsewhere).
def contains_raw_infix_in?(f)
  f.to_s.enum_for(:scan, /\bIN\s*\(/i).each do
    m = Regexp.last_match
    return true if raw_infix_in_position?(f[0...m.begin(0)])
  end
  false
end

# Strip out quoted string literals and [Column Name] references so a
# residual-SQL-keyword scan never mistakes the CONTENTS of a string or an
# identifier for the keyword itself (e.g. a pattern literal "united states"
# or a column named [Like Button Clicks]). Same masking the vendored
# converter's own hasResidualInfixOperator/hasResidualCaseKeyword do
# (converter/sql.mjs) — reproduced independently here because lint_formula
# runs on the FINAL sigmaFormula, downstream of that converter, not on its
# internals.
def mask_strings_and_brackets(f)
  f.to_s.gsub(/"(?:[^"\\]|\\.)*"|'(?:[^'\\]|\\.)*'|\[[^\]]*\]/, ' ')
end

# Lint a translated Sigma formula for the traps that ship silently-broken output.
# Returns [errors, warnings].
def lint_formula(sigma, klass = nil)
  errors = []
  warnings = []
  f = sigma.to_s

  # A raw SQL infix `x IN (a, b)` survived translation → Sigma has no infix
  # IN/IsIn operator; it silently blanks the column. Sigma's own `In(...)`
  # FUNCTION form (e.g. `In([Region], "East", "West")`) is real, documented
  # syntax and must NOT be flagged — see contains_raw_infix_in? /
  # raw_infix_in_position? above for the shape this distinguishes on.
  #
  # (No separate `Contains(` guard here anymore — it used to blanket-suppress
  # this whole check whenever a formula contained an unrelated Contains(...)
  # call ANYWHERE, e.g. from a translated LIKE clause, which could mask a
  # genuine infix-IN bug coexisting in the same formula. `\bIN\s*\(/i` never
  # actually matches inside the word "Contains(" in the first place — \b
  # requires "in" to start a fresh token, and "Contains(" doesn't create that
  # boundary — so the guard was never protecting against a real false
  # positive; it only ever introduced that false-negative loophole. The
  # per-occurrence, shape-based check above already excludes legitimate
  # Contains(...)/In(...) calls on its own, so the guard is both redundant
  # and actively wrong to keep.)
  if contains_raw_infix_in?(f)
    errors << "Contains a raw SQL infix IN (...) — Sigma has no infix IN/IsIn operator; expand to an OR-chain ([c]=a or [c]=b), or rewrite as Sigma's own In([c], a, b) function, or it silently blanks the column (feedback_sigma_formula_isin)."
  end

  # A raw SQL infix `x LIKE 'pattern'` (or `NOT LIKE`) survived translation —
  # Sigma has no LIKE operator at all (unlike IN, there is no Sigma FUNCTION
  # form named Like(...) to also rule out — LIKE is always a bare infix SQL
  # keyword), and it will fail to evaluate rather than silently blank. Checked
  # as a WHOLE-WORD match on the formula with quoted strings and [bracketed]
  # identifiers masked out first (mask_strings_and_brackets, above) — not a
  # bare substring test. A bare /like/i substring test is exactly the
  # false-positive class this file has already been burned by twice on the
  # IN( rule above (see raw_infix_in_position?'s and the removed Contains(
  # guard's history comments): it would misfire on a pattern literal that
  # itself contains the word ("...LIKE 'i like turtles'" — masked away here)
  # or a column reference that happens to contain "Like" as a standalone word
  # ([Like Button Clicks] — also masked away), even though Sigma has entirely
  # legitimate string functions (Contains/StartsWith/EndsWith) that a LIKE
  # clause should have been translated to instead.
  #
  # WARNING, not error (2026-08-05 batch-verify blocker 1): a raw infix IN(
  # above is a hard error because Sigma silently BLANKS the column — the
  # wrong-but-quiet failure mode this file's error tier exists to catch
  # loudly before it ships. A residual LIKE is a DIFFERENT failure shape: it
  # fails to evaluate (loud, visible in Sigma's own UI), and it is exactly
  # the shape `--convert` already flags via `converted:false` (see
  # resolve_entry) — a Beast Mode has never had a "missing" tier separate
  # from converted:false to route this through cleanly. Making it a hard
  # lintError with no override path meant this check aborted the very cold
  # run it was added to protect (migrate-domo.rb's convert-beast-modes phase
  # treats any --lint exit 1 as fatal, with no waiver — measured on the real
  # "Non-US Leads" Beast Mode). A warning still lands in the emitted entry's
  # `lintWarnings` (formulas.json) AND gets a loud stderr summary at --lint
  # time (see the CLI section below) — never silenced — but does not abort
  # the run; discovery/formula-overrides.json remains the fix path for the
  # underlying formula.
  if mask_strings_and_brackets(f) =~ /\bLIKE\b/i
    warnings << "Contains a raw SQL infix LIKE '...' — Sigma has no LIKE operator; rewrite using Contains([col], \"pattern\"), StartsWith([col], \"pattern\"), or EndsWith([col], \"pattern\"), or it will fail to evaluate. Non-fatal (see discovery/formula-overrides.json), but review before shipping."
  end

  # And()/Or()/Not() as FUNCTION CALLS silently produce null rows — must be infix.
  if f =~ /\b(And|Or)\s*\(/i
    warnings << 'Uses And()/Or() as a function call — Sigma wants infix `and`/`or`; the function form can null rows (formulas.md).'
  end
  warnings << 'Uses Not() as a function call — verify; infix negation is safer.' if f =~ /\bNot\s*\(/i

  # Window functions present — remind of the workbook-master limitation.
  if f =~ /\b(Rank|SumOver|CountOver|CumulativeSum|CumulativeCount|MovingAvg)\s*\(/i
    warnings << 'Window function present — silently errors in workbook-master/DM calc cols (feedback_sigma_window_functions).'
  end

  # Balanced brackets/parens sanity (a common cause of "IF chokes").
  errors << 'Unbalanced parentheses.' if f.count('(') != f.count(')')
  errors << 'Unbalanced [ ] brackets.' if f.count('[') != f.count(']')

  [errors, warnings]
end

# Look up an operator-authored override for one pending entry. Keyed by the
# Beast Mode's stable `id` (calculation_<uuid>) first, falling back to the
# human-friendly `name` — ids are opaque, so name is an accepted alternate
# key. Returns the override Hash or nil.
def find_override(entry, overrides)
  ov = overrides[entry['id']] || overrides[entry['name']]
  ov.is_a?(Hash) ? ov : nil
end

# Resolve one discovery/formulas.pending.json entry against the operator
# sidecar, then apply the same POST-lint every entry gets. Returns
# [resolved_entry_or_nil, warnings]. resolved_entry is nil when there is still
# no sigmaFormula (no override applied) — the caller drops it, exactly
# today's honest-drop behaviour (refs/live-validation-2026-07-30.md).
#
# An override SUPPLIES a sigmaFormula that is missing, OR SUPERSEDES one
# --convert already filled in but flagged converted:false (still-broken
# machine output) — widened 2026-08-03 because --convert's
# lookConvertExpression fallback is total (always produces SOME sigmaFormula,
# even a bad one), so "missing" alone had become nearly unreachable in the
# orchestrated pipeline (there is no interposition point to hand-clear a
# sigmaFormula between --convert and --lint in the automated flow). It never
# silently clobbers a formula that converted CLEANLY — converted:true, or a
# legacy entry with no `converted` key at all (entry['converted'] != false is
# true for nil, so already_resolved's truth value is unchanged for those) — a
# no-op override there is still warned, not applied.
def resolve_entry(entry, overrides)
  warnings = []
  sigma = entry['sigmaFormula']
  already_resolved = !(sigma.nil? || sigma.to_s.strip.empty?) && entry['converted'] != false
  override = find_override(entry, overrides)
  used_override = false
  lod_plan = entry['class'].to_s == 'lod' ?
    DomoSigma::BeastModeLod.fixed_percent_of_total_plan(entry['originalSql']) : nil
  fixed_aggregate_plan = entry['class'].to_s == 'lod' ?
    DomoSigma::BeastModeLod.fixed_aggregate_plan(entry['originalSql']) : nil
  used_lod_synthesis = false
  semantic = DomoSigma::BeastModeSemantics.translate(entry, sigma)
  used_semantic_synthesis = false
  semantic_block_reason = nil
  semantic_placement = nil

  if override && !override['sigmaFormula'].to_s.strip.empty?
    if already_resolved && entry['class'].to_s != 'lod'
      warnings << "formula-overrides.json has an entry for " \
        "#{entry['name'] || entry['id']} but it already has a sigmaFormula that " \
        "converted cleanly (converted:true) — override NOT applied (an override " \
        "only supersedes a missing or converted:false result)."
    else
      sigma = override['sigmaFormula']
      used_override = true
    end
  elsif lod_plan
    sigma = DomoSigma::BeastModeLod.fixed_percent_formula(lod_plan)
    used_lod_synthesis = true
  elsif fixed_aggregate_plan
    sigma = DomoSigma::BeastModeLod.fixed_aggregate_placeholder(fixed_aggregate_plan)
    lod_plan = fixed_aggregate_plan
    used_lod_synthesis = true
  elsif semantic && semantic['status'] == 'translated'
    sigma = semantic['formula']
    semantic_placement = semantic['placement']
    used_semantic_synthesis = true
  elsif semantic && semantic['status'] == 'blocked'
    semantic_block_reason = semantic['reason']
  end

  return [nil, warnings] if sigma.nil? || sigma.to_s.strip.empty?

  errs, lint_warns = lint_formula(sigma, entry['class'])
  resolved = entry.merge('sigmaFormula' => sigma, 'lintErrors' => errs, 'lintWarnings' => lint_warns)
  if used_override
    resolved['_source'] = 'formula-override'
    resolved['lodPlacement'] = { 'kind' => 'operator-workbook-formula' } if entry['class'].to_s == 'lod'
    # Human-authored, trusted — clear any stale automated converted:false +
    # its "could not fully translate" note (which would otherwise describe
    # formula content no longer even present in sigmaFormula) before applying
    # the override's own note, if any.
    resolved['converted'] = true
    resolved.delete('note')
    resolved['note'] = override['note'] if override['note']
    warnings << "#{entry['name'] || entry['id']}: sigmaFormula supplied by " \
      "discovery/formula-overrides.json (hand-authored) — automated conversion " \
      "did not produce a fully reliable formula for this Beast Mode (missing, or " \
      "flagged converted:false); verify by hand. CASE WHEN / COUNT(DISTINCT) / " \
      "double-bracketed ALL-CAPS refs are fixed (sigma-data-model-mcp PR #115, " \
      "#116) so this is NOT that historical 74%-fail case — check " \
      "refs/live-validation-2026-07-30.md and this script's still-open gaps " \
      "(WEEKDAY day-numbering mismatch [override: Mod(Weekday([col])+5,7)], " \
      "CEILING/FLOOR aggregates, untranslatable infix LIKE) for what actually " \
      "still needs a hand-authored formula."
  elsif used_lod_synthesis
    resolved['_source'] = 'domo-lod-synthesis'
    resolved['lodPlacement'] = lod_plan
    resolved['converted'] = true
    resolved.delete('note')
    resolved['note'] = 'Domo COUNT-or-SUM / FIXED-percent denominator synthesized as a workbook PercentOfTotal formula; final scope is selected from the card visual roles.'
    warnings << "#{entry['name'] || entry['id']}: recognized Domo fixed-percent-of-total LOD; " \
                'the workbook builder will select color/x-axis/grand-total scope from the card bindings.'
  elsif used_semantic_synthesis
    resolved['_source'] = 'domo-semantic-synthesis'
    resolved['semanticPlacement'] = semantic_placement if semantic_placement
    resolved['converted'] = true
    resolved.delete('note')
    resolved['note'] = 'Domo-specific semantic rewrite applied after generic SQL conversion.'
    warnings << "#{entry['name'] || entry['id']}: applied a Domo-specific semantic rewrite."
  elsif semantic_block_reason
    resolved['_source'] = 'domo-semantic-block'
    resolved['converted'] = false
    resolved['note'] = semantic_block_reason
    warnings << "#{entry['name'] || entry['id']}: blocked from automatic placement — #{semantic_block_reason}."
  elsif entry['converted'] == false
    # Track E: --convert already computed a REAL converted flag (via the
    # vendored hasResidualCaseKeyword/hasResidualInfixOperator) — surface it
    # loudly here rather than letting a "flagged unreliable but still has SOME
    # string in sigmaFormula" entry ride through --lint silently. No override
    # was applied above (none exists for this id/name, or its sigmaFormula is
    # blank) — per the widened eligibility rule, a discovery/formula-
    # overrides.json entry for this id/name WOULD supersede this
    # converted:false result, so suggest adding one.
    warnings << "#{entry['name'] || entry['id']}: automated conversion flagged this formula as " \
      "converted:false (still contains raw CASE/WHEN/THEN or an infix LIKE/BETWEEN Sigma has no " \
      "equivalent for) — review before shipping; a discovery/formula-overrides.json entry WILL " \
      "supersede this converted:false result."
  end
  [resolved, warnings]
end

# Override keys (id or name) that matched NO pending entry at all. A typo'd
# id/name in formula-overrides.json must not silently do nothing.
def unmatched_override_keys(pending, overrides)
  known = pending.flat_map { |e| [e['id'], e['name']] }.compact
  overrides.keys.reject { |k| known.include?(k) }
end

run_main = ($PROGRAM_NAME == __FILE__)
if run_main
opts = {}
OptionParser.new do |o|
  o.on('--lint') { opts[:lint] = true }
  o.on('--convert') { opts[:convert] = true }
  o.on('--in PATH')  { |v| opts[:in] = v }
  o.on('--out PATH') { |v| opts[:out] = v }
  o.on('--overrides PATH') { |v| opts[:overrides] = v }
  # Track E 3-tier resolution: --mcp-dir/DOMO_MCP_DIR (tier 2, explicit dev
  # opt-in) and --converter-out (tier 3 resume — an agent-produced JSON array
  # of [{id, sigmaFormula, converted, warnings, note?}] filled by hand via the
  # manual convert_sql_to_sigma_formula MCP call the exit-10 path prints).
  o.on('--mcp-dir DIR') { |v| opts[:mcp_dir] = File.expand_path(v) }
  o.on('--converter-out PATH') { |v| opts[:converter_out] = v }
end.parse!(ARGV)

if opts[:convert]
  # ---- Track E: run the SQL-formula converter over the whole pending file,
  # one node invocation, no agent/MCP call in the loop ----------------------
  path = opts[:in] || File.join(OUT, 'formulas.pending.json')
  pending = JSON.parse(File.read(path))

  if opts[:converter_out]
    # Tier 3 resume: an agent already ran convert_sql_to_sigma_formula by hand
    # per the exit-10 instructions below and saved [{id, sigmaFormula,
    # converted, warnings, note?}] to this file. Merge by id; never clobber
    # fields this tier doesn't supply.
    filled = JSON.parse(File.read(opts[:converter_out]))
    by_id = {}
    filled.each { |e| by_id[e['id']] = e }
    applied_ids = []
    pending.each do |e|
      src = by_id[e['id']]
      next unless src
      applied_ids << e['id']
      e['sigmaFormula'] = src['sigmaFormula']
      e['converted']    = src['converted']
      e['warnings']     = src['warnings']
      # Always overwrite — nil when src has no note — so a formula that is
      # NOW cleanly converted never carries forward a stale "could not fully
      # translate" note from a prior run's pending entry.
      e['note']         = src['note']
    end
    unmatched_ids = by_id.keys - applied_ids
    unmatched_ids.each do |id|
      warn "  ⚠ --converter-out id '#{id}' matches no Beast Mode in #{path} — typo'd id? (ignored)"
    end
    out = opts[:out] || path
    File.write(out, JSON.pretty_generate(pending))
    warn "  filled #{applied_ids.size}/#{filled.size} formula(s) from --converter-out " \
         "#{opts[:converter_out]}#{unmatched_ids.empty? ? '' : " (#{unmatched_ids.size} unmatched — see warnings above)"}"
    exit 0
  end

  conv, _dev_dir, desc = resolve_sql_converter(opts[:mcp_dir] || ENV['DOMO_MCP_DIR'], VENDORED_SQL)
  # resolve_sql_converter only checks FILE EXISTENCE of the bundle/dev build —
  # it never confirms `node` itself is invokable. A resolved `conv` with no
  # `node` on PATH (e.g. this script run directly, bypassing doctor.sh's usual
  # node-prerequisite gate) must NOT fall through to the raw Open3::ENOENT
  # crash below; it gets the same clean instructional exit-10 as a missing
  # bundle.
  node_available = conv && begin
    _o, _e, st = Open3.capture3('node', '--version')
    st.success?
  rescue Errno::ENOENT
    false
  end
  if conv.nil? || !node_available
    if conv.nil?
      warn '  vendored converter (converter/sql.mjs) missing and no local sigma-data-model-mcp ' \
           'build (--mcp-dir / DOMO_MCP_DIR).'
    else
      warn "  converter: #{desc}"
      warn '  but `node` is not on PATH — required to run it locally (doctor.sh normally gates on this).'
    end
    warn ''
    warn '  >>> GATE: for EACH entry in discovery/formulas.pending.json, call'
    warn '      convert_sql_to_sigma_formula(sql: normalizedSql), collect the result as'
    warn '      {id, sigmaFormula, converted, warnings, note?}, write the whole array to a'
    warn '      JSON file, then re-run:'
    warn '        ruby scripts/convert-beast-modes.rb --convert --converter-out <that file>'
    warn '      No formulas were translated.'
    exit 10
  end
  warn "  converter: #{desc}"

  import_specifier =
    (Gem.win_platform? && conv.to_s.match?(/\A[A-Za-z]:/)) ? 'file:///' + conv.gsub('\\', '/') : conv

  Dir.mktmpdir('domo-convert') do |dir|
    in_path  = File.join(dir, 'pending.json')
    res_path = File.join(dir, 'results.json')
    File.write(in_path, JSON.generate(pending))

    runner = File.join(dir, 'run.mjs')
    File.write(runner, <<~JS)
      import { readFileSync, writeFileSync } from 'node:fs';
      import { lookSqlToSigmaRules, lookConvertExpression, hasResidualCaseKeyword, hasResidualInfixOperator, lookUnknownFunctions } from #{import_specifier.to_json};
      const pending = JSON.parse(readFileSync(#{in_path.to_json}, 'utf8'));
      // Same per-formula orchestration as sigma-data-model-mcp's src/tools.ts
      // convert_sql_to_sigma_formula tool handler — try the rule engine first,
      // fall back to the total mechanical converter, then check for residual
      // untranslated SQL syntax the same way the live tool already does.
      const NOTE = 'Could not fully translate — output still contains raw SQL syntax Sigma has no equivalent for (CASE/WHEN/THEN, or an infix LIKE/BETWEEN), do not use as-is';
      const out = pending.map((entry) => {
        const sql = entry.normalizedSql;
        const warnings = lookUnknownFunctions(sql).map(fn => `${fn}() has no Sigma mapping — emitted as-is; verify it exists in Sigma.`);
        let sigmaFormula = lookSqlToSigmaRules(sql);
        if (sigmaFormula == null) sigmaFormula = lookConvertExpression(sql);
        const converted = !hasResidualCaseKeyword(sigmaFormula) && !hasResidualInfixOperator(sigmaFormula);
        const result = { ...entry, sigmaFormula, converted, warnings };
        // entry may carry a stale `note` from a prior run (e.g. re-running
        // --convert after the bundle improves, or after a hand-edit to
        // normalizedSql) — never let it survive onto a now-clean result.
        if (!converted) { result.note = NOTE; } else { delete result.note; }
        return result;
      });
      writeFileSync(#{res_path.to_json}, JSON.stringify(out));
    JS

    _stdout, stderr, status = Open3.capture3('node', runner)
    abort "FATAL: converter failed:\n#{stderr}" unless status.success?
    pending = JSON.parse(File.read(res_path))
  end

  out = opts[:out] || path
  File.write(out, JSON.pretty_generate(pending))
  unreliable = pending.count { |e| e['converted'] == false }
  if unreliable.positive?
    warn "  wrote #{out} (#{pending.size} formulas; #{unreliable} flagged converted:false — review before --lint)"
  else
    warn "  wrote #{out} (#{pending.size} formulas — no residual CASE/infix syntax detected in any of " \
         "them; not a full validity guarantee)"
  end
elsif opts[:lint]
  # ---- Validate a filled pending file → formulas.json --------------------
  path = opts[:in] || File.join(OUT, 'formulas.pending.json')
  pending = JSON.parse(File.read(path))
  # Operator sidecar (see header) — read-only, never written by this script.
  overrides_path = opts[:overrides] || File.join(OUT, 'formula-overrides.json')
  overrides = (JSON.parse(File.read(overrides_path)) rescue {}) || {}

  final = []
  unresolved = []
  pending.each do |e|
    resolved, warnings = resolve_entry(e, overrides)
    warnings.each { |w| warn "  ⚠ #{w}" }
    if resolved
      final << resolved
    else
      unresolved << (e['name'] || e['id'])
    end
  end

  unmatched_override_keys(pending, overrides).each do |k|
    warn "  ⚠ discovery/formula-overrides.json key '#{k}' matches no Beast Mode " \
      "id or name in #{path} — typo'd id/name? (ignored)"
  end

  out = opts[:out] || File.join(OUT, 'formulas.json')
  File.write(out, JSON.pretty_generate(final))
  pending_meta = File.join(File.dirname(path), 'formulas.pending.meta.json')
  meta = JSON.parse(File.read(pending_meta)) rescue {}
  File.write(File.join(File.dirname(out), 'formulas.meta.json'), JSON.pretty_generate(
    meta.merge('formulasCount' => final.size, 'writtenAt' => Time.now.utc.iso8601)
  ))
  warn "  wrote #{out} (#{final.size} formulas)"
  bad = final.select { |e| !e['lintErrors'].empty? }
  unless bad.empty?
    warn "\n  ⚠ #{bad.size} formula(s) have lint ERRORS — fix before building:"
    bad.each { |e| warn "    - #{e['name'] || e['id']}: #{e['lintErrors'].join('; ')}" }
  end
  # Blocker 1 (2026-08-05 batch-verify): lint_formula's per-entry `lintWarnings`
  # (e.g. residual infix LIKE, And()/Or()/Not() function-call form, window
  # functions) already ride along in formulas.json, but until now nothing
  # printed a loud stderr summary of them the way the ERRORS block above
  # does — a real finding (residual LIKE) could sit in the artifact
  # unnoticed. Non-fatal (does not affect the exit code below), but never
  # silent.
  cautioned = final.select { |e| !Array(e['lintWarnings']).empty? }
  unless cautioned.empty?
    warn "\n  ⚠ #{cautioned.size} formula(s) have lint WARNINGS — non-fatal, review before shipping:"
    cautioned.each { |e| warn "    - #{e['name'] || e['id']}: #{Array(e['lintWarnings']).join('; ')}" }
  end
  unless unresolved.empty?
    warn "\n  ⚠ #{unresolved.size} Beast Mode(s) still lack a sigmaFormula: #{unresolved.join(', ')}"
  end
  exit(bad.empty? ? 0 : 1)
else
  # ---- Normalize discovery/beast-modes.json → formulas.pending.json ------
  path = opts[:in] || File.join(OUT, 'beast-modes.json')
  beast = JSON.parse(File.read(path))
  pending = beast.map do |b|
    sql = b['sql'] || b['formula'] || b['expression']
    klass = effective_formula_class(sql, b['class'])
    norm, warns = normalize_bm(sql, klass)
    provenance = b.select { |key, _| PROVENANCE_KEYS.include?(key) }
    {
      'id'           => b['id'],
      'name'         => b['name'],
      'scope'        => b['scope'],
      'class'        => klass,
      'originalSql'  => sql,
      'normalizedSql'=> norm,
      'preWarnings'  => warns,
      'needsReview'  => NEEDS_REVIEW.include?(klass) || warns.any? { |w| w.include?('AGGREGATE') },
      'sigmaFormula' => nil,   # ← filled by convert_sql_to_sigma_formula in Phase 2
    }.merge(provenance)
  end
  out = opts[:out] || File.join(OUT, 'formulas.pending.json')
  require 'fileutils'; FileUtils.mkdir_p(OUT)
  File.write(out, JSON.pretty_generate(pending))
  File.write(File.join(File.dirname(out), 'formulas.pending.meta.json'), JSON.pretty_generate(
    'source' => File.expand_path(path),
    'sourceSha256' => formula_source_fingerprint(path),
    'sourceCount' => beast.size,
    'writtenAt' => Time.now.utc.iso8601
  ))
  warn "  wrote #{out} (#{pending.size} Beast Modes to translate)"
  warn "\n  Next (Phase 2): ruby scripts/convert-beast-modes.rb --convert   # local node, no MCP call"
  warn "  then:            ruby scripts/convert-beast-modes.rb --lint"
end
end
