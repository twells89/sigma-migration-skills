#!/usr/bin/env ruby
# frozen_string_literal: true
#
# Shared destination picker for the *-to-sigma migration skills.
# Produces the folderId where a migrated data model + workbook should land.
# The SKILL drives the *asking*; this script just lists candidates and creates folders.
#
#   ruby pick-destination.rb list
#       -> JSON { "workspaces":[{id,name}], "folders":[{id,name,parentId,parentName}],
#                 "myDocuments": "<id>"|null }
#       Only folders the token can EDIT are returned. folderId in a DM/workbook POST
#       accepts either a workspace id (lands in the workspace root) or a folder id.
#
#   ruby pick-destination.rb create --name "<NAME>" [--parent "<workspace-or-folder-id>"]
#       -> JSON { "id", "name", "parentId" }
#       Creates a folder. --parent may be a workspace id, a folder id, or omitted
#       (then it lands in My Documents when resolvable, else org root).
#
# Env: SIGMA_BASE_URL + SIGMA_CLIENT_ID/SIGMA_CLIENT_SECRET (or SIGMA_API_TOKEN).
require 'json'
require_relative 'lib/sigma_rest'

def my_documents_id
  # Only resolvable for a user-bound token; service-account tokens return nil.
  uid = (Sigma.request(:get, '/v2/whoami') rescue {})&.dig('userId')
  return nil unless uid && !uid.to_s.empty?
  entries = ((Sigma.request(:get, "/v2/members/#{uid}/files?typeFilters=folder&limit=500") rescue {}) || {})['entries'] || []
  hit = entries.find { |e| e['name'] == 'My Documents' || e['path'] == 'My Documents' }
  hit && hit['id']
rescue StandardError
  nil
end

def cmd_list
  workspaces = (((Sigma.request(:get, '/v2/workspaces?limit=500') rescue {}) || {})['entries'] || [])
               .map { |w| { 'id' => w['workspaceId'] || w['id'], 'name' => w['name'] } }
  ws_name = workspaces.each_with_object({}) { |w, h| h[w['id']] = w['name'] }
  folders = (((Sigma.request(:get, '/v2/files?typeFilters=folder&limit=500') rescue {}) || {})['entries'] || [])
            .select { |f| f['permission'] == 'edit' }
            .map { |f| { 'id' => f['id'], 'name' => f['name'], 'parentId' => f['parentId'],
                         'parentName' => ws_name[f['parentId']] } }
  puts JSON.pretty_generate('workspaces' => workspaces, 'folders' => folders,
                            'myDocuments' => my_documents_id)
end

def cmd_create(argv)
  name = nil
  parent = nil
  i = 0
  while i < argv.length
    case argv[i]
    when '--name'   then name = argv[i + 1]; i += 2
    when '--parent' then parent = argv[i + 1]; i += 2
    else i += 1
    end
  end
  abort('pick-destination create: --name is required') if name.nil? || name.empty?
  parent ||= my_documents_id
  body = { 'type' => 'folder', 'name' => name }
  body['parentId'] = parent if parent && !parent.to_s.empty?
  res = Sigma.request(:post, '/v2/files', body: JSON.dump(body))
  puts JSON.pretty_generate('id' => res['id'], 'name' => res['name'], 'parentId' => res['parentId'])
end

case ARGV[0]
when 'list', nil then cmd_list
when 'create'    then cmd_create(ARGV[1..])
else abort("usage: pick-destination.rb [list | create --name NAME [--parent ID]]")
end
