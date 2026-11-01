defmodule Ankole.FunctionRuntime.FixtureIsolationTest do
  use Ankole.DataCase, async: false

  alias Ankole.FunctionRuntime.{EndpointPool, HTTP}
  alias Ankole.FunctionRuntimeHelpers

  test "the overload fixture leaves the shared runtime available" do
    original = :sys.get_state(EndpointPool)
    {:ok, shared, lease} = EndpointPool.checkout()
    EndpointPool.release(lease)

    on_exit(fn ->
      restored = :sys.get_state(EndpointPool)
      assert restored.uri == original.uri
      assert restored.endpoints == original.endpoints
    end)

    active = FunctionRuntimeHelpers.saturate()

    try do
      assert {:ok, 200, body} =
               HTTP.at(
                 shared,
                 :post,
                 "/v1/applet/inspect",
                 %{source: "export default {'GET /':()=>true}", env: %{}},
                 5_000
               )

      assert %{"routes" => ["GET /"]} = Torque.decode!(body)
    after
      FunctionRuntimeHelpers.release(active)
    end
  end
end
