#!/usr/bin/env ruby
# frozen_string_literal: true

# Credential-free browser-auth coverage for QuickSight's Ruby Sigma live paths.

require 'minitest/autorun'
require 'net/http'
require_relative 'lib/sigma_rest'

class QuickSightSigmaAuthTest < Minitest::Test
  BASE = 'https://api.sigmacomputing.com'
  PROVIDER = {
    'SIGMA_API_TOKEN' => 'browser-refreshed-token',
    'SIGMA_TOKEN_MINTED_AT' => '2026-10-05T20:00:00Z',
    'SIGMA_AUTH_METHOD' => 'browser'
  }.freeze

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

  def response(klass, code, message, body)
    value = klass.new('1.1', code, message)
    value.instance_variable_set(:@read, true)
    value.instance_variable_set(:@body, body)
    value
  end

  def setup
    @saved = ENV.to_h
    ENV['SIGMA_BASE_URL'] = BASE
    ENV['SIGMA_API_TOKEN'] = 'caller-token'
    %w[SIGMA_CLIENT_ID SIGMA_CLIENT_SECRET SIGMA_TOKEN_MINTED_AT SIGMA_AUTH_METHOD].each do |key|
      ENV.delete(key)
    end
    Sigma.instance_variable_set(:@token_override, nil)
    Sigma.instance_variable_set(:@minted_at, nil)
    Sigma.instance_variable_set(:@refresh_inflight, false)
  end

  def teardown
    ENV.replace(@saved)
  end

  def test_browser_only_refresh_retries_one_401
    http = SequenceHTTP.new(
      response(Net::HTTPUnauthorized, '401', 'Unauthorized', '{"code":"unauthorized"}'),
      response(Net::HTTPOK, '200', 'OK', '{"ok":true}')
    )

    result = Sigma.stub(:token_provider_result, PROVIDER) do
      Sigma.request(:get, '/v2/whoami', http: http)
    end

    assert_equal({ 'ok' => true }, result)
    assert_equal ['Bearer caller-token', 'Bearer browser-refreshed-token'], http.authorization
    assert_equal 'browser', ENV['SIGMA_AUTH_METHOD']
    refute ENV.key?('SIGMA_CLIENT_ID')
  end

  def test_second_401_is_not_retried
    http = SequenceHTTP.new(
      response(Net::HTTPUnauthorized, '401', 'Unauthorized', '{}'),
      response(Net::HTTPUnauthorized, '401', 'Unauthorized', '{}')
    )

    assert_raises(Sigma::Error) do
      Sigma.stub(:token_provider_result, PROVIDER) do
        Sigma.request(:get, '/v2/whoami', http: http)
      end
    end
    assert_equal 2, http.authorization.length
  end

  def test_known_stale_token_refreshes_before_request
    ENV['SIGMA_TOKEN_MINTED_AT'] = '2026-10-05T19:09:59Z'
    token = Time.stub(:now, Time.utc(2026, 10, 5, 20, 0, 0)) do
      Sigma.stub(:token_provider_result, PROVIDER) { Sigma.auth_token }
    end
    assert_equal 'browser-refreshed-token', token
  end

  def test_plugin_local_ruby_helpers_use_shared_client
    %w[
      post-and-readback.rb
      put-layout.rb
      validate-sigma-formula.rb
    ].each do |filename|
      source = File.read(File.join(__dir__, filename))
      assert_includes source, 'Sigma.request(', "#{filename} must delegate requests"
      refute_includes source, "req['Authorization']", "#{filename} must not attach a static bearer"
      refute_includes source, "ENV.fetch('SIGMA_API_TOKEN')", "#{filename} must not require a static bearer"
    end

    scout = File.read(File.join(__dir__, 'scout-validate-and-persist.rb'))
    assert_includes scout, 'validate-sigma-formula.rb'
  end
end
