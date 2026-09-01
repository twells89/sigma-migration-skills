#!/usr/bin/env ruby
# frozen_string_literal: true
#
# lint-twin-parity.rb — .rb/.py twin API-parity gate (issue #753).
#
# Several shared/lib modules ship as `.rb` + `.py` twins. The pairing reads as
# "these are equivalent", and that is the assumption anyone porting a caller
# makes — but equivalence was asserted by FILE NAMING ALONE. tools/check-shared.rb
# enforces byte-identical VENDORING of one file into each plugin; nothing checked
# that a `.py` twin still exports what its `.rb` does. A ported caller just hits
# AttributeError at runtime, or silently takes a different path.
#
# WHY THIS COMPARES PUBLIC APIs, NOT `^def` LINES
# ----------------------------------------------
# The obvious implementation — diff `grep '^def '` on each side — reports ~70%
# false positives on this tree, and a gate that cries wolf gets switched off. It
# has to model how each language actually marks something internal:
#
#   * Python's leading underscore IS the privacy marker. `_walk_chain` is
#     `walk_chain`; reporting it missing is noise.
#   * Ruby `private` / `module_function` regions are internal too — and all three
#     `code_rep` methods that look absent from the Python side sit below its
#     `private` on line 145.
#   * `def self.foo` is public even inside a `private` region (Ruby applies
#     `private` to instance methods only). coverage_catalog depends on this.
#   * Ruby predicates/bangs (`token_stale?`, `refresh_token!`) lose the suffix.
#   * Ruby's `initialize` is Python's `__init__`.
#   * Some twins deliberately RENAME (warehouse_transforms `apply` ->
#     `apply_transforms`). That is a mapping, not a gap.
#
# What survives all of that is a real divergence. Each one is either fixed or
# recorded in the allow-list below WITH A REASON, so the next person doesn't
# re-report it (which is exactly what #753 asked for).
#
# Exit 0 = every pair reconciled; exit 1 = an unexplained gap. Offline,
# creds-free. LINT_ROOT lets tools/test-lint-twin-parity.rb drive it against
# throwaway fixture trees, mirroring check-plugin-version-bump.sh.

require 'json'
require 'set'
# Ruby 2.6 floor (macOS system ruby): this file uses a 2.7+ Enumerable
# method. Polyfilled rather than rewritten — see shared/lib/ruby_compat.rb.
require_relative '../shared/lib/ruby_compat'

ROOT = ENV['LINT_ROOT'] || File.expand_path('..', __dir__)
Dir.chdir(ROOT)

LIB = ENV['TWIN_LIB_DIR'] || 'shared/lib'

# --- Deliberate divergences -------------------------------------------------
# Ruby-side public names with no Python twin, each with the reason it is absent.
# Adding a name here is a decision to be reviewed, not a way to silence the gate.
ALLOWED = {
  'sigma_rest' => {
    'list_entries' =>
      'Not ported. Its pagination contract (`nextPage`/`page`) is documented as ' \
      'WRONG for the columns endpoints, which use nextPageToken/pageToken — see the ' \
      'comments in discover-columns.rb and discover-warehouse-columns.rb explaining ' \
      'why they hand-roll the loop instead. A Python port must not be a blind ' \
      'translation; port the endpoint-correct loop. Only live ruby caller: ' \
      'fidelity-loop.rb.'
  }
}.freeze

# Ruby name => Python name, where the twin intentionally uses a different name.
RENAMES = {
  'warehouse_transforms' => { 'apply' => 'apply_transforms', 'detect' => 'detect_warehouse' }
}.freeze

# --- Extraction -------------------------------------------------------------

# Public method names defined in a Ruby file.
#
# Heuristic, documented on purpose: a bare `private` line puts subsequent
# INSTANCE methods (`def foo`) out of the public API until end of file, while
# `def self.foo` stays public regardless. That is exact for every twin in this
# tree; if a future twin nests a private region inside a module that later
# reopens a public one, this over-reports rather than under-reports, and the
# reviewer adds an allow-list entry or splits the file.
def ruby_public(src)
  names = Set.new
  private_mode = false
  src.each_line do |line|
    stripped = line.strip
    private_mode = true if stripped == 'private'
    private_mode = false if stripped == 'public' || stripped == 'module_function'
    next unless (m = stripped.match(/\Adef\s+(self\.)?([a-zA-Z_][a-zA-Z_0-9]*[?!]?)/))
    is_singleton = !m[1].nil?
    next if private_mode && !is_singleton   # `private` never hides `def self.`
    name = m[2].sub(/[?!]\z/, '')           # token_stale? -> token_stale
    name = '__init__' if name == 'initialize'
    names << name
  end
  names
end

# All function/method names defined in a Python file, split into public and
# underscore-private. A leading underscore is the privacy marker; dunders are kept
# public because they are part of the observable API.
def python_names(src)
  pub = Set.new
  priv = Set.new
  src.each_line do |line|
    next unless (m = line.strip.match(/\A(?:async\s+)?def\s+([a-zA-Z_][a-zA-Z_0-9]*)/))
    name = m[1]
    if name.start_with?('_') && !name.start_with?('__')
      priv << name.sub(/\A_+/, '')
    else
      pub << name
    end
  end
  [pub, priv]
end

# --- Compare ----------------------------------------------------------------

pairs = Dir.glob(File.join(LIB, '*.rb')).sort.filter_map do |rb|
  base = File.basename(rb, '.rb')
  next if base.start_with?('test_')          # test twins are checked by running them
  py = File.join(File.dirname(rb), "#{base}.py")
  File.exist?(py) ? [base, rb, py] : nil
end

if pairs.empty?
  puts "OK: no .rb/.py twin pairs under #{LIB}/ to check."
  exit 0
end

gaps       = []  # no counterpart AT ALL — fail unless allow-listed
visibility = []  # exists, but only as `_name` — report; a porting trap, not a bug
explained  = []  # allow-listed — report, don't fail
stale      = []  # allow-listed but no longer missing — fail (keeps the list honest)

pairs.each do |mod, rb, py|
  rb_names = ruby_public(File.read(rb, encoding: 'UTF-8'))
  py_pub, py_priv = python_names(File.read(py, encoding: 'UTF-8'))
  renames  = RENAMES[mod] || {}
  allowed  = ALLOWED[mod] || {}

  present_pub = ->(n) { py_pub.include?(n) || py_pub.include?(renames[n].to_s) }
  present_any = ->(n) { present_pub.call(n) || py_priv.include?(n) || py_priv.include?(renames[n].to_s) }

  rb_names.each do |n|
    next if present_pub.call(n)
    if py_priv.include?(n) || py_priv.include?(renames[n].to_s)
      # THIS is the case #753's `^def` diff mistook for a missing function:
      # metric_binding.walk_chain is `_walk_chain`, sigma_rest.token_stale? is
      # `_token_stale`. The behaviour is there; only the visibility differs.
      visibility << [mod, n]
    elsif allowed.key?(n)
      explained << [mod, n, allowed[n]]
    else
      gaps << [mod, n, rb, py]
    end
  end

  # An allow-list entry for something that IS now present is stale — drop it, or
  # the list quietly grows into a permanent exemption nobody rereads.
  allowed.each_key { |n| stale << [mod, n] if present_any.call(n) }
end

checked = pairs.map(&:first)

unless gaps.empty?
  warn '::error::.rb/.py twin API gap — a Python caller of these hits AttributeError (#753):'
  gaps.each do |mod, name, rb, py|
    warn "  #{mod}: `#{name}` is public in #{rb} but absent from #{py}"
  end
  warn ''
  warn 'Fix by ONE of:'
  warn "  * port it to the .py twin;"
  warn "  * make it private on the Ruby side (`private`, or `_`-prefix the Python name) if it is internal;"
  warn "  * add it to ALLOWED in tools/lint-twin-parity.rb WITH A REASON, if the omission is deliberate."
end

unless stale.empty?
  warn '::error::stale ALLOWED entries in tools/lint-twin-parity.rb — these now EXIST in the .py twin:'
  stale.each { |mod, name| warn "  #{mod}: `#{name}` — delete this allow-list entry." }
  warn ''
end

exit 1 unless gaps.empty? && stale.empty?

puts "OK: #{checked.length} .rb/.py twin pair(s) reconciled — no missing function. " \
     "(#{explained.length} documented non-port, #{visibility.length} visibility-only difference.)"
explained.group_by(&:first).each do |mod, rows|
  puts "  ~ #{mod}: #{rows.map { |r| r[1] }.join(', ')} — deliberately not ported, see ALLOWED"
end
unless visibility.empty?
  puts
  puts 'Visibility-only (present as `_name` in the .py twin — a Python caller must'
  puts 'use the underscored name; these are NOT missing functions):'
  visibility.group_by(&:first).each do |mod, rows|
    puts "  ~ #{mod}: #{rows.map { |r| "#{r[1]} -> _#{r[1]}" }.join(', ')}"
  end
end
exit 0
