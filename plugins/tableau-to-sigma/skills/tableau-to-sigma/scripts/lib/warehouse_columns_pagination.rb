# frozen_string_literal: true
# Plugin-local (NOT shared/lib/sigma_rest.rb) exhaustive pagination for Sigma's
# warehouse-catalog `/v2/connections/tables/<inodeId>/columns` endpoint.
#
# LIVE-VERIFIED 2026-08 (logical-model-objectgraph live fixture build, a real
# 64-physical-column Snowflake fact table via the same live Sigma connection
# this repo's other live warehouse fixtures use): this endpoint's actual pagination
# cursor is `nextPageToken` in the response body / `pageToken` on the request
# query string — NOT the `nextPage`/`page` convention `Sigma.list_entries`
# (shared/lib/sigma_rest.rb) assumes. Calling `Sigma.list_entries` against this
# endpoint makes exactly ONE request: `nextPage` is never present in the
# response, so `list_entries`'s own termination check (`page = data['nextPage'];
# break if page.nil?`) fires immediately and it silently returns page 1 only
# (50 of 64 columns on the live fixture table) — the exact M1 regression this
# code exists to prevent, reproduced live against real warehouse metadata
# rather than a synthetic offline fixture. Confirmed against the live endpoint:
#
#   GET .../columns?limit=1000              -> 50 entries, nextPageToken: 50
#   GET .../columns?limit=1000&page=50      -> 50 entries AGAIN (page 1 — `page`
#                                               is silently ignored server-side)
#   GET .../columns?limit=1000&pageToken=50 -> 14 entries, nextPageToken: null
#
# 50 + 14 = 64, matching the live fact table's real physical column count.
#
# Kept plugin-local rather than patching the shared canonical
# (shared/lib/sigma_rest.rb, vendored byte-identical into 13 plugins per
# shared/manifest.json) because correcting a live-endpoint pagination
# contract needs its own dedicated cross-plugin verification pass — out of
# scope for this fixture task, and a PR touching a shared file cannot also
# carry plugin-scoped changes under this repo's "PR = 1 plugin OR shared"
# rule. See corpus/tableau/logical-model-objectgraph/MANIFEST.md's live
# validation section for the full repro and a pointer to the follow-up this
# implies for shared/lib/sigma_rest.rb + its other 12 consumers.
#
# Built on `Sigma.request` (shared/lib/sigma_rest.rb), not raw Net::HTTP, so
# every page GET still inherits the shared lib's 401-refresh-and-retry
# behavior and single auth path — only the pagination LOOP is reimplemented.
require_relative 'sigma_rest'

module WarehouseColumnsPagination
  # Exhaustively lists entries at `path` (a GET endpoint returning
  # { "entries": [...], "nextPage": ... } OR { "entries": [...], "nextPageToken": ... }).
  # The cursor convention is detected from whichever key the FIRST page's
  # response actually carries, then that same convention is used for every
  # subsequent page — so this is correct against either shape, not just the
  # one this endpoint happens to use today.
  #
  # An optional block receives each page's parsed body as it arrives (same
  # observability seam as Sigma.list_entries — callers use it to announce a
  # multi-page fetch on stderr without re-implementing the loop). A repeated
  # cursor or malformed page is fatal. Returning the entries accumulated so
  # far would recreate the exact silent-partial-catalog failure this helper
  # exists to prevent.
  def self.list(path, http: nil, limit: 1000)
    raise Sigma::Error, 'warehouse columns page limit must be positive' unless limit.to_i.positive?

    entries = []
    cursor = nil
    cursor_param = nil
    seen = {}
    pages = 0
    loop do
      qs = "limit=#{limit}"
      qs += "&#{cursor_param}=#{URI.encode_www_form_component(cursor.to_s)}" if cursor && cursor_param
      full_path = "#{path}#{path.include?('?') ? '&' : '?'}#{qs}"
      doc = Sigma.request(:get, full_path, http: http)
      unless doc.is_a?(Hash)
        raise Sigma::Error,
              "#{path}: columns endpoint returned #{doc.class}, expected a JSON object; " \
              'refusing a partial column list'
      end
      page_entries = doc['entries']
      unless page_entries.is_a?(Array) && page_entries.all? { |entry| entry.is_a?(Hash) }
        raise Sigma::Error,
              "#{path}: columns endpoint response has no valid entries array; " \
              'refusing a partial column list'
      end
      pages += 1
      yield doc if block_given?
      entries.concat(page_entries)

      next_cursor =
        if doc.key?('nextPageToken')
          cursor_param = 'pageToken'
          doc['nextPageToken']
        else
          cursor_param = 'page'
          doc['nextPage']
        end
      break if next_cursor.nil? || next_cursor.to_s.empty?
      if seen[next_cursor]
        cursor_label = cursor_param == 'page' ? 'nextPage token' : 'nextPageToken cursor'
        raise Sigma::Error,
              "#{path}: server repeated #{cursor_label} #{next_cursor.inspect} after " \
              "#{pages} page(s); refusing a partial column list"
      end

      seen[next_cursor] = true
      cursor = next_cursor
    end
    entries
  end
end
