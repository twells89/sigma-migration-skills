#!/usr/bin/env ruby
# Regression test for D1 + Pass-7 canvas (gaps beads-sigma-ubr5.15 / .6): the
# workbook theme derived from the parsed layout. build-workbook-spec.rb turns the
# outermost zone fill into themeOverrides.colorOverrides.backgroundCanvas and the
# tinted region-card container fills into themeOverrides.categoricalScheme (the
# SOURCE mark palette — 8-digit-alpha tint #07b4a24e → base #07b4a2).
#
# Exercises the pure derive_theme(layout) helper directly (no live POST).
# Usage:  ruby scripts/test-theme-derivation.rb
require 'json'
require_relative 'lib/theme_derive'

DIR = __dir__
# v5.0: derive_theme moved to the shared lib (ThemeDerive.derive) so the
# standalone and orchestrated paths cannot diverge. Assert the wrapper in
# build-workbook-spec.rb still delegates there (the old regex-extract+eval
# approach would silently test dead code once the body moved).
SRC = File.read(File.join(DIR, 'build-workbook-spec.rb'))
abort('build-workbook-spec.rb no longer delegates derive_theme to ThemeDerive') unless
  SRC =~ /^def derive_theme\b.*?ThemeDerive\.derive/m
def derive_theme(layout)
  ThemeDerive.derive(layout)
end

fails = []
def check(cond, msg, fails)
  fails << msg unless cond
  puts "  #{cond ? 'PASS' : 'FAIL'}  #{msg}"
end

# Mirrors the benchmark: a white-canvas dashboard, 4 region cards tinted with
# 8-digit-alpha region hues, plus a grey solid KPI card (must NOT enter the scheme).
LAYOUT = [{
  'dashboard' => 'Job Losses',
  'zone_tree' => [{
    'id' => '1', 'kind' => 'container', 'fill_color' => '#ffffff', 'children' => [
      { 'id' => 'kpi', 'kind' => 'container', 'fill_color' => '#e6e6e6' }, # grey solid → excluded
      { 'id' => 'south', 'kind' => 'container', 'caption' => 'South',    'fill_color' => '#07b4a24e' },
      { 'id' => 'west',  'kind' => 'container', 'caption' => 'West',     'fill_color' => '#e8519a4e' },
      { 'id' => 'ne',    'kind' => 'container', 'caption' => 'Northeast','fill_color' => '#827bb84e' },
      { 'id' => 'mw',    'kind' => 'container', 'caption' => 'Midwest',  'fill_color' => '#f28e2b4e' }
    ]
  }]
}]

theme = derive_theme(LAYOUT)

check(theme['backgroundCanvas'] == '#ffffff',
      "canvas = outermost zone fill (got #{theme['backgroundCanvas'].inspect})", fails)
check(theme['categoricalScheme'] == %w[#07b4a2 #e8519a #827bb8 #f28e2b],
      "categoricalScheme = source region bases, alpha stripped, in order (got #{theme['categoricalScheme'].inspect})", fails)
check(!(theme['categoricalScheme'] || []).include?('#e6e6e6'),
      "grey solid KPI-card fill excluded from the scheme", fails)

# No styled containers → no theme (Sigma defaults; never worse).
plain = derive_theme([{ 'dashboard' => 'X', 'zone_tree' => [
  { 'id' => '1', 'kind' => 'container', 'children' => [{ 'id' => 'c', 'kind' => 'chart' }] }
] }])
check(plain == {}, "unstyled dashboard → empty theme (got #{plain.inspect})", fails)

# Tableau's default fixed dashboard canvas is white even when no explicit
# background style is serialized; Sigma otherwise renders gray gutters.
fixed_plain = derive_theme([{
  'dashboard' => 'Fixed',
  'canvas_px' => { 'w' => 1600, 'h' => 1000, 'sizing_mode' => 'fixed' },
  'zone_tree' => [{ 'id' => 'root', 'kind' => 'container' }]
}])
check(fixed_plain['backgroundCanvas'] == '#ffffff',
      "unstyled fixed dashboard defaults to white canvas (got #{fixed_plain['backgroundCanvas'].inspect})", fails)

# Single tinted card → no categoricalScheme (needs the multi-member pattern).
one = derive_theme([{ 'dashboard' => 'X', 'zone_tree' => [
  { 'id' => '1', 'kind' => 'container', 'fill_color' => '#07b4a24e' }
] }])
check(one['categoricalScheme'].nil?, "single tinted container → no scheme (needs >=2)", fails)

# Dedup: same base at two alphas collapses to one scheme entry.
dup = derive_theme([{ 'dashboard' => 'X', 'zone_tree' => [
  { 'id' => 'a', 'kind' => 'container', 'fill_color' => '#07b4a24e' },
  { 'id' => 'b', 'kind' => 'container', 'fill_color' => '#07b4a21b' },
  { 'id' => 'c', 'kind' => 'container', 'fill_color' => '#e8519a4e' }
] }])
check(dup['categoricalScheme'] == %w[#07b4a2 #e8519a], "same base at 2 alphas dedups (got #{dup['categoricalScheme'].inspect})", fails)

# --- brand_palette (general D1): the source's color-encoding palette wins ----
# A color-SCHEME dashboard (no tinted region cards) still gets a real scheme
# from parse-twb-layout's brand_palette, instead of degenerating to white fills.
brand = derive_theme([{
  'dashboard' => 'ER', 'brand_palette' => %w[#ba2020 #8f1716 #ac4746],
  'zone_tree' => [{ 'id' => '1', 'kind' => 'container', 'fill_color' => '#ffffff6d', 'children' => [
    { 'id' => 'c1', 'kind' => 'container', 'fill_color' => '#ffffff' }, # white card — must NOT be the palette
    { 'id' => 'c2', 'kind' => 'container', 'fill_color' => '#fafafa' }
  ] }]
}])
check(brand['categoricalScheme'] == %w[#ba2020 #8f1716 #ac4746],
      "brand_palette (color encodings) beats white card fills (got #{brand['categoricalScheme'].inspect})", fails)
check(brand['backgroundCanvas'] == '#ffffff',
      "canvas 8-digit alpha stripped to solid #rrggbb (got #{brand['backgroundCanvas'].inspect})", fails)

# brand_palette with a single colour → too few to theme, fall back to tints.
fb = derive_theme([{
  'dashboard' => 'X', 'brand_palette' => %w[#4e79a7],
  'zone_tree' => [
    { 'id' => 'a', 'kind' => 'container', 'fill_color' => '#07b4a24e' },
    { 'id' => 'b', 'kind' => 'container', 'fill_color' => '#e8519a4e' }
  ]
}])
check(fb['categoricalScheme'] == %w[#07b4a2 #e8519a],
      "single-colour brand_palette falls back to the tint palette (got #{fb['categoricalScheme'].inspect})", fails)

puts
if fails.empty?
  puts 'ALL PASS — D1/Pass-7 theme derivation (canvas + region palette + brand palette)'
  exit 0
else
  puts "#{fails.size} FAILURE(S):"
  fails.each { |f| puts "  - #{f}" }
  exit 1
end
