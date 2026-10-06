#!/usr/bin/env ruby
# frozen_string_literal: true

# Offline integration coverage for find-or-pick-dm.rb's response-preserving
# Sigma.request delegation. The first list request receives a 401; a browser-only
# provider (no client id/secret) refreshes the token and the picker retries once.

require 'json'
require 'open3'
require 'tmpdir'
require 'webrick'

failures = []

def check(condition, message, failures)
  if condition
    puts "  ok - #{message}"
  else
    warn "  FAIL - #{message}"
    failures << message
  end
end

picker = File.expand_path('find-or-pick-dm.rb', __dir__)
requests = []
request_mutex = Mutex.new

server = WEBrick::HTTPServer.new(
  BindAddress: '127.0.0.1',
  Port: 0,
  Logger: WEBrick::Log.new(File::NULL),
  AccessLog: []
)
server.mount_proc('/v2/dataModels') do |request, response|
  authorization = request['authorization']
  request_mutex.synchronize { requests << [request.path, authorization] }
  response['Content-Type'] = 'application/json'

  if authorization == 'Bearer expired-browser-token'
    response.status = 401
    response.body = JSON.generate('code' => 'unauthorized')
  elsif request.path == '/v2/dataModels'
    response.status = 200
    response.body = JSON.generate(
      'entries' => [
        {
          'dataModelId' => 'dm-orders',
          'name' => 'Orders Fact',
          'updatedAt' => '2026-10-05T20:00:00Z'
        },
        {
          'dataModelId' => 'dm-unavailable',
          'name' => 'Unrelated Model',
          'updatedAt' => '2026-10-05T19:00:00Z'
        }
      ],
      'nextPage' => nil
    )
  elsif request.path == '/v2/dataModels/dm-orders/spec'
    response.status = 200
    response.body = JSON.generate(
      'pages' => [
        {
          'elements' => [
            {
              'source' => {
                'kind' => 'warehouse-table',
                'path' => %w[ACME SALES ORDERS_FACT]
              },
              'columns' => [{ 'name' => 'ORDER_ID' }, { 'name' => 'REVENUE' }]
            }
          ]
        }
      ]
    )
  elsif request.path == '/v2/dataModels/dm-unavailable/spec'
    response.status = 403
    response.body = 'spec unavailable marker'
  else
    response.status = 404
    response.body = '{}'
  end
end

thread = Thread.new { server.start }
sleep 0.2

begin
  Dir.mktmpdir do |dir|
    signature_path = File.join(dir, 'signature.json')
    result_path = File.join(dir, 'dm-match.json')
    provider_path = File.join(dir, 'browser_provider.py')
    provider_log = File.join(dir, 'provider.log')

    File.write(
      signature_path,
      JSON.pretty_generate(
        'tableau_workbook' => 'Orders Fact',
        'warehouse_tables' => ['ACME.SALES.ORDERS_FACT'],
        'referenced_columns' => %w[ORDER_ID REVENUE]
      )
    )
    File.write(
      provider_path,
      <<~PYTHON
        import datetime
        import os

        with open(os.environ["PROVIDER_LOG"], "a", encoding="utf-8") as handle:
            handle.write(os.environ.get("SIGMA_CLIENT_ID", "<missing>") + "\\n")
        minted = datetime.datetime.now(datetime.timezone.utc).isoformat().replace("+00:00", "Z")
        print("export SIGMA_API_TOKEN=browser-refreshed-token")
        print("export SIGMA_TOKEN_MINTED_AT=" + minted)
        print("export SIGMA_AUTH_METHOD=browser")
      PYTHON
    )

    env = {
      'HOME' => dir,
      'PROVIDER_LOG' => provider_log,
      'SIGMA_BASE_URL' => "http://127.0.0.1:#{server.config[:Port]}",
      'SIGMA_ALLOW_INSECURE_BASE_URL' => '1',
      'SIGMA_API_TOKEN' => 'expired-browser-token',
      'SIGMA_TOKEN_PROVIDER' => provider_path,
      'SIGMA_CLIENT_ID' => nil,
      'SIGMA_CLIENT_SECRET' => nil,
      'SIGMA_TOKEN_MINTED_AT' => nil,
      'SIGMA_AUTH_METHOD' => nil
    }
    _stdout, stderr, status = Open3.capture3(
      env,
      'ruby', picker,
      '--workbook-signature', signature_path,
      '--out', result_path,
      '--auto-pick',
      '--refresh'
    )

    result = File.exist?(result_path) ? JSON.parse(File.read(result_path)) : {}
    captured = request_mutex.synchronize { requests.dup }
    provider_lines = File.exist?(provider_log) ? File.readlines(provider_log, chomp: true) : []

    check(status.exitstatus == 0, 'picker succeeds after the browser refresh', failures)
    check(result['recommended_dm_id'] == 'dm-orders' && result['auto_picked'] == true,
          'ranking and auto-pick behavior are preserved', failures)
    check(captured.first(2) == [
            ['/v2/dataModels', 'Bearer expired-browser-token'],
            ['/v2/dataModels', 'Bearer browser-refreshed-token']
          ],
          'the 401 list request is retried once with the refreshed bearer', failures)
    check(captured.drop(2).all? { |_path, auth| auth == 'Bearer browser-refreshed-token' },
          'subsequent spec requests use the refreshed browser token', failures)
    check(provider_lines == ['<missing>'],
          'refresh invokes the provider once with no SIGMA_CLIENT_ID gating', failures)
    check(!stderr.include?('SIGMA_CLIENT_ID'),
          'browser-only auth does not report a missing client id', failures)
    check(stderr.include?('403') && stderr.include?('spec unavailable marker'),
          'final non-2xx status and body still reach picker failure handling', failures)
  end
ensure
  server.shutdown
  thread.join
end

abort "#{failures.length} picker auth test(s) failed" unless failures.empty?
puts "\nAll picker browser-auth tests passed."
