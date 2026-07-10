#!/usr/bin/env ruby
# wb-rep.rb — element-level file representation ("rep") of a Sigma workbook spec.
#
# The Sigma spec API is whole-workbook only (GET/PUT the entire spec). Large
# multi-page workbooks blow up an agent's context when edited as one document.
# This tool makes the ELEMENT the unit of work by exploding the spec into a
# directory of small files, and reassembling them on push:
#
#   <rep>/
#     workbook.yaml              top-level fields (name, folderId, schemaVersion, ...)
#     pages/
#       010-overview/
#         _page.yaml             page fields minus elements (id, name, visibility)
#         _layout.xml            this page's <Page> block from the top-level layout XML
#         010-revenue-kpi.yaml   one element per file (filename prefix = order)
#         020-sales-by-region.yaml
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
#   import <spec.yaml> [dir]     explode an existing local spec file (create mode: push POSTs)
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

RESPONSE_ONLY = %w[workbookId url documentVersion latestDocumentVersion ownerId
                   createdBy updatedBy createdAt updatedAt].freeze
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

# Split the top-level layout XML into [preamble, { page_id => chunk }].
# Chunks are verbatim byte slices so an untouched rep reassembles identically.
def split_layout(layout)
  return [XML_PROLOG, {}] if layout.nil? || layout.empty?
  starts = []
  layout.scan(/<Page[\s>]/) { starts << Regexp.last_match.begin(0) }
  return [layout, {}] if starts.empty?
  preamble = layout[0...starts.first]
  chunks = {}
  starts.each_with_index do |s, i|
    chunk = layout[s...(starts[i + 1] || layout.length)]
    id = chunk[/\A<Page[^>]*\bid="([^"]*)"/, 1]
    warn "wb-rep: warning — layout <Page> block without an id attribute; it will be appended last" unless id
    chunks[id || "_orphan#{i}"] = chunk
  end
  [preamble, chunks]
end

def explode(spec, dir, raw_yaml:, manifest_extra: {})
  spec = spec.dup
  pages = spec.delete('pages') || []
  layout = spec.delete('layout')
  preamble, layout_chunks = split_layout(layout)
  top = strip_response_only(spec)

  FileUtils.rm_rf(File.join(dir, 'pages'))
  FileUtils.mkdir_p(File.join(dir, 'pages'))
  FileUtils.mkdir_p(File.join(dir, '.sigma'))
  File.write(File.join(dir, 'workbook.yaml'), YAML.dump(top))
  File.write(File.join(dir, '.sigma', 'layout-preamble.xml'), preamble)

  used_page_dirs = {}
  pages.each_with_index do |page, pi|
    page = page.dup
    elements = page.delete('elements') || []
    base = slug(page['name']) || slug(page['id']) || "page-#{pi + 1}"
    base += "-#{page['id']}"[0, 20] if used_page_dirs[base]
    used_page_dirs[base] = true
    pdir = File.join(dir, 'pages', format('%03d-%s', (pi + 1) * 10, base))
    FileUtils.mkdir_p(pdir)
    File.write(File.join(pdir, '_page.yaml'), YAML.dump(page))
    if (chunk = layout_chunks.delete(page['id']))
      File.write(File.join(pdir, '_layout.xml'), chunk)
    end
    used = {}
    elements.each_with_index do |el, ei|
      ebase = slug(el['name']) || slug(el['kind']) || 'element'
      ebase += "-#{slug(el['id']) || ei}" if used[ebase]
      used[ebase] = true
      File.write(File.join(pdir, format('%03d-%s.yaml', (ei + 1) * 10, ebase)), YAML.dump(el))
    end
  end
  layout_chunks.each_key do |k|
    warn "wb-rep: warning — layout <Page id=\"#{k}\"> matches no page in the spec; chunk dropped"
  end

  File.write(File.join(dir, '.sigma', 'snapshot.yaml'), raw_yaml)
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
  spec = load_yaml_file(wb_path)
  preamble_path = File.join(dir, '.sigma', 'layout-preamble.xml')
  preamble = File.exist?(preamble_path) ? File.read(preamble_path) : XML_PROLOG

  pages = []
  layout_parts = []
  Dir[File.join(dir, 'pages', '*/')].sort.each do |pdir|
    ppath = File.join(pdir, '_page.yaml')
    die "missing _page.yaml in #{pdir}" unless File.exist?(ppath)
    page = load_yaml_file(ppath)
    elements = Dir[File.join(pdir, '*.yaml')].sort
                                             .reject { |f| File.basename(f) == '_page.yaml' }
                                             .map { |f| load_yaml_file(f) }
    page['elements'] = elements
    pages << page
    lpath = File.join(pdir, '_layout.xml')
    layout_parts << File.read(lpath) if File.exist?(lpath)
  end
  spec['pages'] = pages
  spec['layout'] = preamble + layout_parts.join unless layout_parts.empty?
  spec
end

# ---- diffing -------------------------------------------------------------

def index_by_id(arr)
  (arr || []).each_with_index.map { |x, i| [x['id'] || "@#{i}", x] }.to_h
end

def changed_keys(a, b)
  (a.keys | b.keys).reject { |k| a[k] == b[k] }
end

def diff_specs(old_spec, new_spec)
  lines = []
  ot = strip_response_only(old_spec).reject { |k, _| %w[pages layout].include?(k) }
  nt = strip_response_only(new_spec).reject { |k, _| %w[pages layout].include?(k) }
  changed_keys(ot, nt).each { |k| lines << "~ workbook.#{k}" }

  old_pages = index_by_id(old_spec['pages'])
  new_pages = index_by_id(new_spec['pages'])
  _, old_layout = split_layout(old_spec['layout'])
  _, new_layout = split_layout(new_spec['layout'])

  (old_pages.keys | new_pages.keys).each do |pid|
    op = old_pages[pid]
    np = new_pages[pid]
    pname = (np || op)['name'] || pid
    if op.nil? then lines << "+ page \"#{pname}\" (#{(np['elements'] || []).size} elements)"; next end
    if np.nil? then lines << "- page \"#{pname}\""; next end
    meta = changed_keys(op.reject { |k, _| k == 'elements' }, np.reject { |k, _| k == 'elements' })
    lines << "~ page \"#{pname}\" [#{meta.join(', ')}]" unless meta.empty?
    lines << "~ page \"#{pname}\" layout" if old_layout[pid] != new_layout[pid]
    oe = index_by_id(op['elements'])
    ne = index_by_id(np['elements'])
    el_lines = []
    (oe.keys | ne.keys).each do |eid|
      o = oe[eid]
      n = ne[eid]
      ename = (n || o)['name'] || (n || o)['kind'] || eid
      if o.nil? then el_lines << "  + element \"#{ename}\" (#{eid})"
      elsif n.nil? then el_lines << "  - element \"#{ename}\" (#{eid})"
      elsif o != n then el_lines << "  ~ element \"#{ename}\" (#{eid}) [#{changed_keys(o, n).join(', ')}]"
      end
    end
    lines << "  page \"#{pname}\":" unless el_lines.empty?
    lines.concat(el_lines)
  end
  lines
end

def snapshot_spec(dir)
  path = File.join(dir, '.sigma', 'snapshot.yaml')
  File.exist?(path) ? YAML.load(File.read(path)) : nil
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
  _, chunks = split_layout(spec['layout'])
  (spec['pages'] || []).each do |page|
    chunk = chunks[page['id']] or next # no layout block = auto-arrange, nothing to check
    (page['elements'] || []).each do |el|
      next if chunk.include?(%(elementId="#{el['id']}"))
      warn "wb-rep: warning — element \"#{el['name'] || el['id']}\" (page \"#{page['name']}\") is not referenced in the page's _layout.xml"
    end
  end
end

# ---- commands ------------------------------------------------------------

def cmd_pull(args, force:)
  wb_id = args.shift or die 'usage: wb-rep.rb pull <workbook-id> [dir]'
  dir = args.shift || '.'
  if File.exist?(File.join(dir, 'workbook.yaml')) && rep_dirty?(dir) && !force
    die "rep at #{dir} has local changes (see `status`) — pull would overwrite them; use --force to discard", 1
  end
  raw = api(:get, "/v2/workbooks/#{wb_id}/spec")
  spec = YAML.load(raw)
  explode(spec, dir, raw_yaml: raw,
                     manifest_extra: { 'workbookId' => wb_id, 'url' => spec['url'] })
  n_el = (spec['pages'] || []).sum { |p| (p['elements'] || []).size }
  puts "pulled \"#{spec['name']}\" -> #{dir} (#{(spec['pages'] || []).size} pages, #{n_el} elements)"
end

def cmd_import(args)
  src = args.shift or die 'usage: wb-rep.rb import <spec.yaml> [dir]'
  dir = args.shift || '.'
  raw = File.read(src)
  explode(YAML.load(raw), dir, raw_yaml: raw)
  puts "imported #{src} -> #{dir} (create mode: push will POST a new workbook)"
end

def cmd_status(args)
  dir = args.shift || '.'
  snap = snapshot_spec(dir)
  unless snap
    spec = assemble(dir)
    n_el = (spec['pages'] || []).sum { |p| (p['elements'] || []).size }
    puts "create mode — never pushed (#{(spec['pages'] || []).size} pages, #{n_el} elements staged)"
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
    remote = YAML.load(api(:get, "/v2/workbooks/#{wb_id}/spec"))
    drift = diff_specs(snap, remote)
    unless drift.empty?
      warn 'wb-rep: remote workbook changed since last pull — pushing would overwrite:'
      drift.each { |l| warn "  #{l}" }
      die 'resolve by re-running pull (re-apply your edits) or push --force to overwrite', 1
    end
  end

  lint_layout_coverage(spec)

  body = YAML.dump(strip_response_only(spec))
  if validate
    require 'tempfile'
    Tempfile.create(['wb-rep-spec', '.yaml']) do |f|
      f.write(body)
      f.flush
      validator = File.expand_path('validate-spec.sh', __dir__)
      if File.exist?(validator)
        ok = system(validator, f.path)
        die 'validator found issues (above) — fix them or push --no-validate to override', 1 unless ok
      end
    end
  end

  if wb_id
    api(:put, "/v2/workbooks/#{wb_id}/spec", body)
  else
    die 'create mode: workbook.yaml must include folderId' unless spec['folderId']
    res = YAML.load(api(:post, '/v2/workbooks/spec', body))
    wb_id = res['workbookId'] or die "create response had no workbookId:\n#{res.inspect}"
    mf['workbookId'] = wb_id
  end

  raw = api(:get, "/v2/workbooks/#{wb_id}/spec")
  readback = YAML.load(raw)
  FileUtils.mkdir_p(File.join(dir, '.sigma'))
  File.write(File.join(dir, '.sigma', 'snapshot.yaml'), raw)
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
# and distil authorable capabilities live from the public OpenAPI.
def cmd_summarize(args)
  target = args.shift || '.'
  spec = if File.directory?(target)
           snapshot_spec(target) || assemble(target)
         else
           YAML.load(api(:get, "/v2/workbooks/#{target}/spec"))
         end
  puts "#{spec['name']}  (schemaVersion #{spec['schemaVersion']})"
  sources = []
  (spec['pages'] || []).each do |p|
    els = p['elements'] || []
    kinds = els.group_by { |e| e['kind'] }.map { |k, v| "#{k}×#{v.size}" }.join(', ')
    vis = p['visibility'] == 'hidden' ? ' [hidden]' : ''
    puts "  page \"#{p['name']}\"#{vis}: #{els.size} elements (#{kinds})"
    els.each do |e|
      s = e['source'] or next
      sources << (s['path'] ? s['path'].join('.') : s['kind'] == 'data-model' ? "data-model #{s['dataModelId']}" : nil)
    end
  end
  puts "  sources: #{sources.compact.uniq.join(', ')}" unless sources.compact.empty?
end

OPENAPI_CACHE = '/tmp/sigma-api.json'.freeze
OPENAPI_URL = 'https://help.sigmacomputing.com/openapi/sigma-computing-public-rest-api.json'.freeze

# Depth-first pre-order walk over every Hash node reachable from `node`
# (mirrors jq's `.. | objects`): yields the node itself, then recurses into
# each Hash/Array value it contains, in place, so "first match wins" callers
# see nodes in the same order jq's `first(...)` would.
def walk_openapi_objects(node, &blk)
  return unless node.is_a?(Hash) || node.is_a?(Array)
  if node.is_a?(Hash)
    blk.call(node)
    node.each_value { |v| walk_openapi_objects(v, &blk) }
  else
    node.each { |v| walk_openapi_objects(v, &blk) }
  end
end

# True when `node` is the schema for element/control kind `k` — either
# directly (properties.kind.enum == [k]) or via an allOf branch. Mirrors the
# jq selector this replaced:
#   (.allOf? and any(.allOf[]?; .properties?.kind?.enum==[$k])) or .properties?.kind?.enum==[$k]
def openapi_kind_match?(node, k)
  return true if node.dig('properties', 'kind', 'enum') == [k]
  Array(node['allOf']).any? { |a| a.is_a?(Hash) && a.dig('properties', 'kind', 'enum') == [k] }
end

# Plain Net::HTTP::Get.new(uri) + start does not follow redirects (unlike
# `curl` without `-L`); the docs host serves this URL via a 308, so this is
# needed for the fetch below to actually land on the JSON.
def http_get_following_redirects(url, limit = 5)
  die 'too many HTTP redirects fetching OpenAPI' if limit.zero?
  uri = URI(url)
  res = Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == 'https', read_timeout: 120) { |h| h.get(uri) }
  res.is_a?(Net::HTTPRedirection) ? http_get_following_redirects(res['location'], limit - 1) : res
end

def cmd_capabilities(args)
  kind = field = nil
  if (i = args.index('--kind')) then kind = args[i + 1]; args.slice!(i, 2); end
  if (i = args.index('--field')) then field = args[i + 1]; args.slice!(i, 2); end
  unless File.exist?(OPENAPI_CACHE)
    res = http_get_following_redirects(OPENAPI_URL)
    die "failed to fetch OpenAPI (HTTP #{res.code})" unless res.code.to_i.between?(200, 299)
    File.write(OPENAPI_CACHE, res.body)
  end
  spec = JSON.parse(File.read(OPENAPI_CACHE))

  if kind.nil?
    # jq: [.. | objects | select(.properties.kind.enum) | .properties.kind.enum[0]] | unique[]
    kinds = []
    walk_openapi_objects(spec) do |n|
      enum = n.dig('properties', 'kind', 'enum')
      kinds << enum[0] if enum
    end
    puts kinds.compact.uniq.sort
    return
  end

  match = nil
  walk_openapi_objects(spec) { |n| match ||= n if openapi_kind_match?(n, kind) }
  die "no schema found for kind=#{kind}" unless match

  if field.nil?
    # jq: [.allOf[]?.properties // .properties | keys[]] | unique[]
    branches = Array(match['allOf']).map { |a| a['properties'] }.compact
    branches = [match['properties'] || {}] if branches.empty?
    puts branches.flat_map(&:keys).uniq.sort
  else
    # jq: [.. | objects | select(.properties["field"]) | .properties["field"]] | .[0]
    found = nil
    walk_openapi_objects(match) do |n|
      next unless found.nil?
      found = n['properties'][field] if n['properties'].is_a?(Hash) && n['properties'].key?(field)
    end
    puts found.nil? ? 'null' : JSON.pretty_generate(found)
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
  pages = spec['pages'] || []
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
when 'status'   then cmd_status(argv)
when 'assemble' then cmd_assemble(argv)
when 'push'         then cmd_push(argv, force: force, validate: !no_validate)
when 'render'       then cmd_render(argv)
when 'summarize'    then cmd_summarize(argv)
when 'capabilities' then cmd_capabilities(argv)
else
  die "usage: wb-rep.rb {pull <workbook-id> [dir] | import <spec.yaml> [dir] | status [dir] | assemble [dir] [-o file] | push [dir] | render [dir] [--page <id|name>] [--element <id>] | summarize [dir|workbook-id] | capabilities [--kind K [--field F]]} [--force] [--no-validate]"
end
