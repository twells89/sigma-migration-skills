require 'fileutils'
module Helper
  ROOT = File.expand_path('..', __dir__)
  def self.fixtures_dir(tier); File.join(ROOT, 'fixtures', tier); end
  def self.tmp_out
    d = "/tmp/domo-assessment-test-#{Process.pid}"
    FileUtils.mkdir_p(d); d
  end
  def self.assert(cond, msg)
    raise "FAIL: #{msg}" unless cond
    puts "  ok: #{msg}"
  end
end
