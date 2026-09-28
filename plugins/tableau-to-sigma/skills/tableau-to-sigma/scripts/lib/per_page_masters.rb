# frozen_string_literal: true
#
# per_page_masters.rb — PLAN-v3 PR-17: per-page (per-dashboard) master instances.
#
# THE DEFECT (V5.6-CONTROLS-AUDIT D11, the multi-page control-bind failure). The
# mechanical build hardwires ONE hidden master table on the "Data" page; every
# content page's charts, helpers, and controls reference that single
# `elementId: master`. Sigma propagates a control's filter along SOURCE CHAINS,
# not page boundaries — so on a multi-page (page-per-dashboard) workbook every
# page's controls compose on the SAME master: page A's control refilters page
# B's charts, page copies AND-compose, and no gate sees it. A single master
# shared across pages is structurally wrong under Sigma's control model.
#
# THE FIX. Give each content page that uses the master its OWN clone of the
# master (and of the hidden helper closure it draws on), with page-scoped ids
# (`master-<page-slug>`, `<helper-id>-<page-slug>`). Every clone still lives on
# the hidden Data page (so nothing renders a stray table on a content page —
# the phase-5 "giant table" trap is avoided), but page A's charts/controls now
# reference `master-<A>` and page B's reference `master-<B>`: a control's
# filter reaches exactly its own page's tiles and no others.
#
# STAGING (PR-17 is flag-staged for one release). This transform is a FINAL,
# opt-in structural pass — the orchestrator only runs it under
# `--per-page-masters`. It is ALSO self-gating: with 0 or 1 content page drawing
# on the master there is nothing to de-share, so `split!` is a no-op and the
# emitted spec is byte-identical to the shared-master build. Only when >=2
# pages need a master does it clone. Default OFF ⇒ every existing migration
# (single- AND multi-page) is unchanged until a caller opts in.
#
# Column ids are preserved on every clone (only the ELEMENT id changes), so a
# control's `filters[].columnId` target still resolves and name-based chart
# formulas ([Master/<col>]) are untouched. Reference rewriting is purely
# STRUCTURAL: every hash value under an `elementId` key that names a cloned
# element is repointed — this covers `source.elementId`, a control's
# `source.source.elementId` value list, and `filters[].source.elementId`
# targets uniformly, with no JSON-text splicing.
#
# Tableau-specific (NOT a shared/vendored lib): the master/Data-page shape it
# operates on is produced by this plugin's mechanical builder.
require 'set'
require 'json'
# Ruby 2.6 floor (macOS system ruby): this file uses a 2.7+ Enumerable
# method. Polyfilled rather than rewritten — see shared/lib/ruby_compat.rb.
require_relative 'ruby_compat'

module PerPageMasters
  module_function

  # The hidden Data page (master + helper elements). Matched by id or name so it
  # works for both the mechanical build ('page-data'/'Data') and the standalone
  # build-workbook-spec assembler.
  def data_page(spec)
    (spec['pages'] || []).find do |p|
      p.is_a?(Hash) && (p['id'].to_s.downcase.include?('data') || p['name'].to_s == 'Data')
    end
  end

  def content_pages(spec, dp)
    (spec['pages'] || []).reject { |p| p.equal?(dp) }
  end

  # Structural sources that make a page consume Data-page elements. A copied
  # control's filters can still contain workbook-wide targets at this point;
  # those are NOT page dependencies and must not pull every page's helper
  # closure into every clone.
  def page_source_ids(page)
    nodes = (page['elements'] || []).map do |element|
      if element['kind'] == 'control'
        { 'source' => element['source'] }
      else
        element
      end
    end
    referenced_ids(nodes)
  end

  # Every elementId reference value reachable inside a node (source.elementId,
  # source.source.elementId, filters[].source.elementId, ...).
  def referenced_ids(node)
    ids = []
    walk = lambda do |n|
      case n
      when Hash
        n.each do |k, v|
          ids << v if k == 'elementId' && v.is_a?(String)
          walk.call(v)
        end
      when Array
        n.each { |v| walk.call(v) }
      end
    end
    walk.call(node)
    ids
  end

  # Repoint every `elementId` value named in `mapping` (old id => new id), in
  # place. Non-elementId strings and unmapped ids are left untouched.
  def rewrite_refs!(node, mapping)
    walk = lambda do |n|
      case n
      when Hash
        n.each do |k, v|
          if k == 'elementId' && v.is_a?(String) && mapping.key?(v)
            n[k] = mapping[v]
          else
            walk.call(v)
          end
        end
      when Array
        n.each { |v| walk.call(v) }
      end
    end
    walk.call(node)
    node
  end

  # Transitive closure over the Data-page pool: the seed ids plus every pool
  # element they reference (helper -> master, helper -> helper), following only
  # ids that name a pool element.
  def pool_closure(pool_by_id, seed_ids)
    seen = Set.new
    stack = seed_ids.select { |id| pool_by_id.key?(id) }
    until stack.empty?
      id = stack.pop
      next if seen.include?(id)
      seen << id
      referenced_ids(pool_by_id[id]).each do |r|
        stack << r if pool_by_id.key?(r) && !seen.include?(r)
      end
    end
    seen.to_a
  end

  # Source-before-consumer order for the rebuilt Data page (the POST resolves
  # refs in document order). Kahn-style: an element is placeable once no still-
  # unplaced sibling is one of its referenced ids. A cycle (impossible for
  # generated helpers) falls back to insertion order for the stuck remainder.
  def toposort(els)
    by_id = els.each_with_object({}) { |e, h| h[e['id']] = e if e.is_a?(Hash) && e['id'] }
    remaining = els.dup
    ordered = []
    until remaining.empty?
      batch = remaining.select do |e|
        refs = referenced_ids(e)
        remaining.none? { |o| !o.equal?(e) && o.is_a?(Hash) && refs.include?(o['id']) && by_id.key?(o['id']) }
      end
      batch = [remaining.first] if batch.empty?
      ordered.concat(batch)
      remaining -= batch
    end
    ordered
  end

  def slugify(name)
    s = name.to_s.downcase.gsub(/[^a-z0-9]+/, '-').gsub(/-+/, '-')
    s = s.sub(/^-/, '').sub(/-$/, '')
    s.empty? ? 'p' : s[0, 40]
  end

  def page_suffix(page, used)
    base = slugify(page['name'] || page['id'])
    slug = base
    n = 1
    while used[slug]
      n += 1
      slug = "#{base}-#{n}"
    end
    used[slug] = true
    slug
  end

  def deep_dup(el)
    JSON.parse(JSON.generate(el))
  end

  # Keep only the master columns actually referenced by one page's charts,
  # controls, helper closure, master filters, or another retained master calc.
  # This runs only on per-page clones; the <=1-page no-op contract remains
  # byte-identical. If no dependency can be proven, fail safe by keeping all.
  def slim_master!(master, consumers)
    columns = master['columns'] || []
    return { before: columns.size, after: columns.size } if columns.empty?

    master_name = master['name'].to_s
    names = Set.new
    ids = Set.new
    scan = lambda do |node|
      case node
      when Hash
        node.each do |key, value|
          ids << value if key == 'columnId' && value.is_a?(String)
          scan.call(value)
        end
      when Array
        node.each { |value| scan.call(value) }
      when String
        node.scan(/\[#{Regexp.escape(master_name)}\/([^\]]+)\]/) { |m| names << m[0] }
      end
    end
    scan.call(consumers)
    # Filters/defaults can live directly on the master. Exclude columns/order,
    # otherwise the master's own declaration would retain every column.
    scan.call(master.reject { |key, _| %w[columns order].include?(key) })

    by_name = columns.each_with_object({}) { |column, out| out[column['name']] = column if column['name'] }
    needed = columns.select { |column| names.include?(column['name']) || ids.include?(column['id']) }
                    .map { |column| column['id'] }.to_set
    return { before: columns.size, after: columns.size } if needed.empty?

    # Calculated master columns may depend on sibling columns by bare [Name].
    # Close those dependencies before pruning so formula order remains valid.
    changed = true
    while changed
      changed = false
      columns.select { |column| needed.include?(column['id']) }.each do |column|
        column['formula'].to_s.scan(/\[([^\]\/]+)\]/) do |match|
          dependency = by_name[match[0]]
          next unless dependency && !needed.include?(dependency['id'])
          needed << dependency['id']
          changed = true
        end
      end
    end

    before = columns.size
    master['columns'] = columns.select { |column| needed.include?(column['id']) }
    master['order'] = (master['order'] || []).select { |id| needed.include?(id) }
    { before: before, after: master['columns'].size }
  end

  # Split the ONE shared master into per-page instances. Mutates `spec` in place.
  # Returns a summary hash including aggregate master width before/after slimming.
  #
  # No-op (applied:false) unless >=2 content pages reference a Data-page element
  # — the single-consumer case keeps the shared master and stays byte-identical
  # to the pre-PR-17 build.
  def split!(spec)
    result = { applied: false, pages: 0, masters: 0, clones: 0,
               master_columns_before: 0, master_columns_after: 0 }
    return result unless spec.is_a?(Hash)
    dp = data_page(spec)
    return result unless dp
    pool = dp['elements'] || []
    return result if pool.empty?
    pool_by_id = pool.each_with_object({}) { |e, h| h[e['id']] = e if e.is_a?(Hash) && e['id'] }
    return result if pool_by_id.empty?

    cpages = content_pages(spec, dp)
    using = cpages.select { |pg| page_source_ids(pg).any? { |id| pool_by_id.key?(id) } }
    return result if using.size <= 1 # nothing to de-share
    # FAST-PATH / handoff re-entry receives the already-split authored spec.
    # Running the transform again used to produce ids such as
    # `master-overview-overview`, remove the first-generation masters, and
    # leave layout XML pointing at elements that no longer existed. Detect the
    # page suffix contract before cloning: every consuming page already reaches
    # at least one Data-page element ending in its own unique page suffix.
    reentry_slugs = {}
    already_split = using.all? do |page|
      suffix = page_suffix(page, reentry_slugs)
      page_source_ids(page).any? do |id|
        pool_by_id.key?(id) && id.end_with?("-#{suffix}")
      end
    end
    return result if already_split

    # A master is a Data-page table sourced from the data model (source.kind ==
    # 'data-model'); helpers source another workbook-local element. Used only for
    # the summary count.
    master_ids = pool.select do |e|
      e.is_a?(Hash) && e['kind'] == 'table' && e.dig('source', 'kind') == 'data-model'
    end.map { |e| e['id'] }.to_set

    new_pool = []
    used_slugs = {}
    masters_made = Set.new
    using.each do |pg|
      slug = page_suffix(pg, used_slugs)
      closure = pool_closure(pool_by_id, page_source_ids(pg))
      mapping = closure.each_with_object({}) { |id, h| h[id] = "#{id}-#{slug}" }
      page_element_ids = (pg['elements'] || []).filter_map { |element| element['id'] }.to_set
      (pg['elements'] || []).select { |element| element['kind'] == 'control' }.each do |control|
        control['filters'] = (control['filters'] || []).select do |target|
          target_id = target.dig('source', 'elementId')
          closure.include?(target_id) || page_element_ids.include?(target_id)
        end
      end
      page_clones = []
      closure.each do |id|
        clone = deep_dup(pool_by_id[id])
        clone['id'] = mapping[id]
        rewrite_refs!(clone, mapping) # helper->master, helper->helper internal refs
        new_pool << clone
        page_clones << clone
        masters_made << clone['id'] if master_ids.include?(id)
      end
      rewrite_refs!(pg['elements'], mapping)
      page_clones.select { |clone| master_ids.include?(mapping.key(clone['id'])) }.each do |master|
        consumers = pg['elements'] + page_clones.reject { |clone| clone.equal?(master) }
        widths = slim_master!(master, consumers)
        result[:master_columns_before] += widths[:before]
        result[:master_columns_after] += widths[:after]
      end
    end

    # Every content page that used the pool now references a clone, so the
    # original pool elements are unreferenced — replace them with the clones,
    # kept in source-before-consumer order.
    dp['elements'] = toposort(new_pool)

    result[:applied] = true
    result[:pages]   = using.size
    result[:masters] = masters_made.size
    result[:clones]  = new_pool.size
    result
  end
end
