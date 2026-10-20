defmodule Ankole.ModelIntegerIDTest do
  use ExUnit.Case, async: true

  alias Ankole.ModelIntegerID

  test "matches the Worker canonical integer ID contract" do
    vectors =
      __DIR__
      |> Path.join("../../../kernel/proto/ankole/runtime_fabric/v1/model_integer_id_vectors.json")
      |> File.read!()
      |> Ankole.JSON.decode!()

    for value <- vectors["valid"] ++ vectors["valid_wire"] do
      assert {:ok, id} = ModelIntegerID.parse(value)
      assert id >= 1000 and id <= 9_007_199_254_740_991
    end

    for value <- vectors["invalid"] ++ vectors["invalid_wire"] do
      assert ModelIntegerID.parse(value) == :error
    end
  end
end
