#!/usr/bin/env ruby
# sigma_format must emit the field-proven Sigma number-format shape
# ({kind:"number", decimalPlaces:N}), never an unverified d3 formatString.
#   ruby test/test-sigma-format.rb

require_relative '../scripts/lib/domo_sigma_util'
include DomoSigma

f = sigma_format({'type'=>'NUMBER','precision'=>0}, 'Days Using')
raise "got #{f.inspect}" unless f == {'kind'=>'number','decimalPlaces'=>0}
f2 = sigma_format({'type'=>'DECIMAL','decimals'=>2}, 'Years in Domo')
raise "got #{f2.inspect}" unless f2['decimalPlaces']==2
raise 'formatString leaked' if [f,f2].any? { |x| x.key?('formatString') }
puts 'test-sigma-format: PASS'
