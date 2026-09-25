# frozen_string_literal: true
# element_export.rb — pull one Sigma workbook element's rendered rows as CSV.
#
# Lifted verbatim from verify-warehouse.rb's private element_csv, the live-proven
# path since 2026-07-30, because the parity oracle's Sigma-side collector
# (collect-parity-actuals.rb) needs exactly the same fetch.
#
# YES, THIS DUPLICATES verify-warehouse.rb, AND THAT IS DELIBERATE FOR NOW.
# The obviously-better move is to make verify-warehouse.rb delegate here so one
# copy of the retry/poll loop exists. That was implemented and its tests passed
# — and then reverted, because verify-warehouse.rb is a SHARED CANONICAL file
# (shared/scripts/verify-warehouse.rb, byte-identical across plugins, enforced
# by check-shared.rb on every commit). Deduping it means editing the canonical,
# re-running sync-shared.rb, and version-bumping every affected plugin — a
# fleet-wide change that must not ride a domo feature PR. Bead beads-sigma-2tkm
# reached the same conclusion for the same reason and was right to.
#
# So: this copy stays domo-local until a dedicated shared-file PR moves the
# helper to shared/lib/ and repoints both callers. Until then the two MUST be
# changed together — that is the cost being accepted here, recorded rather than
# left for someone to discover.
#
# The flow is Sigma's documented element export:
#   POST /v2/workbooks/{wb}/export   { elementId, format: { type: 'csv' } } -> queryId
#   GET  /v2/query/{queryId}/download  (text/csv, binary)
# The download 404s or returns empty while the query is still rendering, so both
# are treated as "keep polling" rather than as failures. Transient 429/408/50x
# are retried up to 4 times with exponential backoff + jitter.
#
# Returns [:ok, csv_string] or [:fail, reason_string] — never raises for an
# expected failure, so a caller can record a per-tile reason instead of dying
# on the first bad element.
require 'json'

module ElementExport
  module_function

  # fixture: optional Hash{elementId => csv_string} for offline tests.
  def fetch_csv(element_id, workbook_id, timeout: 120, fixture: nil)
    if fixture
      txt = fixture[element_id]
      return [:fail, 'no fixture row for element'] if txt.nil?
      return [:ok, txt]
    end
    attempts = 0
    begin
      attempts += 1
      r = Sigma.request(:post, "/v2/workbooks/#{workbook_id}/export",
                        body: JSON.generate({ elementId: element_id,
                                              format: { type: 'csv' } }))
      qid = r && r['queryId']
      return [:fail, "export POST returned no queryId: #{r.inspect[0, 120]}"] unless qid
      t0 = Time.now
      loop do
        return [:fail, "export poll timed out (#{timeout}s)"] if Time.now - t0 > timeout
        sleep 1.0
        begin
          b = Sigma.request(:get, "/v2/query/#{qid}/download", accept: 'text/csv', binary: true)
          return [:ok, b] if b && !b.to_s.empty?   # 204-empty = still rendering
        rescue Sigma::Error => e
          raise unless e.message.lines.first.to_s =~ /\b404\b/
        end
      end
    rescue Sigma::Error, Timeout::Error, Errno::ETIMEDOUT => e
      msg = e.message.lines.first.to_s
      if attempts < 4 && msg =~ /\b(429|408|50[234])\b|Too Many Requests|timed? ?out/i
        sleep((1.5 * (2**(attempts - 1))) + rand * 0.5)
        retry
      end
      [:fail, msg[0, 160]]
    end
  end
end
