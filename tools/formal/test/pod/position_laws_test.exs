defmodule Ankole.Formal.Pod.PositionLawsTest do
  use ExUnit.Case, async: true
  use Lynx.Case

  alias Ankole.Pod.Position

  laws "Position basic contracts" do
    law open_bounds_default,
      expects: Position.between(nil, nil) == {:ok, "V"},
      proof: ~LEAN"""
      decide
      """
  end
end
