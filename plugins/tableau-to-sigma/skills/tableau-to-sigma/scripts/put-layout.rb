#!/usr/bin/env ruby
# GET a workbook spec, replace per-page layouts with a single top-level layout
# XML (provided), strip read-only fields, PUT back.
#
# Container layouts: a <Container> in the layout XML must be paired with a
# `kind: container` placeholder element in the spec (else it is silently
# dropped — layout-playbook.md). Layout builders that emit Containers
# write a sidecar `<layout>.elements.json` ({pageId: [element, ...]}) next to
# the layout XML; this script injects those elements (containers + header
# text) into the matching pages before the PUT. Pass --elements to override
# the sidecar path. Injection is idempotent (existing element ids are kept).
#
# A builder may intentionally omit a displaced decorative element only by
# writing `<layout>.prune-elements.json`. This script accepts version-1
# `manual-composite` records only and removes those exact ids from flat
# document.elements before final coverage validation. Arbitrary missing
# elements remain fatal.
#
# Usage:
#   ruby put-layout.rb --workbook <wbId> --layout <layout.xml> \
#     [--elements <elements.json>] [--prune-elements <prune-elements.json>]

require 'net/http'
require 'uri'
require 'json'
require 'yaml'
require 'date'
require 'optparse'
require 'cgi'

abort 'FATAL: SIGMA_SHADOW_COMPILE=1 forbids live layout GET/PUT operations' if ENV['SIGMA_SHADOW_COMPILE'] == '1'

opts = {}
OptionParser.new do |p|
  p.on('--workbook ID') { |v| opts[:wb] = v }
  p.on('--layout PATH') { |v| opts[:layout] = v }
  p.on('--elements PATH', 'spec elements to inject (default: <layout>.elements.json if present)') { |v| opts[:elements] = v }
  p.on('--prune-elements PATH', 'explicit manual-composite elements to remove (default: <layout>.prune-elements.json if present)') { |v| opts[:prune_elements] = v }
  p.on('--nav-buttons PATH', 'nav-button sidecar (default: sibling *-nav-buttons.json) — rewrites the nav.invalid placeholder URLs to live page URLs') { |v| opts[:nav_buttons] = v }
  # v5.4: the pivot grand-totals SHIP step. A pivot carrying a `totals` key
  # 500s its CSV export (probe-isolated v5.4: `totals` is the SOLE trigger —
  # value type is irrelevant; ratio/PercentOfTotal export fine), which poisons
  # verify-anchors' pivot exports. Generated pivots carry the key from build;
  # verify-anchors strips it around its own CSV exports (restoring after), and
  # THIS pass — the final spec mutation, once the gates are green — repairs any
  # pivot the bracket left totals-less. --apply-pivot-totals runs a totals-ONLY
  # pass (no --layout needed): GET spec → set showGrandTotals:hidden on every
  # pivot lacking a totals key (path-independent, like hidden-titles; an
  # optional *-pivot-totals.json sidecar overrides per element id) → PUT.
  # Idempotent. The sidecar is globbed from the --layout dir, the --workdir,
  # and the cwd (v5.4.9 review fix: the finalize ship step passes no --layout,
  # which made the documented sidecar override unreachable on the automated
  # path — migrate-tableau.rb now passes --workdir).
  p.on('--apply-pivot-totals', 'ship step: (re)hide pivot grand totals as a final PUT (see header). --layout optional.') { opts[:apply_pivot_totals] = true }
  p.on('--workdir DIR', 'migration workdir — where sidecars (*-pivot-totals.json) are globbed when --layout is absent') { |v| opts[:workdir] = v }
end.parse!
abort('missing --workbook') unless opts[:wb]
abort('missing --layout') unless opts[:layout] || opts[:apply_pivot_totals]

# Read the Sigma token the shell-neutral way every sibling script uses (post-and-
# readback.rb etc.): lib/sigma_rest loads <WORK>/auth.json (get_token.py's handoff)
# at require time — keyed on SIGMA_WORKDIR then cwd — sets SIGMA_BASE_URL from it,
# and self-mints/refreshes via client_credentials. This replaces the old
# ENV.fetch('SIGMA_API_TOKEN') that KeyError-crashed at load when the token lived
# only in auth.json (field-caught: put-layout forced a manual token-export + a
# Git-Bash /c/ path failure). Honor this script's --workdir / --layout dir as
# <WORK> so a standalone run finds auth.json even when launched elsewhere; explicit
# env always wins. MUST set SIGMA_WORKDIR before the require (bootstrap runs then).
ENV['SIGMA_WORKDIR'] ||= opts[:workdir] ||
                         (opts[:layout] && File.dirname(File.expand_path(opts[:layout])))
$LOAD_PATH.unshift File.expand_path('lib', __dir__)
require 'sigma_rest'
require 'code_rep'
require 'workbook_code'

BASE = ENV.fetch('SIGMA_BASE_URL') # sigma_rest fills this from auth.json when unset

def http(method, path, body = nil)
  attempts = 0
  loop do
    attempts += 1
    uri = URI("#{BASE}#{path}")
    req = case method
          when :get then Net::HTTP::Get.new(uri)
          when :put then r = Net::HTTP::Put.new(uri); r.body = body; r['Content-Type'] = 'application/json'; r
          end
    req['Authorization'] = "Bearer #{Sigma.auth_token}"
    req['Accept']        = 'application/json'
    res = Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == 'https') { |h| h.request(req) }
    if res.code.to_i == 401 && attempts == 1 && ENV['SIGMA_CLIENT_ID']
      warn '  [auth] Sigma token expired mid-run — refreshing and retrying...'
      Sigma.refresh_token!
      next
    end
    return res
  end
end

raw_spec = JSON.parse(http(:get, "/v2/workbooks/#{opts[:wb]}/spec").body)
# Workbook code-rep nests pages/layout/schemaVersion/kind under a top-level
# `document` key (live since 2026-08) and REJECTS the old flat body on PUT
# with a 400 — unwrap the GET before any spec['pages'] access below; this
# endpoint is workbook-only (data-model code-rep is confirmed unchanged).
spec = Sigma::CodeRep.document(raw_spec)

# Layout application is skipped in the totals-ONLY ship pass (--apply-pivot-totals
# with no --layout): the layout + hidden-titles already rode the Phase-5 PUT;
# this pass touches nothing but the pivot `totals` keys.
if opts[:layout]
  xml = File.read(opts[:layout], encoding: 'UTF-8')
  abort "FATAL: empty elementId in layout XML" if xml.match?(/elementId=""/)
  spec['layout'] = xml

  # PRUNE stale injected layout chrome (orphan-fix, class 2). A rebuilt layout
  # (e.g. after --rename fixed zone matching) generates a different container
  # set, but earlier PUTs already injected the previous set into the spec — and
  # an injected element no longer referenced by the incoming layout XML is
  # auto-flowed by Sigma as an empty white card (bottom-left; live-caught on a
  # stale "tc-<page>-extra" safety-net band surviving every re-PUT). Only OUR
  # injected id namespaces are candidates — containers "tc-/syn-/band-", their
  # fabricated "-hdrtext" text, "dv-" dividers (see build-dashboard-layout.rb's
  # sidecar) — user elements are never touched, and anything the new layout
  # still references is kept.
  refd = xml.scan(/elementId="([^"]+)"/).flatten

  # Explicit manual-composite prune contract. A decorative floating image that
  # cannot be represented without being stranded far below its source is
  # intentionally absent from the layout. The builder names every such element
  # in a strict sidecar; remove only those exact ids from flat document.elements
  # so WorkbookCode.validate can continue enforcing complete placement for
  # everything else. An absent id is allowed for idempotent re-PUTs, but a
  # malformed record, unknown page, duplicate id, or still-referenced id is
  # fatal rather than becoming a broad missing-element escape hatch.
  prune_path = opts[:prune_elements] || "#{opts[:layout]}.prune-elements.json"
  if File.exist?(prune_path)
    prune_doc = JSON.parse(File.read(prune_path))
    records = prune_doc.is_a?(Hash) ? prune_doc['elements'] : nil
    abort "FATAL: invalid explicit prune sidecar #{prune_path}: version must be 1" unless prune_doc.is_a?(Hash) && prune_doc['version'] == 1
    abort "FATAL: invalid explicit prune sidecar #{prune_path}: elements must be an array" unless records.is_a?(Array)
    page_ids = Array(spec['pages']).filter_map { |page| page['id'] if page.is_a?(Hash) }
    invalid = records.reject do |record|
      record.is_a?(Hash) && !record['element_id'].to_s.empty? &&
        record['reason'] == 'manual-composite' && page_ids.include?(record['page_id'])
    end
    abort "FATAL: invalid explicit prune record(s) in #{prune_path}: #{invalid.inspect}" if invalid.any?
    prune_ids = records.map { |record| record['element_id'] }
    duplicates = prune_ids.tally.select { |_, count| count > 1 }.keys
    abort "FATAL: duplicate explicit prune id(s) in #{prune_path}: #{duplicates.join(', ')}" if duplicates.any?
    referenced = prune_ids & refd
    abort "FATAL: explicit prune id(s) are still referenced by layout: #{referenced.join(', ')}" if referenced.any?

    removed = []
    (spec['elements'] || []).reject! do |element|
      next false unless element.is_a?(Hash) && prune_ids.include?(element['id'])
      removed << element['id']
      true
    end
    puts "pruned #{removed.length}/#{prune_ids.length} explicit manual-composite element(s) before PUT: #{prune_ids.join(', ')}" if prune_ids.any?
  end

  pruned = []
  (spec['elements'] || []).reject! do |el|
    id = el['id'].to_s
    injected = (el['kind'] == 'container' && id.match?(/\A(tc|syn|band)-/)) ||
               (el['kind'] == 'text' && id.match?(/\A(tc|syn|band)-.*-hdrtext\z/)) ||
               (el['kind'] == 'divider' && id.start_with?('dv-'))
    next false unless injected && !refd.include?(id)
    pruned << id
    true
  end
  puts "pruned #{pruned.length} stale injected layout element(s) not referenced by the new layout: #{pruned.join(', ')}" if pruned.any?
end

# Inject container/header-text spec elements (see header comment).
elements_path = opts[:elements] || (opts[:layout] && "#{opts[:layout]}.elements.json")
if elements_path && File.exist?(elements_path)
  inject = JSON.parse(File.read(elements_path))
  injected = 0
  inject.each do |page_id, els|
    page = spec['pages'].find { |p| p['id'] == page_id }
    unless page
      warn "WARN: elements sidecar references unknown page #{page_id.inspect} — skipped"
      next
    end
    spec['elements'] ||= []
    existing = spec['elements'].map { |e| e['id'] }
    els.each do |el|
      next if existing.include?(el['id'])
      spec['elements'] << el
      existing << el['id']
      injected += 1
    end
  end
  puts "injected #{injected} container/header element(s) from #{elements_path}"
end
# Page NAME -> live page id. Built ONCE here — both the nav.invalid URL
# rewrite (below) and the navigate-button target.page repair (further below,
# from the actions-emitted manifest) resolve provisional page references
# through this SAME lookup. Do not build a second name->page map.
page_id_by_name = (spec['pages'] || []).each_with_object({}) { |p, h| h[p['name'].to_s.strip.downcase] = p['id'] }

# ---- v5.0-P2: navigation-button URL rewrite ---------------------------------
# Nav buttons are POSTed with the machine-recognizable placeholder
# https://nav.invalid/#page=<name> (the workbook URL doesn't exist until the
# POST returns). Now that it does: resolve each target page NAME to its live
# page id and rewrite the placeholder — in button `actions[].effects[].url`
# AND in text-pill markdown bodies (the workspace-gated-button fallback).
nav_path = opts[:nav_buttons] || (opts[:layout] && Dir.glob(File.join(File.dirname(opts[:layout]), '*-nav-buttons.json')).first)
if nav_path && File.exist?(nav_path)
  wb_meta = JSON.parse(http(:get, "/v2/workbooks/#{opts[:wb]}").body) rescue {}
  wb_url = wb_meta['url'].to_s
  if wb_url.empty?
    warn 'WARN: workbook URL unavailable — nav-button placeholders left in place'
  else
    rewritten = 0
    unresolved = []
    rewrite = lambda do |s|
      s.gsub(%r{https://nav\.invalid/#page=([^)"'\s<]+)}) do
        name = CGI.unescape(Regexp.last_match(1)) rescue Regexp.last_match(1)
        pid = page_id_by_name[name.strip.downcase]
        if pid
          rewritten += 1
          "#{wb_url}/page/#{pid}"
        else
          unresolved << name
          Regexp.last_match(0)
        end
      end
    end
    (spec['elements'] || []).each do |el|
      el['body'] = rewrite.call(el['body']) if el['body'].is_a?(String) && el['body'].include?('nav.invalid')
      (el['actions'] || []).each do |a|
        (a['effects'] || []).each do |ef|
          ef['url'] = rewrite.call(ef['url']) if ef['url'].is_a?(String) && ef['url'].include?('nav.invalid')
        end
      end
    end
    puts "nav buttons: #{rewritten} placeholder URL(s) rewritten to live page links"
    unresolved.uniq.each { |n| warn "WARN: nav button targets page #{n.inspect} — no live page by that name; placeholder left (verify by hand)" }
  end
end

# ---- v5.5: navigate-button target.page repair -------------------------------
# `navigate` effects on real kind:button elements (SIGMA_BUTTON_ELEMENTS=on)
# carry a PROVISIONAL target.page id: two page-id schemes coexist in this
# codebase — build-workbook-spec.rb:177 assigns "page-<slug>" while
# mechanical-specs.rb:1881 (the orchestrated pipeline customers actually run)
# assigns "page-dash-<N>" by array index — and build-charts-from-signals.rb
# cannot know at build time which scheme the final spec will use. It emits its
# best guess and records the human-readable target dashboard/page NAME on the
# <out>-actions-emitted.json manifest (`targetPageName`, keyed by `actionId`).
# Repair target.page BY NAME now that real page ids exist, through the SAME
# page_id_by_name lookup the nav.invalid URL rewrite above uses (built once,
# near the top of this file — do not build a second name->page map). Mirrors
# that rewrite's philosophy: never crash, never silently leave a broken
# target — an unresolved name gets a loud WARN naming the action and the page,
# with the provisional value left in place so it's easy to spot and fix.
manifest_path = opts[:layout] && Dir.glob(File.join(File.dirname(opts[:layout]), '*-actions-emitted.json')).first
if manifest_path && File.exist?(manifest_path)
  manifest = (JSON.parse(File.read(manifest_path)) rescue nil)
  manifest = [] unless manifest.is_a?(Array)
  nav_repaired = 0
  (spec['elements'] || []).each do |el|
    (el['actions'] || []).each do |a|
      entry = manifest.find { |m| m['actionId'] == a['id'] }
      next unless entry && entry['targetPageName']
      (a['effects'] || []).each do |eff|
        next unless eff['effect'] == 'navigate' && eff.dig('target', 'type') == 'page'
        resolved = page_id_by_name[entry['targetPageName'].to_s.strip.downcase]
        if resolved
          eff['target']['page'] = resolved
          nav_repaired += 1
        else
          warn "WARN: navigate action #{entry['actionId'].inspect} (#{a['id'].inspect}) targets page " \
               "#{entry['targetPageName'].inspect} — no live page by that name; provisional target " \
               "#{eff['target']['page'].inspect} left in place (verify by hand)"
        end
      end
    end
  end
  puts "navigate targets: #{nav_repaired} button action(s) repaired to live page ids" if nav_repaired > 0
end

# ---- v5.1: hidden-titles application ----------------------------------------
# The source hides these elements' worksheet titles (zone show-title='false').
# Applied HERE — the FINAL spec mutation — because the live API rejects
# name:{text, visibility:'hidden'} ("cannot mix … Use one or the other",
# probed 2026-07-12) and the bare {visibility:'hidden'} object breaks every
# upstream name-keyed matcher (layout els_by_name, parity, tile verify). At
# this point nothing else needs names.
# All sidecars, sorted (an unsorted `.first` was nondeterministic when more
# than one build wrote here — review-caught); ids are unioned. The builder
# deletes its sidecar when a rebuild hides nothing, so stale ids don't linger.
ht_paths = opts[:layout] ? Dir.glob(File.join(File.dirname(opts[:layout]), '*-hidden-titles.json')).sort : []
hidden_ids = ht_paths.flat_map do |p|
  body = JSON.parse(File.read(p)) rescue []
  # v5.1.4 shape {workbook:, ids:} or the legacy bare array
  body.is_a?(Hash) ? Array(body['ids']) : Array(body)
end.uniq
# v5.3 PATH-INDEPENDENT fallback: the sidecar is written by the MECHANICAL
# builder, so hand-authored specs (manual path, exit-4/15 recoveries) shipped
# every source-hidden worksheet title as visible chrome (round-5 owner-eye
# consensus defect on all six runs). Derive the hide-set directly from
# dashboard-layout.json (parse always runs): any element whose NAME equals a
# worksheet caption with show-title=false gets hidden too. kpi-chart excluded
# (its name IS the rendered KPI label).
begin
  dl_path = opts[:layout] && File.join(File.dirname(opts[:layout]), 'dashboard-layout.json')
  if dl_path && File.exist?(dl_path)
    dl = JSON.parse(File.read(dl_path))
    dl = [dl] unless dl.is_a?(Array)
    chart_zones = dl.flat_map { |d| d['zones'] || [] }
                    .select { |z| z['kind'] == 'chart' && !z['caption'].to_s.empty? }
    hide_caps  = chart_zones.select { |z| z['show_title'] == false }.map { |z| z['caption'].to_s.strip.downcase }.uniq
    # CONFLICT-SAFE (v5.3.1): a worksheet hidden on one dashboard but SHOWN on
    # another must not be hidden globally — drop conflicted captions.
    shown_caps = chart_zones.reject { |z| z['show_title'] == false }.map { |z| z['caption'].to_s.strip.downcase }.uniq
    hide_caps -= shown_caps
    non_viz = %w[kpi-chart control text image container divider]
    if hide_caps.any?
      (spec['elements'] || []).each do |el|
        next unless el['name'].is_a?(String) && !non_viz.include?(el['kind'].to_s)
        next unless hide_caps.include?(el['name'].strip.downcase)
        hidden_ids << el['id'] unless hidden_ids.include?(el['id'])
      end
    end
  end
rescue StandardError => e
  warn "WARN: hidden-title caption fallback skipped (#{e.class}: #{e.message.to_s[0, 80]})"
end
if hidden_ids.any?
  hid = 0
  (spec['elements'] || []).each do |el|
    next unless hidden_ids.include?(el['id'])
    el['name'] = { 'visibility' => 'hidden' }
    hid += 1
  end
  puts "hidden titles: #{hid}/#{hidden_ids.size} element title(s) hidden (source show-title=false; " \
       "#{ht_paths.any? ? ht_paths.map { |p| File.basename(p) }.join(', ') : 'caption fallback'})"
end

# ---- v5.4: pivot grand-totals SHIP step -------------------------------------
# Re-hide pivot grand totals as the FINAL mutation, once verification has run
# against totals-free pivots (a `totals` key 500s a pivot's CSV export — probe-
# isolated v5.4: the key's PRESENCE is the sole trigger, value type irrelevant).
# Path-independent (like the hidden-titles caption fallback): every pivot-table
# lacking a `totals` key gains {showGrandTotals:'hidden'}. An optional sibling
# *-pivot-totals.json sidecar ({workbook?, totals:{elId => totalsSpec}}) OVERRIDES
# per element id (preserves a deliberate showGrandTotals:'shown' or subtotals
# choice). Runs whenever --apply-pivot-totals is set; idempotent (a pivot that
# already carries a totals key is left as-is).
if opts[:apply_pivot_totals]
  overrides = {}
  # v5.4.9 review fix: the sidecar glob was gated on --layout, but the only
  # automated caller (migrate-tableau.rb --finalize ship step) passes no
  # --layout — the documented override channel had ZERO live readers. Glob the
  # layout dir, the --workdir, and the cwd (manual runs are launched from the
  # workdir). LAST definition per element id wins (deterministic: dirs in that
  # order, files sorted within each) — so verify-anchors' auto-written
  # `anchors-restore-pivot-totals.json` (sorts first) yields to an operator-
  # authored sidecar for the same element id.
  side_dirs = [opts[:layout] && File.dirname(opts[:layout]), opts[:workdir], Dir.pwd].compact.uniq
  side = side_dirs.flat_map { |d| Dir.glob(File.join(d, '*-pivot-totals.json')).sort }.uniq
  side.each do |p|
    body = JSON.parse(File.read(p)) rescue nil
    tot = body.is_a?(Hash) ? (body['totals'] || {}) : {}
    tot.each { |k, v| overrides[k.to_s] = v } if tot.is_a?(Hash)
  end
  puts "pivot totals: sidecar override(s) read from #{side.join(', ')}" if side.any?
  applied = 0
  (spec['elements'] || []).each do |el|
    next unless el.is_a?(Hash) && el['kind'] == 'pivot-table'
    ov = overrides[el['id'].to_s]
    if ov
      el['totals'] = ov; applied += 1
    elsif !el.key?('totals')
      el['totals'] = { 'showGrandTotals' => 'hidden' }; applied += 1
    end
  end
  puts "pivot totals: showGrandTotals applied to #{applied} pivot(s)" \
       "#{overrides.any? ? " (#{overrides.size} sidecar override(s))" : ''}"
end

# Fail before the destructive PUT if an element is absent from layout, appears
# twice, or pages carry legacy nested elements.
shape_errors = WorkbookCode.validate(Sigma::CodeRep.wrap(spec))
abort("FATAL: invalid workbook layout:\n  - #{shape_errors.join("\n  - ")}") if shape_errors.any?

# Preserve the complete document (settings, overlays/panels, agents, and any
# future fields), changing only the fields above.
resp = http(:put, "/v2/workbooks/#{opts[:wb]}/spec", JSON.pretty_generate(Sigma::CodeRep.wrap(spec)))
parsed = YAML.safe_load(resp.body, permitted_classes: [Date, Time])
puts parsed['workbookId'] ? "PUT ok: workbookId=#{parsed['workbookId']}" : "ERROR: #{parsed.inspect}"
exit(parsed['workbookId'] ? 0 : 1)
