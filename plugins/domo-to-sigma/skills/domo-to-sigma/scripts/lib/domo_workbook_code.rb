# frozen_string_literal: true

require_relative 'code_rep'

module DomoSigma
  module WorkbookCode
    module_function

    # Domo still has committed page-nested fixtures, while live and newly built
    # workbook specs use the released document envelope with flat elements.
    # Normalize both shapes for Domo-owned validation without changing shared
    # parity tooling.
    def normalized_document(spec)
      document = Sigma::CodeRep.document(spec)
      pages = Array(document['pages']).map { |page| page.reject { |key, _| key == 'elements' } }
      document.merge(
        'pages' => pages,
        'elements' => Sigma::CodeRep.workbook_elements(document).map(&:dup),
        'layout' => Sigma::CodeRep.canonicalize_layout(document['layout']),
      )
    end
  end
end
