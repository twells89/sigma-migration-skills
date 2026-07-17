# Canonical Sigma formula function whitelist.
# Source: https://help.sigmacomputing.com (Function reference, categories below).
# Last refreshed: 2026-05-18.
#
# Use this list to validate that every function name appearing in a Sigma calc
# formula is a real Sigma function. Anything outside the list is either a
# Tableau-syntax leak (IIF / COUNTD / WINDOW_*), a non-existent helper an agent
# imagined (IsIn / ToText / DateParse — wait, DateParse IS real, see below), or
# a typo. The right fix is always:
#   - rewrite the formula using a function from this list, OR
#   - move the logic into a Custom SQL data-model element (kind: "sql") and
#     reference its columns as plain `[Custom SQL/COL]` refs

require 'set'

module SigmaFunctions
  CATEGORIES = {
    aggregate: %w[
      ArrayAgg ArrayAggDistinct Avg AvgIf Corr Count CountDistinct
      CountDistinctIf CountIf GrandTotal ListAgg ListAggDistinct Max MaxIf
      Median Min MinIf PercentileCont PercentileDisc PercentOfTotal
      RegressionIntercept RegressionR2 RegressionSlope StdDev Subtotal Sum
      SumIf SumProduct Variance VariancePop
    ],
    array: %w[
      Array ArrayCompact ArrayConcat ArrayContains ArrayDistinct ArrayExcept
      ArrayIntersection ArrayJoin ArrayLength ArraySlice RaggedHierarchy
      Sequence SplitToArray Sparkline SparklineAgg
    ],
    date: %w[
      ConvertTimezone DateAdd DateDiff DateFormat DateFromUnix DateFromUnixMs
      DateFromUnixUs DateLookback DatePart DateParse DateTrunc Day DayOfYear
      EndOfMonth Hour InDateRange InPriorDateRange LastDay MakeDate Minute
      Month MonthName Now Quarter Second Today Weekday WeekdayName Year
    ],
    financial: %w[CAGR Effect FV IPmt Nominal NPer Pmt PPmt PV XNPV],
    geography: %w[
      Area Centroid Distance Geography Intersects Json Latitude Longitude
      MakeLine MakePoint Perimeter Text Within
    ],
    logical: %w[Between Choose Coalesce If In IsNotNull IsNull Switch Zn NullIf],
    math: %w[
      Abs Acos Asin Atan Atan2 BinFixed BinRange BitAnd BitOr Ceiling Cos Cot
      Degrees DistanceGlobe DistancePlane Div Exp Floor Greatest GreatestNonNull
      Int IsEven IsOdd Least LeastNonNull Ln Log Mod MRound Pi Power Radians
      Round RoundDown RoundUp RowAvg Sign Sin Sqrt Tan Trunc
    ],
    text: %w[
      Concat Contains EndsWith Find ILike Left Len Like LPad Lower LTrim MD5
      Mid Proper RegexpCount RegexpExtract RegexpMatch RegexpReplace Repeat
      Replace Reverse Right RPad RTrim SHA256 SplitPart StartsWith Substring
      Trim Upper UrlPart
    ],
    type_conversion: %w[Date Json Logical Number Text Variant],
    window: %w[
      CumulativeAvg CumulativeCorr CumulativeCount CumeDist CumulativeMax
      CumulativeMin CumulativeStdDev CumulativeSum CumulativeVariance FillDown
      First FirstNonNull Lag Last LastNonNull Lead MovingAvg MovingCorr
      MovingCount MovingMax MovingMin MovingStdDev MovingSum MovingVariance
      Nth Ntile Rank RankDense RankPercentile RowNumber VisibilityLimit
    ],
    join: %w[Lookup Rollup],
    system: %w[
      CurrentTimezone CurrentUserAttributeText CurrentUserEmail
      CurrentUserFirstName CurrentUserFullName CurrentUserInTeam
    ],
    passthrough: %w[
      AggDatetime AggGeography AggLogical AggNumber AggText AggVariant
      CallDatetime CallGeography CallLogical CallNumber CallText CallVariant
    ]
  }.freeze

  ALL = CATEGORIES.values.flatten.freeze
  ALL_SET = ALL.to_set rescue Set.new(ALL)

  # Bug B (Tableau parity): bare Sigma boolean constants. Tableau calc fields use
  # TRUE/FALSE (and NULL) as boolean/null literals; these are literals, not
  # functions, and must never be treated as unknown identifiers by callers
  # scanning a formula.
  CONSTANTS = %w[True False TRUE FALSE Null null NULL].freeze
  CONSTANTS_SET = CONSTANTS.to_set rescue Set.new(CONSTANTS)

  def self.constant?(name)
    CONSTANTS_SET.include?(name)
  end

  def self.includes?(name)
    ALL_SET.include?(name)
  end

  # Returns the list of UNDOCUMENTED function names referenced in a formula.
  # Detection rule: identifier followed by `(` that isn't already a known Sigma
  # function. Identifiers are simple [A-Za-z_][A-Za-z0-9_]*.
  def self.unknown_functions(formula)
    return [] if formula.nil?
    # Strip string literals so SQL-ish content inside Custom SQL contexts doesn't
    # trigger false positives. Sigma calc formulas use "..." for strings.
    cleaned = formula.gsub(/"(?:\\.|[^"\\])*"/, '""')
    # Bug B (Tableau parity): strip [...]-bracketed column refs BEFORE the
    # function scan. A column name can contain "word(" — e.g.
    # [Order Fact View/Customer Id (CUSTOMER_DIM)] — and the bare
    # `\bword\s*\(` regex would otherwise flag "Id(" / "Name(" as an unknown
    # function and FATAL-abort. Bracketed refs are never function calls, so
    # remove them entirely first.
    cleaned = cleaned.gsub(/\[[^\]]*\]/, '')
    names = cleaned.scan(/\b([A-Za-z_][A-Za-z0-9_]*)\s*\(/).flatten.uniq
    # TRUE/FALSE/NULL are Tableau boolean/null literals, not user functions —
    # never report them as unknown (Bug B: they are valid constants).
    names.reject { |n| includes?(n) || constant?(n) }
  end

  # Known Tableau-syntax leak patterns. These DEFINITELY don't work in Sigma
  # and most of them resemble valid Sigma syntax just enough that a non-strict
  # whitelist might miss them. Flag with explicit translation hints.
  TABLEAU_LEAKS = {
    /\bIIF\s*\(/i        => 'IIF(c, t, e) → Sigma If(c, t, e)',
    /\bCOUNTD\s*\(/i     => 'COUNTD(x) → Sigma CountDistinct(x)',
    /\bIFNULL\s*\(/i     => 'IFNULL(x, y) → Sigma Coalesce(x, y)',
    /\bIS\s+NULL\b/i     => 'x IS NULL → Sigma IsNull(x)',
    /\bIS\s+NOT\s+NULL\b/i => 'x IS NOT NULL → Sigma IsNotNull(x)',
    # case-SENSITIVE: Tableau serializes DATEPART all-caps; the /i version
    # flagged Sigma's own correct DatePart("year", …) (round-5 field-caught —
    # a run translated via Year() just to dodge its own lint)
    /\bDATEPART\s*\(\s*['"]/ => 'DATEPART("part", date) → Sigma DatePart("part", date) — capitalization matters',
    /\bWINDOW_(SUM|AVG|MIN|MAX|COUNT|STDEV)\b(?!P)/i =>
      'WINDOW_*(agg, -n[, m]) → Sigma Moving*(agg, n[, m]); unbounded WINDOW_MAX/MIN/SUM → two-level grouped helper; agg/WINDOW_SUM(agg) → PercentOfTotal(agg, "grand_total") — all as CHART-element viz formulas on the yAxis (refs/window-functions.md), never DM calc columns',
    /\bWINDOW_(MEDIAN|PERCENTILE|CORR|COVARP?|VARP?|STDEVP)\b/i =>
      'WINDOW_MEDIAN/PERCENTILE/CORR/COVAR/VAR/STDEVP → no validated Sigma chart-formula mapping; Custom SQL element with OVER(...) or re-author',
    /\bRUNNING_(SUM|AVG|COUNT|MIN|MAX)\b/i =>
      'RUNNING_* → Sigma Cumulative* as a CHART-element viz formula on the yAxis (follows xAxis sort; auto-partitions by chart color) — never a DM calc column',
    /\bRANK_(DENSE|PERCENTILE)\b/i =>
      'RANK_DENSE/RANK_PERCENTILE → Sigma RankDense/RankPercentile(agg, "desc") as a chart viz formula (Tableau default direction = desc)',
    /\bRANK_(MODIFIED|UNIQUE)\b/i =>
      'RANK_MODIFIED/RANK_UNIQUE → no validated Sigma mapping; Custom SQL RANK()/ROW_NUMBER() OVER(...) or re-author',
    /\b\{\s*(FIXED|INCLUDE|EXCLUDE)\b/i =>
      'Tableau LOD → use Sigma window function family OR a Custom SQL data-model element',
    /\bIsIn\s*\(/        => 'IsIn() is not a Sigma function — use Sigma In(value, list...) OR an or chain',
    /\bToText\s*\(/      => 'ToText() is not a Sigma function — use Sigma Text(...) instead',
    /\bToString\s*\(/    => 'ToString() is not a Sigma function — use Sigma Text(...) instead',
    /\bToNumber\s*\(/    => 'ToNumber() is not a Sigma function — use Sigma Number(...) instead',
    # Field-caught (2 live runs): agent-authored/converter-missed date+text
    # function names that COMPILE-then-error on readback (type=error) and were
    # only WARNed before (dismissible) — one run waved off the CurrentDate warning
    # as a false "whitelist gap", cascading into 52 type=error columns. Promote
    # to hard leaks with the exact Sigma equivalent (also auto-rewritten by
    # FormulaNormalize::TABLEAU_RENAMES on the mechanical path).
    /\bSTR\s*\(/i          => 'STR(x) → Sigma Text(x)',
    /\bCURRENT_?DATE\s*\(/i => 'CurrentDate()/CURRENT_DATE() → Sigma Today() (or Now() for a timestamp)'
  }.freeze

  def self.tableau_leaks(formula)
    return [] if formula.nil?
    TABLEAU_LEAKS.each_with_object([]) do |(re, hint), acc|
      acc << hint if formula.match?(re)
    end
  end
end
