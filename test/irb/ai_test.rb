# frozen_string_literal: true

require "test_helper"

class IRB::AITest < Test::Unit::TestCase
  test "VERSION" do
    assert { ::IRB::AI.const_defined?(:VERSION) }
  end

  # test "something useful" do
  #   assert_equal("expected", "actual")
  # end
end
