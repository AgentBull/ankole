defmodule Ankole.FunctionRuntimeHelpers do
  @moduledoc false
  import ExUnit.Assertions
  alias Ankole.FunctionRuntime.{EndpointPool, HTTP}

  def saturate do
    {:ok, endpoint, lease} = EndpointPool.checkout()
    source = "export default {'GET /':()=>true}"
    digest = :crypto.hash(:sha256, source <> "\n[]") |> Base.encode16(case: :lower)

    assert {:ok, 204, _} =
             HTTP.at(
               endpoint,
               :put,
               "/v1/applet/code/" <> digest,
               %{source: source, env: %{}},
               5_000
             )

    {endpoint, lease, reserve(endpoint, digest, [])}
  end

  def release({endpoint, lease, ids}) do
    Enum.each(ids, fn id ->
      assert {:ok, 204, _} =
               HTTP.at(endpoint, :delete, "/v1/applet/invocations/" <> id, %{}, 5_000)
    end)

    EndpointPool.release(lease)
    # The single-replica pool cools a saturated endpoint briefly.
    Process.sleep(2_100)
  end

  defp reserve(endpoint, digest, ids) when length(ids) < 256 do
    id = Ash.UUIDv7.generate()

    query =
      URI.encode_query(%{
        run_id: id,
        tenant_id: Ankole.Repo.tenant_id!(),
        page_id: "capacity",
        revision: 1,
        sha256: digest,
        timeout_ms: 60_000,
        memory_mb: 64
      })

    case HTTP.at(endpoint, :get, "/v1/applet/invoke?" <> query, %{}, 5_000) do
      {:ok, 204, _} -> reserve(endpoint, digest, [id | ids])
      {:ok, 503, _} -> ids
      other -> flunk("Function runtime preflight failed: #{inspect(other)}")
    end
  end
end
