defmodule Ankole.Ecto.JSONPayloadTest do
  use ExUnit.Case, async: true

  alias Ankole.Ecto.JSONPayload

  test "plain projections persist the same enum and primitive values sent on the wire" do
    result = %{
      status: :inserted,
      facts: [%{claim_type: :fact}],
      flags: [true, false, nil],
      revision: 2
    }

    plain = Ankole.JSON.plain(result)
    assert plain == Ankole.JSON.decode!(Ankole.JSON.encode!(result))
    assert {:ok, ^plain} = JSONPayload.normalize_map(plain)
    assert {:error, :unsupported_atom} = JSONPayload.normalize_map(result)
  end

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
