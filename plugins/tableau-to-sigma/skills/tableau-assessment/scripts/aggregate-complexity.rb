#!/usr/bin/env ruby
# Run the tableau-to-sigma gap-scanner against every cached .twb in
# <out>/twbs/<luid>.twb. Aggregate the per-workbook feature counts into
# <out>/complexity.json.
#
# Usage:
#   ruby scripts/aggregate-complexity.rb --out /tmp/assessment-<site>
#
# Reads:  <out>/twbs/*.twb, <out>/twb-fetch-results.json
# Writes: <out>/complexity.json

require 'json'
require 'optparse'
require 'open3'

# Predicted-parity coverage (y9rd.6): weight each detected feature OCCURRENCE by
# how translatable its status tier is, so a workbook with 50 auto features + 1
# unhandled predicts far higher than 1 auto + 1 unhandled. Tiers come straight
# from the gap-scanner's status (the converter's coverage-matrix ground truth):
#   auto      fully translated by the converter                      → 1.0
#   hint      translated but emits a WARN+formula to verify          → 0.85
#   manual    needs post-publish wiring (reachable, but hand work)   → 0.5
#   unhandled escalation / silent gap (likely lost)                  → 0.0
# A workbook with NO detected complex features = nothing to lose → 100%.
COVERAGE_WEIGHTS = { 'auto' => 1.0, 'hint' => 0.85, 'manual' => 0.5, 'unhandled' => 0.0 }.freeze

# Weighted predicted-parity % over feature occurrences. Returns 100.0 when no
# complex features were detected (a plain workbook). Tier band is a coarse label.
def predicted_parity(feats)
  weighted = 0.0
  total = 0
  feats.each do |f|
    n = (f['count'] || 1).to_i
    total += n
    weighted += n * (COVERAGE_WEIGHTS[f['status']] || 0.0)
  end
  return [100.0, 'A'] if total.zero?
  pct = (weighted / total * 100).round(1)
  band = case pct
         when 90..100 then 'A' # drop-in
         when 75...90 then 'B' # light touch-up
         when 50...75 then 'C' # meaningful manual work
         else 'D'              # hard / re-author risk
         end
  [pct, band]
end

opts = {}
OptionParser.new do |p|
  p.on('--out DIR') { |v| opts[:out] = v }
  p.on('--scanner PATH', 'Override path to scan-workbook-gaps.rb') { |v| opts[:scanner] = v }
end.parse!
abort('--out required') unless opts[:out]

gapscan = opts[:scanner] ||
          File.expand_path('../../tableau-to-sigma/scripts/scan-workbook-gaps.rb', __dir__)
abort("scan-workbook-gaps.rb not found at #{gapscan}") unless File.exist?(gapscan)

twb_dir = File.join(opts[:out], 'twbs')
fetch_results_path = File.join(opts[:out], 'twb-fetch-results.json')
abort("twb-fetch-results.json missing — run fetch-all-twbs.rb first") unless File.exist?(fetch_results_path)
fetch_results = JSON.parse(File.read(fetch_results_path))

results = {}
fetch_results.each do |luid, info|
  next if info['error']
  twb_path = File.join(twb_dir, "#{luid}.twb")
  unless File.exist?(twb_path)
    warn "  skip #{luid} (#{info['name']}): no .twb on disk"
    next
  end

  _out, _err, st = Open3.capture3('ruby', gapscan, twb_path)
  unless st.success?
    warn "  gap-scan failed for #{luid} (#{info['name']})"
    next
  end

  json_path = twb_path.sub(/\.twb$/, '-gaps-report.json')
  unless File.exist?(json_path)
    warn "  gap-scan produced no JSON for #{luid} (#{info['name']})"
    next
  end
  gaps = JSON.parse(File.read(json_path))

  feats = gaps['detected_features'] || []
  by_status = feats.group_by { |f| f['status'] }
  twb_size = info['twb_size'] || info['size'] || File.size(twb_path)
  parity_pct, parity_band = predicted_parity(feats)

  results[luid] = {
    'name'                 => info['name'],
    'twb_size_kb'          => twb_size / 1024,
    'n_features'           => feats.size,
    'n_auto'               => (by_status['auto']      || []).size,
    'n_hint'               => (by_status['hint']      || []).size,
    'n_manual'             => (by_status['manual']    || []).size,
    'n_unhandled'          => (by_status['unhandled'] || []).size,
    # Pre-migration parity PREDICTION (y9rd.6): occurrence-weighted % + A-D band.
    # A prediction from static .twb signal, NOT a measured value-parity score
    # (that comes post-migration from verify-parity.rb) — flag hard workbooks early.
    'predicted_parity_pct' => parity_pct,
    'parity_band'          => parity_band,
    'features'             => feats.map { |f| { 'name' => f['name'], 'status' => f['status'], 'count' => f['count'] } }
                                  .sort_by { |f| -(f['count'] || 0) }
  }
end

File.write(File.join(opts[:out], 'complexity.json'), JSON.pretty_generate(results))
n_hard = results.values.count { |r| %w[C D].include?(r['parity_band']) }
puts "wrote complexity.json (#{results.size} workbooks; #{n_hard} predicted hard [band C/D])"
