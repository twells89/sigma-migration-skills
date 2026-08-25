#!/usr/bin/env ruby
# POST a DM or workbook spec, parse the YAML response, then GET the spec back
# and emit a clean JSON map of pages → elements with server-assigned IDs.
# On the datamodel path, a post-readback COLUMN CENSUS (lib/column_census.rb)
# compares the posted spec's per-element columns against the readback and
# WARNs loudly on any silent drop — columns that vanish without an HTTP error
# or a type="error" entry (a live migration lost 550 of 599 columns this way).
# It is a WARN, not a hard stop: the pre-POST ref-resolution gate
# (assert-wb-refs-resolve.rb) hard-stops the workbook build downstream.
#
# Usage:
#   ruby post-and-readback.rb --type datamodel|workbook --spec <spec.json> --out <id-map.json>
#
# Exit codes:
#   0  posted + readback clean
#   1  hard failure (abort) — POST/PUT rejected, nothing recoverable
#   2  column(s) resolved to type=error on the live DM/workbook
#   3  workbook layout lint violations
#   4  workbook control lint violations
#   6  DATAMODEL QUARANTINED (only with --quarantine-on-failure): one or more
#      broken elements were removed to <workdir>/deferred-elements.json and the
#      REMAINING spec re-POSTed once. The DM is PARTIAL — the migration may NOT
#      be declared GREEN while deferred-elements.json is non-empty
#      (assert-phase6-ran.rb enforces this). Fix the deferred elements, restore
#      them into the spec, re-POST, then delete the file.
#   7  MANUAL-PATH REFUSED: this is a STANDALONE invocation against a workdir the
#      orchestrator drove (migrate-state.json present) with no orchestrator STOP
#      on record (<workdir>/manual-path-authorized.json absent). The manual path
#      is entered via an orchestrator STOP, not cold — re-run the orchestrator,
#      or (deliberately) add --allow-manual-spec "<reason>" (a quality waiver).

require 'net/http'
require 'uri'
require 'json'
require 'yaml'
require 'date'
require 'time'
require 'optparse'

abort 'FATAL: SIGMA_SHADOW_COMPILE=1 forbids POST/PUT/readback operations' if ENV['SIGMA_SHADOW_COMPILE'] == '1'

opts = {}
OptionParser.new do |p|
  p.on('--type T', %w[datamodel workbook]) { |v| opts[:type] = v }
  p.on('--spec P')                         { |v| opts[:spec] = v }
  p.on('--out P')                          { |v| opts[:out]  = v }
  p.on('--workdir P', 'Per-conversion working dir (default: dir of --spec). Used to track posted workbook IDs across retries.') { |v| opts[:workdir] = v }
  p.on('--skip-layout-lint') { opts[:skip_lint] = true }
  p.on('--skip-control-lint') { opts[:skip_control_lint] = true }
  p.on('--control-scope P', 'control-scope.json sidecar (default: <workdir>/control-scope.json if present)') { |v| opts[:control_scope] = v }
  p.on('--update-id ID', 'PUT the spec to this existing workbook/DM id instead of POSTing a new one (retry-safe; avoids orphan workbooks). For workbooks, if omitted, the last id in posted-workbooks.jsonl (or migrate-state.json) is reused automatically.') { |v| opts[:update_id] = v }
  p.on('--force-new-workbook REASON', 'workbooks only: POST a brand-new workbook even though this workdir already ' \
       'recorded one (posted-workbooks.jsonl / migrate-state.json). The old workbook is ORPHANED. Counted as a ' \
       'quality waiver by assert-phase6-ran; name the reason in your report.') { |v| opts[:force_new] = v }
  p.on('--allow-manual-spec REASON', 'deliberately run this script STANDALONE on an orchestrator-driven workdir ' \
       'with no orchestrator STOP on record (manual-path-authorized.json absent). Counted as a quality waiver; ' \
       'name the reason in your report.') { |v| opts[:allow_manual_spec] = v }
  p.on('--quarantine-on-failure', 'DATAMODEL only: when the POST fails naming specific element(s), or the post-POST column census resolves specific elements to type=error, move those elements to <workdir>/deferred-elements.json, re-POST ONCE without them, and exit 6 (PARTIAL DM — never GREEN until the file is resolved). Default (no flag): fail loudly, quarantine nothing.') { opts[:quarantine] = true }
  p.on('--skip-spec-verify REASON', 'workbooks only: skip the POST /v2/workbooks/spec/verify server-side preflight (quality waiver — name it in your report).') { |v| opts[:skip_spec_verify] = v }
  p.on('--skip-style-normalize REASON', 'workbooks only: skip the v5.1 source-derived style contract (pivot totals, format grammar, scheme defaults). Quality waiver — name it in your report.') { |v| opts[:skip_style_normalize] = v }
end.parse!
%i[type spec out].each { |k| abort("missing --#{k}") unless opts[k] }
opts[:workdir] ||= File.dirname(File.expand_path(opts[:spec]))
require 'fileutils'
FileUtils.mkdir_p(opts[:workdir])

$LOAD_PATH.unshift File.expand_path('lib', __dir__)
require 'sigma_rest'
require 'dm_quarantine'
require 'code_rep'
require 'workbook_code'
begin
  require 'offramp' # off-ramp trail (waiver observability); optional — never load-bearing
rescue LoadError
  nil
end

# ── 🚧 Standalone manual-path gate (P1) ──────────────────────────────────────
# The exact field failure: an agent hand-drives post-and-readback against a
# workdir the ORCHESTRATOR was driving, skipping the gated spine (preflight,
# Phase 6, the hard gate) — and POSTs a fresh workbook per fix attempt. When
# this is a cold standalone run (the orchestrator marks its children with
# SIGMA_ORCHESTRATED_RUN=1) on an orchestrator workdir (migrate-state.json
# present), require an orchestrator STOP on record (manual-path-authorized.json)
# or an explicit --allow-manual-spec waiver. The manual path is entered via an
# orchestrator STOP, not cold.
_manual_token = File.join(opts[:workdir], 'manual-path-authorized.json')
_orchestrated = ENV['SIGMA_ORCHESTRATED_RUN'] == '1'
if !_orchestrated && File.exist?(File.join(opts[:workdir], 'migrate-state.json')) &&
   !File.exist?(_manual_token)
  if opts[:allow_manual_spec].to_s.strip.empty?
    warn '========================================================================'
    warn 'REFUSED — the manual path is entered via an orchestrator STOP, not cold.'
    warn "This workdir (#{opts[:workdir]}) is orchestrator-driven (migrate-state.json"
    warn "present) but no STOP is on record (#{File.basename(_manual_token)} absent)."
    warn 'Hand-driving this script skips the gated spine (preflight/control lint,'
    warn 'Phase 6 parity, assert-phase6-ran) — the exact way runs ship unverified.'
    warn 'Do ONE of:'
    warn '  * re-run the orchestrator (it invokes this script itself):'
    warn '      ruby scripts/migrate-tableau.rb --workbook "<name>" --connection <id> [--out <workdir>]'
    warn '  * if an orchestrator STOP routed you here, its token authorizes the path'
    warn '    (converter-stop / workbook-handoff / decisions-stop write it);'
    warn '  * deliberately standalone? add --allow-manual-spec "<reason>" (quality waiver).'
    warn '========================================================================'
    exit 7
  end
  warn "WARN: standalone run on an orchestrated workdir ALLOWED (--allow-manual-spec: #{opts[:allow_manual_spec]}) — " \
       'counted as a quality waiver; name it in your report.'
  Offramp.log(opts[:workdir], kind: 'manual-spec', reason: "waiver: #{opts[:allow_manual_spec]}") if defined?(Offramp)
end

# PR-14: every honored --skip-* leaves a record on the off-ramp trail (they
# are workbook-path waivers; DM runs never honor them, so nothing is logged).
if opts[:type] == 'workbook' && defined?(Offramp)
  { '--skip-spec-verify'     => opts[:skip_spec_verify],
    '--skip-style-normalize' => opts[:skip_style_normalize],
    '--skip-layout-lint'     => opts[:skip_lint],
    '--skip-control-lint'    => opts[:skip_control_lint] }.each do |flag, val|
    next unless val
    Offramp.log(opts[:workdir], kind: 'skip-flag-waived',
                reason: (val.is_a?(String) ? val : nil), detail: flag)
  end
end

QUARANTINE = opts[:quarantine] && opts[:type] == 'datamodel'
DEFERRED_PATH = File.join(opts[:workdir], 'deferred-elements.json')
warn 'NOTE: --quarantine-on-failure only applies to --type datamodel; ignored.' if opts[:quarantine] && opts[:type] != 'datamodel'

BASE = ENV.fetch('SIGMA_BASE_URL')

POST_PATH = opts[:type] == 'datamodel' ? '/v2/dataModels/spec'              : '/v2/workbooks/spec'
GET_PATH  = opts[:type] == 'datamodel' ? '/v2/dataModels/%s/spec'           : '/v2/workbooks/%s/spec'
ID_FIELD  = opts[:type] == 'datamodel' ? 'dataModelId'                      : 'workbookId'

# Wraps a single Sigma REST call with automatic 401-retry-after-refresh
# (tokens last ~1 hour; long conversions outlive a single token). Returns
# the raw Net::HTTPResponse so existing .body / .is_a?(Net::HTTPSuccess)
# checks below keep working unchanged.
def http(method, path, body = nil, accept_json: false)
  attempts = 0
  loop do
    attempts += 1
    uri = URI("#{BASE}#{path}")
    req = case method
          when :post then r = Net::HTTP::Post.new(uri); r.body = body; r['Content-Type'] = 'application/json'; r
          when :put  then r = Net::HTTP::Put.new(uri);  r.body = body; r['Content-Type'] = 'application/json'; r
          when :get  then Net::HTTP::Get.new(uri)
          end
    req['Authorization'] = "Bearer #{Sigma.auth_token}"
    req['Accept']        = 'application/json' if accept_json
    res = Net::HTTP.start(uri.host, uri.port, use_ssl: true, read_timeout: 120) { |h| h.request(req) }
    if res.code.to_i == 401 && attempts == 1 && ENV['SIGMA_CLIENT_ID']
      warn '  [auth] Sigma token expired mid-run, refreshing and retrying...'
      Sigma.refresh_token!
      next
    end
    return res
  end
end

# v5.1 STYLE-NORMALIZE: deterministic source-derived style contract enforced
# on EVERY workbook spec reaching this choke point — mechanical AND
# hand-authored (round-4 forensics: 2 of 3 runs hand-authored after exit-4,
# so builder-only fixes could not close the chrome gaps). Rules are
# conservative (grammar-invalid formats, missing pivot totals, default-royal
# schemes only); every change is logged to <workdir>/style-normalize.json.
# --skip-style-normalize "<reason>" bypasses (named waiver).
def style_normalize!(body_str, workdir, skip_reason)
  return body_str unless $opts_type == 'workbook'
  if skip_reason
    warn "WARN: style-normalize SKIPPED (--skip-style-normalize: #{skip_reason}) — quality waiver."
    return body_str
  end
  spec = JSON.parse(body_str) rescue nil
  return body_str unless spec.is_a?(Hash)
  doc = WorkbookCode.document(spec)
  return body_str unless doc['elements'].is_a?(Array)
  require_relative 'lib/style_normalize'
  changes = StyleNormalize.normalize!(
    { 'pages' => [{ 'elements' => doc['elements'] }], 'settings' => doc['settings'] })
  if changes.any?
    File.write(File.join(workdir, 'style-normalize.json'), JSON.pretty_generate(changes)) rescue nil
    warn "style-normalize: #{changes.size} change(s) applied (#{changes.map { |c| c['rule'] }.uniq.join(', ')}) — style-normalize.json"
    return JSON.generate(spec)
  end
  body_str
end

# v5.4: PATH-INDEPENDENT palette. Apply the source-derived theme to EVERY
# workbook spec reaching this choke point — mechanical AND hand-authored
# (the exit-4 recovery PUT shipped default-blue where the source declares its
# own palette, because only build_wb_spec applied the theme). The derived
# theme lives in the builder's output ('theme' key of chart-specs.json) or
# its flat-mode sidecar (chart-specs-theme.json). No-op when the spec already
# carries a document.settings.theme.overrides or no derived theme exists;
# never load-bearing.
def ensure_theme!(body_str, workdir)
  return body_str unless $opts_type == 'workbook'
  spec = JSON.parse(body_str) rescue nil
  return body_str unless spec.is_a?(Hash)
  doc = WorkbookCode.document(spec)
  return body_str unless doc['elements'].is_a?(Array)
  return body_str if doc.dig('settings', 'theme', 'overrides').is_a?(Hash) && doc['settings']['theme']['overrides'].any?
  theme = nil
  side = File.join(workdir, 'chart-specs-theme.json')
  main = File.join(workdir, 'chart-specs.json')
  if File.exist?(side)
    theme = JSON.parse(File.read(side)) rescue nil
  elsif File.exist?(main)
    cs = JSON.parse(File.read(main)) rescue nil
    theme = cs['theme'] if cs.is_a?(Hash)
  end
  return body_str unless theme.is_a?(Hash) && theme.any?
  require_relative 'lib/theme_derive'
  ThemeDerive.apply!(doc, theme)
  overrides = doc.dig('settings', 'theme', 'overrides')
  if overrides.is_a?(Hash) && overrides.any?
    warn "theme: source-derived theme applied at post time (#{overrides.keys.join(', ')}) — " \
         'path-independent palette (the incoming spec carried none)'
    return JSON.generate(spec)
  end
  body_str
rescue StandardError => e
  warn "WARN: theme-ensure hook failed (#{e.message}) — spec posted as provided"
  body_str
end

# v5.0 preflight: POST /v2/workbooks/spec/verify — Sigma's own server-side
# spec validation with NO persistence. Runs the real validator before the
# create/update, so a spec defect surfaces as a clean local error instead of
# a failed create (workbook POSTs are create-only; a half-validated failure
# costs an orphan-management cycle). Fail-closed on a validation verdict
# (4xx WITH a parseable error body), fail-open on endpoint availability
# (404/405/5xx/network — older tenants may not serve it). Workbooks only;
# no verify endpoint is documented for dataModels. --skip-spec-verify "<reason>"
# bypasses (quality waiver — name it in your report).
def verify_spec!(body, skip_reason, update: false)
  return unless opts_type_workbook?
  if skip_reason
    warn "WARN: spec/verify preflight SKIPPED (--skip-spec-verify: #{skip_reason}) — quality waiver."
    return
  end
  res = http(:post, '/v2/workbooks/spec/verify', body, accept_json: true)
  code = res.code.to_i
  if res.is_a?(Net::HTTPSuccess)
    warn 'spec/verify preflight ok (server-side validation passed)'
  elsif [400, 409, 422].include?(code)
    parsed = (JSON.parse(res.body) rescue nil)
    msg = parsed.is_a?(Hash) ? parsed['message'].to_s : res.body.to_s[0, 800]
    # verify validates the CREATE envelope (folderId required — live-probed
    # 2026-07-11). An update body legitimately carries no folderId, so an
    # envelope-only complaint on a PUT is a shape mismatch, not a spec defect.
    if update && msg.include?('folderId')
      warn 'NOTE: spec/verify wants the create envelope (folderId) this PUT body lacks — preflight skipped for update.'
      return
    end
    warn "\nFAIL — Sigma spec/verify rejected the spec (HTTP #{code}) BEFORE any create/update:"
    warn(parsed ? (JSON.pretty_generate(parsed) rescue msg) : msg)
    abort 'Fix the spec (validate-spec.rb hints + the server errors above), then re-run. ' \
          'Nothing was posted — no orphan to clean up.'
  else
    warn "NOTE: spec/verify preflight unavailable (HTTP #{code}) — proceeding without it."
  end
end
def opts_type_workbook?; $opts_type == 'workbook'; end
$opts_type = opts[:type]

# W2.6 (review fix-wave, 2026-07-30, Important finding 3): derivedVia/partial/
# droppedConditions are object-graph relationship-derivation PROVENANCE
# (converter/tableau.mjs's PR2a ladder) — they exist purely so two EARLIER
# pipeline stages can read them off the SAME dm-spec Hash the converter
# returned: lib/join_plan.rb threads them into join-plan.json so gate 16's
# warehouse uniqueness probe can single out and validate an INFERRED key
# rather than trust it, and emit-relationship-coverage.rb reads them into the
# audit coverage ledger. Both consumers run against the converter's OWN
# output, upstream of this script entirely — they have already done their job
# by the time a spec reaches post-and-readback.rb, so stripping the fields
# here cannot affect either of them (confirmed by
# test-relationship-derivation.rb, which drives the converter + JoinPlan.derive
# directly and never touches this file).
#
# They are NOT part of the documented dataModels/spec relationship shape, and
# we have not live-POSTed one to find out whether Sigma's decoder tolerates an
# unknown relationship field (warehouse-hungry live verification is
# deliberately deferred — see the standing one-workstream-at-a-time
# constraint). validate-spec.rb (this skill's own client-side spec linter)
# tolerates them, but that proves nothing about Sigma's server-side decoder.
# If that decoder is strict about unknown fields, shipping them would 400
# EVERY logical-model migration that wired a relationship this way — strictly
# worse than the status quo of never having sent them. Strip, don't gamble.
DERIVATION_ONLY_REL_KEYS = %w[derivedVia partial droppedConditions].freeze
def strip_relationship_derivation_fields!(spec)
  return 0 unless spec.is_a?(Hash)
  n = 0
  (spec['pages'] || []).each do |pg|
    (pg['elements'] || []).each do |el|
      (el['relationships'] || []).each do |rel|
        next unless rel.is_a?(Hash)
        DERIVATION_ONLY_REL_KEYS.each { |k| n += 1 if rel.delete(k) }
      end
    end
  end
  n
end

# String-in/string-out wrapper for the JSON body variables (post_body/put_body)
# this file threads through style_normalize!/ensure_theme! — datamodel-only
# (those relationship fields never appear on a workbook spec's elements) and a
# silent no-op when the body isn't parseable JSON with a 'pages' array (never
# block the POST/PUT on a stripping concern).
def strip_relationship_derivation_fields_from_json(body_str)
  return body_str unless $opts_type == 'datamodel'
  spec = (JSON.parse(body_str) rescue nil)
  return body_str unless spec.is_a?(Hash) && spec['pages']
  n = strip_relationship_derivation_fields!(spec)
  return body_str if n.zero?
  warn "post-and-readback: stripped #{n} relationship-derivation-provenance field(s) " \
       '(derivedVia/partial/droppedConditions) from the outgoing DM spec immediately before POST/PUT — ' \
       "consumed earlier in the pipeline (lib/join_plan.rb, emit-relationship-coverage.rb); Sigma's tolerance " \
       'for unknown relationship fields is unverified, so they are not sent.'
  JSON.generate(spec)
end

# Orphan-prevention pre-check: workbook POSTs are create-only. If this is a
# second invocation in the same conversion, the previous workbook is being
# orphaned in the customer's My Documents. WARN loudly and emit the PUT
# alternative. Tracked at beads-sigma-38a (3-workbook customer regression).
posted_log = File.join(opts[:workdir],
                       opts[:type] == 'workbook' ? 'posted-workbooks.jsonl' : 'posted-datamodels.jsonl')
prior_ids = []
if posted_log && File.exist?(posted_log)
  prior_ids = File.readlines(posted_log).map { |l| JSON.parse(l)['id'] rescue nil }.compact
end
# Decide POST (create) vs PUT (update existing). An explicit --update-id always
# wins; otherwise, for a workbook retry, auto-reuse the last id we posted in this
# conversion so a re-run UPDATES the workbook in place instead of orphaning it
# (beads-sigma-38a — the 3-workbook customer regression). The orchestrator's
# migrate-state.json is a second id source (a standalone fix attempt may point at
# a workdir whose posted-workbooks.jsonl never existed — the new-workbook-per-fix
# field failure). PUT is the FORCED default whenever an id is known; a plain POST
# on such a workdir requires --force-new-workbook "<reason>" (quality waiver —
# the old object is orphaned). DATAMODELS get the SAME discipline (field
# failure: every mechanical re-run POSTed a fresh DM, littering the customer
# folder with near-identical models): the last id from posted-datamodels.jsonl —
# or, for workdirs that predate that log, the prior run's --out id-map — is
# auto-PUT unless --force-new-workbook names a reason.
state_id = nil
if opts[:type] == 'workbook'
  state_id = (JSON.parse(File.read(File.join(opts[:workdir], 'migrate-state.json')))['workbook_id'] rescue nil)
elsif File.exist?(opts[:out].to_s)
  state_id = (JSON.parse(File.read(opts[:out]))['dataModelId'] rescue nil)
end
known_id = opts[:update_id] || prior_ids.last || state_id
if opts[:force_new]
  abort 'FATAL: --force-new-workbook contradicts --update-id — pass one or the other.' if opts[:update_id]
  if known_id
    warn "WARN: --force-new-workbook (#{opts[:force_new]}) — POSTing a NEW #{opts[:type]} although this workdir " \
         "already recorded #{known_id}. The old #{opts[:type]} is ORPHANED. Counted as a quality waiver; " \
         'name it in your report.'
    Offramp.log(opts[:workdir], kind: 'force-new-workbook',
                reason: opts[:force_new].to_s, detail: "prior #{opts[:type]} #{known_id} orphaned") if defined?(Offramp)
  end
  known_id = nil
end
update_id = known_id
if update_id && !opts[:update_id]
  warn "same-#{opts[:type]} PUT discipline: this workdir already recorded #{opts[:type]} #{update_id} " \
       "(#{prior_ids.any? ? File.basename(posted_log) : 'prior id-map/state'}) — updating it IN PLACE. " \
       "A plain POST would orphan it; to deliberately create a new #{opts[:type]}, re-run with " \
       '--force-new-workbook "<reason>" (quality waiver).'
end

if update_id
  warn "UPDATE mode: PUT #{opts[:type]} #{update_id} (no new #{opts[:type]} created)"
  put_body = File.read(opts[:spec])
  # Layout preservation (bead: layout-wipe-on-re-PUT). A workbook's applied layout
  # lives at document.layout (put-layout.rb writes it there). PUTting a
  # spec WITHOUT that field REPLACES the whole spec and wipes the layout, so the
  # workbook falls back to a single-column stack. If the outgoing spec carries no
  # layout, carry over the LIVE workbook's current layout so this PUT is
  # layout-preserving. put-layout.rb (the intended LAST write) still overrides.
  # Under the orchestrator, put-layout.rb re-derives and re-applies the layout
  # right after this PUT — carrying the live layout here is at best redundant
  # and at worst wrong: mechanical element ids are DETERMINISTIC across
  # rebuilds, so a stale-generation layout can pass the overlap check yet no
  # longer match the freshly planned bands (live-caught: the phase-4 lint then
  # fails on the prior run's geometry). Standalone spot fixes (no orchestrator,
  # no follow-up put-layout) still get the carry.
  if opts[:type] == 'workbook' && ENV['SIGMA_ORCHESTRATED_RUN'] != '1'
    out_spec = (YAML.safe_load(put_body, permitted_classes: [Date, Time]) rescue nil)
    out_doc = out_spec.is_a?(Hash) ? WorkbookCode.document(out_spec) : {}
    if out_spec.is_a?(Hash) && out_doc['layout'].to_s.strip.empty?
      live = http(:get, format(GET_PATH, update_id))
      live_spec = (YAML.safe_load(live.body, permitted_classes: [Date, Time]) rescue nil)
      # Workbook code-rep nests pages/layout under `document` (live since
      # 2026-08); unwrap before reading — this GET is workbook-only here.
      live_spec = Sigma::CodeRep.document(live_spec) if live_spec.is_a?(Hash)
      live_layout = live_spec.is_a?(Hash) ? live_spec['layout'].to_s : ''
      unless live_layout.strip.empty?
        # The layout XML references element ids. Banded layouts reference container
        # + header elements that put-layout.rb injects from its `.elements.json`
        # sidecar — they live in the LIVE spec's pages but NOT in this outgoing
        # spec, so blindly copying the layout 400s ("Dependency not found"). Pull
        # any layout-referenced elements this spec lacks from the live spec (match
        # page by id, then name) so the refs resolve, then carry the layout.
        ref_ids  = live_layout.scan(/elementId="([^"]+)"/).flatten.uniq
        have_ids = Array(out_doc['elements']).filter_map { |element| element['id'] }
        missing  = ref_ids - have_ids
        # GENERATION check: a carry is only sound when the outgoing spec still
        # contains the elements the layout places (a spot fix — ids stable). A
        # FULL REBUILD assigns all-new chart ids; carrying the old layout then
        # imports the old charts below (duplicates) and leaves every new chart
        # unplaced (empty bands + dead rows — caught live by the layout lint).
        # Drop it and let put-layout.rb re-derive placement from layout.xml,
        # which the orchestrator runs right after this PUT.
        stale_generation = (ref_ids & have_ids).size < (ref_ids.size * 0.3).ceil
        if stale_generation
          warn "layout NOT carried: the live layout places #{ref_ids.size} element(s) but only " \
               "#{(ref_ids & have_ids).size} exist in the outgoing spec (stale generation — full rebuild). " \
               'Run put-layout.rb AFTER this PUT or it renders single-column (the orchestrator does).'
        elsif missing.any? && live_spec['elements'].is_a?(Array)
          live_by_id = live_spec['elements'].each_with_object({}) { |element, index| index[element['id']] = element }
          missing.dup.each do |mid|
            le = live_by_id[mid]
            next unless le
            (out_doc['elements'] ||= []) << le
            missing.delete(mid)
          end
        end
        if !stale_generation && missing.empty?
          out_doc['layout'] = live_layout
          put_body = JSON.generate(out_spec)
          warn 'layout-preserve: carried the live workbook layout (+ its container/header elements) into the PUT.'
        elsif !stale_generation
          warn "layout NOT auto-preserved: #{missing.size} layout-referenced element(s) missing and unrecoverable " \
               "(#{missing.first(3).join(', ')}) — run put-layout.rb AFTER this PUT or it renders single-column."
        end
      end
    end
  end
  put_body = style_normalize!(put_body, opts[:workdir], opts[:skip_style_normalize])
  put_body = ensure_theme!(put_body, opts[:workdir])
  put_body = strip_relationship_derivation_fields_from_json(put_body)
  # Workbook code-rep (verify AND the PUT itself) requires the nested
  # `document` envelope (verified live 2026-08-03/04: the flat body 400s,
  # INCLUDING on /verify) — wrap immediately before both calls, once every
  # flat-JSON mutation above (style/theme/relationship-strip) is done. The
  # datamodel surface is confirmed NOT changing, so only the workbook branch
  # wraps.
  if opts[:type] == 'workbook'
    wb_doc = JSON.parse(put_body)
    shape_errors = WorkbookCode.validate(wb_doc)
    abort("workbook code-representation invalid:\n  - #{shape_errors.join("\n  - ")}") if shape_errors.any?
    put_body = JSON.generate(Sigma::CodeRep.wrap(Sigma::CodeRep.document(wb_doc), extra: Sigma::CodeRep.metadata(wb_doc)))
  end
  verify_spec!(put_body, opts[:skip_spec_verify], update: true)
  # W2.5: DM PUT id-stability guard. A Sigma dataModel PUT can RE-MINT element ids
  # (field-caught 2026-07: AAAAAAAAAB -> b4pAUi0swJ), which silently bricks any
  # dependent workbook — every tile then errors "graph resolver exceeded the
  # iteration limit: 200" (~12 min of rebuild + an orphaned broken workbook). Snapshot
  # the live DM element ids before the PUT so the reassignment is caught after.
  $dm_pre_ids = nil
  if opts[:type] == 'datamodel'
    _pre = (JSON.parse(http(:get, format(GET_PATH, update_id), accept_json: true).body) rescue nil)
    $dm_pre_ids = _pre.is_a?(Hash) ? (_pre['pages'] || []).flat_map { |p| (p['elements'] || []).map { |e| e['id'] } }.compact : nil
  end
  resp = http(:put, format(GET_PATH, update_id), put_body)
  parsed = YAML.safe_load(resp.body, permitted_classes: [Date, Time])
  oid = parsed[ID_FIELD] || update_id
  abort("PUT failed (HTTP #{resp.code}): #{parsed.inspect}") unless resp.is_a?(Net::HTTPSuccess)
  warn "PUT ok: #{ID_FIELD}=#{oid}"
else
  post_body = style_normalize!(File.read(opts[:spec]), opts[:workdir], opts[:skip_style_normalize])
  post_body = ensure_theme!(post_body, opts[:workdir])
  post_body = strip_relationship_derivation_fields_from_json(post_body)
  # W2.4 preflight: duplicate element/control ids fail the POST with an opaque
  # API 400 (field: the multi-DS converter minted "AAAAAAAAAB" twice + controlId
  # "Region" twice — ~8 min of root-causing, both field-workbook runs). Name the
  # duplicates BEFORE the network call and hard-stop: dupes mean the GENERATOR is
  # broken (fix it), not the spec (auto-renaming here would desync references).
  begin
    _pf = JSON.parse(post_body)
    _ids = Hash.new(0)
    _elements =
      if opts[:type] == 'workbook'
        Sigma::CodeRep.workbook_elements(_pf)
      else
        (_pf['pages'] || []).flat_map { |page| page['elements'] || [] }
      end
    _elements.each do |el|
      _ids["element id #{el['id']}"] += 1 if el['id']
      _ids["controlId #{el['controlId']}"] += 1 if el['controlId']
    end
    _dupes = _ids.select { |_k, n| n > 1 }
    if _dupes.any?
      warn "FATAL: duplicate ids in the outgoing #{opts[:type]} spec — the POST would 400. Duplicates:"
      _dupes.each { |k, n| warn "         #{k} (used #{n}x)" }
      warn '       This is a GENERATOR bug (multi-datasource converter id collision — see'
      warn '       converter W2.4 fix). Regenerate the spec; do not hand-rename ids (references desync).'
      exit 1
    end
  rescue JSON::ParserError
    nil # non-JSON body (YAML spec) — the API remains the validator
  end
  # Workbook code-rep (verify AND the POST itself) requires the nested
  # `document` envelope (verified live 2026-08-03/04: the flat body 400s,
  # INCLUDING on /verify) — wrap immediately before both calls, AFTER the
  # duplicate-id preflight above (which needs flat `pages`/`elements`). The
  # datamodel surface is confirmed NOT changing, so only the workbook branch
  # wraps.
  if opts[:type] == 'workbook'
    wb_doc = JSON.parse(post_body)
    shape_errors = WorkbookCode.validate(wb_doc)
    abort("workbook code-representation invalid:\n  - #{shape_errors.join("\n  - ")}") if shape_errors.any?
    post_body = JSON.generate(Sigma::CodeRep.wrap(Sigma::CodeRep.document(wb_doc), extra: Sigma::CodeRep.metadata(wb_doc)))
  end
  verify_spec!(post_body, opts[:skip_spec_verify])
  resp = http(:post, POST_PATH, post_body)
  parsed = YAML.safe_load(resp.body, permitted_classes: [Date, Time])
  oid = parsed.is_a?(Hash) ? parsed[ID_FIELD] : nil
  # Rec5 quarantine (opt-in): a POST killed by ONE broken element must not lose
  # the other N-1. If the API error names attributable element(s), defer them
  # to <workdir>/deferred-elements.json and re-POST ONCE without them. If the
  # error is not attributable, fail loudly exactly as before.
  if oid.nil? && QUARANTINE
    spec_doc = JSON.parse(File.read(opts[:spec]))
    found = DmQuarantine.offending_from_error(spec_doc, resp.body.to_s)
    if found[:ids].any?
      q = DmQuarantine.quarantine(spec_doc, found[:ids], found[:reasons])
      $quarantined = q[:deferred]
      File.write(DEFERRED_PATH, JSON.pretty_generate(
        DmQuarantine.deferred_doc(q[:deferred], spec_path: File.expand_path(opts[:spec]))))
      # Same strip as the primary POST body above — this cleaned spec is what
      # actually goes out on the re-POST below, so it needs it independently
      # (deferred-elements.json, written just above, is forensics-only and
      # deliberately keeps the provenance fields).
      strip_relationship_derivation_fields!(q[:spec])
      cleaned_path = File.join(opts[:workdir], 'dm-spec.quarantined.json')
      File.write(cleaned_path, JSON.pretty_generate(q[:spec]))
      warn "QUARANTINE: POST failed naming #{found[:ids].size} element(s) — deferred to #{DEFERRED_PATH}; re-POSTing ONCE without them (#{cleaned_path})"
      found[:ids].each { |id| warn "  - #{id}: #{found[:reasons][id]}" }
      resp = http(:post, POST_PATH, File.read(cleaned_path))
      parsed = YAML.safe_load(resp.body, permitted_classes: [Date, Time])
      oid = parsed.is_a?(Hash) ? parsed[ID_FIELD] : nil
      abort("POST failed AGAIN after quarantining #{found[:ids].size} element(s) — not a single-element failure. " \
            "Deferred file kept for forensics: #{DEFERRED_PATH}. Error: #{parsed.inspect}") if oid.nil?
    end
  end
  abort("POST failed: #{parsed.inspect}") if oid.nil?
  warn "POST ok: #{ID_FIELD}=#{oid}"

  # Append the new ID to the per-conversion log. Newline-delimited JSON so
  # multiple processes can append safely (atomic append on POSIX). Only on
  # create — a PUT reuses an existing id and adds no orphan to track.
  if posted_log
    File.open(posted_log, 'a') do |f|
      f.puts(JSON.generate({ 'id' => oid, 'ran_at' => Time.now.utc.iso8601 }))
    end
  end
end

# Read back
# Fetch the resolved /columns BEFORE writing the id-map so we can attach the
# AUTHORITATIVE per-element column labels (the suffixed display names Sigma
# assigns to disambiguate joined-dim columns — e.g. "Customer Id (CUSTOMER_DIM)").
# derive_master needs these to emit master-column formulas that actually resolve.
# (Same response is reused below for the error-type guard — one round trip.)
# Wrapped in a lambda because the quarantine path below may PUT a cleaned spec
# and needs a SECOND readback of the final live state.
columns_path = opts[:type] == 'datamodel' ?
  "/v2/dataModels/#{oid}/columns" :
  "/v2/workbooks/#{oid}/columns"
readback = lambda do
  # Workbook code-rep responses nest non-metadata fields (pages/layout/
  # schemaVersion/kind) under `document` (live since 2026-08); the DM
  # readback is unchanged and stays flat.
  raw_spec = JSON.parse(http(:get, format(GET_PATH, oid), accept_json: true).body)
  spec = opts[:type] == 'workbook' ? Sigma::CodeRep.document(raw_spec) : raw_spec
  cols_res = http(:get, columns_path, accept_json: true)
  # cols_res is the FIRST page and is kept only for its HTTP status, which the
  # quarantine guards below check. The entries are re-read EXHAUSTIVELY: the
  # error-column census and the re-POST-once quarantine decision must see every
  # column, and a first-page-only read truncates at the server default of 50 —
  # which would declare a wide workbook clean while error columns sat past the cut.
  # Shape is unchanged ({ 'entries' => [...] } or nil), so every downstream
  # cols_json['entries'] read is untouched.
  cols_json =
    if cols_res.is_a?(Net::HTTPSuccess)
      begin
        { 'entries' => Sigma.list_entries(columns_path) }
      rescue StandardError => e
        # LOUD, not silent. A swallowed pagination failure would fall back to the
        # first 50 columns and re-create the exact silent truncation this change
        # exists to remove — so the degraded read announces itself.
        warn "column census: exhaustive read failed (#{e.class}: #{e.message}) — falling " \
             'back to the FIRST PAGE ONLY; the error-column census may be incomplete'
        { 'entries' => (JSON.parse(cols_res.body)['entries'] rescue []), 'census_partial' => true }
      end
    end
  labels_by_el = Hash.new { |h, k| h[k] = [] }
  (cols_json && cols_json['entries'] || []).each do |c|
    labels_by_el[c['elementId']] << c['label'] if c['elementId'] && c['label']
  end
  [spec, cols_res, cols_json, labels_by_el]
end
spec, cols_res, cols_json, labels_by_el = readback.call

# W2.5: detect a DM element-id REASSIGNMENT by the PUT and stop before a dependent
# workbook ships bricked. Only meaningful on the datamodel update path.
if opts[:type] == 'datamodel' && $dm_pre_ids && !$dm_pre_ids.empty?
  post_ids = (spec['pages'] || []).flat_map { |p| (p['elements'] || []).map { |e| e['id'] } }.compact
  vanished = $dm_pre_ids - post_ids # ids present before the PUT, gone after → re-minted/dropped
  if vanished.any?
    # A dependent workbook is one already POSTed in this workdir (it sources the DM
    # by the OLD ids). Track via posted-workbooks.jsonl / migrate-state.json.
    dep_wb = nil
    begin
      pwl = File.join(opts[:workdir], 'posted-workbooks.jsonl')
      dep_wb = File.readlines(pwl).map { |l| (JSON.parse(l)['id'] rescue nil) }.compact.last if File.exist?(pwl)
      if dep_wb.nil?
        ms = File.join(opts[:workdir], 'migrate-state.json')
        dep_wb = (JSON.parse(File.read(ms))['workbook_id'] rescue nil) if File.exist?(ms)
      end
    rescue StandardError
      dep_wb = nil
    end
    warn ''
    warn "⚠️  DM PUT REASSIGNED ELEMENT IDS — #{vanished.size} element id(s) that existed before the PUT are gone:"
    warn "     #{vanished.first(6).join(', ')}#{vanished.size > 6 ? ' …' : ''}"
    warn '     A Sigma dataModel PUT can re-mint element ids. Any workbook sourcing this DM by the OLD ids'
    warn '     now points at dead elements and renders "graph resolver exceeded the iteration limit: 200".'
    if dep_wb
      # Record an off-ramp so the waiver budget / report see the forced situation.
      begin
        File.open(File.join(opts[:workdir], 'offramps.jsonl'), 'a') do |f|
          f.puts(JSON.generate({ 'kind' => 'dm-put-id-reassignment', 'data_model_id' => oid,
                                 'workbook_id' => dep_wb, 'vanished' => vanished.first(20),
                                 'at' => Time.now.utc.iso8601 }))
        end
      rescue StandardError
        nil
      end
      warn "     A dependent workbook is tracked (#{dep_wb}) and is now BROKEN. STOPPING so the run does not"
      warn '     ship a bricked workbook GREEN. Recover by POSTing the workbook FRESH against the new DM'
      warn '     element ids (a new workbook POST re-resolves its sources), or --force-new-workbook. Prefer'
      warn '     POSTing the DM once and building the workbook AFTER, so the DM is never re-PUT under a live workbook.'
      exit 1
    else
      warn '     No dependent workbook is tracked yet — safe to continue. POST the workbook AFTER this DM so'
      warn '     it binds the new element ids (do not build the workbook, then re-PUT the DM).'
    end
  end
end

# CALC-REF CASING REPAIR (datamodel only, re-PUT-once). The vendored converter
# emits calc column refs in Tableau TitleCase ([Totalrev], [Userid]); Snowflake
# reads the real columns back UPPERCASE ([TOTALREV]) and Sigma formula refs are
# case-sensitive, so those calc columns compile to type=error. BEFORE quarantine
# would drop them, re-case each element's BARE column refs to its OWN live column
# labels (the authoritative readback casing), PUT the corrected spec back to the
# SAME id, and re-read once. $recased enforces the re-PUT-ONCE contract. This runs
# qualified:false (never rewrites [alias/COL] element segments) and refuses to
# re-case a bare ref whose column name lives on >1 element (a collapsed multi-
# datasource ref that needs a Lookup, not a casing fix) — so it never masks a real
# gap; the type=error guard below still fires on anything it can't safely fix.
if opts[:type] == 'datamodel' && $recased.nil? && cols_res.is_a?(Net::HTTPSuccess) &&
   ENV['SIGMA_SKIP_RECASE'].to_s.empty?
  begin
    require_relative 'lib/ref_label_repair'
    name_by_id = {}
    (spec['pages'] || []).each { |p| (p['elements'] || []).each { |e| name_by_id[e['id']] = e['name'] } }
    registry = {}
    labels_by_el.each do |eid, labels|
      nm = name_by_id[eid]
      registry[nm] = labels if nm.is_a?(String) && !labels.empty?
    end
    if registry.any?
      spec_doc = JSON.parse(File.read(opts[:spec]))
      els = (spec_doc['pages'] || []).flat_map { |p| p['elements'] || [] }
      rep = RefLabelRepair.repair!(els, registry, qualified: false, same_element_recase: true)
      rep[:ambiguous].each { |m| warn "  RECASE skip: #{m}" }
      if rep[:fixed].positive?
        $recased = rep[:fixed]
        # Same strip as the primary POST/PUT bodies — spec_doc is a fresh
        # re-read of opts[:spec] (line 635), so it still carries the
        # derivation-provenance fields the earlier strip already removed from
        # post_body/put_body; this re-PUT needs its own strip.
        strip_relationship_derivation_fields!(spec_doc)
        recased_path = File.join(opts[:workdir], 'dm-spec.recased.json')
        File.write(recased_path, JSON.pretty_generate(spec_doc))
        warn "RECASE: re-cased #{rep[:fixed]} bare calc ref(s) to live column labels " \
             "(converter emitted TitleCase; warehouse columns are UPPERCASE) — re-PUTting to " \
             "#{ID_FIELD}=#{oid} (#{recased_path})"
        put_res = http(:put, format(GET_PATH, oid), File.read(recased_path))
        if put_res.is_a?(Net::HTTPSuccess)
          spec, cols_res, cols_json, labels_by_el = readback.call
        else
          warn "WARN: re-PUT after re-casing failed (HTTP #{put_res.code}): " \
               "#{put_res.body.to_s[0, 300]} — keeping original readback; the type-error guard will report."
        end
      end
    end
  rescue StandardError => e
    warn "WARN: calc-ref casing repair skipped (#{e.message}) — the type-error guard below still applies."
  end
end

# Rec5 quarantine, census leg (opt-in, datamodel only): the POST succeeded but
# specific live element(s) resolved columns to type=error. Defer those elements,
# PUT the cleaned spec back to the SAME DM id (no orphan), and re-read once.
# $quarantined.nil? enforces the re-POST-ONCE contract: if the POST leg already
# quarantined and errors REMAIN, fail loudly (exit 2) instead of looping.
if QUARANTINE && $quarantined.nil? && cols_res.is_a?(Net::HTTPSuccess)
  census_errors = (cols_json['entries'] || []).select { |c| c.dig('type', 'type') == 'error' }
  if census_errors.any?
    spec_doc = JSON.parse(File.read(opts[:spec]))
    # live element id → name, so census elementIds map back onto spec elements
    live_names = {}
    (spec['pages'] || []).each { |p| (p['elements'] || []).each { |e| live_names[e['id']] = e['name'] } }
    found = DmQuarantine.offending_from_error_columns(spec_doc, census_errors, live_names)
    if found[:ids].any?
      q = DmQuarantine.quarantine(spec_doc, found[:ids], found[:reasons])
      $quarantined = Array($quarantined) + q[:deferred]
      File.write(DEFERRED_PATH, JSON.pretty_generate(
        DmQuarantine.deferred_doc($quarantined, data_model_id: oid, spec_path: File.expand_path(opts[:spec]))))
      # Same strip as the primary POST/PUT bodies — this cleaned spec is what
      # actually goes out on the re-PUT below (deferred-elements.json, written
      # just above, is forensics-only and deliberately keeps the provenance).
      strip_relationship_derivation_fields!(q[:spec])
      cleaned_path = File.join(opts[:workdir], 'dm-spec.quarantined.json')
      File.write(cleaned_path, JSON.pretty_generate(q[:spec]))
      warn "QUARANTINE: column census flagged #{found[:ids].size} element(s) — deferred to #{DEFERRED_PATH}; " \
           "re-PUTting the remaining spec to #{ID_FIELD}=#{oid} (#{cleaned_path})"
      found[:ids].each { |id| warn "  - #{id}: #{found[:reasons][id]}" }
      put_res = http(:put, format(GET_PATH, oid), File.read(cleaned_path))
      abort("re-PUT after quarantine failed (HTTP #{put_res.code}): #{put_res.body.to_s[0, 500]} — " \
            "deferred file kept: #{DEFERRED_PATH}") unless put_res.is_a?(Net::HTTPSuccess)
      spec, cols_res, cols_json, labels_by_el = readback.call
    else
      warn 'QUARANTINE: column census has type=error entries but none map to a spec element — nothing quarantined (failing loudly below).'
    end
  end
end

if opts[:type] == 'workbook'
  out_doc = spec.dup
  out_doc['pages'] = Array(spec['pages']).map do |page|
    page.reject { |key, _| key == 'elements' }
  end
  out_doc['elements'] = Sigma::CodeRep.workbook_elements(spec).map do |element|
    summary = { 'id' => element['id'], 'kind' => element['kind'], 'name' => element['name'] }
    summary['columnLabels'] = labels_by_el[element['id']] if labels_by_el.key?(element['id'])
    summary
  end
  out = Sigma::CodeRep.wrap(out_doc, extra: { ID_FIELD => oid })
else
  out = {
    ID_FIELD => oid,
    'pages'  => spec.fetch('pages', []).map do |p|
      {
        'id'       => p['id'],
        'name'     => p['name'],
        'visibility' => p['visibility'],
        'elements' => (p['elements'] || []).map do |e|
          el = { 'id' => e['id'], 'kind' => e['kind'], 'name' => e['name'] }
          # Workbook controls can target a data-model control only through an
          # explicit parameters[] binding. Preserve the READBACK control handle
          # (and type for audit/debugging) in dm-ids.json so the workbook builder
          # never guesses from the authored request or tries a cross-document
          # [controlId] formula reference.
          if e['kind'] == 'control'
            el['controlId'] = e['controlId']
            el['controlType'] = e['controlType']
          end
          el['columnLabels'] = labels_by_el[e['id']] if labels_by_el.key?(e['id'])
          if e.key?('metrics')
            el['metrics'] = Array(e['metrics']).map do |metric|
              { 'id' => metric['id'], 'name' => metric['name'] }.compact
            end
          end
          el
        end
      }
    end
  }
end
File.write(opts[:out], JSON.pretty_generate(out))
puts JSON.pretty_generate(out)

# Universal silent-error guard: scan every column's resolved type via the
# `/columns` endpoint and fail loudly on any column with type `error`.
#
# A column ends up "error" when the formula compiles successfully against the
# validator but fails at runtime. Typical causes:
#   - Referenced column doesn't exist (typo)
#   - Function doesn't exist in Sigma (e.g., IsIn — see memory feedback_sigma_formula_isin.md)
#   - Window aggregate used in calc-column context (validate-spec catches the known
#     function names; this catches anything else that produces an error type)
#   - Cross-element ref without a Lookup wrapper (compiles, returns NULL forever — actually
#     resolves as the column's declared type, not "error", so this guard misses it; that's
#     why refs/data-model-spec.md has its own callout)
#
# Endpoint: GET /v2/{dataModels|workbooks}/<id>/columns — returns one entry per
# column with `type.type` resolved. Scan for type == "error".

res = cols_res
if res.is_a?(Net::HTTPSuccess)
  error_columns = (cols_json['entries'] || []).select { |c| c.dig('type', 'type') == 'error' }
  if error_columns.any?
    warn "\n========================================"
    warn "FAIL — #{error_columns.size} column(s) compiled to type \"error\":"
    error_columns.each do |c|
      warn "  [element=#{c['elementId']}] #{c['label']} (#{c['columnId']}):"
      warn "    formula: #{c['formula']}"
    end
    warn 'Fix these formulas before continuing — Phase 6 parity would fail downstream.'
    warn 'Common causes: typo in a column ref, IsIn() / non-existent function, window'
    warn 'aggregate in a calc column (use a Custom SQL element instead — see Phase 3).'
    warn "NOTE: errors persist AFTER quarantining #{Array($quarantined).size} element(s) — see #{DEFERRED_PATH}." if $quarantined
    warn '========================================'
    exit(2)
  else
    total = (cols_json['entries'] || []).size
    if cols_json['census_partial']
      warn "column-type guard: census INCOMPLETE — #{total} column(s) read; no `error` types among them, " \
           'but this does NOT confirm the workbook clean (columns past the first page were not read). Re-run.'
    else
      warn "column-type guard: #{total} columns clean (no `error` types)"
    end
  end
else
  warn "WARN: could not fetch /columns for type guard (got HTTP #{res.code}); skipping"
end

# DM column-DROPPAGE guard (a real multi-datasource workbook): the type=error guard above
# only catches columns that POSTed-then-errored. When a multi-datasource workbook
# is collapsed onto its primary, the OTHER sources' columns are simply ABSENT from
# the live DM (never posted) — no error type, so the guard above stays silent while
# the spec declared hundreds more. Surface that gap loudly here; the pre-POST
# ref-resolution gate (assert-wb-refs-resolve.rb) then hard-stops the workbook.
# The per-element COLUMN CENSUS (lib/column_census.rb) enriches the warning
# with posted-vs-resolved counts and the missing column names, and also WARNs
# on smaller silent drops that miss the aggregate droppage threshold.
if opts[:type] == 'datamodel' && res.is_a?(Net::HTTPSuccess)
  declared = (spec['pages'] || []).sum { |p| (p['elements'] || []).sum { |e| (e['columns'] || []).size } }
  live = (cols_json['entries'] || []).size

  # One census pass feeds both the droppage detail and the small-drop warning.
  require_relative 'lib/column_census'
  posted_spec = begin
    JSON.parse(File.read(opts[:spec]))
  rescue JSON::ParserError
    nil # spec file already POSTed fine; census just can't re-read it
  end
  census_problems = posted_spec ? ColumnCensus.census(posted_spec, spec, cols_json['entries'] || []) : []

  if declared > 20 && live < declared * 0.7
    pct = ((1.0 - live.to_f / declared) * 100).round
    warn "\n========================================"
    warn "WARN — DM column DROPPAGE: spec declared #{declared} column(s), live DM has #{live} " \
         "(#{pct}% absent, NOT type=error)."
    warn 'This is the multi-datasource-collapse signature: columns from non-primary datasources'
    warn 'were dropped. The workbook build will fail ref-resolution downstream. Verify the DM has'
    warn 'one element per datasource (multi-element DM) before building the workbook.'
    if census_problems.any?
      warn "Per-element census (#{census_problems.size} element(s) lost columns between POST and readback):"
      ColumnCensus.report_lines(census_problems).each { |l| warn "  #{l}" }
    end
    warn '========================================'
  elsif census_problems.any?
    warn "\n========================================"
    warn "WARN — column/metric census: #{census_problems.size} element(s) lost columns or metrics between POST and readback:"
    ColumnCensus.report_lines(census_problems).each { |l| warn "  #{l}" }
    warn 'Columns are compared only with GET /columns; metrics are compared only with the'
    warn 'full DM readback metrics[] census. Downstream [Master/...] and [Metrics/...] refs'
    warn 'to missing entries will be caught by assert-wb-refs-resolve.rb.'
    warn '========================================'
  elsif posted_spec
    warn "column/metric census: #{ColumnCensus.posted_column_count(posted_spec)} posted column(s) and " \
         "#{ColumnCensus.posted_metric_count(posted_spec)} posted metric(s) all resolved in their readback namespaces"
  end
end

# FILTERS census (both types) — field-caught round 2: element `filters` on a
# pivot-table were SILENTLY DROPPED at PUT (HTTP 200, filter simply absent in
# the readback), so a rank/top-n limit vanished with no signal and the tile
# rendered unbounded. Compare per-element posted-vs-readback filter counts and
# warn loudly on any loss (match by id, then name — DM POST reassigns ids).
begin
  posted_spec ||= (JSON.parse(File.read(opts[:spec])) rescue nil)
  if posted_spec && spec.is_a?(Hash)
    rb_els = opts[:type] == 'workbook' ? Sigma::CodeRep.workbook_elements(spec) :
      (spec['pages'] || []).flat_map { |p| p['elements'] || [] }
    rb_by_id   = rb_els.each_with_object({}) { |e, h| h[e['id']] = e if e['id'] }
    rb_by_name = rb_els.each_with_object({}) { |e, h| h[e['name']] = e if e['name'] }
    posted_els = opts[:type] == 'workbook' ?
      Sigma::CodeRep.workbook_elements(WorkbookCode.canonicalize(posted_spec)) :
      (posted_spec['pages'] || []).flat_map { |p| p['elements'] || [] }
    posted_els.each do |pel|
      posted_f = Array(pel['filters'])
      next if posted_f.empty?
      live = rb_by_id[pel['id']] || rb_by_name[pel['name']]
      next unless live
      live_f = Array(live['filters'])
      next unless live_f.length < posted_f.length
      lost = posted_f.length - live_f.length
      warn "WARN — FILTER silently dropped: element \"#{pel['name'] || pel['id']}\" POSTed #{posted_f.length} " \
           "filter(s) but the readback carries #{live_f.length} (#{lost} lost; kinds posted: " \
           "#{posted_f.map { |f| f['kind'] }.compact.join(', ')}). Sigma accepted the spec and dropped the " \
           'filter without an error — a rank/top-n limit vanishing here renders the element UNBOUNDED. ' \
           'Re-shape the filter (see refs/workbook-layout.md filters) or move the limit into the SOURCE ' \
           '(rank-limited SQL, refs/fidelity-recipes.md).'
    end
  end
rescue StandardError => e
  warn "WARN: filters census skipped (#{e.class}: #{e.message[0, 80]})"
end

# CONTROL-FIELD census (workbooks; issues #415/#417) — the Workbook Spec API
# accepts a family of control fields with 200 and SILENTLY DROPS them on
# readback (list-control editor toggles like showNullOption, bare-date
# date-range startDate/endDate defaults). The preflight lint (A1/A2,
# DROPPED_BY_API in lib/preflight_lint.rb) warns on the KNOWN members
# pre-POST; this audit diffs EVERY posted control's fields against its
# readback so future members of the family surface automatically. WARN, not
# a hard stop: the workbook is live and correct except for the ignored field.
begin
  posted_spec ||= (JSON.parse(File.read(opts[:spec])) rescue nil)
  if opts[:type] == 'workbook' && posted_spec && spec.is_a?(Hash)
    require_relative 'lib/control_field_census'
    cf_problems = ControlFieldCensus.census(
      WorkbookCode.legacy_view(posted_spec), WorkbookCode.legacy_view(spec))
    if cf_problems.any?
      warn "\n========================================"
      warn "WARN — CONTROL FIELD(S) silently dropped by the spec API: #{cf_problems.size} control(s) " \
           'posted field(s) that the readback does not carry (accepted with 200, then ignored — they'
      warn 'never take effect on the live control; Sigma product gap, NOT a spec 400):'
      ControlFieldCensus.report_lines(cf_problems).each { |l| warn "  #{l}" }
      warn 'Known family + sanctioned workarounds: DROPPED_BY_API in scripts/lib/preflight_lint.rb and'
      warn 'sigma-workbooks reference/specification/controls.md ("Dropped-by-API fields"). A dropped'
      warn 'DEFAULT (e.g. date-range startDate/endDate) means the control ships with NO default — set it'
      warn 'in the Sigma UI control editor and record the step in POSTPUBLISH_GUIDE.md.'
      warn 'A dropped TARGET BINDING (#456: "filters (TARGET BINDING dropped ...)") means the control'
      warn 'filters NOTHING: the target column is likely numeric/datetime (cast it with a hidden'
      warn 'Text([<col>]) decode column and bind the filter target + value-source to the decode) or'
      warn 'unresolvable (re-point it at a TABLE element, or record it in POSTPUBLISH_GUIDE.md).'
      warn '========================================'
    else
      n = ControlFieldCensus.controls(WorkbookCode.legacy_view(posted_spec)).size
      warn "control-field census: #{n} posted control(s), no silently-dropped fields" if n.positive?
    end
  end
rescue StandardError => e
  warn "WARN: control-field census skipped (#{e.class}: #{e.message[0, 80]})"
end

# Rec5 quarantine final report: the (re-)POST succeeded and the census is clean,
# but only because broken element(s) were REMOVED. The DM is PARTIAL — exit with
# the distinct code so no caller mistakes this for a full green POST.
if $quarantined && Array($quarantined).any?
  File.write(DEFERRED_PATH, JSON.pretty_generate(
    DmQuarantine.deferred_doc($quarantined, data_model_id: oid, spec_path: File.expand_path(opts[:spec]))))
  names = Array($quarantined).map { |d| d.dig('element', 'name') || d.dig('element', 'id') }
  warn "\n================================================================"
  warn "PARTIAL DM — #{names.size} element(s) QUARANTINED (exit #{DmQuarantine::EXIT_QUARANTINED})"
  warn "================================================================"
  Array($quarantined).each do |d|
    warn "  - #{d.dig('element', 'name') || d.dig('element', 'id')}: #{d['reason']}"
  end
  warn "The remaining elements posted cleanly to #{ID_FIELD}=#{oid}, but the DM is"
  warn "INCOMPLETE. Fix each element spec in:"
  warn "  #{DEFERRED_PATH}"
  warn 'restore it into the DM spec, re-POST (PUT --update-id), and delete the file.'
  warn 'The migration may NOT be declared GREEN while deferred-elements.json is'
  warn 'non-empty — assert-phase6-ran.rb blocks it (escape: --accept-deferred-elements'
  warn '"<reason>", which must be named in the migration report).'
  warn '================================================================'
  exit(DmQuarantine::EXIT_QUARANTINED)
end

# Layout-quality lint (shared scripts/lib/layout_lint.rb — vendored byte-
# identical, md5 discipline): fails loudly on raw-id element display names,
# input controls outside the Container bands of a banded page, and dead
# zones (>25% empty grid rows between a page's first and last element). The
# "PHASEE PBI Employee Dashboard" regression shipped a parity-green workbook
# that was a visual mess — every data gate passed. Escape: --skip-layout-lint
# (legacy/intentional layouts only; name the reason in your report).
if opts[:type] == 'workbook' && !opts[:skip_lint]
  require_relative 'lib/layout_lint'
  violations = LayoutLint.lint(spec)
  if violations.any?
    warn "\n========================================"
    warn "FAIL — layout lint: #{violations.size} violation(s):"
    violations.each { |v| warn "  - #{v}" }
    warn 'Fix the spec/layout and re-PUT before continuing: raw-id names -> derive human'
    warn 'titles; loose controls -> control band or the chart container; dead zones ->'
    warn 're-band the page. The workbook DID post — fix with PUT /v2/workbooks/<id>/spec'
    warn '(re-POSTing creates an orphan).'
    warn '========================================'
    exit(3)
  end
  warn 'layout lint: clean (raw-id names / orphan controls / dead zones)'
end

# Control-wiring lint (shared scripts/lib/control_lint.rb — vendored byte-
# identical, md5 discipline): fails loudly on dead controls (no resolving
# filter target AND no [controlId] formula reference — the "Orders Overview
# (from Looker)" estate escape), ghost filter targets, and controls whose
# source-closure misses same-page queryable elements (the PHASEE
# "Action(Region) -> Monthly Revenue Trend" escape). If the builder emitted a
# control-scope sidecar (<workdir>/control-scope.json — see the lib header
# CONTRACT), it also fails when the source artifact had filter signals but the
# spec shipped zero controls (the Qlik class), and honors per-control
# scope:[...] allowlists for intentional single-chart switchers (grain
# controls). Escape: --skip-control-lint (name the reason in your report).
if opts[:type] == 'workbook' && !opts[:skip_control_lint]
  require_relative 'lib/control_lint'
  scope_path = opts[:control_scope] || File.join(opts[:workdir], 'control-scope.json')
  scope = nil
  if File.exist?(scope_path)
    scope = JSON.parse(File.read(scope_path)) rescue nil
    warn "WARN: #{scope_path} is not valid JSON — control lint runs without source scope" if scope.nil?
  end
  violations = ControlLint.lint(spec, scope: scope)
  if violations.any?
    warn "\n========================================"
    warn "FAIL — control lint: #{violations.size} violation(s):"
    violations.each { |v| warn "  - #{v}" }
    warn 'Fix the control wiring and re-PUT before continuing: dead controls -> add'
    warn 'filters targets ({source:{elementId}, columnId}) or remove the control;'
    warn 'partial reach -> wire the uncovered elements or annotate controlScope in'
    warn 'control-scope.json (see scripts/lib/control_lint.rb CONTRACT). The workbook'
    warn 'DID post — fix with PUT /v2/workbooks/<id>/spec (re-POSTing creates an orphan).'
    warn '========================================'
    exit(4)
  end
  n = ControlLint.controls_report(spec).length
  warn "control lint: clean (#{n} control(s); dead / ghost-target / reach#{scope ? ' / source-scope' : ''})"
end

# Phase 6 nag — column-type guard catches formula-resolution errors but does
# NOT compare data values to Tableau. Phase 6 (mandatory per SKILL.md) is the
# ONLY thing that confirms the chart actually reproduces the source. Emit a
# clear next-step prompt so the agent (or human) doesn't silently skip it.
if opts[:type] == 'workbook'
  warn ""
  warn "================================================================"
  warn "NEXT STEP — Phase 6 (MANDATORY): verify data parity vs Tableau"
  warn "================================================================"
  warn "Column-type guard PASSES means formulas RESOLVE. It does NOT mean"
  warn "the chart values match Tableau's. Run this BEFORE declaring done:"
  warn ""
  warn "  ruby scripts/phase6-parity.rb \\"
  warn "    --tableau <dir-with-views/-and-get-workbook.json> \\"
  warn "    --workbook-id #{oid}"
  warn ""
  warn "Add --extract-mode --extract-tol 0.30 if the Tableau workbook has"
  warn "a .hyper extract (drift between live + cached data is expected)."
  warn "================================================================"
end
