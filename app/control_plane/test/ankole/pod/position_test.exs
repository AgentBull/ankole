defmodule Ankole.Pod.PositionTest do
  use ExUnit.Case, async: true
  use ExUnitProperties
  alias Ankole.Pod.Position

  @alphabet ~c"0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz"

  defp key do
    gen all(
          body <- StreamData.list_of(StreamData.member_of(@alphabet), max_length: 6),
          last <- StreamData.member_of(tl(@alphabet))
        ) do
      List.to_string(body ++ [last])
    end
  end

  property "a key falls strictly between two ordered keys and never ends with the lowest digit" do
    check all(a <- key(), b <- key(), a != b) do
      [lower, upper] = Enum.sort([a, b])
      assert {:ok, middle} = Position.between(lower, upper)
      assert lower < middle and middle < upper
      refute String.ends_with?(middle, "0")
    end
  end

  property "open ends produce a first and a last key" do
    check all(a <- key()) do
      assert {:ok, first} = Position.between(nil, a)
      assert {:ok, last} = Position.between(a, nil)
      assert first < a and a < last
    end
  end

  test "repeated appends and inserts at one place grow slowly" do
    appended =
      Enum.reduce(1..1000, "U", fn _, last ->
        {:ok, next} = Position.between(last, nil)
        assert next > last
        next
      end)

    assert byte_size(appended) < 40

    {lower, upper} =
      Enum.reduce(1..100, {"U", "V"}, fn _, {lower, upper} ->
        {:ok, middle} = Position.between(lower, upper)
        {lower, middle}
      end)

    assert lower < upper and byte_size(upper) < 120
  end

  test "keys it cannot order are rejected" do
    assert :error = Position.between("V", "V")
    assert :error = Position.between("V", "U")
    assert :error = Position.between("A0", nil)
    assert :error = Position.between("019a-uuid", nil)
  end

  test "a renumbered list has ascending keys that accept later inserts" do
    for count <- [1, 2, 61, 62, 63, 500] do
      keys = Position.sequence(count)
      assert length(keys) == count
      assert keys == Enum.sort(keys)
      assert keys == Enum.uniq(keys)
      assert Enum.all?(keys, &match?({:ok, _}, Position.between(&1, nil)))
    end
  end
end
