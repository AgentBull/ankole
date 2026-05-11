defmodule BullXGateway.AdapterErrorTest do
  use ExUnit.Case, async: true

  alias BullXGateway.AdapterError

  test "builds string-keyed adapter error maps" do
    error =
      AdapterError.new("payload", "invalid payload", %{
        field: :adapter,
        nested: %{reason: :bad_shape},
        list: [:one, %{"two" => :three}]
      })

    assert error == %{
             "kind" => "payload",
             "message" => "invalid payload",
             "details" => %{
               "field" => "adapter",
               "nested" => %{"reason" => "bad_shape"},
               "list" => ["one", %{"two" => "three"}]
             }
           }
  end

  test "omits nil optional values" do
    assert %{"present" => 1} =
             %{}
             |> AdapterError.put_present("missing", nil)
             |> AdapterError.put_present("present", 1)
  end
end
