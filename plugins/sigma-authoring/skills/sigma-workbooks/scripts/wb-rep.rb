#!/usr/bin/env ruby
# wb-rep.rb — element-level file representation ("rep") of a Sigma workbook spec.
#
# The Sigma spec API is whole-workbook only (GET/PUT the entire spec). Large
# multi-page workbooks blow up an agent's context when edited as one document.
# This tool makes the ELEMENT the unit of work by exploding the spec into a
# directory of small files, and reassembling them on push:
#
#   <rep>/
#     workbook.yaml              outer metadata + document fields other than collections/layout
#     elements/
#       010-revenue-kpi.yaml     flat document.elements entries (one element per file)
#       020-sales-by-region.yaml
#     pages/
#       010-overview/
#         _page.yaml             page metadata (id, name, visibility/background)
#         _layout.xml            this page's <Page> block from document.layout
#     overlays/                  same pattern: _overlay.yaml + _layout.xml
#     panels/                    same pattern: _panel.yaml + _layout.xml
#     .sigma/                    plumbing — do not hand-edit
#       manifest.yaml            workbookId, url, baseUrl, pulledAt
#       snapshot.yaml            full spec as last synced with the server
#       layout-preamble.xml      anything before the first <Page> in the layout
#
# Edit element files with normal file tools; nothing here is a new format —
# each file is a verbatim slice of the spec. push reassembles, diffs against
# the snapshot, refuses to clobber remote edits, validates, and PUTs.
#
# Commands:
#   pull <workbook-id> [dir]     GET spec and explode (refuses to overwrite a dirty rep)
#   status [dir]                 element-level diff: working files vs last-synced snapshot
#   push [dir]                   reassemble -> drift-check -> validate -> PUT (or POST create)
#   assemble [dir] [-o file]     print/write the reassembled spec without pushing
#   lint [dir|spec-file]         offline: layout coverage + filter reference integrity
#   import <spec.yaml> [dir]     explode an existing local spec file (create mode: push POSTs)
#   verify <spec-file>           dry-run (Beta endpoint): POST to /v2/workbooks/spec/verify —
#                                zero-persistence schema/reference check; prints valid: true or
#                                the errors array
#   render [dir] [--page X]      export page(s) (or --element <id>) as PNG into <dir>/renders/
#                                — LOOK at what you built and iterate; renders server state
#
# Flags: --force (pull: overwrite dirty rep; push: ignore remote drift)
#        --no-validate (push: skip validate-spec.sh)
#        -o FILE (assemble: write instead of stdout)
#
# Env: SIGMA_BASE_URL, SIGMA_API_TOKEN (obtain via the sigma-api skill / get-token.sh).
# Exit codes: 0 ok / clean, 1 differences or push aborted, 2 usage or API error.

require 'yaml'
require 'json'
require 'net/http'
require 'uri'
require 'fileutils'
require 'time'
require 'tmpdir'
require_relative 'lib/ruby_compat'
require_relative 'lib/code_rep'

RESPONSE_ONLY = %w[workbookId url documentVersion latestDocumentVersion ownerId
                   createdBy updatedBy createdAt updatedAt].freeze
CREATE_METADATA = %w[name folderId description].freeze
COLLECTIONS = {
  'pages' => '_page.yaml',
  'overlays' => '_overlay.yaml',
  'panels' => '_panel.yaml'
}.freeze
XML_PROLOG = %(<?xml version="1.0" encoding="utf-8"?>\n).freeze

def die(msg, code = 2)
  warn "wb-rep: #{msg}"
  exit code
end

def api_raw(method, path, body = nil, content_type: 'application/yaml', accept: 'application/yaml')
  base = ENV['SIGMA_BASE_URL'] or die 'SIGMA_BASE_URL not set — run the sigma-api skill / eval "$(get-token.sh)" first'
  token = ENV['SIGMA_API_TOKEN'] or die 'SIGMA_API_TOKEN not set — run the sigma-api skill / eval "$(get-token.sh)" first'
  uri = URI("#{base.sub(%r{/$}, '')}#{path}")
  req = { get: Net::HTTP::Get, put: Net::HTTP::Put, post: Net::HTTP::Post }.fetch(method).new(uri)
  req['Authorization'] = "Bearer #{token}"
  req['Accept'] = accept
  if body
    req['Content-Type'] = content_type
    req.body = body
  end
  Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == 'https', read_timeout: 120) { |h| h.request(req) }
end

def api(method, path, body = nil, **opts)
  res = api_raw(method, path, body, **opts)
  unless res.code.to_i.between?(200, 299)
    die "#{method.to_s.upcase} #{path} -> HTTP #{res.code}\n#{res.body}", 2
  end
  res.body
end

def slug(s)
  out = s.to_s.downcase.gsub(/[^a-z0-9]+/, '-').gsub(/^-+|-+$/, '')
  out.empty? ? nil : out[0, 60]
end

def strip_response_only(spec)
  spec.reject { |k, _| RESPONSE_ONLY.include?(k) }
end

# Canonical on-disk form mirrors the API: outer metadata plus one wrapped
# document. Legacy flat artifacts are accepted on import and normalized here.
def canonical_spec(spec)
  Sigma::CodeRep.metadata(spec).merge('document' => Sigma::CodeRep.document(spec))
end

def document(spec)
  Sigma::CodeRep.document(spec)
end

# Split the top-level layout XML into [preamble, { page_id => chunk }].
# Chunks are verbatim byte slices so an untouched rep reassembles identically.
# A layout region block opens with <Page>, <Overlay>, or <Panel> (header/
# sidebar). Live GET specs emit a distinct <Panel> tag for header/sidebar
# panels (live-confirmed 2026-08-10) and <Overlay> for overlays, alongside
# <Page>; each is a top-level, id-keyed chunk. Splitting on all three keeps a
# panel/overlay body from being folded into the preceding page chunk.
LAYOUT_REGION_TAGS = %w[Page Overlay Panel].freeze
def split_layout(layout)
  return [XML_PROLOG, {}] if layout.nil? || layout.empty?
  starts = []
  layout.scan(/<(?:#{LAYOUT_REGION_TAGS.join('|')})[\s>]/) { starts << Regexp.last_match.begin(0) }
  return [layout, {}] if starts.empty?
  preamble = layout[0...starts.first]
  chunks = {}
  starts.each_with_index do |s, i|
    chunk = layout[s...(starts[i + 1] || layout.length)]
    id = chunk[/\A<(?:#{LAYOUT_REGION_TAGS.join('|')})[^>]*\bid="([^"]*)"/, 1]
    warn "wb-rep: warning — layout region block without an id attribute; it will be appended last" unless id
    chunks[id || "_orphan#{i}"] = chunk
  end
  [preamble, chunks]
end

def explode(spec, dir, raw_yaml:, manifest_extra: {})
  spec = canonical_spec(spec)
  doc = document(spec).dup
  elements = doc.delete('elements') || []
  collections = COLLECTIONS.keys.to_h { |key| [key, doc.delete(key) || []] }
  layout = doc.delete('layout')
  preamble, layout_chunks = split_layout(layout)
  top = strip_response_only(spec).merge('document' => doc)

  (COLLECTIONS.keys + ['elements']).each { |name| FileUtils.rm_rf(File.join(dir, name)) }
  FileUtils.mkdir_p(File.join(dir, 'elements'))
  FileUtils.mkdir_p(File.join(dir, '.sigma'))
  File.write(File.join(dir, 'workbook.yaml'), YAML.dump(top))
  File.write(File.join(dir, '.sigma', 'layout-preamble.xml'), preamble)

  collections.each do |collection, entries|
    FileUtils.mkdir_p(File.join(dir, collection))
    used_dirs = {}
    entries.each_with_index do |entry, index|
      base = slug(entry['name']) || slug(entry['id']) || "#{collection.sub(/s\z/, '')}-#{index + 1}"
      base += "-#{entry['id']}"[0, 20] if used_dirs[base]
      used_dirs[base] = true
      entry_dir = File.join(dir, collection, format('%03d-%s', (index + 1) * 10, base))
      FileUtils.mkdir_p(entry_dir)
      File.write(File.join(entry_dir, COLLECTIONS.fetch(collection)), YAML.dump(entry))
      if (chunk = layout_chunks.delete(entry['id']))
        File.write(File.join(entry_dir, '_layout.xml'), chunk)
      end
    end
  end

  used = {}
  elements.each_with_index do |el, index|
    base = slug(el['name']) || slug(el['kind']) || 'element'
    base += "-#{slug(el['id']) || index}" if used[base]
    used[base] = true
    File.write(File.join(dir, 'elements', format('%03d-%s.yaml', (index + 1) * 10, base)), YAML.dump(el))
  end
  layout_chunks.each_key do |k|
    warn "wb-rep: warning — layout region block id=\"#{k}\" matches no page, overlay, or panel; chunk dropped"
  end

  File.write(File.join(dir, '.sigma', 'snapshot.yaml'), YAML.dump(canonical_spec(YAML.load(raw_yaml))))
  File.write(File.join(dir, '.sigma', 'manifest.yaml'),
             YAML.dump({ 'baseUrl' => ENV['SIGMA_BASE_URL'], 'pulledAt' => Time.now.utc.iso8601 }.merge(manifest_extra)))
end

def load_yaml_file(path)
  YAML.load(File.read(path)) || {}
rescue Psych::SyntaxError => e
  die "YAML parse error in #{path}: #{e.message}"
end

def assemble(dir)
  wb_path = File.join(dir, 'workbook.yaml')
  die "no workbook.yaml in #{dir} — not a rep directory (run pull/import first)" unless File.exist?(wb_path)
  spec = canonical_spec(load_yaml_file(wb_path))
  doc = document(spec).dup
  preamble_path = File.join(dir, '.sigma', 'layout-preamble.xml')
  preamble = File.exist?(preamble_path) ? File.read(preamble_path) : XML_PROLOG

  layout_parts = []
  COLLECTIONS.each do |collection, metadata_file|
    entries = []
    Dir[File.join(dir, collection, '*/')].sort.each do |entry_dir|
      metadata_path = File.join(entry_dir, metadata_file)
      die "missing #{metadata_file} in #{entry_dir}" unless File.exist?(metadata_path)
      entries << load_yaml_file(metadata_path)
      layout_path = File.join(entry_dir, '_layout.xml')
      layout_parts << File.read(layout_path) if File.exist?(layout_path)
    end
    doc[collection] = entries
  end
  doc['elements'] = Dir[File.join(dir, 'elements', '*.yaml')].sort.map { |f| load_yaml_file(f) }
  doc['layout'] = preamble + layout_parts.join unless layout_parts.empty?
  spec.merge('document' => doc)
end

# ---- diffing -------------------------------------------------------------

def index_by_id(arr)
  (arr || []).each_with_index.map { |x, i| [x['id'] || "@#{i}", x] }.to_h
end

def changed_keys(a, b)
  (a.keys | b.keys).reject { |k| a[k] == b[k] }
end

def diff_specs(old_spec, new_spec)
  old_spec = canonical_spec(old_spec)
  new_spec = canonical_spec(new_spec)
  lines = []
  ot = strip_response_only(old_spec).reject { |k, _| k == 'document' }
  nt = strip_response_only(new_spec).reject { |k, _| k == 'document' }
  changed_keys(ot, nt).each { |k| lines << "~ workbook.#{k}" }

  old_doc = document(old_spec)
  new_doc = document(new_spec)
  old_doc_meta = old_doc.reject { |k, _| COLLECTIONS.key?(k) || %w[elements layout].include?(k) }
  new_doc_meta = new_doc.reject { |k, _| COLLECTIONS.key?(k) || %w[elements layout].include?(k) }
  changed_keys(old_doc_meta, new_doc_meta).each { |k| lines << "~ document.#{k}" }

  _, old_layout = split_layout(old_doc['layout'])
  _, new_layout = split_layout(new_doc['layout'])
  COLLECTIONS.each_key do |collection|
    old_entries = index_by_id(old_doc[collection])
    new_entries = index_by_id(new_doc[collection])
    (old_entries.keys | new_entries.keys).each do |id|
      old_entry = old_entries[id]
      new_entry = new_entries[id]
      label = (new_entry || old_entry)['name'] || id
      singular = collection.sub(/s\z/, '')
      if old_entry.nil?
        lines << "+ #{singular} \"#{label}\""
      elsif new_entry.nil?
        lines << "- #{singular} \"#{label}\""
      else
        meta = changed_keys(old_entry, new_entry)
        lines << "~ #{singular} \"#{label}\" [#{meta.join(', ')}]" unless meta.empty?
        lines << "~ #{singular} \"#{label}\" layout" if old_layout[id] != new_layout[id]
      end
    end
  end

  old_elements = index_by_id(old_doc['elements'])
  new_elements = index_by_id(new_doc['elements'])
  (old_elements.keys | new_elements.keys).each do |id|
    old_element = old_elements[id]
    new_element = new_elements[id]
    label = (new_element || old_element)['name'] || (new_element || old_element)['kind'] || id
    if old_element.nil?
      lines << "+ element \"#{label}\" (#{id})"
    elsif new_element.nil?
      lines << "- element \"#{label}\" (#{id})"
    elsif old_element != new_element
      lines << "~ element \"#{label}\" (#{id}) [#{changed_keys(old_element, new_element).join(', ')}]"
    end
  end
  lines
end

def snapshot_spec(dir)
  path = File.join(dir, '.sigma', 'snapshot.yaml')
  File.exist?(path) ? canonical_spec(YAML.load(File.read(path))) : nil
end

def manifest(dir)
  path = File.join(dir, '.sigma', 'manifest.yaml')
  File.exist?(path) ? YAML.load(File.read(path)) : {}
end

def rep_dirty?(dir)
  snap = snapshot_spec(dir)
  return false unless snap && File.exist?(File.join(dir, 'workbook.yaml'))
  !diff_specs(snap, assemble(dir)).empty?
end

def lint_layout_coverage(spec)
  doc = document(spec)
  layout = doc['layout'].to_s
  elements = Array(doc['elements'])
  declared = index_by_id(elements)
  referenced_all = layout.scan(/\belementId="([^"]+)"/).flatten
  referenced = referenced_all.uniq
  regions = COLLECTIONS.keys.flat_map { |collection| Array(doc[collection]) }
  declared_region_ids = regions.map { |region| region['id'] }.compact.uniq
  referenced_region_ids = layout.scan(/<(?:Page|Overlay|Panel)\b[^>]*\bid="([^"]+)"/).flatten.uniq
  issues = []

  elements.group_by { |element| element['id'] }.each do |id, grouped|
    issues << "duplicate document.elements id #{id.inspect}" if id && grouped.length > 1
  end
  referenced_all.group_by { |id| id }.each do |id, occurrences|
    issues << "element #{id.inspect} is placed #{occurrences.length} times" if occurrences.length > 1
  end
  declared.each do |id, element|
    next if referenced.include?(id)
    issues << "element \"#{element['name'] || id}\" is not placed"
  end
  (referenced - declared.keys).each do |id|
    issues << "layout references undeclared elementId #{id.inspect}"
  end
  (referenced_region_ids - declared_region_ids).each do |id|
    issues << "layout references undeclared page/overlay/panel id #{id.inspect}"
  end
  (declared_region_ids - referenced_region_ids).each do |id|
    issues << "page/overlay/panel #{id.inspect} is missing from layout"
  end

  die "layout validation failed:\n  - #{issues.join("\n  - ")}", 1 unless issues.empty?
end

# Every `filters[].columnId` must name a column that is declared on the element
# that owns it. Two shapes, per reference/specification/controls.md:
#   - control wiring:      { source: { kind: table, elementId }, columnId }
#                          -> the column lives on the TARGET element
#   - element predicate:   { id, columnId, kind: list|top-n|... }
#                          -> the column lives on the OWNING element
#
# Sigma's /v2/workbooks/spec/verify catches the element-predicate case but NOT
# control wiring (measured 2026-08-20): a control filtering a nonexistent column
# returns valid:true, saves with the bogus id intact, and compiles with zero
# errors — the control silently stops filtering. This closes that gap offline.
def lint_reference_integrity(spec)
  doc = document(spec)
  elements = Array(doc['elements'])
  declared = index_by_id(elements)
  columns = elements.each_with_object({}) do |element, acc|
    acc[element['id']] = Array(element['columns']).map { |column| column['id'] }.compact
  end
  issues = []

  elements.each do |element|
    label = element['controlId'] || element['name'] || element['id']
    Array(element['filters']).each_with_index do |filter, idx|
      next unless filter.is_a?(Hash)
      column_id = filter['columnId']
      next if column_id.nil?

      source = filter['source']
      target_id = source.is_a?(Hash) ? source['elementId'] : nil
      if target_id && !declared.key?(target_id)
        issues << "#{label} filters[#{idx}] targets unknown element #{target_id.inspect}"
        next
      end
      target_id ||= element['id']
      next if Array(columns[target_id]).include?(column_id)

      issues << "#{label} filters[#{idx}] references column #{column_id.inspect} " \
                "which is not declared on element #{target_id.inspect}"
    end
  end

  die "reference integrity check failed:\n  - #{issues.join("\n  - ")}", 1 unless issues.empty?
end

AGGREGATE_FORMULA = /\b(?:sum|count|countdistinct|avg|average|min|max|median|percentile|stddev|variance)\s*\(/i.freeze
SINGLE_COLUMN_POINTER_FIELDS = %w[
  xAxis value comparisonColumn holeValue geography latitude longitude region
  size category stage series
].freeze

def lint_column_references(spec)
  elements = Array(document(spec)['elements'])
  declared_elements = index_by_id(elements)
  columns_by_element = elements.each_with_object({}) do |element, columns|
    columns[element['id']] = Array(element['columns']).filter_map do |column|
      column['id'] if column.is_a?(Hash)
    end
  end
  issues = []

  elements.each do |element|
    label = element['name'] || element['controlId'] || element['id'] || '(unnamed)'
    column_ids = columns_by_element[element['id']] || []

    visit = lambda do |value, path|
      case value
      when Hash
        value.each do |key, child|
          if key.to_s.downcase == 'columnid' && key != 'columnId'
            issues << "#{label} #{(path + [key]).join('.')} must be camelCase columnId"
          end
          visit.call(child, path + [key])
        end
      when Array
        value.each_with_index { |child, index| visit.call(child, path + [index]) }
      end
    end
    visit.call(element, [])

    check_pointer = lambda do |pointer, path, valid_ids = column_ids|
      if pointer.is_a?(Hash)
        if pointer.key?('id') && !pointer.key?('columnId')
          issues << "#{label} #{path} uses id; use columnId"
          return
        end
        pointer = pointer['columnId']
      end
      return if pointer.nil?
      return if valid_ids.include?(pointer)

      issues << "#{label} #{path} references undeclared column #{pointer.inspect}"
    end

    SINGLE_COLUMN_POINTER_FIELDS.each do |field|
      pointer = element[field]
      check_pointer.call(pointer, field) if pointer.is_a?(Hash)
    end

    %w[yAxis yAxis2].each do |axis|
      Array(element.dig(axis, 'columnIds')).each_with_index do |pointer, index|
        check_pointer.call(pointer, "#{axis}.columnIds[#{index}]")
      end
    end

    %w[rowsBy columnsBy].each do |shelf|
      Array(element[shelf]).each_with_index do |pointer, index|
        check_pointer.call(pointer, "#{shelf}[#{index}]")
      end
      Array(element.dig('trellis', shelf)).each_with_index do |pointer, index|
        check_pointer.call(pointer, "trellis.#{shelf}[#{index}]")
      end
    end

    Array(element['seriesLineAreaStyle']).each_with_index do |pointer, index|
      check_pointer.call(pointer, "seriesLineAreaStyle[#{index}]")
    end

    if element['kind'] == 'pivot-table'
      Array(element['values']).each_with_index do |pointer, index|
        check_pointer.call(pointer, "values[#{index}]")
      end
    end

    Array(element['order']).each_with_index do |pointer, index|
      check_pointer.call(pointer, "order[#{index}]")
    end

    color = element['color']
    if color.is_a?(Hash)
      check_pointer.call(color, 'color') if color.key?('columnId') || color.key?('id')
      check_pointer.call(color['column'], 'color.column') if color.key?('column')
    end

    next unless element['kind'] == 'control'

    source = element['source']
    next unless source.is_a?(Hash) && source.key?('columnId')

    target_id = source.dig('source', 'elementId')
    unless declared_elements.key?(target_id)
      issues << "#{label} source targets unknown element #{target_id.inspect}"
      next
    end
    check_pointer.call(source['columnId'], 'source.columnId', columns_by_element[target_id] || [])
  end

  die "column pointer validation failed:\n  - #{issues.join("\n  - ")}", 1 unless issues.empty?
end

def lint_groupings(spec)
  issues = []
  warnings = []

  Array(document(spec)['elements']).each do |element|
    next unless element.is_a?(Hash) && element['kind'] == 'table'

    label = element['name'] || element['id'] || '(unnamed)'
    columns = Array(element['columns']).select { |column| column.is_a?(Hash) }
    columns_by_id = columns.each_with_object({}) { |column, out| out[column['id']] = column if column['id'] }
    groupings = Array(element['groupings'])
    aggregate_columns = columns.select { |column| column['formula'].to_s.match?(AGGREGATE_FORMULA) }

    if groupings.empty?
      unless aggregate_columns.empty?
        ids = aggregate_columns.map { |column| column['id'] || column['name'] }.compact
        issues << "#{label} has aggregate columns but no groupings: #{ids.join(', ')}"
      end
      next
    end

    referenced = []
    groupings.each_with_index do |grouping, index|
      unless grouping.is_a?(Hash)
        issues << "#{label} groupings[#{index}] must be an object"
        next
      end
      group_by = Array(grouping['groupBy'])
      calculations = Array(grouping['calculations'])
      referenced.concat(group_by, calculations)

      (group_by + calculations).each do |column_id|
        next if columns_by_id.key?(column_id)

        issues << "#{label} groupings[#{index}] references undeclared column #{column_id.inspect}"
      end
      calculations.each do |column_id|
        column = columns_by_id[column_id]
        next unless column
        next if column['formula'].to_s.match?(AGGREGATE_FORMULA)

        issues << "#{label} groupings[#{index}].calculations references non-aggregate column #{column_id.inspect}"
      end
      Array(grouping['sort']).each_with_index do |sort, sort_index|
        next unless sort.is_a?(Hash)

        column_id = sort['columnId']
        next if column_id.nil? || columns_by_id.key?(column_id)

        issues << "#{label} groupings[#{index}].sort[#{sort_index}] references undeclared column #{column_id.inspect}"
      end
    end

    visible_extras = columns.reject do |column|
      column['hidden'] || referenced.include?(column['id'])
    end
    unless visible_extras.empty?
      ids = visible_extras.map { |column| column['id'] || column['name'] }.compact
      warnings << "#{label} leaves visible detail columns outside groupBy/calculations: #{ids.join(', ')}"
    end
  end

  warnings.each { |message| warn "wb-rep: grouping warning — #{message}" }
  die "grouping validation failed:\n  - #{issues.join("\n  - ")}", 1 unless issues.empty?
end

# ---- commands ------------------------------------------------------------

def cmd_lint(args)
  target = args.shift || '.'
  spec = File.directory?(target) ? assemble(target) : YAML.load_file(target)
  lint_layout_coverage(spec)
  lint_reference_integrity(spec)
  lint_column_references(spec)
  lint_groupings(spec)
  puts 'lint: ok'
end

def cmd_pull(args, force:)
  wb_id = args.shift or die 'usage: wb-rep.rb pull <workbook-id> [dir]'
  dir = args.shift || '.'
  if File.exist?(File.join(dir, 'workbook.yaml')) && rep_dirty?(dir) && !force
    die "rep at #{dir} has local changes (see `status`) — pull would overwrite them; use --force to discard", 1
  end
  raw = api(:get, "/v2/workbooks/#{wb_id}/spec")
  spec = canonical_spec(YAML.load(raw))
  explode(spec, dir, raw_yaml: YAML.dump(spec),
                     manifest_extra: { 'workbookId' => wb_id, 'url' => spec['url'] })
  doc = document(spec)
  puts "pulled \"#{spec['name']}\" -> #{dir} (#{(doc['pages'] || []).size} pages, #{(doc['elements'] || []).size} elements)"
end

def cmd_import(args)
  src = args.shift or die 'usage: wb-rep.rb import <spec.yaml> [dir]'
  dir = args.shift || '.'
  raw = File.read(src)
  explode(YAML.load(raw), dir, raw_yaml: raw)
  puts "imported #{src} -> #{dir} (create mode: push will POST a new workbook)"
end

def create_body(spec)
  clean = strip_response_only(canonical_spec(spec))
  metadata = clean.select { |key, _| CREATE_METADATA.include?(key) }
  doc = document(clean)
  doc = doc.merge('kind' => 'workbook') unless doc['kind']
  Sigma::CodeRep.wrap(doc, extra: metadata)
end

def put_body(spec)
  doc = document(spec)
  doc = doc.merge('kind' => 'workbook') unless doc['kind']
  Sigma::CodeRep.wrap(doc)
end

def cmd_verify(args)
  path = args.shift or die 'usage: wb-rep.rb verify <spec-file>'
  die "no such file: #{path}" unless File.exist?(path)
  result = YAML.load(api(:post, '/v2/workbooks/spec/verify', YAML.dump(create_body(load_yaml_file(path)))))
  if result['valid']
    puts 'valid: true'
  else
    puts 'valid: false'
    (result['errors'] || []).each { |e| puts "  - #{e['summary']}" }
    exit 1
  end
end

def cmd_status(args)
  dir = args.shift || '.'
  snap = snapshot_spec(dir)
  unless snap
    spec = assemble(dir)
    doc = document(spec)
    puts "create mode — never pushed (#{(doc['pages'] || []).size} pages, #{(doc['elements'] || []).size} elements staged)"
    return
  end
  lines = diff_specs(snap, assemble(dir))
  if lines.empty?
    puts 'clean — working files match the last-synced snapshot'
  else
    puts lines
    exit 1
  end
end

def cmd_assemble(args)
  out = nil
  if (i = args.index('-o'))
    out = args[i + 1] or die 'assemble: -o needs a file argument'
    args.slice!(i, 2)
  end
  dir = args.shift || '.'
  yaml = YAML.dump(assemble(dir))
  out ? (File.write(out, yaml); puts "wrote #{out}") : puts(yaml)
end

def cmd_push(args, force:, validate: true)
  dir = args.shift || '.'
  spec = assemble(dir)
  snap = snapshot_spec(dir)
  mf = manifest(dir)
  wb_id = mf['workbookId']
  die "rep has a workbookId but no snapshot in #{dir}/.sigma — re-run pull first" if wb_id && snap.nil?

  lines = snap ? diff_specs(snap, spec) : []
  if wb_id && lines.empty?
    puts 'nothing to push — working files match the last-synced snapshot'
    return
  end
  puts 'changes to push:'
  puts(lines.empty? ? '  (initial create)' : lines.map { |l| "  #{l}" })

  if wb_id && !force
    remote = canonical_spec(YAML.load(api(:get, "/v2/workbooks/#{wb_id}/spec")))
    drift = diff_specs(snap, remote)
    unless drift.empty?
      warn 'wb-rep: remote workbook changed since last pull — pushing would overwrite:'
      drift.each { |l| warn "  #{l}" }
      die 'resolve by re-running pull (re-apply your edits) or push --force to overwrite', 1
    end
  end

  lint_layout_coverage(spec)
  lint_reference_integrity(spec)
  lint_column_references(spec)
  lint_groupings(spec)

  clean_body = strip_response_only(spec)
  if validate
    require 'tempfile'
    Tempfile.create(['wb-rep-spec', '.yaml']) do |f|
      f.write(YAML.dump(clean_body))
      f.flush
      validator = File.expand_path('validate-spec.sh', __dir__)
      if File.exist?(validator)
        ok = system(validator, f.path)
        die 'validator found issues (above) — fix them or push --no-validate to override', 1 unless ok
      end
    end
  end

  if wb_id
    api(:put, "/v2/workbooks/#{wb_id}/spec", YAML.dump(put_body(clean_body)))
  else
    die 'create mode: workbook.yaml must include folderId' unless clean_body['folderId']
    res = canonical_spec(YAML.load(api(:post, '/v2/workbooks/spec', YAML.dump(create_body(clean_body)))))
    wb_id = res['workbookId'] or die "create response had no workbookId:\n#{res.inspect}"
    mf['workbookId'] = wb_id
  end

  readback = canonical_spec(YAML.load(api(:get, "/v2/workbooks/#{wb_id}/spec")))
  FileUtils.mkdir_p(File.join(dir, '.sigma'))
  File.write(File.join(dir, '.sigma', 'snapshot.yaml'), YAML.dump(readback))
  mf['url'] = readback['url']
  mf['pushedAt'] = Time.now.utc.iso8601
  File.write(File.join(dir, '.sigma', 'manifest.yaml'), YAML.dump(mf))

  norm = diff_specs(spec, readback)
  unless norm.empty?
    puts 'server normalized some fields on save (working files now differ from snapshot):'
    puts norm.map { |l| "  #{l}" }
    puts "run `pull #{wb_id} #{dir} --force` to resync files, or leave as-is and `status` will show this delta"
  end
  puts "pushed -> #{readback['url'] || wb_id}"
  puts "verify compile next: scripts/verify-workbook.sh #{wb_id}"
end

# Zoom-style reads (no full-spec load): summarize a workbook or rep cheaply,
# and distil authorable capabilities live from the public OpenAPI. `capabilities`
# is inherently a BULK-discovery tool (every kind, or every field on one kind) —
# for a single endpoint's current request/response shape, the stable per-endpoint
# pages at https://help.sigmacomputing.com/reference/<endpoint-slug> (see
# SKILL.md's "Sources of truth") are the better source; this command doesn't
# cover that case and isn't meant to.
def cmd_summarize(args)
  target = args.shift || '.'
  spec = if File.directory?(target)
           snapshot_spec(target) || assemble(target)
         else
           canonical_spec(YAML.load(api(:get, "/v2/workbooks/#{target}/spec")))
         end
  doc = document(spec)
  puts "#{spec['name']}  (schemaVersion #{doc['schemaVersion']})"
  elements = doc['elements'] || []
  by_id = index_by_id(elements)
  _, layout_chunks = split_layout(doc['layout'])
  sources = []
  COLLECTIONS.each_key do |collection|
    (doc[collection] || []).each do |entry|
      ids = layout_chunks.fetch(entry['id'], '').scan(/\belementId="([^"]+)"/).flatten
      placed = ids.map { |id| by_id[id] }.compact
      kinds = placed.group_by { |element| element['kind'] }.map { |kind, grouped| "#{kind}×#{grouped.size}" }.join(', ')
      vis = entry['visibility'] == 'hidden' ? ' [hidden]' : ''
      puts "  #{collection.sub(/s\z/, '')} \"#{entry['name']}\"#{vis}: #{placed.size} elements (#{kinds})"
    end
  end
  elements.each do |element|
    source = element['source'] or next
    sources << (source['path'] ? source['path'].join('.') : source['kind'] == 'data-model' ? "data-model #{source['dataModelId']}" : nil)
  end
  puts "  sources: #{sources.compact.uniq.join(', ')}" unless sources.compact.empty?
end

# Canonical, stable, unauthenticated compiled OpenAPI. Plain GET — no auth, no
# presigning, no content hash — so it is safe to pin.
#
# History worth not repeating: this used to point at the content-addressed Fern
# docs asset (fdr-prod-docs-files-public.s3.../sigma.docs.buildwithfern.com/<hash>/…).
# That asset later began requiring AWS presigned query params (bare fetch -> 403),
# and — the part that actually bit — it LAGS the live API: as of 2026-08-05 it was
# missing /v2/reports/spec*, still documented the pre-`document`-wrapper request
# body, and lacked the `repeated-container` element kind entirely, which led this
# skill to wrongly document repeated containers as not spec-authorable. Use the
# assets.sigmacomputing.com URL; treat a live workbook readback as the tiebreaker.
OPENAPI_CACHE = File.join(Dir.tmpdir, 'sigma-api.json').freeze
OPENAPI_URL = 'https://assets.sigmacomputing.com/openapi/public-rest-api/sigma-computing-public-rest-api.json'.freeze

# Net::HTTP.get_response doesn't follow redirects; the assets host may redirect.
# Network failures (offline, DNS, TLS, timeout) are returned as nil rather than
# raised, so callers can `die` with an actionable message instead of dumping a
# raw Ruby backtrace on a user who is simply offline.
def http_get_follow(url, limit: 5)
  limit.times do
    res = begin
      Net::HTTP.get_response(URI(url))
    rescue StandardError => e
      @http_get_error = e.message
      return nil
    end
    return res if res.is_a?(Net::HTTPSuccess)
    return nil unless res.is_a?(Net::HTTPRedirection) && res['location']

    url = URI.join(url, res['location']).to_s
  end
  nil
end

# Depth-first walk mirroring jq's `.. | objects`: yields every Hash reachable
# from `node` (including `node` itself), descending through both Hash values
# and Array elements.
def walk_objects(node, &blk)
  return enum_for(:walk_objects, node) unless blk
  case node
  when Hash
    blk.call(node)
    node.each_value { |v| walk_objects(v, &blk) }
  when Array
    node.each { |v| walk_objects(v, &blk) }
  end
end

# Mirrors the jq selector used throughout: a schema matches `kind` either via
# an allOf branch's `properties.kind.enum` or its own.
def kind_schema_match?(obj, kind)
  all_of = obj['allOf']
  allof_match = all_of.is_a?(Array) && all_of.any? { |s| s.is_a?(Hash) && s.dig('properties', 'kind', 'enum') == [kind] }
  allof_match || obj.dig('properties', 'kind', 'enum') == [kind]
end

def find_kind_schema(doc, kind)
  walk_objects(doc).find { |obj| kind_schema_match?(obj, kind) }
end

# Mirrors `[.allOf[]?.properties // .properties | keys[]] | unique[]`: merge
# property keys across allOf branches, falling back to the schema's own
# properties when there's no allOf (or none of its branches have properties).
def merged_properties_keys(schema)
  props_list = []
  if schema['allOf'].is_a?(Array)
    props_list = schema['allOf']
                 .select { |s| s.is_a?(Hash) && s['properties'].is_a?(Hash) }
                 .map { |s| s['properties'] }
  end
  props_list = [schema['properties']].compact if props_list.empty? && schema['properties'].is_a?(Hash)
  props_list.flat_map(&:keys).uniq.sort
end

# Mirrors `.. | objects | select(.properties[field]) | .properties[field] | .[0]`:
# first descendant schema (depth-first) that declares `field`, returning its
# sub-schema.
def find_field_schema(kind_schema, field)
  walk_objects(kind_schema).each do |obj|
    return obj['properties'][field] if obj['properties'].is_a?(Hash) && obj['properties'].key?(field)
  end
  nil
end

def cmd_capabilities(args)
  kind = field = nil
  if (i = args.index('--kind')) then kind = args[i + 1]; args.slice!(i, 2); end
  if (i = args.index('--field')) then field = args[i + 1]; args.slice!(i, 2); end
  unless File.exist?(OPENAPI_CACHE)
    @http_get_error = nil
    res = http_get_follow(OPENAPI_URL)
    unless res
      detail = @http_get_error ? " (#{@http_get_error})" : ''
      die "failed to fetch the compiled OpenAPI from #{OPENAPI_URL}#{detail}. If you are " \
          'offline or the host is unreachable, use a live workbook readback ' \
          '(GET /v2/workbooks/{id}/spec) or a per-endpoint reference page ' \
          '(https://help.sigmacomputing.com/reference/<endpoint-slug>) instead.'
    end
    File.write(OPENAPI_CACHE, res.body)
  end
  doc = JSON.parse(File.read(OPENAPI_CACHE))

  if kind.nil?
    kinds = walk_objects(doc).each_with_object([]) do |obj, acc|
      enum = obj.dig('properties', 'kind', 'enum')
      acc << enum.first if enum.is_a?(Array) && !enum.empty?
    end
    kinds.uniq.sort.each { |k| puts k }
    return
  end

  schema = find_kind_schema(doc, kind)
  die "no schema found for kind #{kind.inspect}" unless schema

  if field.nil?
    merged_properties_keys(schema).each { |k| puts k }
  else
    result = find_field_schema(schema, field)
    puts result.nil? ? 'null' : JSON.pretty_generate(result)
  end
end

def export_png(wb_id, body, out_path, label)
  res = JSON.parse(api(:post, "/v2/workbooks/#{wb_id}/export", JSON.dump(body),
                       content_type: 'application/json', accept: 'application/json'))
  query_id = res['queryId'] or die "export response had no queryId:\n#{res.inspect}"
  deadline = Time.now + 180
  loop do
    r = api_raw(:get, "/v2/query/#{query_id}/download", accept: '*/*')
    code = r.code.to_i
    if code == 200 && r.body && !r.body.empty?
      File.binwrite(out_path, r.body)
      puts "rendered #{label} -> #{out_path} (#{r.body.bytesize / 1024}KB)"
      return
    elsif [202, 204].include?(code) || code == 200
      die "render of #{label} timed out after 180s", 2 if Time.now > deadline
      sleep 3
    else
      die "download for #{label} -> HTTP #{r.code}\n#{r.body}", 2
    end
  end
end

def cmd_render(args)
  page_sel = element_sel = nil
  if (i = args.index('--page')) then page_sel = args[i + 1]; args.slice!(i, 2); end
  if (i = args.index('--element')) then element_sel = args[i + 1]; args.slice!(i, 2); end
  dir = args.shift || '.'
  wb_id = manifest(dir)['workbookId'] or die 'render shows SERVER state — pull or push a real workbook first (no workbookId in manifest)'
  warn 'wb-rep: warning — rep has unpushed local changes; render shows the last-pushed state' if rep_dirty?(dir)
  out_dir = File.join(dir, 'renders')
  FileUtils.mkdir_p(out_dir)

  if element_sel
    export_png(wb_id, { 'elementId' => element_sel, 'format' => { 'type' => 'png' } },
               File.join(out_dir, "element-#{slug(element_sel)}.png"), "element #{element_sel}")
    return
  end

  spec = snapshot_spec(dir) or die "no snapshot in #{dir}/.sigma — run pull or import first"
  pages = document(spec)['pages'] || []
  pages = pages.select { |p| [p['id'], p['name'], slug(p['name'])].compact.include?(page_sel) } if page_sel
  die "no page matches #{page_sel.inspect}" if pages.empty?
  pages.each do |p|
    name = slug(p['name']) || p['id']
    export_png(wb_id, { 'pageId' => p['id'], 'format' => { 'type' => 'png' } },
               File.join(out_dir, "#{name}.png"), "page \"#{p['name'] || p['id']}\"")
  end
end

# ---- main ----------------------------------------------------------------

argv = ARGV.dup
force = !!argv.delete('--force')
no_validate = !!argv.delete('--no-validate')
cmd = argv.shift

case cmd
when 'pull'     then cmd_pull(argv, force: force)
when 'import'   then cmd_import(argv)
when 'verify'   then cmd_verify(argv)
when 'status'   then cmd_status(argv)
when 'assemble' then cmd_assemble(argv)
when 'lint'     then cmd_lint(argv)
when 'push'         then cmd_push(argv, force: force, validate: !no_validate)
when 'render'       then cmd_render(argv)
when 'summarize'    then cmd_summarize(argv)
when 'capabilities' then cmd_capabilities(argv)
else
  die "usage: wb-rep.rb {pull <workbook-id> [dir] | import <spec.yaml> [dir] | verify <spec-file> | status [dir] | assemble [dir] [-o file] | lint [dir|spec-file] | push [dir] | render [dir] [--page <id|name>] [--element <id>] | summarize [dir|workbook-id] | capabilities [--kind K [--field F]]} [--force] [--no-validate]"
end
