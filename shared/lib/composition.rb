# frozen_string_literal: true
# composition.rb — Ruby twin of shared/lib/composition.py. Pure composition
# engine: arrange elements (by role) into a polished layout XML fragment for a
# single <Page>. Sibling-<LayoutElement> form (no GridContainer). Ruby 2.6, stdlib only.
# Twins emit byte-identical output (shared/lib/testdata/composition_exec_golden.txt).
module Composition
  ROLES = %i[control kpi insight hero supporting table master detail header kpi2 trend pivot base].freeze

  # Roles each pattern actually places. A role that resolves (explicitly or via
  # inference) to something OUTSIDE its chosen pattern's set used to be silently
  # dropped from the emitted layout; check_pattern_roles! (below) now raises
  # instead — see compose_exec / compose_master_detail.
  EXEC_ROLES = %i[control kpi insight hero supporting table].freeze
  MASTER_DETAIL_ROLES = %i[control master detail].freeze
  OVERVIEW_ROLES = %i[header control kpi kpi2 trend pivot base].freeze

  # kind -> role inference (used when an element has no explicit :role). Chart
  # kinds default to :supporting; callers wanting a :hero must tag it explicitly.
  KIND_ROLE = {
    'kpi-chart' => :kpi, 'table' => :table, 'pivot-table' => :table,
    'input-table' => :table
  }.freeze
  def self.infer_role(kind)
    KIND_ROLE.fetch(kind.to_s) { :supporting } # chart kinds default to :supporting; caller tags :hero explicitly
  end

  def self.le(id, c0, c1, r0, r1)
    "  <LayoutElement elementId=\"#{id}\" gridColumn=\"#{c0} / #{c1}\" gridRow=\"#{r0} / #{r1}\"/>"
  end

  def self.band(elements, r0, r1, page_cols)
    n = elements.size
    return [] if n.zero?
    raise ArgumentError, "compose: page_cols (#{page_cols}) not evenly divisible by #{n} " \
                          'element(s) in one band' if page_cols % n != 0
    w = page_cols / n
    elements.each_with_index.map { |el, i| le(el[:id], i * w + 1, i * w + 1 + w, r0, r1) }
  end

  def self.roleize(elements)
    elements.map do |e|
      raw = e[:role]
      role = (raw.nil? || raw == '') ? infer_role(e[:kind]) : raw.to_s.to_sym
      unless ROLES.include?(role)
        raise ArgumentError, "compose: unknown role #{role} for element #{e[:id]}"
      end
      { id: e[:id], role: role }
    end
  end

  # Raise when a resolved role isn't in the pattern's consumed set — e.g.
  # :master passed to :exec, or :kpi passed to :master_detail. Root fix (I3):
  # such a role used to fall through every band unrendered and vanish from the
  # emitted layout with no signal.
  def self.check_pattern_roles!(roleized, pattern_name, allowed_roles)
    roleized.each do |e|
      next if allowed_roles.include?(e[:role])
      raise ArgumentError, "compose: role #{e[:role]} (element #{e[:id]}) is not used by pattern #{pattern_name}"
    end
  end

  # bands: the role -> [r0, r1) row-band computation shared by compose_exec
  # and compose_master_detail, extracted so callers can get the layout's
  # structure (which roles land in which row band, and which element ids)
  # without the gridColumn/XML-emission step. Returns
  # [{role:, ids:, r0:, r1:}, ...] in row order. Column splitting within a
  # band still happens in compose_* (via band()), not here — bands() only
  # decides vertical placement.
  def self.bands(elements, pattern, page_cols = 24)
    roleized = roleize(elements)
    by = Hash.new { |h, k| h[k] = [] }
    roleized.each { |e| by[e[:role]] << e }
    row = 1
    out = []
    add = lambda do |role, group, h|
      next if group.empty?
      out << { role: role, ids: group.map { |e| e[:id] }, r0: row, r1: row + h }
      row += h
    end
    case pattern.to_sym
    when :exec
      check_pattern_roles!(roleized, 'exec', EXEC_ROLES)
      [[:control, 2], [:kpi, 6], [:insight, 3], [:hero, 12]].each { |role, h| add.call(role, by[role], h) }
      add.call(:supporting, by[:supporting] + by[:table], 9)
    when :master_detail
      check_pattern_roles!(roleized, 'master_detail', MASTER_DETAIL_ROLES)
      add.call(:control, by[:control], 2)
      add.call(:master_detail, by[:master] + by[:detail], 14)
    when :overview
      check_pattern_roles!(roleized, 'overview', OVERVIEW_ROLES)
      [[:header, 3], [:control, 2], [:kpi, 8], [:kpi2, 8], [:trend, 12], [:pivot, 14], [:base, 9]].each do |role, h|
        add.call(role, by[role], h)
      end
    else
      raise ArgumentError, "compose: unknown pattern #{pattern.inspect}"
    end
    out
  end

  def self.render_bands(elements, pattern, page_cols)
    bands(elements, pattern, page_cols).flat_map do |b|
      band(b[:ids].map { |id| { id: id } }, b[:r0], b[:r1], page_cols)
    end.join("\n")
  end

  def self.compose_exec(elements, page_cols)
    render_bands(elements, :exec, page_cols)
  end

  # :master_detail — an optional thin full-width :control row on top, then
  # :master and :detail share one tall gridRow, split evenly across page_cols
  # (12/12 of 24) via the same band() helper :exec uses. Layout only: the
  # control->detail filter wiring is authored per-element-spec (see
  # composition.md), not emitted here.
  def self.compose_master_detail(elements, page_cols)
    render_bands(elements, :master_detail, page_cols)
  end

  # :overview — an optional stack of full-width bands (each skipped if empty):
  # :header -> :control (filter row) -> :kpi (tall: comparative cards + Δ badges) -> :kpi2
  # (optional 2nd KPI row, e.g. rates) -> :trend -> :pivot -> :base. Every band
  # even-splits its elements across page_cols via the same band() helper
  # :exec/:master_detail use; only vertical stacking differs.
  def self.compose_overview(elements, page_cols)
    render_bands(elements, :overview, page_cols)
  end

  def self.compose(elements, pattern: :exec, page_cols: 24)
    case pattern.to_sym
    when :exec then compose_exec(elements, page_cols)
    when :master_detail then compose_master_detail(elements, page_cols)
    when :overview then compose_overview(elements, page_cols)
    else raise ArgumentError, "compose: unknown pattern #{pattern.inspect}"
    end
  end

  # tabbed_container: a Sigma {kind:"tabbed-container"} page element + its
  # <TabbedContainer> layout XML. Per the live-verified shape: tabs[] in the
  # JSON element are LABELS ONLY (no children); the <Tab> children in the
  # layout map to tabs[] BY POSITION (1st <Tab> = 1st label).
  #
  # GOTCHA (verified): inside a <Tab>, callers pass BARE <LayoutElement>
  # children only -- a nested <GridContainer> inside a <Tab> scrambles tab
  # render order. The <Tab> is itself a mini-grid (gridTemplateColumns /
  # gridTemplateRows), so elements position directly within it; no inner
  # GridContainer is needed.
  def self.tabbed_container(id:, tabs:, grid_column:, grid_row:, tab_bar_alignment: 'start')
    raise ArgumentError, 'tabbed_container: id required' if id.to_s.empty?
    raise ArgumentError, 'tabbed_container: tabs required' if tabs.nil? || tabs.empty?
    tabs.each do |t|
      raise ArgumentError, 'tabbed_container: every tab requires a non-empty name' if t[:name].to_s.empty?
    end
    element = {
      'id' => id,
      'kind' => 'tabbed-container',
      'tabs' => tabs.map { |t| { 'name' => t[:name] } },
      'tabBar' => { 'alignment' => tab_bar_alignment }
    }
    tab_blocks = tabs.map do |t|
      "  <Tab gridTemplateColumns=\"repeat(24, 1fr)\" gridTemplateRows=\"auto\">\n" \
      "#{indent(t[:inner])}\n" \
      '  </Tab>'
    end
    layout = "<TabbedContainer elementId=\"#{id}\" type=\"tabbed-container\" " \
             "gridColumn=\"#{grid_column}\" gridRow=\"#{grid_row}\">\n" \
             "#{tab_blocks.join("\n")}\n" \
             '</TabbedContainer>'
    { element: element, layout: layout }
  end

  # indent: prepend one indent level (2 spaces, this file's per-level unit)
  # to every line of a multi-line XML fragment -- used to nest a tab's bare
  # <LayoutElement> lines (already 2-space indented by le()) one level
  # deeper inside a <Tab> (-> 4 spaces total, matching the verified shape).
  def self.indent(text)
    text.to_s.split("\n").map { |line| "  #{line}" }.join("\n")
  end
end
