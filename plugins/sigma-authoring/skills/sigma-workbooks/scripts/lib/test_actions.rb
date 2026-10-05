# frozen_string_literal: true
# test_actions.rb — run directly: ruby scripts/lib/test_actions.rb (from sigma-workbooks/)
require 'json'
require_relative 'actions'
$failures = 0
def check(desc); ok = yield; puts(ok ? "[ok] #{desc}" : "[FAIL] #{desc}"); $failures += 1 unless ok; end

# Deep-sort hashes/arrays so twin/golden comparison is key-order-independent.
def sort_deep(o)
  case o
  when Hash then o.keys.sort.each_with_object({}) { |k, h| h[k] = sort_deep(o[k]) }
  when Array then o.map { |e| sort_deep(e) }
  else o
  end
end

check('SURFACES: all 4 actions surfaces are GO') do
  expected = %i[button effects input_table_empty input_table_linked]
  Actions::SURFACES.keys.sort == expected.sort && Actions::SURFACES.values.all? { |v| v == true }
end

# --- button -------------------------------------------------------------

check('button: default appearance/trigger + default action_id "a-<id>"') do
  el = Actions.button(id: 'btn-log', text: 'Log note',
                       effects: [{ 'effect' => 'insert-rows', 'tableElementId' => 'annotations', 'values' => {} }])
  el == {
    'id' => 'btn-log', 'kind' => 'button', 'text' => 'Log note', 'appearance' => 'filled',
    'actions' => [{ 'id' => 'a-btn-log', 'trigger' => 'on-click',
                    'effects' => [{ 'effect' => 'insert-rows', 'tableElementId' => 'annotations', 'values' => {} }] }]
  }
end
check('button: custom appearance + trigger are honored') do
  el = Actions.button(id: 'btn-reset', text: 'Reset filters', appearance: 'outline', trigger: 'on-load', effects: [])
  el['appearance'] == 'outline' && el['actions'][0]['trigger'] == 'on-load'
end
check('button: explicit action_id: overrides the "a-<id>" default') do
  el = Actions.button(id: 'btn-reset', text: 'Reset filters', action_id: 'a-reset', effects: [])
  el['actions'][0]['id'] == 'a-reset'
end
check('button: effects array is passed through verbatim (caller builds via effect builders)') do
  effects = [{ 'effect' => 'insert-rows', 'tableElementId' => 't', 'values' => { 'c' => 1 } },
             { 'effect' => 'clear-control', 'scope' => { 'type' => 'page', 'pageId' => 'pg' }, 'usePublishedValue' => true }]
  el = Actions.button(id: 'btn-log', text: 'Log note', effects: effects)
  el['actions'][0]['effects'] == effects && el['actions'][0]['effects'].length == 2
end
check('button: id required') do
  begin; Actions.button(id: '', text: 'x', effects: []); false
  rescue ArgumentError; true; end
end
check('button: text required') do
  begin; Actions.button(id: 'btn-x', text: '', effects: []); false
  rescue ArgumentError; true; end
end
check('button: NO-GO surface -> opt-in marker') do
  el = Actions.button(id: 'btn-log', text: 'Log note', effects: [],
                       surfaces: Actions::SURFACES.merge(button: false))
  el == { 'opt_in' => true, 'id' => 'btn-log' }
end

# --- input_table_empty ---------------------------------------------------

ANNOTATION_COLUMNS = [
  { 'id' => 'an-note', 'type' => 'text', 'name' => 'Review note' },
  { 'id' => 'CREATED_AT' }, { 'id' => 'CREATED_BY' }
].freeze

check('input_table_empty: inputMode defaults to "view" + source.kind:"empty"') do
  el = Actions.input_table_empty(id: 'annotations', connection_id: 'write-conn-1', columns: ANNOTATION_COLUMNS)
  el == {
    'id' => 'annotations', 'kind' => 'input-table', 'inputMode' => 'view',
    'source' => { 'kind' => 'empty', 'connectionId' => 'write-conn-1' },
    'columns' => ANNOTATION_COLUMNS
  }
end
check('input_table_empty: input_mode override is honored') do
  el = Actions.input_table_empty(id: 'annotations', connection_id: 'write-conn-1',
                                 columns: ANNOTATION_COLUMNS, input_mode: 'edit')
  el['inputMode'] == 'edit'
end
check('input_table_empty: invalid input_mode rejected') do
  begin
    Actions.input_table_empty(id: 'annotations', connection_id: 'write-conn-1',
                              columns: ANNOTATION_COLUMNS, input_mode: 'published')
    false
  rescue ArgumentError
    true
  end
end
check('input_table_empty: name: omitted entirely when not given') do
  el = Actions.input_table_empty(id: 'annotations', connection_id: 'write-conn-1', columns: ANNOTATION_COLUMNS)
  !el.key?('name')
end
check('input_table_empty: name: passed through verbatim when given') do
  name = { 'text' => 'Review log (append-only)', 'fontWeight' => 'bold', 'fontSize' => 15, 'color' => '#1A1A1A' }
  el = Actions.input_table_empty(id: 'annotations', connection_id: 'write-conn-1', columns: ANNOTATION_COLUMNS,
                                  name: name)
  el['name'] == name
end
check('input_table_empty: id required') do
  begin; Actions.input_table_empty(id: '', connection_id: 'c', columns: ANNOTATION_COLUMNS); false
  rescue ArgumentError; true; end
end
check('input_table_empty: connection_id required') do
  begin; Actions.input_table_empty(id: 'x', connection_id: '', columns: ANNOTATION_COLUMNS); false
  rescue ArgumentError; true; end
end
check('input_table_empty: columns required (nil)') do
  begin; Actions.input_table_empty(id: 'x', connection_id: 'c', columns: nil); false
  rescue ArgumentError; true; end
end
check('input_table_empty: columns required (empty array)') do
  begin; Actions.input_table_empty(id: 'x', connection_id: 'c', columns: []); false
  rescue ArgumentError; true; end
end
check('input_table_empty: NO-GO surface -> opt-in marker') do
  el = Actions.input_table_empty(id: 'annotations', connection_id: 'write-conn-1', columns: ANNOTATION_COLUMNS,
                                  surfaces: Actions::SURFACES.merge(input_table_empty: false))
  el == { 'opt_in' => true, 'id' => 'annotations' }
end

# --- input_table_linked ---------------------------------------------------

TARGET_COLUMNS = [
  { 'id' => 'tg-fam', 'key' => 'fp-fam' },
  { 'id' => 'tg-actual', 'key' => 'fp-rev', 'name' => 'Actual Revenue' },
  { 'id' => 'tg-target', 'type' => 'number', 'name' => 'Target Revenue' },
  { 'id' => 'tg-var', 'name' => 'Variance vs Target', 'formula' => '[Actual Revenue] - [Target Revenue]' }
].freeze

check('input_table_linked: source.kind:"linked" carries from + connectionId') do
  el = Actions.input_table_linked(id: 'targets', from: 'fam-pivot', connection_id: 'write-conn-1',
                                   columns: TARGET_COLUMNS)
  el == {
    'id' => 'targets', 'kind' => 'input-table', 'inputMode' => 'view',
    'source' => { 'kind' => 'linked', 'from' => 'fam-pivot', 'connectionId' => 'write-conn-1' },
    'columns' => TARGET_COLUMNS
  }
end
check('input_table_linked: input_mode override is honored') do
  el = Actions.input_table_linked(id: 'targets', from: 'fam-pivot', connection_id: 'write-conn-1',
                                  columns: TARGET_COLUMNS, input_mode: 'explore')
  el['inputMode'] == 'explore'
end
check('input_table_linked: invalid input_mode rejected') do
  begin
    Actions.input_table_linked(id: 'targets', from: 'fam-pivot', connection_id: 'write-conn-1',
                               columns: TARGET_COLUMNS, input_mode: 'published')
    false
  rescue ArgumentError
    true
  end
end
check('input_table_linked: id required') do
  begin; Actions.input_table_linked(id: '', from: 'f', connection_id: 'c', columns: TARGET_COLUMNS); false
  rescue ArgumentError; true; end
end
check('input_table_linked: from required') do
  begin; Actions.input_table_linked(id: 'x', from: '', connection_id: 'c', columns: TARGET_COLUMNS); false
  rescue ArgumentError; true; end
end
check('input_table_linked: connection_id required') do
  begin; Actions.input_table_linked(id: 'x', from: 'f', connection_id: '', columns: TARGET_COLUMNS); false
  rescue ArgumentError; true; end
end
check('input_table_linked: columns required (empty array)') do
  begin; Actions.input_table_linked(id: 'x', from: 'f', connection_id: 'c', columns: []); false
  rescue ArgumentError; true; end
end
check('input_table_linked: NO-GO surface -> opt-in marker') do
  el = Actions.input_table_linked(id: 'targets', from: 'fam-pivot', connection_id: 'write-conn-1',
                                   columns: TARGET_COLUMNS,
                                   surfaces: Actions::SURFACES.merge(input_table_linked: false))
  el == { 'opt_in' => true, 'id' => 'targets' }
end

# --- effect builders -------------------------------------------------------

check('insert_rows_effect: {effect, tableElementId, values} — values passed through verbatim') do
  values = { 'an-note' => { 'type' => 'control', 'control' => 'NoteCtl' } }
  Actions.insert_rows_effect(table_element_id: 'annotations', values: values) ==
    { 'effect' => 'insert-rows', 'tableElementId' => 'annotations', 'values' => values }
end
check('insert_rows_effect: table_element_id required') do
  begin; Actions.insert_rows_effect(table_element_id: '', values: {}); false
  rescue ArgumentError; true; end
end
check('insert_rows_effect: NO-GO surface -> {}') do
  Actions.insert_rows_effect(table_element_id: 'annotations', values: {},
                              surfaces: Actions::SURFACES.merge(effects: false)) == {}
end

check('clear_control_effect: {effect, scope:{type:page,pageId}, usePublishedValue:true}') do
  Actions.clear_control_effect(page_id: 'pg') ==
    { 'effect' => 'clear-control', 'scope' => { 'type' => 'page', 'pageId' => 'pg' }, 'usePublishedValue' => true }
end
check('clear_control_effect: page_id required') do
  begin; Actions.clear_control_effect(page_id: ''); false
  rescue ArgumentError; true; end
end
check('clear_control_effect: NO-GO surface -> {}') do
  Actions.clear_control_effect(page_id: 'pg', surfaces: Actions::SURFACES.merge(effects: false)) == {}
end

check('set_control_value_effect: {effect, control, value:{type:constant,value:{type:text,value}}}') do
  Actions.set_control_value_effect(control: 'RegionF', text: 'West') ==
    { 'effect' => 'set-control-value', 'control' => 'RegionF',
      'value' => { 'type' => 'constant', 'value' => { 'type' => 'text', 'value' => 'West' } } }
end
check('set_control_value_effect: control required') do
  begin; Actions.set_control_value_effect(control: '', text: 'West'); false
  rescue ArgumentError; true; end
end
check('set_control_value_effect: empty text is accepted for wizard resets') do
  Actions.set_control_value_effect(control: 'NewName', text: '') ==
    { 'effect' => 'set-control-value', 'control' => 'NewName',
      'value' => { 'type' => 'constant', 'value' => { 'type' => 'text', 'value' => '' } } }
end
check('set_control_value_effect: text required') do
  begin; Actions.set_control_value_effect(control: 'RegionF', text: nil); false
  rescue ArgumentError; true; end
end
check('set_control_value_effect: NO-GO surface -> {}') do
  Actions.set_control_value_effect(control: 'RegionF', text: 'West',
                                    surfaces: Actions::SURFACES.merge(effects: false)) == {}
end

# --- golden ------------------------------------------------------------------

golden = JSON.parse(File.read(File.join(__dir__, 'testdata', 'actions_golden.json')))
check('helpers match actions_golden.json (sorted-key identical)') do
  button_effects = [
    Actions.insert_rows_effect(table_element_id: 'annotations',
                                values: { 'an-note' => { 'type' => 'control', 'control' => 'NoteCtl' } }),
    Actions.clear_control_effect(page_id: 'pg')
  ]
  actual = {
    'button' => Actions.button(id: 'btn-log', text: 'Log note', appearance: 'filled', effects: button_effects),
    'input_table_empty' => Actions.input_table_empty(
      id: 'annotations', connection_id: 'write-conn-1', columns: ANNOTATION_COLUMNS,
      name: { 'text' => 'Review log (append-only)', 'fontWeight' => 'bold', 'fontSize' => 15, 'color' => '#1A1A1A' }
    ),
    'input_table_linked' => Actions.input_table_linked(id: 'targets', from: 'fam-pivot',
                                                        connection_id: 'write-conn-1', columns: TARGET_COLUMNS),
    'insert_rows_effect' => Actions.insert_rows_effect(
      table_element_id: 'annotations', values: { 'an-note' => { 'type' => 'control', 'control' => 'NoteCtl' } }
    ),
    'clear_control_effect' => Actions.clear_control_effect(page_id: 'pg'),
    'set_control_value_effect' => Actions.set_control_value_effect(control: 'RegionF', text: 'West')
  }
  JSON.generate(sort_deep(actual)) == JSON.generate(sort_deep(golden))
end

exit($failures.zero? ? 0 : 1)
