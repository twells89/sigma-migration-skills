require 'json'

module DomoSigma
  module WorkbookPostSanitizer
    module_function

    # Workbook builders retain visibleAsSource:false as an internal hint for
    # parity/census code. Sigma accepts that field only on data-model documents,
    # so strip it from a dedicated transport copy at the final POST boundary.
    def build(source_path, output_path)
      payload = JSON.parse(File.read(source_path))
      removed = 0
      strip = lambda do |node|
        case node
        when Hash
          removed += 1 if node.key?('visibleAsSource')
          node.delete('visibleAsSource')
          node.each_value { |value| strip.call(value) }
        when Array
          node.each { |value| strip.call(value) }
        end
      end
      strip.call(payload)
      raise 'workbook post payload still contains visibleAsSource' if
        JSON.generate(payload).include?('"visibleAsSource"')
      File.write(output_path, JSON.pretty_generate(payload) + "\n")
      { path: output_path, removed: removed }
    end
  end
end
