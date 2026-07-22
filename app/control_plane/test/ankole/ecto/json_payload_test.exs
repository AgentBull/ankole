defmodule Ankole.Ecto.JSONPayloadTest do
  use ExUnit.Case, async: true

  import Ecto.Changeset

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

  test "reports a normalized key collision as a changeset error" do
    changeset =
      {%{}, %{payload: :map}}
      |> cast(%{payload: %{:name => "atom", "name" => "string"}}, [:payload])
      |> JSONPayload.validate_map(:payload)

    refute changeset.valid?

    assert {"must be JSON-serializable object: duplicate normalized key name", []} =
             changeset.errors[:payload]
  end

  test "adds a changeset error instead of leaving Postgrex to raise" do
    changeset =
      {%{}, %{payload: :map}}
      |> cast(%{payload: %{"delta" => "before\0after"}}, [:payload])
      |> JSONPayload.validate_map(:payload)

    refute changeset.valid?

    assert {"must be JSON-serializable object: unsupported_nul_byte", []} =
             changeset.errors[:payload]
  end
end
