# frozen_string_literal: true
#
# modeling_advisory.rb — shared, vendor-neutral runtime advisory.
#
# Prints a one-line MODELING ADVISORY when a converted Sigma data model reproduces
# multiple query-time joins, so the CDW join-cost tradeoff is visible at build time.
#
# It is INFORMATIONAL ONLY: it never gates, never blocks parity, and the converter
# never acts on it. The migration default stays faithful reproduction (parity is the
# gate); materialization / OBT is an opt-in the user chooses and re-verifies. Rationale
# and the measured star-vs-OBT numbers live in refs/modeling-strategy.md.
#
# Usage (from any converter orchestrator, once the DM's join/relationship count is known):
#   require_relative 'lib/modeling_advisory'
#   ModelingAdvisory.print_if_relevant(join_count)          # join_count = Integer
#
# The count is "joins this model can activate" — a relationship only bills a query-time
# join when a View element or lookup activates it, so the advisory says "can activate".

module ModelingAdvisory
  THRESHOLD = 2  # fire at >= 2 activatable joins; single-join models don't warrant the note
  REF = 'refs/modeling-strategy.md'

  # Returns true if the advisory was printed, false otherwise (so callers can log/track).
  def self.print_if_relevant(join_count, io: $stdout, ref: REF)
    n = join_count.to_i
    return false if n < THRESHOLD

    io.puts "   MODELING ADVISORY: this data model reproduces #{n} query-time join(s) it can activate."
    io.puts "   Sigma runs each join live in the warehouse per query. For HOT, join-heavy dashboards,"
    io.puts "   consider materializing a flat table (Sigma-native materialization, or an upstream OBT) —"
    io.puts "   OPTIONAL, changes grain (re-verify with the same parity oracle), and worth it only for"
    io.puts "   repeatedly-queried reports. Default here is faithful reproduction. See #{ref}."
    true
  end
end
