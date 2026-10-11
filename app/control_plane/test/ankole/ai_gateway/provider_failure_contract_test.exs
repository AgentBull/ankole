defmodule Ankole.AIGateway.ProviderFailureContractTest do
  use Ankole.AIGatewayCase

  alias Ankole.AIGateway.CredentialPool
  alias Ankole.AIGateway.ProviderConfigs.Provider
  alias Ankole.AIGateway.CredentialAttempts
  alias Ankole.AIGateway.FailureDiagnostics
  alias Ankole.AIGateway.HostedTools.ImageGeneration
  alias Ankole.AIGateway.UniversalAIRequest

  @fixture Path.expand("../../fixtures/provider_failure_contract.json", __DIR__)
  @rows Ankole.JSON.decode!(File.read!(@fixture))

  for row <- @rows do
    test "native failure contract #{row["name"]}" do
      row = unquote(Macro.escape(row))
      snapshot = snapshot(row)
      assert snapshot["summary"] == row["summary"]
      assert snapshot == Map.fetch!(row, "expected")

      assert FailureDiagnostics.route_retryable?(reason(row)) ==
               (row["name"] in ["H2", "H3"] or row["summary"]["route_retryable"])
    end
  end

  test "credential failures preserve persisted health and retry actions" do
    for {name, seconds, code, action} <- [
          {"A1", 1, "rate_limit_exceeded", :short_retry},
          {"A2", 30, "rate_limit_exceeded", :pool_exhausted},
          {"A4", 3_600, "insufficient_quota", :pool_exhausted},
          {"A6", 300, "invalid_api_key", :original},
          {"A7", nil, nil, :challenge},
          {"A8", nil, nil, :original},
          {"A9", nil, nil, :original},
          {"A10", nil, nil, :route_retry},
          {"H1", nil, nil, :original}
        ] do
      :ok = CredentialPool.reset_for_test()
      {provider, entry, context} = credential_context()
      failure = @rows |> Enum.find(&(&1["name"] == name)) |> reason()

      result =
        CredentialAttempts.plan_retry(context, %{marker: :spec}, failure,
          credential_retry_jitter: &Function.identity/1
        )

      case action do
        :short_retry ->
          assert {:retry, next, %{marker: :spec}, delay} = result
          assert delay in 0..1_000

          assert {:stop, {:credential_pool_exhausted, _}, _} =
                   CredentialAttempts.plan_retry(next, %{marker: :spec}, failure,
                     credential_retry_jitter: &Function.identity/1
                   )

        :pool_exhausted ->
          assert {:stop, {:credential_pool_exhausted, _}, _} = result

        :original ->
          assert {:stop, ^failure, stopped} = result
          assert stopped.runtime == context.runtime

        :challenge ->
          assert {:stop, challenge, ^context} = result

          assert FailureDiagnostics.classify(challenge).error_code ==
                   "chatgpt_cloudflare_challenge"

        :route_retry ->
          assert {:retry, _, %{marker: :spec}, 500} = result
      end

      assert_health(provider, entry, seconds, code)
    end
  end

  test "terminal provider events keep excerpt out of credential health" do
    for {status, excerpt, seconds} <- [
          {429, %{"error" => %{"type" => "rate_limit_error"}}, 1},
          {429, %{"error" => %{"code" => "insufficient_quota"}}, 1},
          {529, %{"error" => %{"type" => "overloaded_error"}}, nil},
          {401, %{"error" => %{"type" => "authentication_error"}}, 300}
        ] do
      {provider, entry, context} = credential_context()

      event_error = %{
        "code" => "provider_status_rejected",
        "message" => "provider request failed",
        "details_json" => %{
          "provider_status" => status,
          "provider_body_excerpt" => Ankole.JSON.encode!(excerpt)
        }
      }

      :ok = CredentialAttempts.record_failure(context, event_reason(event_error))
      assert_health(provider, entry, seconds, if(seconds, do: "provider_status_rejected"))
    end
  end

  test "hosted rate limits are recorded only after the hosted retry boundary" do
    {provider, entry, context} = credential_context()
    failure = @rows |> Enum.find(&(&1["name"] == "H1")) |> reason()
    :ok = CredentialAttempts.record_failure(context, failure)
    assert_health(provider, entry, 1, "rate_limit_exceeded")
  end

  test "absolute cooldown failures preserve attributed provider errors" do
    recovery = DateTime.utc_now(:second) |> DateTime.add(90)

    for {name, expected_code} <- [{"A3", "rate_limit_exceeded"}, {"A5", "nil"}] do
      {provider, entry, context} = credential_context()
      row = Enum.find(@rows, &(&1["name"] == name))

      input =
        Map.put(row["input"], "provider_headers", [
          ["retry-after", "30"],
          ["x-codex-primary-reset-at", Integer.to_string(DateTime.to_unix(recovery))]
        ])

      failure = UniversalAIRequest.normalize_stream_error(input)

      assert {:stop, {:credential_pool_exhausted, _}, _} =
               CredentialAttempts.plan_retry(context, %{marker: :spec}, failure)

      assert_health(provider, entry, 90, expected_code)
      stored = hd(Repo.get!(Provider, provider.id).credential_pool["entries"])
      assert {:ok, until, _} = DateTime.from_iso8601(stored["cooldown_until"])
      assert DateTime.compare(until, recovery) == :eq
    end
  end

  defp credential_context do
    {:ok, provider} =
      ProviderConfigs.create_provider(%{
        provider_id: "failure-contract-#{System.unique_integer([:positive])}",
        provider_kind: "openai",
        credential_pool: %{"entries" => [%{"id" => "only", "api_key" => "sk-test"}]}
      })

    entry = hd(provider.credential_pool["entries"])

    context = %{
      runtime: %{
        "provider_id" => provider.provider_id,
        "provider_kind" => "openai",
        "provider" => provider,
        "credential_id" => entry["id"],
        "credential_entry" => entry
      },
      build: fn _, _ -> {:ok, %{marker: :spec}} end,
      request: %{},
      attempt_number: 1,
      attempted_ids: MapSet.new(),
      route_retry_used?: false,
      refresh_used?: false
    }

    {provider, entry, context}
  end

  defp assert_health(provider, entry, nil, nil) do
    stored = Repo.get!(Provider, provider.id).credential_pool["entries"] |> hd()
    assert stored["id"] == entry["id"]
    refute stored["cooldown_until"]
    refute stored["cooldown_reason"]
  end

  defp assert_health(provider, entry, seconds, code) do
    stored = Repo.get!(Provider, provider.id).credential_pool["entries"] |> hd()
    assert stored["id"] == entry["id"]
    assert {:ok, until, _} = DateTime.from_iso8601(stored["cooldown_until"])
    assert DateTime.diff(until, DateTime.utc_now(), :second) in (seconds - 2)..seconds
    assert stored["cooldown_reason"]["error"]["last_error_code"] == code
    assert stored["cooldown_reason"]["status"] == "exhausted"
  end

  defp event_reason(error), do: Ankole.AIGateway.ProviderFailure.from_event_error(error)

  def snapshot(row) do
    reason = reason(row)
    classification = FailureDiagnostics.classify(reason)
    projection = FailureDiagnostics.project(reason)
    image = ImageGeneration.normalize_execution_error(reason)

    context = %{
      runtime: %{"provider_id" => "contract-provider"},
      build: fn _runtime, _request -> {:ok, %{}} end,
      request: %{"input" => "contract"},
      attempt_number: 1,
      attempted_ids: MapSet.new(),
      route_retry_used?: false,
      refresh_used?: false
    }

    route? =
      case CredentialAttempts.plan_retry(context, %{marker: :spec}, reason,
             credential_retry_jitter: &Function.identity/1
           ) do
        {:retry, _context, %{marker: :spec}, _delay} -> true
        {:stop, _reason, _context} -> false
      end

    %{
      "summary" => %{
        "error_code" => classification.error_code,
        "failure_kind" => Atom.to_string(classification.failure_kind),
        "retryable" => Map.get(classification, :retryable, "absent"),
        "route_retryable" => route?,
        "project_status" => projection.status,
        "project_code" => projection.error["code"]
      },
      "classification" => classification,
      "projection" => Map.update!(projection, :headers, &Map.delete(&1, "retry-after")),
      "image_error" => Map.from_struct(image),
      "image_log_fields" => ImageGeneration.failure_log_fields(nil, reason)
    }
    |> Ankole.JSON.encode!()
    |> Ankole.JSON.decode!()
  end

  defp reason(%{"mode" => "native", "input" => input}),
    do: UniversalAIRequest.normalize_stream_error(input)

  defp reason(%{"mode" => "raw", "input" => input}), do: input
  defp reason(%{"mode" => "atom", "input" => "stream_aborted"}), do: :stream_aborted
  defp reason(%{"mode" => "pool", "input" => input}), do: {:credential_pool_exhausted, input}
end
