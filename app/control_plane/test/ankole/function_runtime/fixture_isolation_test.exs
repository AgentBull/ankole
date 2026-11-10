defmodule Ankole.FunctionRuntime.FixtureIsolationTest do
  use Ankole.DataCase, async: false

  alias Ankole.FunctionRuntime.EndpointPool
  alias Ankole.FunctionRuntimeHelpers

  test "Actions select the configured deployment while foreground calls retain theirs" do
    original = :sys.get_state(EndpointPool)
    {:ok, shared, lease} = EndpointPool.checkout()
    EndpointPool.release(lease)
    active = FunctionRuntimeHelpers.saturate()
    assert {_endpoint, _lease, [_reservation]} = active

    on_exit(fn ->
      :sys.replace_state(
        EndpointPool,
        &%{&1 | action_url: original.action_url, action_endpoints: original.action_endpoints}
      )
    end)

    try do
      {:ok, _} =
        Ankole.AppConfigure.put_global_by_key("pod.applet.action_runtime_url", shared.url)

      {:ok, isolated, route_lease} = EndpointPool.checkout()
      EndpointPool.release(route_lease)
      refute isolated.url == shared.url

      source = "export default {actions:{work:{handler:async()=>({deployment:'action'})}}}"
      sha = :crypto.hash(:sha256, source <> "\n[]") |> Base.encode16(case: :lower)
      package = %{tenant_id: Repo.tenant_id!(), source: source, env: %{}, sha256: sha}

      context = %{
        "actionKey" => "work",
        "applet" => %{"pageId" => Ash.UUIDv7.generate(), "revision" => 1}
      }

      {:ok, _, run_id} =
        Ankole.FunctionRuntime.AppletClient.start(package, context,
          lane: :action,
          timeout_ms: 5_000
        )

      assert_receive {:applet_runtime, ^run_id, :done,
                      {:completed, %{"status" => 200, "body" => %{"deployment" => "action"}}}},
                     10_000

      {:ok, still_isolated, route_lease} = EndpointPool.checkout()
      EndpointPool.release(route_lease)
      assert still_isolated.url == isolated.url
    after
      FunctionRuntimeHelpers.release(active)
    end
  end
end
