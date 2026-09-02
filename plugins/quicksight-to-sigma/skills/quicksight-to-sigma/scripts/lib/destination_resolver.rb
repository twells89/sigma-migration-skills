# frozen_string_literal: true

# Resolves the authenticated user's Sigma "My Documents" inode ID.
#
# Sigma's documented source of truth is GET /v2/members/{memberId}.homeFolderId.
# The older file-list fallback remains for tenants that do not expose that
# field, but it must return the folder's id—not its parentId.
module DestinationResolver
  class Error < StandardError; end

  module_function

  def my_documents_id(api = Sigma)
    member_id = api.request(:get, '/v2/whoami')['userId']
    raise Error, '/v2/whoami returned no userId' if member_id.to_s.empty?

    member = api.request(:get, "/v2/members/#{member_id}")
    home_folder_id = member && member['homeFolderId']
    return home_folder_id unless home_folder_id.to_s.empty?

    member_entry = api.list_entries("/v2/members/#{member_id}/files")
                      .find { |entry| my_documents?(entry) }
    home_folder_id = member_entry && member_entry['id']
    return home_folder_id unless home_folder_id.to_s.empty?

    global_entry = api.list_entries('/v2/files?typeFilters=folder')
                      .find do |entry|
                        my_documents?(entry) && entry['ownerId'] == member_id
                      end
    home_folder_id = global_entry && global_entry['id']
    return home_folder_id unless home_folder_id.to_s.empty?

    raise Error, 'member record and file listings returned no My Documents folder id'
  end

  def my_documents?(entry)
    entry.is_a?(Hash) &&
      (entry['name'] == 'My Documents' || entry['path'] == 'My Documents')
  end
end
