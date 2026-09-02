# frozen_string_literal: true

require 'fileutils'
require 'json'
require_relative 'blind_grade'

module DomoVisualHandoff
  EXIT_PENDING = 20
  SOURCE_BASENAME = 'source-dashboard.png'
  TARGET_BASENAME = 'sigma-render.png'
  GRADE_BASENAME = 'blind-grade.json'
  REQUEST_BASENAME = 'visual-grade-request.json'
  CHECKLIST_KEYS = BlindGrade::DIMENSION_KEYS

  module_function

  def png?(path)
    File.file?(path.to_s) && File.binread(path, 8) == "\x89PNG\r\n\x1a\n".b
  rescue StandardError
    false
  end

  def stage_source!(source_path, workdir)
    source = File.expand_path(source_path.to_s)
    raise ArgumentError, "source dashboard PNG not found or invalid: #{source}" unless png?(source)

    target = File.join(workdir, SOURCE_BASENAME)
    FileUtils.cp(source, target) unless source == File.expand_path(target)
    target
  end

  def write_request!(workdir:, source_path:, target_path:, rubric_path:, brief_path:,
                     grade_path:, reason: nil)
    request = {
      'schema' => 'domo-visual-grade-request/v1',
      'status' => source_path ? 'awaiting-blind-grade' : 'awaiting-source-dashboard',
      'source_png' => source_path,
      'target_png' => target_path,
      'rubric_path' => rubric_path,
      'brief_path' => brief_path,
      'output_json' => grade_path,
      'resume_command' => 'rerun the same migrate-domo.rb command; it will consume the grade idempotently',
      'reason' => reason
    }.compact
    path = File.join(workdir, REQUEST_BASENAME)
    File.write(path, JSON.pretty_generate(request) + "\n")
    path
  end

  def validate_grade(grade_path, workdir:)
    BlindGrade.load_and_validate(grade_path, workdir: workdir)
  end

  def record_args(validation, workdir:, target_path:, grade_path:)
    doc = validation.fetch('doc')
    checklist = CHECKLIST_KEYS.map do |key|
      "#{key}=#{doc.fetch('dimensions').fetch(key).fetch('verdict')}"
    end.join(',')
    gaps = Array(doc['top_gaps']).map(&:to_s).reject(&:empty?)
    notes = gaps.empty? ? 'Context-free blind visual grade completed.' : gaps.join('; ')
    [
      '--workdir', workdir,
      '--agent-vision', 'true',
      '--verdict', (doc.fetch('verdict') == 'pass' ? 'pass' : 'divergent'),
      '--notes', notes,
      '--screenshot', target_path,
      '--blind-grade', File.expand_path(grade_path, workdir),
      '--checklist', checklist
    ]
  end
end
