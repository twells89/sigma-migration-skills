# frozen_string_literal: true
#
# anchor_values.rb — PURE canonicalization of printed dashboard values.
#
# WHY. Two field migrations shipped dashboards whose NUMBERS were wrong while
# every judgment gate recorded "pass": a ranked list showed different members
# with 10x-off values ("$1.2T" where the source printed "12,345B"), and panels
# collapsed to a fraction of the source's buckets. The fix is a MEASURED value
# bar: the agent transcribes the source's printed values EXACTLY as printed
# (Phase 1d, source-anchors.json), and verify-anchors.rb checks each printed
# value against the live workbook's element CSV exports. This module is the
# arithmetic core of that check: it parses a printed form ("12,345B", "$1.2T",
# "-2%", "(12.3%)", "$733,215.26", "12.3k") into a (value, precision) pair and
# decides whether a real number could have RENDERED as that printed form.
#
# MATCH RULE. A printed value MATCHES a real number when the real number rounds
# to the printed form at the printed precision — i.e. |actual - printed_value|
# <= half of the last printed digit's place value (scaled by any K/M/B/T
# suffix). "12,345B" therefore matches any real in [18,036.5B, 12,345.5B]
# (tolerance ±0.5e9), and 1.2e12 ("$1.2T") is a loud 10x MISS.
#
# CANDIDATE INTERPRETATIONS (all checked by match?):
#   - suffixed values ("12,345B") also match the UNSCALED face value (12345)
#     because some warehouses store the column already in that display unit;
#   - percents ("-2%") match both percent POINTS (-2) and the FRACTION (-0.02).
# Neither weakens the 10x/regrouping detection — the wrong values seen in the
# field match none of the interpretations.
#
# Pure, stdlib-only, no IO. Unit tests: scripts/test-anchor-values.rb.

module AnchorValues
  KINDS = %w[currency number percent].freeze

  SUFFIXES = {
    'k' => 1e3, 'm' => 1e6, 'b' => 1e9, 't' => 1e12
  }.freeze

  CURRENCY_SYMBOLS = %w[$ € £ ¥].freeze

  module_function

  # Parse a printed form into its PRIMARY canonical interpretation.
  # Returns { value: Float, tol: Float, kind: 'currency'|'number'|'percent',
  #           negative: Boolean } or nil when the string is not a printed number.
  # For percents the primary value is in percent POINTS ("-2%" → -2.0 ± 0.5);
  # candidates() adds the fraction form.
  def parse(raw)
    s = raw.to_s.strip
    return nil if s.empty?

    negative = false
    # Accounting-style parenthesized negative: "(12.3%)", "($4,120)".
    if s.start_with?('(') && s.end_with?(')')
      negative = true
      s = s[1..-2].to_s.strip
    end
    # Leading minus (ASCII or unicode), possibly before OR after a currency symbol.
    if s.start_with?('-', '−', '–')
      negative = true
      s = s[1..].to_s.strip
    end

    kind = 'number'
    if CURRENCY_SYMBOLS.include?(s[0])
      kind = 'currency'
      s = s[1..].to_s.strip
      if s.start_with?('-', '−', '–') # "$-12.4"
        negative = true
        s = s[1..].to_s.strip
      end
    end

    percent = false
    if s.end_with?('%')
      percent = true
      kind = 'percent'
      s = s[0..-2].to_s.strip
    end

    multiplier = 1.0
    if !percent && s =~ /\A(.*?)\s*([kKmMbBtT])\z/ && !Regexp.last_match(1).to_s.strip.empty?
      body = Regexp.last_match(1).strip
      suf  = Regexp.last_match(2).downcase
      multiplier = SUFFIXES[suf]
      s = body
    end

    digits = s.delete(',')
    return nil unless digits =~ /\A(?:\d+(?:\.\d+)?|\.\d+)\z/

    decimals = digits.include?('.') ? digits.split('.', 2)[1].length : 0
    face = Float(digits)
    step = 10.0**-decimals
    value = face * multiplier
    value = -value if negative
    { value: value, tol: (step / 2.0) * multiplier, kind: kind, negative: negative }
  end

  # All acceptable (value, tol) interpretations of a printed form, primary first.
  # Returns an Array of [value, tol] pairs, or [] when unparseable.
  def candidates(raw)
    p = parse(raw)
    return [] if p.nil?
    out = [[p[:value], p[:tol]]]
    if p[:kind] == 'percent'
      # Fraction form: exports often carry 0.02 where the dashboard prints "2%".
      out << [p[:value] / 100.0, p[:tol] / 100.0]
    else
      # Unscaled face value for suffixed forms ("12,345B" ↔ a column already
      # denominated in billions). Only differs when a suffix was present.
      pr = parse(strip_suffix(raw))
      out << [pr[:value], pr[:tol]] if pr && (pr[:value] - p[:value]).abs > Float::EPSILON
    end
    out
  end

  # Does a real number match the printed form? (See MATCH RULE above.)
  def match?(raw, actual)
    return false if actual.nil?
    a = begin
      Float(actual)
    rescue ArgumentError, TypeError
      return false
    end
    candidates(raw).any? do |value, tol|
      (a - value).abs <= tol + (1e-9 * [value.abs, 1.0].max)
    end
  end

  # The schema `kind` of a printed form ('currency'|'number'|'percent'), or nil.
  def kind(raw)
    p = parse(raw)
    p && p[:kind]
  end

  # Relative distance between a real number and the printed form's primary
  # value — used to rank "closest miss" candidates in reports. Float::INFINITY
  # when the form is unparseable.
  def relative_distance(raw, actual)
    p = parse(raw)
    return Float::INFINITY if p.nil? || actual.nil?
    a = begin
      Float(actual)
    rescue ArgumentError, TypeError
      return Float::INFINITY
    end
    # Best (smallest) distance across all interpretations, so a fraction-form
    # percent ranks as close as its points form.
    candidates(raw).map { |v, _| (a - v).abs / [v.abs, 1e-9].max }.min
  end

  # Remove a trailing K/M/B/T suffix (keeps sign/currency/percent decorations).
  def strip_suffix(raw)
    raw.to_s.sub(/\s*[kKmMbBtT](\)?)\z/, '\1')
  end
end
