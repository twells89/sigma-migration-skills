#!/usr/bin/env ruby
# Store Sigma credentials so any coding agent can load them:
#   - ~/.claude/settings.json   — Claude Code auto-loads this into the env
#   - ~/.sigma-migration/env    — neutral, sourceable file every other agent
#                                 (Cursor, Cortex Code, plain shell) can use
# get-token.sh and lib/sigma_rest.rb fall back to the neutral file when the
# env vars aren't already set, so the skill works under any agent.

require 'io/console'
require 'json'
require 'fileutils'

SETTINGS_PATH = File.expand_path("~/.claude/settings.json")
NEUTRAL_PATH  = File.expand_path("~/.sigma-migration/env")

# Upsert `export KEY='value'` lines into the neutral cred file (0600), preserving
# any other vars already there (e.g. Tableau creds from setup-tableau.rb).
def upsert_neutral_env(pairs)
  FileUtils.mkdir_p(File.dirname(NEUTRAL_PATH), mode: 0o700)
  body = File.exist?(NEUTRAL_PATH) ? File.read(NEUTRAL_PATH) : ""
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

puts "Sigma credential setup"
puts "Values are stored in #{SETTINGS_PATH} and loaded automatically into every Claude Code session."
puts

print "Base URL [https://aws-api.sigmacomputing.com]: "
base = $stdin.gets.chomp
base = "https://aws-api.sigmacomputing.com" if base.empty?

# Client ID is NOT a secret — echo it so the reader can eyeball it. A hidden
# (noecho) prompt here was a recurring quickstart confusion: people paste the
# wrong value blind and only discover it when auth fails.
print "Client ID (not a secret — will echo): "
cid = $stdin.gets.chomp

print "Client Secret (hidden): "
sec = $stdin.noecho(&:gets).chomp
puts

if [base, cid, sec].any?(&:empty?)
  abort "Base URL, Client ID, and Client Secret are all required. Aborting without writing settings."
end

# The one-command orchestrators (migrate-looker.py, migrate-qlik.rb, ...) need
# the FULL warehouse-connection UUID for DM conversion. Capturing it here (when
# known) saves an export step on every run. Optional — Enter to skip.
print "Connection ID (full warehouse-connection UUID, optional — Enter to skip): "
conn = $stdin.gets.chomp

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

redacted_secret = sec.length > 8 ? "#{sec[0..3]}…#{sec[-4..]} (#{sec.length} chars)" : "(#{sec.length} chars)"

puts
puts "Credentials saved to:"
puts "  #{SETTINGS_PATH}  (Claude Code auto-loads this)"
puts "  #{NEUTRAL_PATH}  (any other agent / shell)"
puts
puts "  SIGMA_BASE_URL:      #{base}"
puts "  SIGMA_CLIENT_ID:     #{cid}"
puts "  SIGMA_CLIENT_SECRET: #{redacted_secret}"
puts "  SIGMA_CONNECTION_ID: #{conn.empty? ? '(skipped)' : conn}"
puts
puts "If the Client ID above looks like a URL or doesn't match what Sigma showed you, re-run this script."
puts "Claude Code: open a new session (or run `! source ~/.claude/settings.json`)."
puts "Other agents / shell: run `source ~/.sigma-migration/env` once per shell —"
puts "though get-token.sh and the Ruby scripts auto-source it for you."
