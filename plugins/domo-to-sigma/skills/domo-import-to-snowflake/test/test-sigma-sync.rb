#!/usr/bin/env ruby
# frozen_string_literal: true

require 'json'
require 'minitest/autorun'

class TestSigmaSync < Minitest::Test
  CLI = File.expand_path('../scripts/domo_import_to_snowflake.rb', __dir__)
  SOURCE = File.read(CLI)
  HELPER_SOURCE = SOURCE[/^def sigma_sync_body\(database, schema\)\n.*?\nend\n/m]

  module Helper
    module_eval(HELPER_SOURCE)
  end

  def test_syncs_the_landed_schema_with_required_path_body
    assert_equal(
      { 'path' => %w[CSA TJ] },
      JSON.parse(Object.new.extend(Helper).sigma_sync_body('CSA', 'TJ'))
    )
  end

  def test_sync_call_passes_the_body
    assert_includes SOURCE, 'body: sigma_sync_body(opts[:target_db], opts[:target_schema])'
  end
end
