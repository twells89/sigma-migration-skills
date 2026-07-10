#!/usr/bin/env ruby
# export-zone-images.rb — crop a full-dashboard PNG into per-zone sub-images.
#
# Phase 6 visual-QA helper.  The Tableau MCP's view-image endpoint is server-
# side-capped (~957 KB regardless of the requested W/H), so dense dashboards
# (e.g. 22-row crosstab pivots) are unreadable when rendered full-width.
# This script takes:
#   (a) the full dashboard PNG already fetched by the Phase-1d PNG gate, and
#   (b) the parse-twb-layout zone geometry (x/y/w/h as percentages),
# and writes one cropped PNG per chart zone so the agent can compare each
# tile individually against its Sigma counterpart.
#
# Usage:
#   ruby scripts/export-zone-images.rb \
#     --image   <full-dashboard.png>   \
#     --layout  <layout.json>          \
#     --dashboard "Dashboard Name"     \
#     --out-dir <dir>
#     [--kinds chart,bitmap]           # default: chart
#     [--min-pct 2.0]                  # skip zones smaller than this % in w or h (default 2.0)
#
# Output:
#   <out-dir>/<zone_id>-<safe_caption>.png   one file per matched zone
#   <out-dir>/_zones.json                    { zone_id => { caption, png_path, x_pct, ... } }
#
# Image cropping: uses macOS sips (built-in on darwin).
# If neither sips nor ImageMagick (convert/magick) is present, exits with a
# clear error naming what to install.
#
# No Sigma credentials required — operates entirely on local files.

require 'json'
require 'fileutils'
require 'optparse'
require 'rbconfig'

# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------
opts = { kinds: %w[chart], min_pct: 2.0 }
OptionParser.new do |p|
  p.banner = "Usage: ruby export-zone-images.rb --image <png> --layout <json> --dashboard <name> --out-dir <dir>"
  p.on('--image PATH',      'Full dashboard PNG')           { |v| opts[:image]     = v }
  p.on('--layout PATH',     'layout.json from parse-twb-layout') { |v| opts[:layout] = v }
  p.on('--dashboard NAME',  'Dashboard name to match')      { |v| opts[:dashboard] = v }
  p.on('--out-dir DIR',     'Output directory for crops')   { |v| opts[:out_dir]   = v }
  p.on('--kinds LIST',      'Comma-sep zone kinds (default: chart)') { |v| opts[:kinds] = v.split(',') }
  p.on('--min-pct N', Float,'Skip zones smaller than N% in w or h (default: 2.0)') { |v| opts[:min_pct] = v }
end.parse!

%i[image layout dashboard out_dir].each do |k|
  abort "ERROR: --#{k.to_s.tr('_', '-')} is required" unless opts[k]
end
abort "ERROR: image file not found: #{opts[:image]}"   unless File.exist?(opts[:image])
abort "ERROR: layout file not found: #{opts[:layout]}" unless File.exist?(opts[:layout])

# ---------------------------------------------------------------------------
# Detect image tool
# ---------------------------------------------------------------------------
# sips is macOS-only (not present on Windows/Linux) and its own presence check
# used to be a shell string relying on POSIX-only redirection (`>/dev/null
# 2>&1`), which is not portable to cmd.exe. Gate the probe on the host OS and
# use array-form `system` (bypasses the shell entirely, so no redirection
# syntax is needed) — on non-macOS this skips straight to the ImageMagick
# fallback with a one-line note instead of attempting/failing on `sips`.
MACOS = RbConfig::CONFIG['host_os'] =~ /darwin/i ? true : false

def tool_available?(*cmd)
  system(*cmd, out: File::NULL, err: File::NULL)
rescue StandardError
  false
end

TOOL =
  if MACOS && tool_available?('sips', '--version')
    :sips
  elsif tool_available?('convert', '-version')
    :imagemagick_convert
  elsif tool_available?('magick', '-version')
    :imagemagick_magick
  else
    warn 'NOTE: sips is macOS-only and this is not macOS — skipping straight to ImageMagick (also not found).' unless MACOS
    abort "ERROR: no image-cropping tool found.\n" \
          "  macOS: sips is built-in (/usr/bin/sips) — it should be present.\n" \
          "  Linux: install ImageMagick (apt install imagemagick / brew install imagemagick).\n" \
          "  Windows: install ImageMagick (choco install imagemagick / winget install ImageMagick.ImageMagick) " \
          'and ensure `magick` is on PATH.'
  end
warn "Image tool: #{TOOL}"

# ---------------------------------------------------------------------------
# Read image dimensions
# ---------------------------------------------------------------------------
def image_dimensions(path)
  case TOOL
  when :sips
    out = `sips -g pixelWidth -g pixelHeight #{Shellwords.escape(path)} 2>/dev/null`
    w = out[/pixelWidth:\s+(\d+)/, 1]&.to_i
    h = out[/pixelHeight:\s+(\d+)/, 1]&.to_i
    abort "ERROR: could not read dimensions from #{path}" unless w && h
    [w, h]
  when :imagemagick_convert, :imagemagick_magick
    cmd = TOOL == :imagemagick_magick ? 'magick' : 'convert'
    out = `#{cmd} #{Shellwords.escape(path)} -ping -format "%wx%h" info: 2>/dev/null`
    m = out.match(/(\d+)x(\d+)/)
    abort "ERROR: could not read dimensions from #{path}" unless m
    [m[1].to_i, m[2].to_i]
  end
end

require 'shellwords'
img_w, img_h = image_dimensions(opts[:image])
warn "Dashboard image: #{img_w}x#{img_h}px (#{opts[:image]})"

# ---------------------------------------------------------------------------
# Load layout and find dashboard
# ---------------------------------------------------------------------------
layout = JSON.parse(File.read(opts[:layout]))
dashboard = layout.find { |d| d['dashboard'] == opts[:dashboard] }
abort "ERROR: dashboard #{opts[:dashboard].inspect} not found in #{opts[:layout]}.\n" \
      "Available: #{layout.map { |d| d['dashboard'] }.join(', ')}" unless dashboard

zones = dashboard['zones'] || []
chart_zones = zones.select do |z|
  opts[:kinds].include?(z['kind']) &&
    z['w_pct'].to_f >= opts[:min_pct] &&
    z['h_pct'].to_f >= opts[:min_pct]
end

if chart_zones.empty?
  abort "ERROR: no zones with kind in #{opts[:kinds].inspect} (min #{opts[:min_pct]}%) " \
        "found for dashboard #{opts[:dashboard].inspect}"
end
warn "Found #{chart_zones.size} zones to crop (kinds: #{opts[:kinds].join(', ')})"

# ---------------------------------------------------------------------------
# Crop helper
# ---------------------------------------------------------------------------
def safe_filename(str)
  str.to_s.gsub(/[^A-Za-z0-9_\-]/, '_').gsub(/__+/, '_').slice(0, 80)
end

def crop_image(src, dst, px_x, px_y, px_w, px_h)
  case TOOL
  when :sips
    # sips --cropOffset offsetY offsetX -c height width src -o dst
    cmd = "sips --cropOffset #{px_y} #{px_x} -c #{px_h} #{px_w} " \
          "#{Shellwords.escape(src)} -o #{Shellwords.escape(dst)} >/dev/null 2>&1"
    system(cmd) or abort "ERROR: sips crop failed for #{dst}"
  when :imagemagick_convert
    cmd = "convert #{Shellwords.escape(src)} -crop #{px_w}x#{px_h}+#{px_x}+#{px_y} " \
          "+repage #{Shellwords.escape(dst)} 2>/dev/null"
    system(cmd) or abort "ERROR: convert crop failed for #{dst}"
  when :imagemagick_magick
    cmd = "magick #{Shellwords.escape(src)} -crop #{px_w}x#{px_h}+#{px_x}+#{px_y} " \
          "+repage #{Shellwords.escape(dst)} 2>/dev/null"
    system(cmd) or abort "ERROR: magick crop failed for #{dst}"
  end
end

# ---------------------------------------------------------------------------
# Crop each zone
# ---------------------------------------------------------------------------
FileUtils.mkdir_p(opts[:out_dir])
manifest = {}

chart_zones.each do |z|
  x_pct = z['x_pct'].to_f
  y_pct = z['y_pct'].to_f
  w_pct = z['w_pct'].to_f
  h_pct = z['h_pct'].to_f

  px_x = (x_pct / 100.0 * img_w).round
  px_y = (y_pct / 100.0 * img_h).round
  px_w = (w_pct / 100.0 * img_w).round
  px_h = (h_pct / 100.0 * img_h).round

  # Clamp to image bounds
  px_x = [[px_x, 0].max, img_w - 1].min
  px_y = [[px_y, 0].max, img_h - 1].min
  px_w = [[px_w, 1].max, img_w - px_x].min
  px_h = [[px_h, 1].max, img_h - px_y].min

  caption   = z['caption'] || z['view_ref'] || "zone_#{z['id']}"
  safe_cap  = safe_filename(caption)
  out_name  = "#{z['id']}-#{safe_cap}.png"
  out_path  = File.join(opts[:out_dir], out_name)

  crop_image(opts[:image], out_path, px_x, px_y, px_w, px_h)

  bytes = File.exist?(out_path) ? File.size(out_path) : 0
  manifest[z['id']] = {
    'caption'  => caption,
    'kind'     => z['kind'],
    'x_pct'    => x_pct, 'y_pct' => y_pct, 'w_pct' => w_pct, 'h_pct' => h_pct,
    'px_x'     => px_x,  'px_y'  => px_y,  'px_w'  => px_w,  'px_h'  => px_h,
    'png_path' => out_path,
    'bytes'    => bytes
  }
  warn "  [#{z['id']}] #{caption} → #{out_name} (#{px_w}x#{px_h}px, #{bytes}B)"
end

zones_path = File.join(opts[:out_dir], '_zones.json')
File.write(zones_path, JSON.pretty_generate(manifest))
warn ""
warn "Cropped #{manifest.size} zone(s) → #{opts[:out_dir]}"
warn "Manifest: #{zones_path}"
