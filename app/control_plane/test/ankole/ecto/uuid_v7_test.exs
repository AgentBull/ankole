defmodule Ankole.Ecto.UUIDv7Test do
  use ExUnit.Case, async: true

  @uuid_v7 ~r/\A[0-9a-f]{8}-[0-9a-f]{4}-7[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\z/

  test "autogenerate returns kernel-backed UUIDv7 strings" do
    assert Ankole.Ecto.UUIDv7.autogenerate() =~ @uuid_v7
  end

  test "stores and loads as normal PostgreSQL uuid values" do
    uuid = Ankole.Ecto.UUIDv7.autogenerate()

    assert {:ok, ^uuid} = Ankole.Ecto.UUIDv7.cast(uuid)
    assert {:ok, raw_uuid} = Ankole.Ecto.UUIDv7.dump(uuid)
    assert {:ok, ^uuid} = Ankole.Ecto.UUIDv7.load(raw_uuid)
  end
end
