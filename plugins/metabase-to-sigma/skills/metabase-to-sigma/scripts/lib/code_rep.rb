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
    # `elements`, `overlays`, and `panels` are workbook-document collections,
    # alongside page metadata and the required layout. `settings`
    # (theme/navigation) and `agents` belong here too. Omitting any of these
    # sweeps them onto the metadata envelope, where they are invalid and are
    # silently dropped on write.
    DOC_KEYS = %w[
      schemaVersion pages elements overlays panels kind layout settings agents
    ].freeze

    # REMOVED from the API. The workbook theme is now `settings.theme.name` and
    # `settings.theme.overrides` (published OpenAPI: createWorkbookSpec — there
    # are zero occurrences of themeName/themeOverrides in it). The individual
    # override keys are unchanged (categoricalScheme, colorOverrides, hasCards,
    # borderRadius, elementBorder, titleFont, tableStyles, …) — only the
    # container path moved. document() folds the legacy pair forward so specs
    # and fixtures written before the move still produce a valid body.
    LEGACY_THEME_KEYS = %w[themeName themeOverrides].freeze

    class << self
      # Read path: accepts the live nested shape OR a legacy flat artifact.
      def document(response)
        return {} unless response.is_a?(Hash)
        inner = response['document']
        doc = inner.is_a?(Hash) ? inner : response.select { |k, _| DOC_KEYS.include?(k) }
        fold_legacy_theme(doc, response)
      end

      def metadata(response)
        return {} unless response.is_a?(Hash)
        response.reject do |k, _|
          k == 'document' || DOC_KEYS.include?(k) || LEGACY_THEME_KEYS.include?(k)
        end
      end

      # Emitter helper — set the workbook theme on a document hash in the CURRENT
      # shape. Builders should call this instead of assigning the removed
      # themeName/themeOverrides pair. Returns the same hash for chaining.
      def set_theme(doc, name: nil, overrides: nil)
        return doc unless name || (overrides.is_a?(Hash) && !overrides.empty?)
        settings = (doc['settings'] ||= {})
        theme    = (settings['theme'] ||= {})
        theme['name'] = name if name
        if overrides.is_a?(Hash) && !overrides.empty?
          theme['overrides'] = (theme['overrides'] || {}).merge(overrides)
        end
        doc
      end

      # Read the theme back out of either shape (nested settings.theme, or a
      # legacy flat themeName/themeOverrides artifact). Returns {name:, overrides:}.
      def theme(spec)
        d = document(spec)
        t = d.dig('settings', 'theme') || {}
        { 'name' => t['name'], 'overrides' => t['overrides'] || {} }
      end

      # Write path: every live workbook code-rep endpoint requires the wrapper
      # and flat document.elements. Flatten legacy page-nested artifacts and
      # canonicalize legacy layout tags at this boundary so older converter
      # output remains postable during migration; emitters always send the
      # live-verified <Element>/<Container> vocabulary.
      def wrap(document_hash, extra: {})
        extra.merge('document' => canonicalize_document(flatten_elements(document_hash)))
      end

      # Read compatibility for pre-2026-08-08 artifacts. LayoutElement and
      # GridContainer are rejected by the live workbook verify endpoint, so
      # they must never cross an emission boundary unchanged.
      def canonicalize_layout(layout_xml)
        layout_xml.to_s
                  .gsub(%r{<(/?)LayoutElement\b}, '<\1Element')
                  .gsub(%r{<(/?)GridContainer\b}, '<\1Container')
      end

      # WORKBOOK-ONLY shape helpers. Workbook elements are a flat document
      # collection; pages contain metadata only. Page membership is encoded by
      # the required layout's <Page> blocks. Keep these helpers in CodeRep so
      # callers cannot accidentally apply this shape to data-model specs, whose
      # pages[*].elements nesting is unchanged.
      def workbook_elements(spec)
        doc = document(spec)
        els = doc['elements']
        return els.select { |el| el.is_a?(Hash) } if els.is_a?(Array)

        # Transitional read compatibility for saved pre-release workbook
        # artifacts. Current API payloads must still emit flat elements (wrap
        # enforces that); this fallback only prevents readers from silently
        # dropping elements while old local readbacks are being replaced.
        Array(doc['pages']).flat_map do |page|
          page.is_a?(Hash) ? Array(page['elements']).select { |el| el.is_a?(Hash) } : []
        end
      end

      # { page_id => [element_id, ...] }, in layout order.
      def workbook_page_element_ids(spec)
        doc = document(spec)
        doc['layout'].to_s
                     .scan(%r{<Page\b[^>]*\bid="([^"]*)"[^>]*>(.*?)</Page>}m)
                     .each_with_object({}) do |(page_id, body), out|
          # Restrict ownership to actual layout nodes. A generic elementId
          # scan can accidentally claim ids from unrelated nested attributes.
          # Legacy aliases remain readable, but all writes canonicalize them.
          out[page_id] = body.scan(
            %r{<(?:Element|Container|TabbedContainer|LayoutElement|GridContainer)\b[^>]*\belementId="([^"]*)"}
          ).flatten.uniq
        end
      end

      # { element_id => page metadata hash }. Layout is authoritative; pages
      # that appear only in layout still receive a minimal {id,name} descriptor.
      def workbook_page_by_element(spec)
        doc = document(spec)
        pages = doc['pages'].is_a?(Array) ? doc['pages'].select { |pg| pg.is_a?(Hash) } : []
        pages_by_id = pages.each_with_object({}) { |pg, out| out[pg['id']] = pg if pg['id'] }
        workbook_page_element_ids(doc).each_with_object({}) do |(page_id, element_ids), out|
          page = pages_by_id[page_id] || { 'id' => page_id, 'name' => page_id }
          element_ids.each { |element_id| out[element_id] ||= page }
        end
      end

      # [[element, page_metadata_or_nil], ...] for flat workbook elements.
      def workbook_elements_with_pages(spec)
        page_by_element = workbook_page_by_element(spec)
        workbook_elements(spec).map do |el|
          [el, page_by_element[el['id'] || el['elementId']]]
        end
      end

      private

      def canonicalize_document(doc)
        return doc unless doc.is_a?(Hash) && doc.key?('layout')
        doc.merge('layout' => canonicalize_layout(doc['layout']))
      end

      # Emit only the current API shape. Elements are workbook-global in the
      # payload; layout XML retains their page placement. Existing flat
      # elements win ordering, while legacy page-nested elements are appended
      # once by id.
      def flatten_elements(doc)
        return doc unless doc.is_a?(Hash)
        pages = doc['pages']
        return doc unless pages.is_a?(Array)

        flattened_pages = []
        nested_elements = []
        pages.each do |page|
          page_copy = page.dup
          nested_elements.concat(Array(page_copy.delete('elements')))
          flattened_pages << page_copy
        end
        existing_elements = Array(doc['elements'])
        elements = []
        seen = {}
        (existing_elements + nested_elements).each do |element|
          key = element.is_a?(Hash) && element['id']
          next if key && seen[key]
          seen[key] = true if key
          elements << element
        end

        doc.merge('pages' => flattened_pages, 'elements' => elements)
      end

      # themeName/themeOverrides -> settings.theme.{name,overrides}. Non-mutating:
      # only builds a new hash when a legacy key is actually present, so the
      # common (already-correct) path returns the input untouched.
      def fold_legacy_theme(doc, source)
        name      = doc['themeName']      || source['themeName']
        overrides = doc['themeOverrides'] || source['themeOverrides']
        has_ov    = overrides.is_a?(Hash) && !overrides.empty?
        return doc unless name || has_ov || doc.key?('themeName') || doc.key?('themeOverrides')

        out      = doc.reject { |k, _| LEGACY_THEME_KEYS.include?(k) }
        settings = (out['settings'] || {}).dup
        theme    = (settings['theme'] || {}).dup
        theme['name'] ||= name if name
        theme['overrides'] = (theme['overrides'] || {}).merge(overrides) if has_ov
        return out if theme.empty?

        settings['theme'] = theme
        out['settings'] = settings
        out
      end
    end
  end
end
