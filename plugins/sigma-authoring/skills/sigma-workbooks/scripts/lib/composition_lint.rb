# frozen_string_literal: true
# composition_lint.rb — verify a composed layout XML fragment: each gridRow band
# tiles the columns [1, page_cols+1) with no gap/overlap, and bands are contiguous
# vertically with no gap/overlap. A top-level <Container> (Styling's header /
# section_card card wrappers — scripts/lib/styling.rb) participates in PAGE band
# tiling exactly like an <Element>: its own gridColumn/gridRow is the rect
# checked against the page. Its DIRECT CHILDREN are then validated the SAME way
# but against the container's OWN rect — column count from the container's
# gridTemplateColumns ("repeat(N, ...)" -> N; absent -> page_cols), and rows
# starting at 1 (children use container-relative row numbering, same convention
# as Styling.header/section_card). Nesting-aware — a stack walk so a nested
# container's own close tag can't truncate an outer container's body. Returns
# an array of human-readable errors ([] = clean).
module CompositionLint
  # Canonical GET/POST grammar is Element + Container. The two old aliases
  # remain parseable so the linter can inspect historical snapshots, but every
  # helper in this package emits only the canonical names.
  CONTAINER_TAGS = %w[Container GridContainer].freeze
  ELEMENT_TAGS = %w[Element LayoutElement].freeze
  TOKENS = %r{
    </(?:#{CONTAINER_TAGS.join('|')})>|
    <(?:#{CONTAINER_TAGS.join('|')})\b[^>]*?/?>|
    <(?:#{ELEMENT_TAGS.join('|')})\b[^>]*?/?>
  }mx

  module_function

  # Pull {id:, c0:, c1:, r0:, r1:} out of a <Container ...> or
  # <Element ...> opening/self-closing tag, independent of attribute
  # order (a Container carries extra attrs — type, gridTemplateColumns,
  # gridTemplateRows — between elementId and gridColumn/gridRow).
  def self.rect_of(tag)
    { id: tag[/elementId="([^"]*)"/, 1],
      c0: tag[/gridColumn="\s*(\d+)/, 1].to_i, c1: tag[/gridColumn="\s*\d+\s*\/\s*(\d+)/, 1].to_i,
      r0: tag[/gridRow="\s*(\d+)/, 1].to_i, r1: tag[/gridRow="\s*\d+\s*\/\s*(\d+)/, 1].to_i }
  end

  # A container's own local column count, from its gridTemplateColumns
  # ("repeat(N, ...)" -> N); nil (fall back to page_cols) if absent/unparsed.
  def self.tmpl_cols_of(tag)
    tmpl = tag[/gridTemplateColumns="([^"]*)"/, 1]
    rep = tmpl && tmpl[/repeat\(\s*(\d+)/, 1]
    rep && rep.to_i
  end

  # Parse the top-level entries of a layout XML fragment into a tree:
  # [{type: :element|:container, id:, c0:, c1:, r0:, r1:, tmpl_cols:, children: [...]}, ...]
  # (tmpl_cols/children only meaningful for :container). A nesting-aware
  # stack walk so an inner container's </Container> can't truncate an
  # outer one's body.
  def self.parse(xml)
    roots = []
    stack = []
    xml.to_s.scan(TOKENS) do
      tag = Regexp.last_match(0)
      tag_name = tag[%r{</?([A-Za-z]+)}, 1]
      if tag.start_with?('</') && CONTAINER_TAGS.include?(tag_name)
        node = stack.pop
        (stack.empty? ? roots : stack.last[:children]) << node if node
      elsif CONTAINER_TAGS.include?(tag_name)
        node = rect_of(tag).merge(type: :container, tmpl_cols: tmpl_cols_of(tag), children: [])
        if tag.end_with?('/>')
          (stack.empty? ? roots : stack.last[:children]) << node
        else
          stack.push(node)
        end
      else
        node = rect_of(tag).merge(type: :element)
        (stack.empty? ? roots : stack.last[:children]) << node
      end
    end
    roots.concat(stack) # tolerate unclosed containers rather than dropping them
    roots
  end

  # Core check shared by the page and every container: `members` (rects with
  # id/c0/c1/r0/r1) must tile every atomic row slice across
  # [1, ncols+1), starting at row 1, with no gap/overlap. Slicing at every
  # member boundary handles both ordinary horizontal bands and mosaics where
  # one tall left rectangle spans two shorter right-side rectangles.
  def self.check_region(members, ncols, label)
    return [] if members.empty?
    errors = []
    members.each do |member|
      if member[:c0] >= member[:c1] || member[:r0] >= member[:r1]
        errors << "#{label}: #{member[:id]} has a non-positive layout rectangle"
      end
    end

    row_bounds = members.flat_map { |e| [e[:r0], e[:r1]] }.uniq.sort
    errors << "#{label}: top band does not start at row 1 (starts at #{row_bounds.first})" if row_bounds.first != 1

    row_bounds.each_cons(2) do |r0, r1|
      cols = members.select { |e| e[:r0] <= r0 && e[:r1] >= r1 }
                    .sort_by { |e| [e[:c0], e[:c1]] }
      if cols.empty?
        errors << "#{label}: vertical gap across rows #{r0}/#{r1}"
        next
      end
      if cols.first[:c0] != 1
        errors << "#{label}: slice rows #{r0}/#{r1}: does not start at column 1 (starts at #{cols.first[:c0]})"
      end
      if cols.last[:c1] != ncols + 1
        errors << "#{label}: slice rows #{r0}/#{r1}: does not fill to #{ncols + 1} (dead columns; ends at #{cols.last[:c1]})"
      end
      cols.each_cons(2) do |a, b|
        next if a[:c1] == b[:c0]
        defect = a[:c1] > b[:c0] ? 'overlap' : 'gap'
        errors << "#{label}: slice rows #{r0}/#{r1}: column #{defect} between #{a[:id]} and #{b[:id]} " \
                  "(#{a[:c1]} vs #{b[:c0]})"
      end
    end
    errors
  end

  # Recursively check every <Container>'s direct children against the
  # container's OWN rect (not the page).
  def self.check_containers(node, page_cols)
    return [] unless node[:type] == :container
    ncols = node[:tmpl_cols] || page_cols
    errors = check_region(node[:children], ncols, "container #{node[:id]}")
    node[:children].each { |child| errors.concat(check_containers(child, page_cols)) }
    errors
  end

  def self.check(layout_xml, page_cols: 24)
    roots = parse(layout_xml)
    return ['no <Element> tags found'] if roots.empty?
    errors = check_region(roots, page_cols, 'page')
    roots.each { |node| errors.concat(check_containers(node, page_cols)) }
    errors
  end
end
