#!/usr/bin/env ruby
# Review and, only with per-workbook user confirmation, delete orphan Sigma
# workbooks left by spec-iteration retries.
#
# SAFETY CONTRACT:
#   * --keep is mandatory when the ledger contains more than one workbook.
#     The last ledger line is NOT assumed to be live: workdirs and their
#     append-only ledgers can be reused across migration runs.
#   * Every candidate is read back from BOTH the workbook and file APIs before
#     deletion. It must resolve to the same workbook inode, folder, creator, and
#     owner context as the explicitly kept workbook.
#   * Deletion is interactive only. The operator must type each candidate's full
#     ID after reviewing its live name/path/timestamps. There is deliberately no
#     --yes/non-interactive bypass.
#   * --dry-run performs all read-only validation and writes the proposed IDs,
#     but never prompts or deletes.
#
# Usage:
#   ruby scripts/cleanup-orphan-workbooks.rb --workdir /tmp/<name> --keep <live-id>
#   ruby scripts/cleanup-orphan-workbooks.rb --workdir /tmp/<name> --keep <live-id> --dry-run
#
# This script is NOT a way to delete the workbook just built. It always preserves
# --keep. Use Sigma's UI when the current workbook itself should be removed.
#
# Writes <workdir>/cleanup-marker.json for assert-phase6-ran.rb.
#
# Exit codes:
#   0  no cleanup needed, dry-run completed, or all candidates were confirmed/deleted
#   1  a candidate was refused, skipped, or failed
#   2  unsafe/invalid invocation (including a non-interactive destructive run)

require 'net/http'
require 'uri'
require 'json'
require 'time'
require 'optparse'

module OrphanWorkbookCleanup
  ID_PATTERN = /\A[A-Za-z0-9_-]+\z/.freeze

  module_function

  def parse_options(argv)
    opts = { dry_run: false }
    OptionParser.new do |parser|
      parser.on('--workdir DIR') { |value| opts[:workdir] = value }
      parser.on('--dry-run') { opts[:dry_run] = true }
      parser.on('--keep ID') { |value| opts[:keep] = value }
      # Retained for CLI compatibility. A missing ledger is always a safe no-op.
      parser.on('--allow-empty-log') { opts[:allow_empty] = true }
    end.parse!(argv)
    opts
  end

  def load_ledger(path)
    records = []
    File.readlines(path).each_with_index do |line, index|
      next if line.strip.empty?
      begin
        record = JSON.parse(line)
      rescue JSON::ParserError => e
        raise ArgumentError, "invalid JSON at #{File.basename(path)} line #{index + 1}: #{e.message}"
      end
      unless record.is_a?(Hash) && record['id'].is_a?(String) &&
             !record['id'].empty? && ID_PATTERN.match?(record['id'])
        raise ArgumentError, "#{File.basename(path)} line #{index + 1} must contain a safe string id"
      end
      records << record
    end
    records
  end

  def parse_json_response(response, label)
    code = response.code.to_i
    raise "#{label} returned HTTP #{code}" unless code.between?(200, 299)
    parsed = JSON.parse(response.body.to_s)
    raise "#{label} returned a non-object body" unless parsed.is_a?(Hash)
    parsed
  rescue JSON::ParserError => e
    raise "#{label} returned invalid JSON: #{e.message}"
  end

  def inspect_workbook(id, requester)
    workbook = parse_json_response(requester.call(:get, "/v2/workbooks/#{id}"),
                                   "GET /v2/workbooks/#{id}")
    file = parse_json_response(requester.call(:get, "/v2/files/#{id}"),
                               "GET /v2/files/#{id}")

    raise "workbook API returned #{workbook['workbookId'].inspect}, expected #{id}" unless workbook['workbookId'] == id
    raise "file API returned #{file['id'].inspect}, expected #{id}" unless file['id'] == id
    raise "file #{id} is type #{file['type'].inspect}, not workbook" unless file['type'] == 'workbook'
    if workbook['workbookUrlId'] && file['urlId'] && workbook['workbookUrlId'] != file['urlId']
      raise "workbook/file URL identifiers disagree for #{id}"
    end

    {
      'id' => id,
      'name' => file['name'] || workbook['name'],
      'path' => file['path'] || workbook['path'],
      'parentId' => file['parentId'],
      'ownerId' => file['ownerId'] || workbook['ownerId'],
      'createdBy' => file['createdBy'] || workbook['createdBy'],
      'createdAt' => file['createdAt'] || workbook['createdAt'],
      'updatedAt' => file['updatedAt'] || workbook['updatedAt']
    }
  end

  def same_cleanup_context?(candidate, kept)
    %w[parentId ownerId createdBy].all? do |key|
      candidate[key] && kept[key] && candidate[key] == kept[key]
    end
  end

  def marker_path(workdir)
    File.join(workdir, 'cleanup-marker.json')
  end

  def write_marker(workdir, marker)
    File.write(marker_path(workdir), JSON.pretty_generate(marker))
  end

  def tty?(input)
    input.respond_to?(:tty?) && input.tty?
  end

  def run(argv, env: ENV, input: $stdin, output: $stdout, error: $stderr, requester: nil)
    opts = parse_options(argv.dup)
    unless opts[:workdir]
      error.puts '--workdir required'
      return 2
    end

    log = File.join(opts[:workdir], 'posted-workbooks.jsonl')
    unless File.exist?(log)
      output.puts "[OK] no posted-workbooks.jsonl at #{log} — nothing to clean up"
      return 0
    end

    begin
      records = load_ledger(log)
    rescue ArgumentError => e
      error.puts "REFUSED: #{e.message}"
      return 2
    end
    if records.empty?
      output.puts '[OK] posted-workbooks.jsonl is empty — nothing to clean up'
      return 0
    end

    unique_ids = records.map { |record| record['id'] }.uniq
    if unique_ids.length == 1
      if opts[:keep] && opts[:keep] != unique_ids.first
        error.puts "REFUSED: --keep #{opts[:keep]} is not the ledger workbook #{unique_ids.first}"
        return 2
      end
      keep_id = opts[:keep] || unique_ids.first
      output.puts "[OK] only one POSTed workbook (#{keep_id}) — no orphans to clean up"
      write_marker(opts[:workdir], {
                     'ran_at' => Time.now.utc.iso8601, 'kept' => keep_id,
                     'deleted' => [], 'failed' => [], 'skipped' => [],
                     'dry_run' => opts[:dry_run]
                   })
      return 0
    end

    keep_id = opts[:keep].to_s
    if keep_id.empty?
      error.puts 'REFUSED: --keep <live-workbook-id> is required; ledger order is not proof of which workbook is live.'
      error.puts "Ledger IDs: #{unique_ids.join(', ')}"
      return 2
    end
    unless ID_PATTERN.match?(keep_id) && unique_ids.include?(keep_id)
      error.puts "REFUSED: --keep #{keep_id.inspect} is not a safe ID present in posted-workbooks.jsonl"
      return 2
    end
    unless opts[:dry_run] || tty?(input)
      error.puts 'REFUSED: workbook deletion requires an interactive terminal.'
      error.puts "Review first: ruby #{__FILE__} --workdir #{opts[:workdir]} --keep #{keep_id} --dry-run"
      error.puts 'Then run the same command without --dry-run and type each workbook ID when prompted.'
      return 2
    end

    unless requester
      base = env['SIGMA_BASE_URL']
      unless base && !base.empty?
        error.puts 'SIGMA_BASE_URL not set'
        return 2
      end
      requester = real_requester(base, env)
    end

    begin
      kept = inspect_workbook(keep_id, requester)
    rescue StandardError => e
      error.puts "REFUSED: could not validate the workbook to keep: #{e.message}"
      return 2
    end

    candidates = unique_ids.reject { |id| id == keep_id }
    output.puts "KEEPING (explicit --keep): #{kept['name'].inspect}"
    output.puts "  id:      #{keep_id}"
    output.puts "  path:    #{kept['path']}"
    output.puts "  created: #{kept['createdAt']}"
    output.puts
    output.puts "Reviewing #{candidates.length} ledger candidate(s). Ledgers can span multiple runs."
    output.puts 'Confirm only workbooks you recognize as retries from this migration.'

    deleted = []
    failed = []
    skipped = []
    would_delete = []

    candidates.each do |id|
      begin
        candidate = inspect_workbook(id, requester)
        unless same_cleanup_context?(candidate, kept)
          raise 'folder, owner, or creator differs from the explicitly kept workbook'
        end
      rescue StandardError => e
        error.puts "  [REFUSED] #{id}: #{e.message}"
        failed << { 'id' => id, 'reason' => e.message }
        next
      end

      output.puts
      output.puts 'CANDIDATE:'
      output.puts "  name:    #{candidate['name'].inspect}"
      output.puts "  id:      #{id}"
      output.puts "  path:    #{candidate['path']}"
      output.puts "  created: #{candidate['createdAt']}"
      output.puts "  updated: #{candidate['updatedAt']}"

      if opts[:dry_run]
        output.puts '  [DRY-RUN] validated; no deletion performed'
        would_delete << candidate
        next
      end

      output.print "Type the full workbook ID to delete this candidate, or press Enter to keep it:\n> "
      output.flush
      confirmation = input.gets.to_s.strip
      unless confirmation == id
        output.puts "  [KEPT] #{id} — confirmation did not match"
        skipped << { 'id' => id, 'reason' => 'user did not type the full workbook ID' }
        next
      end

      response = requester.call(:delete, "/v2/files/#{id}")
      code = response.code.to_i
      if code.between?(200, 299) || code == 404
        output.puts "  [deleted] #{id} (HTTP #{code})"
        deleted << { 'id' => id, 'status' => code }
      else
        body = response.body.to_s[0..200]
        error.puts "  [FAIL] #{id} (HTTP #{code}) — #{body}"
        failed << { 'id' => id, 'status' => code, 'body' => body }
      end
    end

    marker = {
      'ran_at' => Time.now.utc.iso8601,
      'kept' => keep_id,
      'deleted' => deleted,
      'failed' => failed,
      'skipped' => skipped,
      'dry_run' => opts[:dry_run]
    }
    marker['would_delete'] = would_delete if opts[:dry_run]
    write_marker(opts[:workdir], marker)

    if opts[:dry_run]
      output.puts "\n[DRY-RUN] #{would_delete.length} candidate(s) validated; no DELETE calls made."
      return failed.empty? ? 0 : 1
    end
    if failed.any? || skipped.any?
      error.puts "\nCleanup incomplete: deleted #{deleted.length}, refused/failed #{failed.length}, kept by user #{skipped.length}."
      return 1
    end

    output.puts "\n[OK] user confirmed and deleted #{deleted.length} orphan workbook(s); kept #{keep_id}"
    0
  rescue OptionParser::ParseError => e
    error.puts e.message
    2
  end

  def real_requester(base, env)
    $LOAD_PATH.unshift File.expand_path('lib', __dir__)
    require 'sigma_rest'
    lambda do |method, path|
      attempts = 0
      loop do
        attempts += 1
        uri = URI("#{base}#{path}")
        request = method == :delete ? Net::HTTP::Delete.new(uri) : Net::HTTP::Get.new(uri)
        request['Authorization'] = "Bearer #{Sigma.auth_token}"
        request['Accept'] = 'application/json'
        response = Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == 'https',
                                  read_timeout: 30) { |http| http.request(request) }
        if response.code.to_i == 401 && attempts == 1 && env['SIGMA_CLIENT_ID']
          Sigma.refresh_token!
          next
        end
        break response
      end
    end
  end
end

exit OrphanWorkbookCleanup.run(ARGV) if $PROGRAM_NAME == __FILE__
