defmodule Ankole.AIGateway.RateLimitIntegrationTest do
  alias Ankole.AIGateway.FailureResponse
  use Ankole.AIGatewayCase

  alias Ankole.AIGateway.CredentialPool
  alias Ankole.AIGateway.ResponsesPreparation
  alias Ankole.AIGateway.ResponseStream

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
    # Allow 1ms each for the persisted deadline and remaining-wait truncation.
    assert second_at - first_at >= 1_998
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
    assert FailureResponse.project(reason).error["type"] == "rate_limit_error"
    assert {:ok, retry_at, _} = DateTime.from_iso8601(details["retry_at"])
    assert DateTime.diff(retry_at, DateTime.utc_now(), :millisecond) in 0..1_000

    assert {:error, {:credential_pool_exhausted, _} = local_reason} =
             AIGateway.create_response(agent.uid, request)

    assert FailureResponse.project(local_reason).error["message"] == "Please wait."

    assert FailureResponse.project(local_reason).error["details_json"]["provider_error_code"] ==
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
      projection = FailureResponse.project(reason)
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

    assert FailureResponse.project(reason).error["details_json"]["provider_error_code"] ==
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

  test "a provider diagnostic followed by close retains quota health without replay" do
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
             "type" => "error",
             "error" => %{
               "code" => "insufficient_quota",
               "type" => "rate_limit_error",
               "status" => 429,
               "message" => "Provider quota is exhausted."
             }
           }
         ], false}
      end)

    assert {:ok, stream, _meta} = AIGateway.open_sse_stream(agent.uid, request)
    events = collect_events(stream)
    assert Enum.map(events, & &1["type"]) == ["response.created", "response.failed"]
    error = List.last(events)["response"]["error"]
    assert error["code"] == "insufficient_quota"
    assert error["message"] == "Provider quota is exhausted."
    assert error["provider_error_code"] == "insufficient_quota"
    assert error["provider_error_type"] == "rate_limit_error"
    assert error["provider_status"] == 429
    assert_receive :attempt
    refute_receive :attempt

    [provider_id, _model] = String.split(request["model"], "/", parts: 2)
    assert {:ok, config} = ProviderConfigs.get_provider(provider_id)
    [credential] = config["credential_pool"]["entries"]
    assert credential["status"] == "exhausted"
    assert credential["last_error_code"] == "insufficient_quota"
    assert {:ok, retry_at, _} = DateTime.from_iso8601(credential["retry_at"])
    assert DateTime.diff(retry_at, DateTime.utc_now(), :second) in 3_598..3_600
  end

  for {error_type, status} <- [{"overloaded_error", 529}, {"rate_limit_error", 429}] do
    @tag claude_error: {error_type, status}
    test "a slow consumer receives the full Claude #{error_type} terminal", context do
      {error_type, status} = context.claude_error
      test_pid = self()

      {agent, request} =
        provider(
          fn _upstream ->
            send(test_pid, :attempt)

            {:sse, 200, Enum.take(anthropic_stream_events(), 3) ++ [claude_error(error_type)],
             false}
          end,
          "claude"
        )

      assert {:ok, stream, _meta} = AIGateway.open_sse_stream(agent.uid, request)
      monitor = Process.monitor(stream.pid)
      stream_ref = stream.ref
      events = collect_through_delta(stream, [])

      refute_receive {:ai_gateway_response_stream, ^stream_ref, :events, _, {:terminal, _}}
      refute_receive {:DOWN, ^monitor, :process, _, _}, 1_500

      assert {:ok, [terminal], {:terminal, _outcome}} = ResponseStream.next(stream, 5_000)
      assert terminal["type"] == "response.failed"

      [provider_id, _model] = String.split(request["model"], "/", parts: 2)
      assert {:ok, config} = ProviderConfigs.get_provider(provider_id)
      [credential] = config["credential_pool"]["entries"]
      assert credential["status"] == if(status == 429, do: "exhausted", else: "ok")

      assert Enum.map(events, & &1["type"]) == [
               "response.created",
               "response.output_item.added",
               "response.content_part.added",
               "response.output_text.delta"
             ]

      assert %{
               "code" => "provider_status_rejected",
               "failure_kind" => "provider_response",
               "provider_error_type" => ^error_type,
               "provider_status" => ^status,
               "retryable" => true
             } = terminal["response"]["error"]

      assert_receive :attempt
      refute_receive :attempt
      assert_receive {:DOWN, ^monitor, :process, _, :normal}, 2_000
    end
  end

  test "Claude credential retries preserve read credit before the first provider event" do
    test_pid = self()
    counter = start_supervised!({Agent, fn -> 0 end})

    {agent, request} =
      provider(
        fn upstream ->
          attempt = Agent.get_and_update(counter, &{&1, &1 + 1})
          send(test_pid, {:attempt, upstream})

          events =
            if attempt == 0,
              do: [claude_error("rate_limit_error")],
              else: anthropic_stream_events()

          {:sse, 200, events, false}
        end,
        "claude",
        [
          %{"id" => "first", "label" => "First", "api_key" => "sk-first"},
          %{"id" => "second", "label" => "Second", "api_key" => "sk-second"}
        ]
      )

    assert {:ok, stream, _meta} = AIGateway.open_sse_stream(agent.uid, request)
    stream_ref = stream.ref
    assert_receive {:attempt, first}, 5_000
    assert_receive {:attempt, second}, 5_000
    refute_receive {:ai_gateway_response_stream, ^stream_ref, :events, _, _}

    events = collect_events(stream)
    assert List.last(events)["type"] == "response.completed"
    assert Enum.count(events, &(&1["type"] == "response.created")) == 1
    refute Enum.any?(events, &(&1["type"] == "response.failed"))

    refute_receive {:attempt, _}
    assert first.body == second.body

    assert first.headers["x-api-key"] != second.headers["x-api-key"]
  end

  test "an early Claude overload returns its retryable terminal without replay" do
    test_pid = self()

    {agent, request} =
      provider(
        fn _upstream ->
          send(test_pid, :attempt)
          {:sse, 200, [claude_error("overloaded_error")], false}
        end,
        "claude"
      )

    assert {:ok, stream, _meta} = AIGateway.open_sse_stream(agent.uid, request)
    events = collect_events(stream)
    assert [terminal] = events
    assert terminal["type"] == "response.failed"

    assert %{
             "provider_status" => 529,
             "provider_error_type" => "overloaded_error",
             "retryable" => true
           } = terminal["response"]["error"]

    assert_receive :attempt
    refute_receive :attempt
  end

  for action <- [:cancel, :disconnect] do
    @tag consumer_action: action
    test "a pending Claude terminal is released on consumer #{action}", context do
      consumer =
        spawn(fn ->
          receive do
            :stop -> :ok
          end
        end)

      on_exit(fn -> Process.exit(consumer, :kill) end)

      {agent, request} =
        provider(
          fn _upstream ->
            {:sse, 200,
             Enum.take(anthropic_stream_events(), 3) ++ [claude_error("overloaded_error")], false}
          end,
          "claude"
        )

      assert {:ok, stream, _meta} =
               AIGateway.open_sse_stream(agent.uid, request, receiver: consumer)

      monitor = Process.monitor(stream.pid)
      assert :ok = ResponseStream.read(stream, 4)
      assert Ankole.Eventually.eventually(fn -> :sys.get_state(stream.pid).provider_output? end)
      refute :sys.get_state(stream.pid).semantic.terminal?

      case context.consumer_action do
        :cancel -> assert :ok = ResponseStream.cancel(stream, "consumer_cancelled")
        :disconnect -> send(consumer, :stop)
      end

      assert_receive {:DOWN, ^monitor, :process, _, :normal}, 1_000
    end
  end

  test "a credited Claude terminal remains readable after the owner exits" do
    {agent, request} =
      provider(
        fn _upstream ->
          {:sse, 200,
           Enum.take(anthropic_stream_events(), 3) ++ [claude_error("overloaded_error")], false}
        end,
        "claude"
      )

    assert {:ok, stream, _meta} = AIGateway.open_sse_stream(agent.uid, request)
    monitor = Process.monitor(stream.pid)
    assert :ok = ResponseStream.read(stream, 5)
    assert_receive {:DOWN, ^monitor, :process, _, :normal}, 2_000

    events = collect_events(stream)

    assert Enum.map(events, & &1["type"]) == [
             "response.created",
             "response.output_item.added",
             "response.content_part.added",
             "response.output_text.delta",
             "response.failed"
           ]

    assert %{
             "provider_status" => 529,
             "provider_error_type" => "overloaded_error",
             "failure_kind" => "provider_response"
           } = List.last(events)["response"]["error"]
  end

  test "the synchronous collector keeps a Claude error after text output" do
    {agent, request} =
      provider(
        fn _upstream ->
          {:sse, 200,
           Enum.take(anthropic_stream_events(), 3) ++ [claude_error("rate_limit_error")], false}
        end,
        "claude"
      )

    assert {:ok, %{spec: spec}} =
             ResponsesPreparation.prepare(agent.uid, request, stream?: true)

    assert {:ok, %{terminal_response: response}, _meta} =
             ResponseStream.collect(agent.uid, request, spec)

    assert response["status"] == "failed"

    assert %{
             "provider_status" => 429,
             "provider_error_type" => "rate_limit_error",
             "failure_kind" => "provider_response"
           } = response["error"]
  end

  defp collect_through_delta(stream, events) do
    assert {:ok, batch, :continue} = ResponseStream.next(stream, 5_000)
    events = events ++ batch

    if Enum.any?(batch, &(&1["type"] == "response.output_text.delta")),
      do: events,
      else: collect_through_delta(stream, events)
  end

  defp claude_error(type),
    do: %{"type" => "error", "error" => %{"type" => type, "message" => "Anthropic #{type}"}}

  defp collect_events(stream) do
    assert {:ok, events, status} = ResponseStream.next(stream, 5_000)

    case status do
      :continue -> events ++ collect_events(stream)
      {:terminal, _outcome} -> events
    end
  end

  defp provider(
         handler,
         kind \\ "openai",
         entries \\ [%{"id" => "only", "label" => "Only", "api_key" => "sk-test"}]
       ) do
    %{principal: agent} = agent_fixture()
    id = "rate-limit-#{System.unique_integer([:positive])}"
    base_url = start_upstream_server(handler)

    assert {:ok, _} =
             ProviderConfigs.create_provider(%{
               provider_id: id,
               provider_kind: kind,
               base_url: base_url,
               credential_pool: %{"entries" => entries},
               connection_options: %{"transport" => %{}}
             })

    model = if kind == "claude", do: "claude-sonnet-4-5", else: "gpt-5.5"
    {agent, %{"model" => "#{id}/#{model}", "input" => "hello"}}
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
