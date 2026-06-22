# frozen_string_literal: true
#
# DaxGate — pure classifier for the PowerBI converter's DAX warnings into the
# migrate-powerbi.rb decision questions. Extracted from migrate-powerbi.rb so the
# gap-scout-gate regression (PR #153) is unit-testable (test-dax-gate.rb).
#
# The converter prefixes each warning: ⛔ = no/failed translation (drops to Null);
# ⚠ = restructure-needed; ✅ = SUCCESS (auto-translated — RANKX→SQL window helper,
# USERELATIONSHIP→alternate join path, …); ℹ = informational (clean auto-handle).
#
# Regression guard: ✅ and ℹ are NEVER decisions, and a ⚠ whose measure the converter
# actually REALIZED in the DM (e.g. TOTALYTD → grouped CumulativeSum element) is a
# handled restructure, not a gap. Only ⛔ and genuinely-DROPPED ⚠ become decisions.
module DaxGate
  module_function

  # Display-names the converter realized in the DM model (element + metric + column
  # names) — used to tell a handled restructure from a real drop.
  def realized_names(dm_model)
    names = []
    ((dm_model && dm_model['pages']) || []).each do |pg|
      (pg['elements'] || []).each do |el|
        names << el['name'].to_s.strip unless el['name'].to_s.strip.empty?
        (el['metrics'] || []).each { |m| names << m['name'].to_s.strip unless m['name'].to_s.strip.empty? }
        (el['columns'] || []).each { |c| names << c['name'].to_s.strip unless c['name'].to_s.strip.empty? }
      end
    end
    names
  end

  # The measure name the warning is about (first quoted token), or '' if none.
  def measure_of(ws)
    (ws[/"([^"]+)"/, 1] || '').strip
  end

  # conv_warnings: Array<String> (converter `warnings`), dm_model: the converted
  # sigmaDataModel. Returns the DAX decision questions (same shape migrate-powerbi.rb
  # pushes onto `questions`): dax_no_equivalent (⛔) and dax_needs_restructure
  # (genuinely-dropped ⚠). ✅/ℹ and DM-realized ⚠ produce NO question.
  def dax_questions(conv_warnings, dm_model)
    realized = realized_names(dm_model)
    out = []
    (conv_warnings || []).each do |w|
      ws = w.to_s.gsub(/\s+/, ' ').strip
      next if ws.start_with?('ℹ')  # informational; auto-handled, no human choice
      next if ws.start_with?('✅') # SUCCESS — converter translated it; not a degradation
      mname = measure_of(ws)
      if ws.start_with?('⛔')
        out << { 'id' => 'dax_no_equivalent', 'severity' => 'review',
                 'detail' => ws,
                 'options' => ['proceed (measure degrades to Null; original DAX kept in description)',
                               'abort and re-author the measure manually'],
                 'default' => 'proceed (measure degrades to Null; original DAX kept in description)' }
      else # ⚠ and any unmarked warning
        # A ⚠ measure the converter REALIZED as a DM element/metric/column is a handled
        # restructure (e.g. TOTALYTD → grouped CumulativeSum element), not a gap — skip it.
        next if !mname.empty? && realized.include?(mname)
        out << { 'id' => 'dax_needs_restructure', 'severity' => 'review',
                 'detail' => ws,
                 'options' => ['proceed (converter best-effort; verify in Sigma)',
                               'restructure manually via gap-scout (scripts/gap-scout.md)'],
                 'default' => 'proceed (converter best-effort; verify in Sigma)' }
      end
    end
    out
  end
end
