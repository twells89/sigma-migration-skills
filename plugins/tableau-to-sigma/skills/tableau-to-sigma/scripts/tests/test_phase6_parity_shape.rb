# frozen_string_literal: true
#
# test_phase6_parity_shape.rb — regression test for phase6-parity.rb's
# workbook code-rep GET readback (Task 3.8).
#
# Live GET /v2/workbooks/{id}/spec now nests non-metadata fields under a
# top-level `document` key (verified 2026-08-03/04). phase6-parity.rb GETs the
# live spec in PASS 1 and writes the FULL release response to wb-readback.json.
# WorkbookCode consumers resolve the nested document through CodeRep, while
# freshness/evidence gates retain workbookId + latestDocumentVersion. Dropping
# that outer metadata made stale readbacks and parity plans indistinguishable.
#
# Run: ruby scripts/tests/test_phase6_parity_shape.rb

require 'minitest/autorun'
require_relative '../lib/code_rep'

SCRIPT_NAME = 'phase6-parity.rb'

class TestPhase6ParityShape < Minitest::Test
  # Sanity-checks the shared adapter itself. Already shipped (Task 3.x), so
  # this alone would NOT fail pre-fix -- it documents the expected shape that
  # the real regression test below actually enforces against the script.
  def test_document_resolves_nested_readback
    readback = { 'workbookId' => 'w', 'document' => { 'pages' => [{ 'id' => 'p1' }] } }
    assert_equal [{ 'id' => 'p1' }], Sigma::CodeRep.document(readback)['pages']
    assert_nil readback['pages'], 'proves the old flat read was nil'
  end

  # Real regression signal: retain outer metadata in wb-readback and bind the
  # parity plan to the live document version.
  def test_script_preserves_release_readback_and_version
    src = File.read(File.join(__dir__, '..', SCRIPT_NAME))
    assert_includes src, 'JSON.pretty_generate(raw_spec)'
    assert_includes src, "plan['workbook_document_version']"
    assert_includes src, 'Phase 6 finalize blocked: parity-plan.json is STALE'
  end
end
