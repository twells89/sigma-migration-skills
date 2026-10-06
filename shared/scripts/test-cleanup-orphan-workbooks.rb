#!/usr/bin/env ruby
# frozen_string_literal: true

require 'tmpdir'
require 'fileutils'
require 'json'
require 'stringio'
require_relative 'cleanup-orphan-workbooks'

Response = Struct.new(:code, :body)

class TtyInput < StringIO
  def tty?
    true
  end
end

class SequenceHTTP
  attr_reader :authorization

  def initialize(*responses)
    @responses = responses
    @authorization = []
  end

  def request(request)
    @authorization << request['Authorization']
    @responses.shift
  end
end

failures = []

def check(condition, message, failures)
  if condition
    puts "  ok - #{message}"
  else
    warn "  FAIL - #{message}"
    failures << message
  end
end

def response(body, code = 200)
  Response.new(code.to_s, JSON.generate(body))
end

def net_response(klass, code, message, body)
  value = klass.new('1.1', code, message)
  value.instance_variable_set(:@read, true)
  value.instance_variable_set(:@body, body)
  value
end

def workbook(id, name: "Migration #{id}", owner: 'member-1', creator: 'member-1')
  {
    'workbookId' => id,
    'workbookUrlId' => "url-#{id}",
    'name' => name,
    'path' => 'My Documents/Migrations',
    'ownerId' => owner,
    'createdBy' => creator,
    'createdAt' => '2026-08-27T12:00:00Z',
    'updatedAt' => '2026-08-27T12:05:00Z'
  }
end

def file_record(id, name: "Migration #{id}", parent: 'folder-1', owner: 'member-1', creator: 'member-1',
                type: 'workbook')
  {
    'id' => id,
    'urlId' => "url-#{id}",
    'name' => name,
    'type' => type,
    'parentId' => parent,
    'path' => 'My Documents/Migrations',
    'ownerId' => owner,
    'createdBy' => creator,
    'createdAt' => '2026-08-27T12:00:00Z',
    'updatedAt' => '2026-08-27T12:05:00Z'
  }
end

def requester_for(records, calls)
  lambda do |method, path|
    calls << [method, path]
    if method == :delete
      Response.new('200', '{}')
    elsif path =~ %r{\A/v2/workbooks/([^/]+)\z}
      response(records.fetch(Regexp.last_match(1)).fetch(:workbook))
    elsif path =~ %r{\A/v2/files/([^/]+)\z}
      response(records.fetch(Regexp.last_match(1)).fetch(:file))
    else
      Response.new('404', '{}')
    end
  end
end

def write_ledger(dir, records)
  File.write(File.join(dir, 'posted-workbooks.jsonl'),
             records.map { |record| JSON.generate(record) }.join("\n") + "\n")
end

def run_cleanup(dir, args: [], input: StringIO.new, requester: nil)
  out = StringIO.new
  err = StringIO.new
  code = OrphanWorkbookCleanup.run(
    ['--workdir', dir, *args],
    env: {},
    input: input,
    output: out,
    error: err,
    requester: requester
  )
  [code, out.string, err.string]
end

puts '== malformed ledgers fail closed =='
Dir.mktmpdir do |dir|
  File.write(File.join(dir, 'posted-workbooks.jsonl'), "{\"id\":\"wb-1\"}\nnot-json\n")
  calls = []
  code, _out, err = run_cleanup(dir, args: ['--keep', 'wb-1'], requester: ->(*parts) { calls << parts })
  check(code == 2, 'invalid JSON exits 2', failures)
  check(err.include?('invalid JSON'), 'invalid ledger line is reported', failures)
  check(calls.empty?, 'invalid ledger causes no API calls', failures)
end

puts '== multiple entries require an explicit keep id =='
Dir.mktmpdir do |dir|
  write_ledger(dir, [{ 'id' => 'wb-old' }, { 'id' => 'wb-live' }])
  calls = []
  code, _out, err = run_cleanup(dir, requester: ->(*parts) { calls << parts })
  check(code == 2, 'missing --keep exits 2', failures)
  check(err.include?('--keep <live-workbook-id> is required'), 'refusal explains explicit keep requirement', failures)
  check(calls.empty?, 'missing keep causes no API calls', failures)
end

puts '== non-interactive destructive runs never delete =='
Dir.mktmpdir do |dir|
  write_ledger(dir, [{ 'id' => 'wb-old' }, { 'id' => 'wb-live' }])
  calls = []
  code, _out, err = run_cleanup(
    dir,
    args: ['--keep', 'wb-live'],
    input: StringIO.new("wb-old\n"),
    requester: ->(*parts) { calls << parts }
  )
  check(code == 2, 'non-interactive invocation exits 2', failures)
  check(err.include?('requires an interactive terminal'), 'refusal names interactive requirement', failures)
  check(calls.empty?, 'non-interactive invocation makes no API calls', failures)
end

puts '== live metadata must match the kept workbook context =='
Dir.mktmpdir do |dir|
  write_ledger(dir, [{ 'id' => 'wb-other-folder' }, { 'id' => 'wb-live' }])
  records = {
    'wb-live' => { workbook: workbook('wb-live'), file: file_record('wb-live') },
    'wb-other-folder' => {
      workbook: workbook('wb-other-folder'),
      file: file_record('wb-other-folder', parent: 'folder-2')
    }
  }
  calls = []
  code, _out, err = run_cleanup(
    dir,
    args: ['--keep', 'wb-live'],
    input: TtyInput.new("wb-other-folder\n"),
    requester: requester_for(records, calls)
  )
  check(code == 1, 'context mismatch exits 1', failures)
  check(err.include?('folder, owner, or creator differs'), 'context mismatch is reported', failures)
  check(calls.none? { |method, _path| method == :delete }, 'context mismatch causes no DELETE', failures)
  marker = JSON.parse(File.read(File.join(dir, 'cleanup-marker.json')))
  check(marker['failed'].first['id'] == 'wb-other-folder', 'refused id is recorded in marker', failures)
end

puts '== deletion requires typing each exact candidate id =='
Dir.mktmpdir do |dir|
  write_ledger(dir, [{ 'id' => 'wb-old' }, { 'id' => 'wb-live' }])
  records = {
    'wb-live' => { workbook: workbook('wb-live'), file: file_record('wb-live') },
    'wb-old' => { workbook: workbook('wb-old'), file: file_record('wb-old') }
  }
  calls = []
  code, out, err = run_cleanup(
    dir,
    args: ['--keep', 'wb-live'],
    input: TtyInput.new("wb-old\n"),
    requester: requester_for(records, calls)
  )
  check(code.zero?, 'exact confirmation succeeds', failures)
  check(err.empty?, 'successful cleanup has no stderr', failures)
  check(out.include?('Type the full workbook ID'), 'operator receives an explicit prompt', failures)
  deletes = calls.select { |method, _path| method == :delete }
  check(deletes == [[:delete, '/v2/files/wb-old']], 'only the confirmed candidate is deleted', failures)
  check(calls.none? { |method, path| method == :delete && path.include?('wb-live') },
        'the explicit keep id is never deleted', failures)
end

puts '== declined candidates remain and make cleanup incomplete =='
Dir.mktmpdir do |dir|
  write_ledger(dir, [{ 'id' => 'wb-old' }, { 'id' => 'wb-live' }])
  records = {
    'wb-live' => { workbook: workbook('wb-live'), file: file_record('wb-live') },
    'wb-old' => { workbook: workbook('wb-old'), file: file_record('wb-old') }
  }
  calls = []
  code, out, _err = run_cleanup(
    dir,
    args: ['--keep', 'wb-live'],
    input: TtyInput.new("\n"),
    requester: requester_for(records, calls)
  )
  check(code == 1, 'declining a candidate exits 1', failures)
  check(out.include?('[KEPT] wb-old'), 'declined candidate is reported as kept', failures)
  check(calls.none? { |method, _path| method == :delete }, 'declining causes no DELETE', failures)
  marker = JSON.parse(File.read(File.join(dir, 'cleanup-marker.json')))
  check(marker['skipped'].first['id'] == 'wb-old', 'declined id is recorded in marker', failures)
end

puts '== dry-run validates metadata without prompting or deleting =='
Dir.mktmpdir do |dir|
  write_ledger(dir, [{ 'id' => 'wb-old' }, { 'id' => 'wb-live' }])
  records = {
    'wb-live' => { workbook: workbook('wb-live'), file: file_record('wb-live') },
    'wb-old' => { workbook: workbook('wb-old'), file: file_record('wb-old') }
  }
  calls = []
  code, out, err = run_cleanup(
    dir,
    args: ['--keep', 'wb-live', '--dry-run'],
    requester: requester_for(records, calls)
  )
  check(code.zero?, 'dry-run exits 0', failures)
  check(err.empty?, 'valid dry-run has no stderr', failures)
  check(out.include?('[DRY-RUN] validated'), 'dry-run reports validated candidate', failures)
  check(calls.none? { |method, _path| method == :delete }, 'dry-run makes no DELETE calls', failures)
  marker = JSON.parse(File.read(File.join(dir, 'cleanup-marker.json')))
  check(marker['dry_run'] == true && marker['would_delete'].first['id'] == 'wb-old',
        'dry-run marker records proposed candidate', failures)
end

puts '== real requester delegates browser-only 401 refresh to Sigma.request =='
saved_env = ENV.to_h
original_provider = nil
begin
  ENV['SIGMA_BASE_URL'] = 'https://api.sigmacomputing.com'
  ENV['SIGMA_API_TOKEN'] = 'expired-browser-token'
  ENV['SIGMA_CLIENT_ID'] = '' # prevent neutral-env bootstrap while requiring sigma_rest
  %w[SIGMA_CLIENT_SECRET SIGMA_TOKEN_MINTED_AT SIGMA_AUTH_METHOD].each { |key| ENV.delete(key) }

  http = SequenceHTTP.new(
    net_response(Net::HTTPUnauthorized, '401', 'Unauthorized', '{"code":"unauthorized"}'),
    net_response(Net::HTTPOK, '200', 'OK', '{"workbookId":"wb-live"}')
  )
  requester = OrphanWorkbookCleanup.real_requester(ENV['SIGMA_BASE_URL'], ENV, http: http)
  ENV.delete('SIGMA_CLIENT_ID')

  Sigma.instance_variable_set(:@token_override, nil)
  Sigma.instance_variable_set(:@minted_at, nil)
  Sigma.instance_variable_set(:@refresh_inflight, false)
  Sigma.instance_variable_set(:@validated_bases, nil)
  provider_calls = 0
  provider = {
    'SIGMA_API_TOKEN' => 'browser-refreshed-token',
    'SIGMA_TOKEN_MINTED_AT' => Time.now.utc.iso8601,
    'SIGMA_AUTH_METHOD' => 'browser'
  }
  original_provider = Sigma.method(:token_provider_result)
  Sigma.define_singleton_method(:token_provider_result) do
    provider_calls += 1
    provider
  end

  raw = requester.call(:get, '/v2/workbooks/wb-live')
  check(raw.code == '200' && raw.body == '{"workbookId":"wb-live"}',
        'requester preserves the final response code/body object', failures)
  check(provider_calls == 1, 'a 401 invokes the browser token provider exactly once', failures)
  check(http.authorization == ['Bearer expired-browser-token', 'Bearer browser-refreshed-token'],
        'the retry uses the browser-refreshed bearer token', failures)
  check(!ENV.key?('SIGMA_CLIENT_ID'),
        'browser refresh and retry do not require SIGMA_CLIENT_ID', failures)

  unavailable_http = SequenceHTTP.new(
    net_response(Net::HTTPServiceUnavailable, '503', 'Unavailable', 'retry later')
  )
  unavailable_requester = OrphanWorkbookCleanup.real_requester(
    ENV['SIGMA_BASE_URL'], ENV, http: unavailable_http
  )
  unavailable = unavailable_requester.call(:delete, '/v2/files/wb-old')
  check(unavailable.code == '503' && unavailable.body == 'retry later',
        'final non-2xx status and body remain available to cleanup safety logic', failures)
ensure
  if original_provider
    Sigma.singleton_class.send(:define_method, :token_provider_result, original_provider)
  end
  ENV.replace(saved_env)
end

abort "#{failures.length} cleanup safety test(s) failed" unless failures.empty?
puts "\nAll cleanup safety tests passed."
