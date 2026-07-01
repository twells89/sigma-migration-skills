#!/usr/bin/env ruby
# Store Tableau credentials so any coding agent can load them:
#   - ~/.claude/settings.json   — Claude Code auto-loads this into the env
#   - ~/.sigma-migration/env    — neutral, sourceable file every other agent uses
# Use this when the Tableau MCP isn't available (or when the workbook has an embedded
# datasource that the MCP can't see). See refs/tableau-rest.md.

require 'io/console'
require 'json'
require 'fileutils'

SETTINGS_PATH = File.expand_path("~/.claude/settings.json")
NEUTRAL_PATH  = File.expand_path("~/.sigma-migration/env")

# Upsert `export KEY='value'` lines into the neutral cred file (0600), preserving
# any other vars already there (e.g. Sigma creds from setup.rb).
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

puts "Tableau credential setup"
puts "Values are stored in #{SETTINGS_PATH} and loaded automatically into every Claude Code session."
puts

print "Deployment — [c]loud or self-hosted [s]erver? [c]: "
is_server = $stdin.gets.to_s.strip.downcase.start_with?("s")

if is_server
  print "Server URL (e.g. https://tableau.mycompany.com): "
  server = $stdin.gets.chomp
else
  print "Server URL [https://10ay.online.tableau.com]: "
  server = $stdin.gets.chomp
  server = "https://10ay.online.tableau.com" if server.empty?
end
server = server.sub(%r{/+$}, '')

if is_server
  print "Site contentUrl (path segment after /site/ in the URL; LEAVE BLANK for the Default site): "
else
  print "Site contentUrl (the path segment after /site/ in the Tableau URL, e.g. 'dataflow'): "
end
content_url = $stdin.gets.chomp

print "PAT name (the label you typed when creating the token in Tableau): "
pat_name = $stdin.gets.chomp

print "PAT secret (will be hidden): "
pat_secret = $stdin.noecho(&:gets).chomp
puts

# contentUrl is intentionally allowed to be empty — that's the Tableau Server
# "Default" site. Everything else is required.
if [server, pat_name, pat_secret].any?(&:empty?)
  abort "Server URL, PAT name, and PAT secret are required. Aborting without writing settings."
end

settings = File.exist?(SETTINGS_PATH) ? JSON.parse(File.read(SETTINGS_PATH)) : {}
settings["env"] ||= {}
settings["env"]["TABLEAU_SERVER_URL"]        = server
settings["env"]["TABLEAU_SITE_CONTENT_URL"]  = content_url
settings["env"]["TABLEAU_PAT_NAME"]          = pat_name
settings["env"]["TABLEAU_PAT_SECRET"]        = pat_secret

File.write(SETTINGS_PATH, JSON.pretty_generate(settings))

upsert_neutral_env(
  "TABLEAU_SERVER_URL"       => server,
  "TABLEAU_SITE_CONTENT_URL" => content_url,
  "TABLEAU_PAT_NAME"         => pat_name,
  "TABLEAU_PAT_SECRET"       => pat_secret,
)

puts "Wrote Tableau credentials to:"
puts "  #{SETTINGS_PATH}  (Claude Code auto-loads this)"
puts "  #{NEUTRAL_PATH}  (any other agent / shell)"
puts
puts "Claude Code: open a new session (or `! source ~/.claude/settings.json`)."
puts "Other agents / shell: `source ~/.sigma-migration/env`, then run"
puts "`eval \"$(scripts/get-tableau-token.sh)\"` to sign in."
