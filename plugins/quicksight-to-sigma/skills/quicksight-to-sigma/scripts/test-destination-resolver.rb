#!/usr/bin/env ruby
# frozen_string_literal: true

require 'minitest/autorun'
require_relative 'lib/destination_resolver'

class DestinationResolverTest < Minitest::Test
  class FakeSigma
    attr_reader :requests, :lists

    def initialize(member:, member_files: [], global_files: [])
      @member = member
      @member_files = member_files
      @global_files = global_files
      @requests = []
      @lists = []
    end

    def request(method, path)
      @requests << [method, path]
      return { 'userId' => 'member-1' } if path == '/v2/whoami'
      return @member if path == '/v2/members/member-1'

      raise "unexpected request: #{method} #{path}"
    end

    def list_entries(path)
      @lists << path
      return @member_files if path == '/v2/members/member-1/files'
      return @global_files if path == '/v2/files?typeFilters=folder'

      raise "unexpected list: #{path}"
    end
  end

  def test_uses_documented_member_home_folder_id
    api = FakeSigma.new(member: { 'homeFolderId' => 'home-folder-id' })

    assert_equal 'home-folder-id', DestinationResolver.my_documents_id(api)
    assert_equal [[:get, '/v2/whoami'], [:get, '/v2/members/member-1']], api.requests
    assert_empty api.lists
  end

  def test_legacy_listing_uses_folder_id_not_parent_id
    api = FakeSigma.new(
      member: {},
      member_files: [{
        'id' => 'my-documents-id',
        'parentId' => 'wrong-parent-id',
        'name' => 'My Documents'
      }]
    )

    assert_equal 'my-documents-id', DestinationResolver.my_documents_id(api)
  end

  def test_orchestrator_resolves_the_accepted_default
    source = File.read(
      File.expand_path('migrate-quicksight.rb', __dir__), encoding: 'UTF-8'
    )

    assert_includes source, 'opts[:folder] = DestinationResolver.my_documents_id'
    assert_match(/folderId default: resolved caller's My Documents/, source)
  end
end
