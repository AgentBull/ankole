defmodule Ankole.Ecto.JSONPayloadTest do
  use ExUnit.Case, async: true

  alias Ankole.Ecto.JSONPayload

  test "rejects NUL bytes before a nested JSONB value reaches PostgreSQL" do
    assert {:error, :unsupported_nul_byte} =
             JSONPayload.normalize_map(%{"events" => [%{"delta" => "before\0after"}]})
  end

  test "rejects NUL bytes in JSONB object keys" do
    assert {:error, :unsupported_nul_byte} =
             JSONPayload.normalize_map(%{"before\0after" => "value"})
  end

  test "rejects atom and string keys that normalize to the same JSON key" do
    assert {:error, {:duplicate_normalized_key, "name"}} =
             JSONPayload.normalize_map(%{:name => "atom", "name" => "string"})
  end

  test "resource JSON objects report normalized key collisions before persistence" do
    assert {:error, message: "must be JSON-serializable object: duplicate normalized key"} =
             Ankole.Ash.Types.JSONMap.cast_input(%{:name => "atom", "name" => "string"}, [])
  end

  test "resource JSON objects reject NUL bytes before Postgrex" do
    assert {:error, message: "must be JSON-serializable object: unsupported_nul_byte"} =
             Ankole.Ash.Types.JSONMap.cast_input(%{"delta" => "before\0after"}, [])
  end
end
