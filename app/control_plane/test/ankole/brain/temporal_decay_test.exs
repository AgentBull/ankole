defmodule Ankole.Brain.TemporalDecayTest do
  use ExUnit.Case, async: true

  alias Ankole.Brain.TemporalDecay

  test "is one half at the half-life and scales scores multiplicatively" do
    assert_in_delta TemporalDecay.multiplier(30, 30), 0.5, 1.0e-12
    assert_in_delta TemporalDecay.apply(0.8, 30, 30), 0.4, 1.0e-12
  end

  test "clamps future ages and disables decay at a nonpositive half-life" do
    assert TemporalDecay.multiplier(-10, 30) == 1.0
    assert TemporalDecay.multiplier(10, 0) == 1.0
    assert TemporalDecay.multiplier(10, -1) == 1.0
  end
end
