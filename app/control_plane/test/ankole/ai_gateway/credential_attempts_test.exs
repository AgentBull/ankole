defmodule Ankole.AIGateway.CredentialAttemptsTest do
  use ExUnit.Case, async: true

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
      {:universal_ai_request_failed,
       %{"code" => "upstream_read_failed", "stage" => "hosted_responses"}}

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
