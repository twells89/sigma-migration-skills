# frozen_string_literal: true
#
# cli_encoding.rb — G3: UTF-8 bootstrap for CLI entry points. NOT 2.6-only.
#
# Field failure, BOTH field-workbook runs (3 crashes total): under an unset/C
# locale Ruby tags ARGV strings ASCII-8BIT; the first em-dash ("—", \xE2…) in an
# agent-authored --notes/--name/--reason then blows up on the way into JSON —
# Encoding::UndefinedConversionError inside JSON.generate on 2.6
# (pick-destination.rb cmd_create, record-visual-check.rb), and
# `incompatible character encodings: UTF-8 and ASCII-8BIT` on 3.3 the moment the
# value is interpolated into a UTF-8 literal (audit-agg-semantics.rb, #752).
# Every supported Ruby is affected; only the exception class moved.
#
# Any script that round-trips agent-authored prose through JSON must
# `require_relative 'lib/cli_encoding'` before parsing options. Note that
# `File.read(path, encoding: 'UTF-8')` does NOT substitute for this — it fixes
# reads, not ARGV. Conversely this does not fix an inline `ruby -e` assertion
# whose SOURCE text holds a non-ASCII byte: -e script encoding comes from the
# locale, so only a UTF-8 LANG/LC_ALL fixes those (see corpus/run-corpus.sh).
# Ruby 3.0 FROZE ARGV's strings, so the original in-place force_encoding/scrub!
# raised `can't modify frozen String (FrozenError)` on exactly the input this
# guard exists to repair — i.e. the shim was silently broken on every Ruby >= 3.0,
# including the 3.3 that CI pins (found while fixing issue #752). The ARGV ARRAY
# is still mutable, so replace the element instead of mutating the string.
Encoding.default_external = Encoding::UTF_8
Encoding.default_internal = Encoding::UTF_8
ARGV.each_with_index do |a, i|
  next unless a.is_a?(String) && a.encoding == Encoding::ASCII_8BIT
  s = a.dup.force_encoding(Encoding::UTF_8)
  s.scrub!('') unless s.valid_encoding?
  ARGV[i] = s
end
