# Warehouse-specific SQL transforms for Sigma migration skills.
#
# Usage:
#   require_relative 'warehouse_transforms'
#
#   warehouse = WarehouseTransforms.detect(sigma_base, token, connection_id)
#   clean_sql  = WarehouseTransforms.apply(raw_sql, warehouse)
#
# Warehouses: bigquery | snowflake | databricks | redshift | postgres | mysql | athena | unknown

require 'net/http'
require 'json'
require 'uri'

module WarehouseTransforms
  SIGMA_TYPE_MAP = {
    "bigquery"   => "bigquery",
    "snowflake"  => "snowflake",
    "databricks" => "databricks",
    "redshift"   => "redshift",
    "postgres"   => "postgres",
    "postgresql" => "postgres",
    "mysql"      => "mysql",
    "athena"     => "athena",
  }.freeze

  def self.detect(sigma_base, token, connection_id)
    return "unknown" unless sigma_base && token && connection_id
    uri  = URI("#{sigma_base.chomp('/')}/v2/connections/#{connection_id}")
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl      = uri.scheme == "https"
    http.open_timeout = 8
    http.read_timeout = 8
    req  = Net::HTTP::Get.new(uri.path, "Authorization" => "Bearer #{token}", "Accept" => "application/json")
    resp = http.request(req)
    data = JSON.parse(resp.body)
    raw  = (data["type"] || data["connectionType"] || "").downcase
    SIGMA_TYPE_MAP[raw] || "unknown"
  rescue StandardError
    "unknown"
  end

  def self.apply(sql, warehouse)
    return sql if sql.nil? || sql.empty? || warehouse == "unknown"

    case warehouse
    when "bigquery"
      # ARRAY_AGG(x [IGNORE NULLS]) → array_to_string(ARRAY_AGG(x [IGNORE NULLS]), ', ')
      sql = sql.gsub(/\bARRAY_AGG\s*\([^)]+(?:\s+IGNORE\s+NULLS)?\)(?:\s+IGNORE\s+NULLS)?/i) do |m|
        m =~ /array_to_string/i ? m : "array_to_string(#{m}, ', ')"
      end

    when "snowflake"
      sql = sql.gsub(/\bARRAY_AGG\s*\(([^)]+)\)/i) { "LISTAGG(#{$1}, ', ')" }

    when "databricks"
      sql = sql.gsub(/\bcollect_list\s*\(([^)]+)\)/i) { "array_join(collect_list(#{$1}), ', ')" }

    when "redshift", "postgres"
      sql = sql.gsub(/\bARRAY_AGG\s*\(([^)]+)\)/i) { "STRING_AGG(CAST(#{$1} AS VARCHAR), ', ')" }

    when "athena"
      sql = sql.gsub(/\bARRAY_AGG\s*\(([^)]+)\)/i) { "array_join(array_agg(#{$1}), ', ')" }
    end

    sql
  end
end
