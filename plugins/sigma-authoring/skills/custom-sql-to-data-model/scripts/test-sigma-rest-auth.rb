#!/usr/bin/env ruby
# frozen_string_literal: true

require 'minitest/autorun'
require 'net/http'

ENV['SIGMA_BASE_URL'] = 'https://api.sigmacomputing.com'
ENV['SIGMA_API_TOKEN'] = 'caller-token'
ENV.delete('SIGMA_CLIENT_ID')
ENV.delete('SIGMA_CLIENT_SECRET')

require_relative 'lib/sigma_rest'

class SigmaRestDualAuthTest < Minitest::Test
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
    ENV['SIGMA_BASE_URL'] = 'https://api.sigmacomputing.com'
    ENV['SIGMA_API_TOKEN'] = 'caller-token'
    ENV.delete('SIGMA_CLIENT_ID')
    ENV.delete('SIGMA_CLIENT_SECRET')
    ENV.delete('SIGMA_TOKEN_MINTED_AT')
    ENV.delete('SIGMA_AUTH_METHOD')
    Sigma.instance_variable_set(:@token_override, nil)
    Sigma.instance_variable_set(:@refresh_inflight, false)
  end

  def test_unknown_age_caller_token_is_preserved_until_401_then_refreshed
    unauthorized = response(Net::HTTPUnauthorized, '401', 'Unauthorized', '{"code":"unauthorized"}')
    success = response(Net::HTTPOK, '200', 'OK', '{"ok":true}')
    http = SequenceHTTP.new(unauthorized, success)
    provider = {
      'SIGMA_API_TOKEN' => 'browser-refreshed-token',
      'SIGMA_TOKEN_MINTED_AT' => '2026-10-05T20:00:00Z',
      'SIGMA_AUTH_METHOD' => 'browser'
    }

    result = Time.stub(:now, Time.utc(2026, 10, 5, 20, 0, 0)) do
      Sigma.stub(:token_provider_result, provider) do
        Sigma.request(:get, '/v2/whoami', http: http)
      end
    end

    assert_equal({ 'ok' => true }, result)
    assert_equal(
      ['Bearer caller-token', 'Bearer browser-refreshed-token'],
      http.authorization
    )
    assert_equal 'browser', ENV['SIGMA_AUTH_METHOD']
    assert_equal '2026-10-05T20:00:00Z', ENV['SIGMA_TOKEN_MINTED_AT']
  end

  def test_known_50_minute_old_token_refreshes_before_request
    ENV['SIGMA_TOKEN_MINTED_AT'] = '2026-10-05T19:10:00Z'
    success = response(Net::HTTPOK, '200', 'OK', '{"ok":true}')
    http = SequenceHTTP.new(success)
    provider_calls = 0
    provider = lambda do
      provider_calls += 1
      {
        'SIGMA_API_TOKEN' => 'proactively-refreshed-token',
        'SIGMA_TOKEN_MINTED_AT' => '2026-10-05T20:00:00Z',
        'SIGMA_AUTH_METHOD' => 'browser'
      }
    end

    result = Time.stub(:now, Time.utc(2026, 10, 5, 20, 0, 0)) do
      Sigma.stub(:token_provider_result, provider) do
        Sigma.request(:get, '/v2/whoami', http: http)
      end
    end

    assert_equal({ 'ok' => true }, result)
    assert_equal 1, provider_calls
    assert_equal ['Bearer proactively-refreshed-token'], http.authorization
  end

  def test_known_token_younger_than_50_minutes_is_preserved
    ENV['SIGMA_TOKEN_MINTED_AT'] = '2026-10-05T19:10:01Z'
    success = response(Net::HTTPOK, '200', 'OK', '{"ok":true}')
    http = SequenceHTTP.new(success)
    unexpected_provider = -> { flunk 'provider should not run before 50 minutes' }

    result = Time.stub(:now, Time.utc(2026, 10, 5, 20, 0, 0)) do
      Sigma.stub(:token_provider_result, unexpected_provider) do
        Sigma.request(:get, '/v2/whoami', http: http)
      end
    end

    assert_equal({ 'ok' => true }, result)
    assert_equal ['Bearer caller-token'], http.authorization
  end

  def test_malformed_mint_age_preserves_caller_token
    ENV['SIGMA_TOKEN_MINTED_AT'] = 'not-a-timestamp'
    success = response(Net::HTTPOK, '200', 'OK', '{"ok":true}')
    http = SequenceHTTP.new(success)
    unexpected_provider = -> { flunk 'unknown token age must wait for a 401' }

    result = Sigma.stub(:token_provider_result, unexpected_provider) do
      Sigma.request(:get, '/v2/whoami', http: http)
    end

    assert_equal({ 'ok' => true }, result)
    assert_equal ['Bearer caller-token'], http.authorization
  end

  def test_missing_token_mints_through_provider
    ENV.delete('SIGMA_API_TOKEN')
    provider = {
      'SIGMA_API_TOKEN' => 'client-token',
      'SIGMA_TOKEN_MINTED_AT' => '2026-10-05T20:00:00Z',
      'SIGMA_AUTH_METHOD' => 'client-credentials'
    }

    token = Sigma.stub(:token_provider_result, provider) { Sigma.auth_token }

    assert_equal 'client-token', token
    assert_equal 'client-credentials', ENV['SIGMA_AUTH_METHOD']
  end
end
