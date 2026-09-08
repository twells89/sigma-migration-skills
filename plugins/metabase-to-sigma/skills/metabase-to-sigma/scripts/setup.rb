#!/usr/bin/env ruby
# Store Sigma credentials so any coding agent can load them:
#   - ~/.claude/settings.json   — Claude Code auto-loads this into the env
#   - ~/.sigma-migration/env    — neutral, sourceable file every other agent
#                                 (Cursor, Cortex Code, plain shell) can use
# get-token.sh and lib/sigma_rest.rb fall back to the neutral file when the
# env vars aren't already set, so the skill works under any agent.
#
# THE USER RUNS THIS ONCE, in a real terminal. Three modes:
#   * interactive (a TTY): prompts for each value (secret hidden), OR
#   * flags (no TTY / automation):
#       ruby scripts/setup.rb --client-id <id> --client-secret <secret> \
#         [--base-url https://aws-api.sigmacomputing.com] [--connection-id <uuid>]
#   * environment (--from-env, or automatic when stdin is not a TTY):
#       SIGMA_CLIENT_ID + SIGMA_CLIENT_SECRET [+ SIGMA_BASE_URL,
#       SIGMA_CONNECTION_ID] — persists the already-exported values without
#       inlining the secret into any command line or transcript.
# When stdin is NOT a TTY (agent harness, piped run) and neither flags nor env
# vars supply the values, this prints both non-interactive invocations and
# exits 2 instead of hanging forever on a prompt nobody can answer. The secret
# is NEVER read via an echoing prompt (IO#noecho raises Errno::EBADF on
# Windows Git-Bash mintty; the fallback is the env var, not visible typing).

require 'io/console'
require 'json'
require 'fileutils'
require 'optparse'
require 'uri'
begin
  require_relative 'lib/redact'   # vendored plugin layout (scripts/lib/redact.rb)
rescue LoadError
  require_relative '../lib/redact' # canonical layout (shared/scripts + shared/lib)
end

SETTINGS_PATH = File.expand_path("~/.claude/settings.json")
NEUTRAL_PATH  = File.expand_path("~/.sigma-migration/env")
DEFAULT_BASE  = "https://aws-api.sigmacomputing.com"

flags = {}
OptionParser.new do |p|
  p.banner = "usage: ruby scripts/setup.rb [--client-id ID --client-secret SECRET] " \
             "[--base-url URL] [--connection-id UUID] [--from-env]"
  p.on('--base-url URL',       "Sigma API base URL (default: #{DEFAULT_BASE})") { |v| flags[:base] = v }
  p.on('--client-id ID',       'Sigma API client id (not a secret)')            { |v| flags[:cid]  = v }
  p.on('--client-secret SEC',  'Sigma API client secret')                       { |v| flags[:sec]  = v }
  p.on('--connection-id UUID', 'full warehouse-connection UUID (optional)')     { |v| flags[:conn] = v }
  p.on('--from-env', 'read SIGMA_CLIENT_ID/SIGMA_CLIENT_SECRET/SIGMA_BASE_URL/SIGMA_CONNECTION_ID from the environment (no prompts, nothing echoed)') { flags[:from_env] = true }
  p.on('-h', '--help') { puts p; exit 0 }
end.parse!

# --from-env (explicit, or implicitly attempted when no TTY): pull the values
# already exported in this shell. Reported per-value below.
$value_sources = {}
if flags[:from_env] || (!$stdin.tty? && flags[:cid].to_s.empty? && flags[:sec].to_s.empty?)
  { base: 'SIGMA_BASE_URL', cid: 'SIGMA_CLIENT_ID', sec: 'SIGMA_CLIENT_SECRET', conn: 'SIGMA_CONNECTION_ID' }.each do |k, var|
    next unless flags[k].to_s.empty? && !ENV[var].to_s.empty?
    flags[k] = ENV[var]
    $value_sources[k] = "env #{var}"
  end
  if flags[:from_env] && (flags[:cid].to_s.empty? || flags[:sec].to_s.empty?)
    warn 'ERROR: --from-env given but SIGMA_CLIENT_ID and/or SIGMA_CLIENT_SECRET are not set.'
    warn "Export them first (they are stored, never echoed):"
    warn "  export SIGMA_CLIENT_ID='<id>'  SIGMA_CLIENT_SECRET='<secret>'"
    warn "  [export SIGMA_BASE_URL='#{DEFAULT_BASE}'  SIGMA_CONNECTION_ID='<uuid>']"
    exit 2
  end
end

# Upsert `export KEY='value'` lines into the neutral cred file (0600), preserving
# any other vars already there (e.g. Tableau creds from setup-tableau.rb).
def upsert_neutral_env(pairs)
  FileUtils.mkdir_p(File.dirname(NEUTRAL_PATH), mode: 0o700)
  # encoding: 'UTF-8' — this body is regexp-matched below, so a raw read would
  # inherit the locale's default external encoding and raise
  # `invalid byte sequence in US-ASCII` on any non-ASCII byte already in the file
  # (a password or path with an accent is enough). F5 crash class, #752.
  body = File.exist?(NEUTRAL_PATH) ? File.read(NEUTRAL_PATH, encoding: 'UTF-8') : ""
  pairs.each do |k, v|
    line = "export #{k}='#{v}'"
    if body =~ /^export #{Regexp.escape(k)}=.*$/
      body = body.sub(/^export #{Regexp.escape(k)}=.*$/, line)
    else
      body += "\n" unless body.empty? || body.end_with?("\n")
      body += line + "\n"
    end
  end
  File.write(NEUTRAL_PATH, body)
  File.chmod(0o600, NEUTRAL_PATH)
end

puts "Sigma credential setup — the user runs this ONCE (interactive or via flags)."
puts "Values are stored in #{SETTINGS_PATH} and loaded automatically into every Claude Code session."
puts

interactive = $stdin.tty?
need_prompt = flags[:cid].to_s.empty? || flags[:sec].to_s.empty?

if need_prompt && !interactive
  # No TTY, no flags, no env vars: NEVER hang on gets — print the exact
  # non-interactive invocations instead (env path first: it keeps the secret
  # out of command lines and transcripts).
  warn 'ERROR: stdin is not a TTY, so the interactive prompts cannot run — and'
  warn '--client-id/--client-secret were not passed (and SIGMA_CLIENT_ID/'
  warn 'SIGMA_CLIENT_SECRET are not in the environment). Run it non-interactively:'
  warn ''
  warn '  # preferred (secret stays out of the command line):'
  warn "  export SIGMA_CLIENT_ID='<id>'  SIGMA_CLIENT_SECRET='<secret>'"
  warn '  ruby scripts/setup.rb --from-env'
  warn ''
  warn '  # or via flags:'
  warn '  ruby scripts/setup.rb \\'
  warn "    --client-id <SIGMA_CLIENT_ID> --client-secret '<SIGMA_CLIENT_SECRET>' \\"
  warn "    [--base-url #{DEFAULT_BASE}] [--connection-id <uuid>]"
  warn ''
  warn '…or run it once from a real terminal (it will prompt). Never inline the'
  warn 'secret into a shared command log — prefer the interactive prompt when a'
  warn 'human is present.'
  exit 2
end

base = flags[:base].to_s
cid  = flags[:cid].to_s
sec  = flags[:sec].to_s
conn = flags[:conn].to_s

if need_prompt
  if base.empty?
    print "Base URL [#{DEFAULT_BASE}]: "
    base = $stdin.gets.to_s.chomp
  end
  # Client ID is NOT a secret — echo it so the reader can eyeball it. A hidden
  # (noecho) prompt here was a recurring quickstart confusion: people paste the
  # wrong value blind and only discover it when auth fails.
  if cid.empty?
    print "Client ID (not a secret — will echo): "
    cid = $stdin.gets.to_s.chomp
  end
  if sec.empty?
    print "Client Secret (hidden): "
    # HIDDEN-OR-ENV ONLY. IO#noecho raises (Errno::EBADF on Windows Git-Bash
    # mintty; ENOTTY/ENXIO/IOError elsewhere) when stdin is not a real TTY even
    # though tty? said it was — the field crash echoed secrets on the retry.
    # On that failure: use SIGMA_CLIENT_SECRET from the environment if present,
    # else exit 2 with instructions — NEVER fall back to an echoing gets.
    sec = begin
      s = $stdin.noecho(&:gets)
      puts
      s.to_s.chomp
    rescue StandardError => e
      puts
      env_sec = ENV['SIGMA_CLIENT_SECRET'].to_s
      if env_sec.empty?
        warn "ERROR: hidden prompt unavailable (#{e.class}: #{e.message}) and SIGMA_CLIENT_SECRET is not set."
        warn 'Refusing to read the secret via an echoing prompt. Either:'
        warn "  export SIGMA_CLIENT_SECRET='<secret>'   # then re-run (or use --from-env)"
        warn '  …or pass --client-secret, or run from a real terminal.'
        exit 2
      end
      warn "(hidden prompt unavailable — #{e.class}; using SIGMA_CLIENT_SECRET from the environment, value not echoed)"
      $value_sources[:sec] = "env SIGMA_CLIENT_SECRET (hidden prompt unavailable: #{e.class})"
      env_sec
    end
  end
end
base = DEFAULT_BASE if base.empty?

if [base, cid, sec].any?(&:empty?)
  abort "Base URL, Client ID, and Client Secret are all required. Aborting without writing settings."
end

# Security (A2): refuse to persist credentials for a non-https / non-sigmacomputing.com
# base URL — a poisoned base would exfiltrate the client id/secret on every run.
# Opt out (self-hosted/dev) with SIGMA_ALLOW_INSECURE_BASE_URL=1 (loud warning).
if ENV['SIGMA_ALLOW_INSECURE_BASE_URL'] == '1'
  warn "WARNING: SIGMA_ALLOW_INSECURE_BASE_URL=1 — skipping SIGMA_BASE_URL validation (#{base})"
else
  _bu = (URI.parse(base) rescue nil)
  _bh = _bu&.host&.downcase
  abort "SIGMA_BASE_URL must use https:// (got '#{base}'). Refusing to write credentials. Set SIGMA_ALLOW_INSECURE_BASE_URL=1 to override (self-hosted/dev)." unless _bu&.scheme == 'https'
  abort "SIGMA_BASE_URL host '#{_bh}' is not a sigmacomputing.com host. Refusing to write credentials. Set SIGMA_ALLOW_INSECURE_BASE_URL=1 to override." unless _bh == 'sigmacomputing.com' || _bh&.end_with?('.sigmacomputing.com')
end

# The one-command orchestrators (migrate-looker.py, migrate-qlik.rb, ...) need
# the FULL warehouse-connection UUID for DM conversion. Capturing it here (when
# known) saves an export step on every run. Optional — Enter to skip.
if conn.empty? && need_prompt
  print "Connection ID (full warehouse-connection UUID, optional — Enter to skip): "
  conn = $stdin.gets.to_s.chomp
end

settings = File.exist?(SETTINGS_PATH) ? JSON.parse(File.read(SETTINGS_PATH)) : {}
settings["env"] ||= {}
settings["env"]["SIGMA_BASE_URL"]      = base
settings["env"]["SIGMA_CLIENT_ID"]     = cid
settings["env"]["SIGMA_CLIENT_SECRET"] = sec
settings["env"]["SIGMA_CONNECTION_ID"] = conn unless conn.empty?

FileUtils.mkdir_p(File.dirname(SETTINGS_PATH))
File.write(SETTINGS_PATH, JSON.pretty_generate(settings))

pairs = {
  "SIGMA_BASE_URL"      => base,
  "SIGMA_CLIENT_ID"     => cid,
  "SIGMA_CLIENT_SECRET" => sec,
}
pairs["SIGMA_CONNECTION_ID"] = conn unless conn.empty?
upsert_neutral_env(pairs)

# Contract: never echo credential values — mask all but the last 4 characters.
redacted_secret = "#{Redact.mask(sec)} (#{sec.length} chars)"

puts
puts "Credentials saved to:"
puts "  #{SETTINGS_PATH}  (Claude Code auto-loads this)"
puts "  #{NEUTRAL_PATH}  (any other agent / shell)"
puts
_src = ->(k) { $value_sources[k] ? "  [from #{$value_sources[k]}]" : '' }
puts "  SIGMA_BASE_URL:      #{base}#{_src.call(:base)}"
puts "  SIGMA_CLIENT_ID:     #{cid}#{_src.call(:cid)}"
puts "  SIGMA_CLIENT_SECRET: #{redacted_secret}#{_src.call(:sec)}"
puts "  SIGMA_CONNECTION_ID: #{conn.empty? ? '(skipped)' : conn}#{_src.call(:conn)}"
puts
puts "If the Client ID above looks like a URL or doesn't match what Sigma showed you, re-run this script."
puts "Claude Code: open a new session (or run `! source ~/.claude/settings.json`)."
puts "Other agents / shell: run `source ~/.sigma-migration/env` once per shell —"
puts "though get-token.sh and the Ruby scripts auto-source it for you."
