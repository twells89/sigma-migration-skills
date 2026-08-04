# shared/lib/code_rep.rb
# Shape adapter for the Sigma WORKBOOK code representation
# (POST /v2/workbooks/spec, GET|PUT /v2/workbooks/{id}/spec, POST /v2/workbooks/spec/verify).
#
# Verified live 2026-08-03/04: this surface nests non-metadata fields under a top-level
# `document` key and REJECTS the old flat body with HTTP 400 — including on /verify.
# Sigma engineering confirmed 2026-08-03 that the DATA-MODEL code-rep surface is NOT
# changing, so this adapter is deliberately workbook-only and always writes the nested
# shape. Do NOT use it on /v2/dataModels/.../spec payloads — that API ignores `document`
# and will 400 on a missing top-level `schemaVersion`.
#
# Reads stay tolerant of the legacy flat shape because flat artifacts still exist on
# disk (committed workbook snapshots, fixtures) even though the API no longer returns them.
module Sigma
  module CodeRep
    # The non-metadata fields that live INSIDE `document`. Confirmed by live readback.
    DOC_KEYS = %w[schemaVersion pages kind layout].freeze

    class << self
      # Read path: accepts the live nested shape OR a legacy flat artifact.
      def document(response)
        return {} unless response.is_a?(Hash)
        inner = response['document']
        return inner if inner.is_a?(Hash)
        response.select { |k, _| DOC_KEYS.include?(k) }
      end

      def metadata(response)
        return {} unless response.is_a?(Hash)
        response.reject { |k, _| k == 'document' || DOC_KEYS.include?(k) }
      end

      # Write path: every live workbook code-rep endpoint requires the wrapper.
      def wrap(document_hash, extra: {})
        extra.merge('document' => document_hash)
      end
    end
  end
end
