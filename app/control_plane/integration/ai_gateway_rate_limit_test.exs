defmodule Ankole.AIGateway.RateLimitIntegrationTest do
  use Ankole.AIGatewayCase

  alias Ankole.AIGateway.CredentialPool
  alias Ankole.AIGateway.FailureDiagnostics

  setup do
    :ok = CredentialPool.reset_for_test()
    :ok
  end

  test "a single credential recovers through the native HTTP path after Retry-After" do
    test_pid = self()
    counter = start_supervised!({Agent, fn -> 0 end})

    {agent, request} =
      provider(fn upstream ->
        attempt = Agent.get_and_update(counter, &{&1, &1 + 1})
        send(test_pid, {:attempt, System.monotonic_time(:millisecond), upstream})

        if attempt == 0,
          do: limited("RequestBurstTooFast", [{"retry-after", "2"}]),
          else: {:json, 200, completed()}
      end)

    assert {:ok, %{body: %{"id" => "resp_recovered"}}} =
             AIGateway.create_response(agent.uid, request)

    assert_receive {:attempt, first_at, first}
    assert_receive {:attempt, second_at, second}
    assert second_at - first_at >= 2_000
    assert first.body == second.body
    assert first.headers["authorization"] == second.headers["authorization"]
    refute_receive {:attempt, _, _}
  end

  test "an unknown 429 retries once and later callers retain its cause during the short cooldown" do
    test_pid = self()

    {agent, request} =
      provider(fn _upstream ->
        send(test_pid, :attempt)
        limited("NewProviderThrottleCode", [])
      end)

    assert {:error, {:credential_pool_exhausted, details} = reason} =
             AIGateway.create_response(agent.uid, request)

    assert_receive :attempt
    assert_receive :attempt
    refute_receive :attempt
    assert details["upstream_error"]["code"] == "NewProviderThrottleCode"
    assert FailureDiagnostics.project(reason).error["type"] == "rate_limit_error"
    assert {:ok, retry_at, _} = DateTime.from_iso8601(details["retry_at"])
    assert DateTime.diff(retry_at, DateTime.utc_now(), :millisecond) in 0..1_000

    assert {:error, {:credential_pool_exhausted, _} = local_reason} =
             AIGateway.create_response(agent.uid, request)

    assert FailureDiagnostics.project(local_reason).error["message"] == "Please wait."

    assert FailureDiagnostics.project(local_reason).error["details_json"]["provider_error_code"] ==
             "NewProviderThrottleCode"

    refute_receive :attempt
  end

  test "long Retry-After and explicit quota failures return recovery times without early retry" do
    for {code, headers, seconds, type} <- [
          {"rate_limit_exceeded", [{"retry-after", "60"}], 60, "rate_limit_error"},
          {"insufficient_quota", [], 3_600, "usage_limit_reached"}
        ] do
      test_pid = self()

      {agent, request} =
        provider(fn _upstream ->
          send(test_pid, :attempt)
          limited(code, headers)
        end)

      assert {:error, {:credential_pool_exhausted, details} = reason} =
               AIGateway.create_response(agent.uid, request)

      assert_receive :attempt
      refute_receive :attempt
      assert {:ok, retry_at, _} = DateTime.from_iso8601(details["retry_at"])
      assert DateTime.diff(retry_at, DateTime.utc_now(), :second) in (seconds - 2)..seconds
      projection = FailureDiagnostics.project(reason)
      assert projection.error["type"] == type
      assert projection.error["details_json"]["provider_error_code"] == code
    end
  end

  test "streaming keeps the retry bound and upstream error through the native path" do
    test_pid = self()

    {agent, request} =
      provider(fn _upstream ->
        send(test_pid, :attempt)
        limited("RequestBurstTooFast", [{"retry-after", "0"}])
      end)

    assert {:error, {:credential_pool_exhausted, _} = reason} =
             AIGateway.open_sse_stream(agent.uid, Map.put(request, "stream", true))

    assert_receive :attempt
    assert_receive :attempt
    refute_receive :attempt

    assert FailureDiagnostics.project(reason).error["details_json"]["provider_error_code"] ==
             "RequestBurstTooFast"
  end

  test "a rate limit after the first provider event never replays the request" do
    test_pid = self()

    {agent, request} =
      provider(fn _upstream ->
        send(test_pid, :attempt)

        {:sse, 200,
         [
           %{
             "type" => "response.created",
             "response" => Map.put(completed(), "status", "in_progress")
           },
           %{
             "type" => "response.failed",
             "response" =>
               Map.merge(completed(), %{
                 "status" => "failed",
                 "error" => %{
                   "code" => "rate_limit_exceeded",
                   "type" => "rate_limit_error",
                   "message" => "Please wait."
                 }
               })
           }
         ], false}
      end)

    assert {:ok, stream, _meta} =
             AIGateway.open_sse_stream(agent.uid, Map.put(request, "stream", true))

    events = collect_events(stream)
    assert Enum.any?(events, &(&1["type"] == "response.created"))
    terminal = Enum.find(events, &(&1["type"] == "response.failed"))
    assert terminal["response"]["error"]["code"] == "rate_limit_exceeded"
    assert_receive :attempt
    refute_receive :attempt
  end

  defp collect_events(stream) do
    :ok = AIGateway.read_response_stream(stream, 1)

    receive do
      {:ai_gateway_response_stream, ref, :events, events, :continue} when ref == stream.ref ->
        events ++ collect_events(stream)

      {:ai_gateway_response_stream, ref, :events, events, {:terminal, _outcome}}
      when ref == stream.ref ->
        events
    after
      5_000 -> flunk("The response stream did not finish.")
    end
  end

  defp provider(handler) do
    %{principal: agent} = agent_fixture()
    id = "rate-limit-#{System.unique_integer([:positive])}"
    base_url = start_upstream_server(handler)

    assert {:ok, _} =
             ProviderConfigs.create_provider(%{
               provider_id: id,
               provider_kind: "openai",
               base_url: base_url,
               credential_pool: %{
                 "entries" => [%{"id" => "only", "label" => "Only", "api_key" => "sk-test"}]
               },
               connection_options: %{"transport" => %{"http_versions" => ["h1"]}}
             })

    {agent, %{"model" => "#{id}/gpt-5.5", "input" => "hello"}}
  end

  defp limited(code, headers),
    do:
      {:json, 429, headers,
       %{"error" => %{"code" => code, "type" => "rate_limit_error", "message" => "Please wait."}}}

  defp completed,
    do: %{
      "id" => "resp_recovered",
      "object" => "response",
      "status" => "completed",
      "output" => [],
      "usage" => %{}
    }
end
