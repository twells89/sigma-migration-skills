#!/usr/bin/env ruby
# Credential-free startup-auth tests for assert-phase6-ran.rb.

require 'json'
require 'tmpdir'
require 'open3'
require 'socket'
require 'time'

GATE = File.expand_path('assert-phase6-ran.rb', __dir__)

def write_fixtures(dir)
  File.write(File.join(dir, 'parity-final.json'), JSON.generate(
    'charts_total' => 1,
    'charts_pass' => 1,
    'status' => 'PASS',
    'mode' => 'live',
    'tile_census' => {
      'zones_total' => 1,
      'charts_built' => 1,
      'zones_unmatched' => 0,
      'unmatched_zone_names' => []
    }
  ))
  File.write(
    File.join(dir, 'posted-workbooks.jsonl'),
    JSON.generate('id' => 'wb-auth-test') + "\n"
  )
  File.write(
    File.join(dir, 'wb-ids.json'),
    JSON.generate('workbookId' => 'wb-auth-test')
  )
end

failures = []
def check(condition, message, failures)
  puts "  #{condition ? 'PASS' : 'FAIL'}  #{message}"
  failures << message unless condition
end

puts 'test-assert-phase6-auth.rb — startup auth uses the shared provider'

Dir.mktmpdir('phase6-auth') do |dir|
  write_fixtures(dir)
  provider = File.join(dir, 'provider.py')
  marker = File.join(dir, 'provider-calls')
  File.write(provider, <<~PY)
    with open(#{marker.inspect}, "a") as marker:
        marker.write("called\\n")
    print("export SIGMA_API_TOKEN=browser-only-token")
    print("export SIGMA_TOKEN_MINTED_AT=#{Time.now.utc.iso8601}")
    print("export SIGMA_AUTH_METHOD=browser-cache")
  PY

  server = TCPServer.new('127.0.0.1', 0)
  port = server.addr[1]
  requests = []
  thread = Thread.new do
    loop do
      client = server.accept
      request_line = client.gets.to_s
      headers = {}
      while (line = client.gets)
        break if line == "\r\n"
        key, value = line.split(':', 2)
        headers[key.downcase] = value.to_s.strip if value
      end
      path = request_line.split[1].to_s
      requests << [path, headers['authorization']]
      body =
        if path.include?('/columns')
          JSON.generate('entries' => [])
        else
          JSON.generate('document' => { 'layout' => '' })
        end
      client.write(
        "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n" \
        "Content-Length: #{body.bytesize}\r\nConnection: close\r\n\r\n#{body}"
      )
      client.close
    end
  rescue IOError, Errno::EBADF
    nil
  end

  env = {
    'SIGMA_BASE_URL' => "http://127.0.0.1:#{port}",
    'SIGMA_API_TOKEN' => nil,
    'SIGMA_CLIENT_ID' => nil,
    'SIGMA_CLIENT_SECRET' => nil,
    'SIGMA_TOKEN_PROVIDER' => provider,
    'SIGMA_ALLOW_INSECURE_BASE_URL' => '1'
  }
  out, _err, status = Open3.capture3(env, 'ruby', GATE, '--workdir', dir)
  server.close
  thread.join

  check(status.exitstatus == 6,
        'browser-only auth reaches gate 4 (empty-layout failure), not gate 3 credential failure',
        failures)
  check(out.include?('[OK] gate 3/7: 0 live columns clean'),
        'gate 3 runs with the provider token', failures)
  check(requests.any? { |path, auth| path.include?('/columns') && auth == 'Bearer browser-only-token' },
        'the freshly surfaced provider token authorizes the live GET', failures)
  calls = File.exist?(marker) ? File.readlines(marker).length : 0
  check(calls == 1, 'startup resolves the browser provider exactly once', failures)
end

Dir.mktmpdir('phase6-auth-fail') do |dir|
  write_fixtures(dir)
  provider = File.join(dir, 'provider.py')
  File.write(provider, "raise SystemExit(1)\n")
  env = {
    'SIGMA_BASE_URL' => 'http://127.0.0.1:1',
    'SIGMA_API_TOKEN' => nil,
    'SIGMA_CLIENT_ID' => nil,
    'SIGMA_CLIENT_SECRET' => nil,
    'SIGMA_TOKEN_PROVIDER' => provider,
    'SIGMA_ALLOW_INSECURE_BASE_URL' => '1'
  }
  _out, err, status = Open3.capture3(env, 'ruby', GATE, '--workdir', dir)
  check(status.exitstatus == 5,
        'provider failure remains fail-closed at the live column gate', failures)
  check(err.include?('live column-type check CANNOT run'),
        'provider failure keeps the existing fail-closed diagnostic', failures)
end

if failures.empty?
  puts 'test-assert-phase6-auth.rb: ALL PASS'
  exit 0
end

warn "test-assert-phase6-auth.rb: #{failures.length} FAILURE(S)"
failures.each { |failure| warn "  - #{failure}" }
exit 1
