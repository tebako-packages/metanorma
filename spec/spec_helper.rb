# frozen_string_literal: true

SPEC_ROOT = __dir__

RSpec.configure do |config|
  config.disable_monkey_patching!
  config.expect_with(:rspec) { |expectations| expectations.syntax = :expect }
  config.order = :random
  Kernel.srand(config.seed)
end
