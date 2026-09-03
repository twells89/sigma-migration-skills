# frozen_string_literal: true
#
# ruby_compat.rb — makes the skills' documented Ruby 2.6 floor actually true.
#
# WHY THIS EXISTS. Every converter documents a 2.6 floor (macOS system Ruby) so
# an agent never has to install a runtime mid-migration — 30 comments across the
# tree say "not filter_map — that's Ruby 2.7+; the skills target 2.6". But 57
# call sites crept in anyway, and `ruby -c` cannot see them: a missing METHOD is
# a runtime NoMethodError, not a syntax error, and CI runs 3.x so it never hit
# one. doctor.sh compounded it by printing the Ruby version without asserting a
# floor, so 2.6.10 passed green while the code needed 2.7.
#
# The field failure mode is worse than a crash. Of 277 tableau test files under
# system 2.6: 7 died with a clean `undefined method 'filter_map'`, but 6 more
# reported a SEMANTIC failure instead — e.g. test-layout-px-rows.rb prints
# "per-dashboard derivation: Fixed=74, Auto=48 (got {})". A sub-script crashed,
# something rescued it, and the caller carried on with empty data. In a real
# migration that ships a silently degraded workbook rather than stopping.
#
# So: polyfill, don't rewrite 57 call sites. Agents keep working on stock macOS
# and new code keeps modern idioms. tools/lint-ruby-floor.rb enforces that any
# file using one of these methods actually requires this file.
#
# Additive and idempotent by construction: each polyfill is guarded by a
# respond_to?/method_defined? check, so on 2.7+ this file defines NOTHING and
# the real C implementations are used. Safe to require twice, and safe to
# require from a library (it never changes behaviour on a modern Ruby).
#
# Must itself stay 2.6-parseable: no endless method defs, no pattern matching.

# Enumerable#filter_map — Ruby 2.7.
#
# NOT `map { … }.compact`: filter_map drops every FALSEY result, so a block
# returning `false` is dropped too, while compact only removes nil. Using
# map+compact as the polyfill would keep `false` and silently change results for
# any predicate-shaped block. `select { |x| x }` reproduces the real semantics.
unless Enumerable.method_defined?(:filter_map)
  module Enumerable
    def filter_map
      return to_enum(:filter_map) unless block_given?
      out = []
      each { |item| (val = yield(item)) && out << val }
      out
    end
  end
end

# Enumerable#tally — Ruby 2.7. Counts occurrences into a Hash.
# (Hit live: an agent's migration crashed here inside the workbook validator.)
unless Enumerable.method_defined?(:tally)
  module Enumerable
    def tally
      each_with_object({}) { |item, acc| acc[item] = (acc[item] || 0) + 1 }
    end
  end
end

# Hash#except — Ruby 3.0. Not currently used in-tree; polyfilled because it is
# the next idiom likely to be reached for, and a NoMethodError mid-migration is
# expensive to diagnose.
unless Hash.method_defined?(:except)
  class Hash
    def except(*keys)
      reject { |k, _| keys.include?(k) }
    end
  end
end
