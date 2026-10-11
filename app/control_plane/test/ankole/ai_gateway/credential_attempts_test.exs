defmodule Ankole.AIGateway.CredentialAttemptsTest do
  use Ankole.AIGatewayCase

  alias Ankole.AIGateway.ProviderConfigs.Provider
  alias Ankole.AIGateway.CredentialAttempts

  test "prepare_stream returns the retry context and a native-only spec" do
    context = context()

    spec = %{
      api_resolver: :openai_responses,
      credential_attempt: context,
      hosted_credential_attempt: %{private: true},
      tool_loop: %{private: true}
    }

    assert {^context, %{api_resolver: :openai_responses}} =
             CredentialAttempts.prepare_stream(spec)
  end

  test "plan_retry returns its delay without sleeping" do
    test_pid = self()
    context = context()
    reason = %{"code" => "connect_timeout", "stage" => "connect"}

    opts = [
      credential_retry_base_ms: 100,
      credential_retry_jitter: &Function.identity/1,
      credential_retry_sleep: fn delay -> send(test_pid, {:slept, delay}) end
    ]

    assert {:retry, next_context, %{marker: :same_request}, 100} =
             CredentialAttempts.plan_retry(
               context,
               %{
                 marker: :same_request,
                 credential_attempt: :private,
                 hosted_credential_attempt: :private,
                 tool_loop: :private
               },
               reason,
               opts
             )

    assert next_context.route_retry_used?
    refute_receive {:slept, _delay}
    refute Map.has_key?(next_context, :delay_ms)

    assert {:stop, ^reason, ^next_context} =
             CredentialAttempts.plan_retry(
               next_context,
               %{marker: :same_request},
               reason,
               opts
             )
  end

  test "plan_retry does not opt hosted failures into credential recovery" do
    context = context()

    reason =
      %Ankole.AIGateway.ProviderFailure{
        kind: :other,
        code: "upstream_read_failed",
        stage: "hosted_responses"
      }

    assert {:stop, ^reason, ^context} =
             CredentialAttempts.plan_retry(context, %{marker: :same_request}, reason,
               credential_retry_jitter: &Function.identity/1
             )

    assert {:retry, _next_context, %{marker: :same_request}, 250} =
             CredentialAttempts.plan_retry(context, %{marker: :same_request}, reason,
               credential_retry_allow_hosted_failure: true,
               credential_retry_jitter: &Function.identity/1
             )
  end

  test "build_round removes all control-plane private keys" do
    build = fn runtime, request ->
      {:ok,
       %{
         marker: {runtime, request},
         credential_attempt: :nested,
         hosted_credential_attempt: :nested,
         tool_loop: :nested
       }}
    end

    context = context(build)

    assert {:ok, %{marker: {%{"provider_id" => "provider"}, %{"input" => "next"}}}, next} =
             CredentialAttempts.build_round(context, %{"input" => "next"})

    assert next.request == %{"input" => "next"}
    assert next.attempt_number == 0
    assert next.attempted_ids == MapSet.new()
    refute next.route_retry_used?
    refute next.refresh_used?
  end

  for scenario <- [:permanent, :retry_after, :reset_at, :no_header, :unavailable] do
    test "forced OAuth refresh failure preserves #{scenario} health and selection" do
      refresh_failure_scenario(unquote(scenario))
    end
  end

  test "forced OAuth refresh 429 retains the exhausted pool code and absolute retry clock" do
    refresh_failure_scenario(:reset_at, pool_size: 1)
  end

  defp refresh_failure_scenario(scenario, opts \\ []) do
    reset_at = DateTime.utc_now(:second) |> DateTime.add(90)
    test_pid = self()

    issuer =
      start_upstream_server(fn request ->
        send(test_pid, {:refresh_request, request.body["refresh_token"]})

        case scenario do
          :permanent ->
            {:json, 400, %{"error" => %{"code" => "refresh_token_invalidated"}}}

          :retry_after ->
            {:json, 429, [{"retry-after", "30"}], %{"error" => %{"code" => "rate_limit"}}}

          :reset_at ->
            {:json, 429,
             [{"x-codex-primary-reset-at", Integer.to_string(DateTime.to_unix(reset_at))}],
             %{"error" => %{"code" => "rate_limit"}}}

          :no_header ->
            {:json, 429, %{"error" => %{"code" => "rate_limit"}}}

          :unavailable ->
            {:json, 503, %{"error" => %{"code" => "unavailable"}}}
        end
      end)

    id = "refresh-contract-#{System.unique_integer([:positive])}"
    now = DateTime.utc_now(:second)

    token = fn label ->
      payload = %{"sub" => label, "exp" => DateTime.to_unix(DateTime.add(now, 3_600))}
      "e30." <> Base.url_encode64(Ankole.JSON.encode!(payload), padding: false) <> ".signature"
    end

    entries =
      for name <- Enum.take(["first", "second"], Keyword.get(opts, :pool_size, 2)) do
        %{
          "id" => name,
          "label" => name,
          "access_token" => token.(name),
          "refresh_token" => "#{name}-refresh",
          "id_token" => token.("identity-#{name}"),
          "account_id" => "#{name}-account",
          "auth_type" => "oauth",
          "last_refresh" => DateTime.to_iso8601(now)
        }
      end

    {:ok, provider} =
      ProviderConfigs.create_provider(%{
        provider_id: id,
        provider_kind: "chatgpt_subscription",
        connection_options: %{"auth_issuer" => issuer},
        credential_pool: %{"entries" => entries}
      })

    {:ok, selected} = ProviderConfigs.resolve_credential(provider)
    {:ok, connection} = ProviderConfigs.runtime_connection(provider, selected)
    first = selected["entry"]

    context = %{
      runtime: %{
        "provider" => provider,
        "provider_id" => id,
        "provider_kind" => "chatgpt_subscription",
        "credential_id" => "first",
        "credential_entry" => first,
        "connection_options" => connection
      },
      build: fn _, _ -> {:ok, %{marker: :next}} end,
      request: %{},
      attempt_number: 0,
      attempted_ids: MapSet.new(),
      route_retry_used?: false,
      refresh_used?: false
    }

    reason = %Ankole.AIGateway.ProviderFailure{
      kind: :status_rejected,
      provider_status: 401,
      provider_body: %{"error" => %{"code" => "token_expired"}},
      provider_headers: []
    }

    result =
      CredentialAttempts.plan_retry(context, %{}, reason,
        credential_retry_jitter: &Function.identity/1
      )

    assert_receive {:refresh_request, "first-refresh"}
    refute_receive {:refresh_request, "second-refresh"}
    stored = Repo.get!(Provider, provider.id).credential_pool["entries"] |> hd()

    if scenario == :unavailable do
      assert {:stop, {:chatgpt_refresh_transient, 503, _, "unavailable"}, ^context} = result
      refute stored["cooldown_until"]
    else
      if Keyword.get(opts, :pool_size, 2) == 1 do
        assert {:stop, {:credential_pool_exhausted, details}, next} = result
        assert details["upstream_error"] == %{"code" => "rate_limit"}
        assert {:ok, retry_at, _} = DateTime.from_iso8601(details["retry_at"])
        assert DateTime.compare(retry_at, reset_at) == :eq
        assert details["statuses"]["first"]["provider_status"] == 429
        assert next.runtime["credential_id"] == "first"
        assert next.attempted_ids == MapSet.new(["first"])
      else
        assert {:retry, next, %{marker: :next}, 250} = result
        assert next.runtime["credential_id"] == "second"
        assert next.attempted_ids == MapSet.new(["first"])
      end

      reason = stored["cooldown_reason"]

      if scenario == :permanent do
        assert reason["status"] == "dead"

        assert reason["error"] == %{
                 "last_error_code" => "nil",
                 "last_error_message" => "nil",
                 "last_error_reason" => "nil",
                 "provider_status" => 401
               }

        assert stored["cooldown_until"] == "9999-12-31T00:00:00Z"
      else
        assert reason["status"] == "exhausted"
        assert reason["error"]["last_error_code"] == "rate_limit"
        assert reason["error"]["provider_status"] == 429

        assert reason["error"]["last_error_reason"] == "chatgpt_refresh_failed"

        assert {:ok, until, _} = DateTime.from_iso8601(stored["cooldown_until"])

        case scenario do
          :reset_at -> assert DateTime.compare(until, reset_at) == :eq
          :retry_after -> assert DateTime.diff(until, now, :second) in 30..31
          :no_header -> assert DateTime.diff(until, now, :second) in 1..2
        end
      end
    end
  end

  defp context(build \\ fn _runtime, _request -> {:ok, %{}} end) do
    %{
      runtime: %{"provider_id" => "provider"},
      build: build,
      request: %{"input" => "first"},
      attempt_number: 0,
      attempted_ids: MapSet.new(),
      route_retry_used?: false,
      refresh_used?: false
    }
  end
end
