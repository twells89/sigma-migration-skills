#!/usr/bin/env ruby
# frozen_string_literal: true

require 'digest'
require 'json'
require 'minitest/autorun'
require 'tmpdir'
require_relative '../scripts/lib/visual_handoff'

class TestVisualHandoff < Minitest::Test
  PNG = "\x89PNG\r\n\x1a\nfixture".b

  def grade(source, target)
    dimensions = DomoVisualHandoff::CHECKLIST_KEYS.each_with_object({}) do |key, out|
      out[key] = { 'verdict' => 'pass', 'evidence' => "#{key} checked" }
    end
    {
      'schema' => 'blind-grade/v1',
      'source_png' => source,
      'target_png' => target,
      'source_sha256' => Digest::SHA256.file(source).hexdigest,
      'target_sha256' => Digest::SHA256.file(target).hexdigest,
      'dimensions' => dimensions,
      'per_tile' => [{ 'position' => 'r1c1', 'source_family' => 'kpi', 'target_family' => 'kpi' }],
      'verdict' => 'pass',
      'top_gaps' => []
    }
  end

  def test_stages_source_and_writes_resumable_request
    Dir.mktmpdir do |dir|
      original = File.join(dir, 'provided.png')
      File.binwrite(original, PNG)
      staged = DomoVisualHandoff.stage_source!(original, dir)
      assert_equal File.join(dir, 'source-dashboard.png'), staged
      assert_equal PNG, File.binread(staged)

      request_path = DomoVisualHandoff.write_request!(
        workdir: dir, source_path: staged, target_path: File.join(dir, 'sigma-render.png'),
        rubric_path: '/skill/refs/layout-visual-qa.md', brief_path: '/skill/refs/blind-grader-brief.md',
        grade_path: File.join(dir, 'blind-grade.json')
      )
      request = JSON.parse(File.read(request_path))
      assert_equal 'awaiting-blind-grade', request['status']
      assert_match(/rerun the same migrate-domo/, request['resume_command'])
    end
  end

  def test_rejects_a_non_png_source
    Dir.mktmpdir do |dir|
      path = File.join(dir, 'source.txt')
      File.write(path, 'not an image')
      assert_raises(ArgumentError) { DomoVisualHandoff.stage_source!(path, dir) }
    end
  end

  def test_valid_grade_becomes_record_visual_check_arguments
    Dir.mktmpdir do |dir|
      source = File.join(dir, 'source-dashboard.png')
      target = File.join(dir, 'sigma-render.png')
      grade_path = File.join(dir, 'blind-grade.json')
      File.binwrite(source, PNG)
      File.binwrite(target, PNG + 'target')
      File.write(grade_path, JSON.pretty_generate(grade(source, target)))

      validation = DomoVisualHandoff.validate_grade(grade_path, workdir: dir)
      assert_empty validation['errors']
      args = DomoVisualHandoff.record_args(
        validation, workdir: dir, target_path: target, grade_path: grade_path
      )
      assert_equal 'true', args[args.index('--agent-vision') + 1]
      assert_equal 'pass', args[args.index('--verdict') + 1]
      checklist = args[args.index('--checklist') + 1]
      DomoVisualHandoff::CHECKLIST_KEYS.each { |key| assert_includes checklist, "#{key}=pass" }
    end
  end

  def test_stale_grade_is_not_consumable
    Dir.mktmpdir do |dir|
      source = File.join(dir, 'source-dashboard.png')
      target = File.join(dir, 'sigma-render.png')
      grade_path = File.join(dir, 'blind-grade.json')
      File.binwrite(source, PNG)
      File.binwrite(target, PNG)
      File.write(grade_path, JSON.pretty_generate(grade(source, target)))
      File.binwrite(target, PNG + 'changed')

      validation = DomoVisualHandoff.validate_grade(grade_path, workdir: dir)
      assert validation['errors'].any? { |error| error.include?('target_sha256 does NOT match') }
    end
  end

  def test_blind_failure_records_as_divergent
    Dir.mktmpdir do |dir|
      source = File.join(dir, 'source-dashboard.png')
      target = File.join(dir, 'sigma-render.png')
      grade_path = File.join(dir, 'blind-grade.json')
      File.binwrite(source, PNG)
      File.binwrite(target, PNG)
      doc = grade(source, target)
      doc['verdict'] = 'fail'
      doc['dimensions']['composition_match']['verdict'] = 'fail'
      File.write(grade_path, JSON.pretty_generate(doc))

      validation = DomoVisualHandoff.validate_grade(grade_path, workdir: dir)
      args = DomoVisualHandoff.record_args(
        validation, workdir: dir, target_path: target, grade_path: grade_path
      )
      assert_equal 'divergent', args[args.index('--verdict') + 1]
    end
  end
end
