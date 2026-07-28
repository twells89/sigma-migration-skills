require 'json'; require_relative 'helper'
%w[datasets pages cards users pdp dataflows activity-log].each do |name|
  f = File.join(Helper.fixtures_dir('tier-b'), "#{name}.json")
  Helper.assert(File.exist?(f), "#{name}.json present")
  d = JSON.parse(File.read(f))
  Helper.assert(d.key?('columns') && d.key?('rows'), "#{name} has columns+rows")
end
# One card must have zero views (→ retire) and one must reference an unhandled Beast Mode (→ needs-gap-scout)
cards = JSON.parse(File.read(File.join(Helper.fixtures_dir('tier-b'),'cards.json')))
Helper.assert(cards['rows'].any?, 'cards non-empty')

# Tier-B degradation: the public Cards dataset never exposes Beast Mode SQL/text —
# tier-b's cards.json must carry no Beast Mode column (that signal is Tier-A-only,
# via beast-modes.json / card-defs.json).
Helper.assert(!cards['columns'].any? { |c| c =~ /Beast Mode/ },
              'tier-b cards.json carries no Beast Mode column (public-API fidelity)')

# So the Tier-B needs-gap-scout scenario must be reachable via a structural signal
# alone: a card sourced from a DataFlow output dataset. Cross-reference
# dataflows.json's Output DataSet IDs against cards.json's DataSet ID.
dataflows = JSON.parse(File.read(File.join(Helper.fixtures_dir('tier-b'), 'dataflows.json')))
df_out_idx = dataflows['columns'].index('Output DataSet IDs')
output_dataset_ids = dataflows['rows'].map { |r| r[df_out_idx] }

card_id_idx = cards['columns'].index('Card ID')
card_ds_idx = cards['columns'].index('DataSet ID')
dataflow_sourced_cards = cards['rows'].select { |r| output_dataset_ids.include?(r[card_ds_idx]) }
Helper.assert(dataflow_sourced_cards.any?,
              'a card is sourced from a DataFlow output dataset (tier-b structural gap-scout signal)')

# That DataFlow-sourced card must have >=1 view, so it is distinct from the
# zero-view retire card.
activity = JSON.parse(File.read(File.join(Helper.fixtures_dir('tier-b'), 'activity-log.json')))
al_obj_idx = activity['columns'].index('Object ID')
al_action_idx = activity['columns'].index('Action Type')
viewed_object_ids = activity['rows'].select { |r| r[al_action_idx] == 'VIEWED' }.map { |r| r[al_obj_idx] }
Helper.assert(dataflow_sourced_cards.any? { |r| viewed_object_ids.include?(r[card_id_idx]) },
              'the DataFlow-sourced card has >=1 view (not the retire card)')

puts 'test-fixtures: PASS'
