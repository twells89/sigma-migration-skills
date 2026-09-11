require 'minitest/autorun'
require_relative '../code_rep'

class TestCodeRep < Minitest::Test
  LAYOUT = '<Page id="p"><Element elementId="e1"/></Page>'
  LIVE   = { 'workbookId' => 'w1', 'name' => 'N',
             'document' => { 'schemaVersion' => 1, 'pages' => [{ 'id' => 'p' }],
                             'elements' => [{ 'id' => 'e1', 'kind' => 'table' }],
                             'overlays' => [{ 'id' => 'o1' }], 'panels' => [{ 'id' => 'pn1' }],
                             'layout' => LAYOUT } }
  LEGACY = { 'workbookId' => 'w1', 'name' => 'N',
             'schemaVersion' => 1, 'pages' => [{ 'id' => 'p' }],
             'elements' => [{ 'id' => 'e1', 'kind' => 'table' }],
             'overlays' => [{ 'id' => 'o1' }], 'panels' => [{ 'id' => 'pn1' }],
             'layout' => LAYOUT }
  LEGACY_NESTED = {
    'schemaVersion' => 1,
    'pages' => [
      { 'id' => 'page-data', 'name' => 'Data',
        'elements' => [{ 'id' => 'source', 'kind' => 'table' }] },
      { 'id' => 'page-1', 'name' => 'Overview',
        'elements' => [{ 'id' => 'chart', 'kind' => 'bar-chart' }] }
    ],
    'layout' => '<Page id="page-data"><Element elementId="source"/></Page>' \
                '<Page id="page-1"><Element elementId="chart"/></Page>'
  }.freeze

  def test_reads_both_shapes
    [LIVE, LEGACY].each do |r|
      assert_equal 1, Sigma::CodeRep.document(r)['schemaVersion']
      assert_equal [{ 'id' => 'p' }], Sigma::CodeRep.document(r)['pages']
      assert_equal ['e1'], Sigma::CodeRep.document(r)['elements'].map { |el| el['id'] }
    end
  end

  def test_metadata_split
    [LIVE, LEGACY].each { |r| assert_equal %w[name workbookId], Sigma::CodeRep.metadata(r).keys.sort }
  end

  def test_wrap_always_nests
    doc = { 'schemaVersion' => 1, 'pages' => [] }
    api_doc = doc.merge('elements' => [])
    assert_equal({ 'document' => api_doc }, Sigma::CodeRep.wrap(doc))
    assert_equal({ 'name' => 'N', 'document' => api_doc }, Sigma::CodeRep.wrap(doc, extra: { 'name' => 'N' }))
  end

  def test_round_trip_lossless_from_both_shapes
    [LIVE, LEGACY].each do |r|
      doc = Sigma::CodeRep.document(r)
      assert_equal doc, Sigma::CodeRep.document(Sigma::CodeRep.wrap(doc))
    end
  end

  def test_document_collections_stay_inside_document
    [LIVE, LEGACY].each do |r|
      doc = Sigma::CodeRep.document(r)
      assert_equal [{ 'id' => 'o1' }], doc['overlays']
      assert_equal [{ 'id' => 'pn1' }], doc['panels']
      %w[elements overlays panels].each { |key| refute_includes Sigma::CodeRep.metadata(r), key }
    end
  end

  def test_workbook_page_membership_comes_from_layout
    doc = Sigma::CodeRep.document(LIVE)
    assert_nil doc['pages'].first['elements']
    assert_equal({ 'p' => ['e1'] }, Sigma::CodeRep.workbook_page_element_ids(doc))
    element, page = Sigma::CodeRep.workbook_elements_with_pages(doc).first
    assert_equal 'e1', element['id']
    assert_equal 'p', page['id']
  end

  def test_page_nested_elements_flatten_for_api
    assert_equal %w[chart source],
                 Sigma::CodeRep.workbook_elements(LEGACY_NESTED).map { |element| element['id'] }.sort
    wrapped = Sigma::CodeRep.wrap(LEGACY_NESTED)
    assert_equal %w[chart source], wrapped.dig('document', 'elements').map { |element| element['id'] }.sort
    assert wrapped.dig('document', 'pages').all? { |page| !page.key?('elements') }
    assert_equal %w[chart source], Sigma::CodeRep.workbook_elements(wrapped).map { |element| element['id'] }.sort
  end

  def test_wrap_canonicalizes_rejected_legacy_layout_tags
    legacy_layout = '<Page id="p"><GridContainer elementId="c"><LayoutElement elementId="e1"/></GridContainer></Page>'
    emitted = Sigma::CodeRep.wrap(LEGACY.merge('layout' => legacy_layout)).dig('document', 'layout')
    assert_equal '<Page id="p"><Container elementId="c"><Element elementId="e1"/></Container></Page>', emitted
    refute_match(/LayoutElement|GridContainer/, emitted)
  end

  def test_wrap_canonicalizes_legacy_alignment_fields_and_drawer_position
    legacy = {
      'pages' => [],
      'elements' => [
        { 'id' => 'text', 'kind' => 'text', 'verticalAlign' => 'middle' },
        { 'id' => 'kpi', 'kind' => 'kpi-chart',
          'layout' => { 'anchor' => 'start', 'verticalAnchor' => 'end', 'titleOrient' => 'bottom' } },
        { 'id' => 'tabs', 'kind' => 'tabbed-container', 'tabBar' => { 'alignment' => 'end' } },
        { 'id' => 'h-rule', 'kind' => 'divider', 'align' => 'start' },
        { 'id' => 'v-rule', 'kind' => 'divider', 'direction' => 'vertical', 'align' => 'end' }
      ],
      'overlays' => [
        { 'id' => 'filters', 'type' => 'drawer',
          'drawer' => { 'width' => 'medium', 'position' => 'end', 'showShadow' => 'shown' } }
      ]
    }
    emitted = Sigma::CodeRep.wrap(legacy)['document']
    by_id = emitted['elements'].each_with_object({}) { |element, out| out[element['id']] = element }
    assert_equal 'center', by_id['text']['verticalAlign']
    assert_equal({ 'anchor' => 'left', 'verticalAnchor' => 'bottom', 'titleOrient' => 'bottom' },
                 by_id['kpi']['layout'])
    assert_equal 'right', by_id['tabs'].dig('tabBar', 'alignment')
    assert_equal 'top', by_id['h-rule']['align']
    assert_equal 'right', by_id['v-rule']['align']
    assert_equal({ 'width' => 'medium', 'showShadow' => 'shown' },
                 emitted.dig('overlays', 0, 'drawer'))
    assert_equal 'middle', legacy.dig('elements', 0, 'verticalAlign')
    assert_equal 'end', legacy.dig('overlays', 0, 'drawer', 'position')
  end

  def test_page_membership_accepts_legacy_aliases_but_ignores_unrelated_attributes
    legacy_layout = '<Page id="p"><GridContainer elementId="c"><LayoutElement elementId="e1"/>' \
                    '<Noise elementId="not-layout"/></GridContainer></Page>'
    assert_equal({ 'p' => %w[c e1] },
                 Sigma::CodeRep.workbook_page_element_ids(LEGACY.merge('layout' => legacy_layout)))
  end

  LIVE_WITH_SETTINGS = { 'workbookId' => 'w1', 'name' => 'N',
                         'document' => { 'schemaVersion' => 1, 'pages' => [{ 'id' => 'p' }],
                                         'settings' => { 'theme' => { 'name' => 'dark' } },
                                         'agents' => [{ 'id' => 'a1' }] } }.freeze
  LEGACY_WITH_SETTINGS = { 'workbookId' => 'w1', 'name' => 'N',
                           'schemaVersion' => 1, 'pages' => [{ 'id' => 'p' }],
                           'settings' => { 'theme' => { 'name' => 'dark' } },
                           'agents' => [{ 'id' => 'a1' }] }.freeze

  # Regression for the "themeName/agents silently dropped" bug: DOC_KEYS previously
  # listed only schemaVersion/pages/kind/layout, so settings/agents fell through to
  # metadata() and got wrapped OUTSIDE `document` on write — invalid on PUT (document-only
  # allowlist) and stripped on POST/verify. See project_sigma_document_wrapper_migration.
  def test_settings_and_agents_stay_inside_document
    [LIVE_WITH_SETTINGS, LEGACY_WITH_SETTINGS].each do |r|
      doc = Sigma::CodeRep.document(r)
      assert_equal({ 'theme' => { 'name' => 'dark' } }, doc['settings'])
      assert_equal [{ 'id' => 'a1' }], doc['agents']
      refute_includes Sigma::CodeRep.metadata(r).keys, 'settings'
      refute_includes Sigma::CodeRep.metadata(r).keys, 'agents'
    end
  end

  # --- theme relocation -----------------------------------------------------
  # themeName/themeOverrides were REMOVED from the API (zero occurrences in the
  # published OpenAPI); the theme is settings.theme.{name,overrides}. Emitters
  # that still write the flat pair lose the whole theme silently, so document()
  # folds it forward and set_theme() gives builders the correct shape.
  LEGACY_THEME = { 'workbookId' => 'w1', 'name' => 'N', 'schemaVersion' => 1, 'pages' => [],
                   'themeName' => 'Light',
                   'themeOverrides' => { 'categoricalScheme' => %w[#111 #222] } }.freeze

  def test_legacy_theme_folds_into_settings
    doc = Sigma::CodeRep.document(LEGACY_THEME)
    assert_equal 'Light', doc.dig('settings', 'theme', 'name')
    assert_equal %w[#111 #222], doc.dig('settings', 'theme', 'overrides', 'categoricalScheme')
  end

  def test_removed_theme_keys_never_survive
    doc = Sigma::CodeRep.document(LEGACY_THEME)
    refute_includes doc.keys, 'themeName'
    refute_includes doc.keys, 'themeOverrides'
    meta = Sigma::CodeRep.metadata(LEGACY_THEME)
    refute_includes meta.keys, 'themeName'
    refute_includes meta.keys, 'themeOverrides'
    assert_equal %w[name workbookId], meta.keys.sort # real metadata still passes through
  end

  def test_fold_does_not_clobber_an_existing_nested_theme
    src = LEGACY_THEME.merge('settings' => { 'theme' => { 'name' => 'Dark' },
                                             'navigation' => { 'pageHeader' => 'enabled' } })
    doc = Sigma::CodeRep.document(src)
    assert_equal 'Dark', doc.dig('settings', 'theme', 'name') # nested wins over legacy
    assert_equal 'enabled', doc.dig('settings', 'navigation', 'pageHeader') # sibling preserved
  end

  def test_document_leaves_a_correct_doc_untouched
    good = { 'schemaVersion' => 1, 'pages' => [], 'settings' => { 'theme' => { 'name' => 'Dark' } } }
    assert_equal good, Sigma::CodeRep.document(good)
    assert_same good, Sigma::CodeRep.document({ 'document' => good })
  end

  def test_set_theme_writes_the_current_shape
    doc = { 'schemaVersion' => 1, 'pages' => [] }
    Sigma::CodeRep.set_theme(doc, name: 'Light', overrides: { 'hasCards' => 'shown' })
    assert_equal 'Light', doc.dig('settings', 'theme', 'name')
    assert_equal 'shown', doc.dig('settings', 'theme', 'overrides', 'hasCards')
    refute_includes doc.keys, 'themeName'
    # merges rather than replacing, and preserves sibling settings
    doc['settings']['navigation'] = { 'pageHeader' => 'enabled' }
    Sigma::CodeRep.set_theme(doc, overrides: { 'borderRadius' => 'round' })
    assert_equal %w[borderRadius hasCards], doc.dig('settings', 'theme', 'overrides').keys.sort
    assert_equal 'enabled', doc.dig('settings', 'navigation', 'pageHeader')
  end

  def test_set_theme_is_a_no_op_without_a_theme
    doc = { 'pages' => [] }
    assert_equal({ 'pages' => [] }, Sigma::CodeRep.set_theme(doc, overrides: {}))
  end

  def test_theme_reader_handles_both_shapes
    assert_equal 'Light', Sigma::CodeRep.theme(LEGACY_THEME)['name']
    assert_equal %w[#111 #222], Sigma::CodeRep.theme(LEGACY_THEME)['overrides']['categoricalScheme']
    nested = { 'document' => { 'settings' => { 'theme' => { 'name' => 'Dark' } } } }
    assert_equal 'Dark', Sigma::CodeRep.theme(nested)['name']
    assert_equal({}, Sigma::CodeRep.theme({ 'pages' => [] })['overrides'])
  end

  def test_settings_and_agents_round_trip_through_wrap
    [LIVE_WITH_SETTINGS, LEGACY_WITH_SETTINGS].each do |r|
      doc = Sigma::CodeRep.document(r)
      wrapped = Sigma::CodeRep.wrap(doc, extra: Sigma::CodeRep.metadata(r))
      wrapped_doc = Sigma::CodeRep.document(wrapped)
      assert_equal doc['settings'], wrapped_doc['settings']
      assert_equal doc['agents'], wrapped_doc['agents']
      assert_equal [], wrapped_doc['elements']
      assert_nil wrapped['settings'] # must NOT leak to top level — PUT allowlists document only
      assert_nil wrapped['agents']
    end
  end
end
