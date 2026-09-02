#!/usr/bin/env ruby
# frozen_string_literal: true

require 'minitest/autorun'

class TestColorOverrides < Minitest::Test
  BUILDER = File.expand_path('../scripts/build-workbook-spec.rb', __dir__)
  SOURCE = File.read(BUILDER)
  HELPER_SOURCE = SOURCE[/^def sigma_color_overrides\(background_canvas\)\n.*?\nend\n/m]

  module Helper
    module_eval(HELPER_SOURCE)
  end

  def test_emits_live_api_array_shape
    assert_equal(
      [{ 'name' => 'backgroundCanvas', 'color' => '#F4F4F4' }],
      Object.new.extend(Helper).sigma_color_overrides('#F4F4F4')
    )
  end

  def test_both_theme_paths_use_the_helper
    assert_operator SOURCE.scan('sigma_color_overrides(').length, :>=, 3
  end
end
