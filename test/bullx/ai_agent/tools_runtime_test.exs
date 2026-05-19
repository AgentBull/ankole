defmodule BullX.AIAgent.ToolsRuntimeTest do
  use ExUnit.Case, async: true

  alias BullX.AIAgent.Tools.Context
  alias BullX.AIAgent.Tools.Error
  alias BullX.AIAgent.Tools.Retry

  test "retry executes only retryable errors up to the configured attempt count" do
    Process.put(:attempts, 0)

    result =
      Retry.execute(
        fn ->
          attempts = Process.get(:attempts, 0) + 1
          Process.put(:attempts, attempts)

          case attempts do
            1 -> {:error, Error.new(:tool_timeout, "timeout", true)}
            2 -> {:ok, "done"}
          end
        end,
        max_attempts: 3,
        base_delay_ms: 0,
        sleep_fun: fn _delay -> :ok end
      )

    assert {:ok, "done"} = result
    assert Process.get(:attempts) == 2
  end

  test "retry does not repeat non-retryable errors" do
    Process.put(:attempts, 0)

    assert {:error, %Error{code: :tool_failed, retryable: false}} =
             Retry.execute(
               fn ->
                 Process.put(:attempts, Process.get(:attempts, 0) + 1)
                 {:error, Error.new(:tool_failed, "failed", false)}
               end,
               max_attempts: 3,
               base_delay_ms: 0,
               sleep_fun: fn _delay -> :ok end
             )

    assert Process.get(:attempts) == 1
  end

  test "context clamps tool and Req timeouts to the generation deadline" do
    context = context(deadline_at_ms: System.system_time(:millisecond) + 50)

    assert Context.clamp_timeout_ms(context, 5_000) <= 50

    assert [receive_timeout: receive_timeout] =
             Context.clamp_req_options(context, receive_timeout: 5_000)

    assert receive_timeout <= 50

    expired = context(deadline_at_ms: System.system_time(:millisecond) - 1)
    assert Context.clamp_timeout_ms(expired, 5_000) == 0
    assert [receive_timeout: 0] = Context.clamp_req_options(expired, receive_timeout: 5_000)
  end

  defp context(attrs) do
    struct!(
      Context,
      Map.merge(
        %{
          caller_principal_id: "caller",
          agent_principal_id: "agent",
          conversation_id: "conversation",
          source_type: "target_session_entry",
          source_id: "source",
          tool_call_id: "tool-call",
          tool_name: "tool",
          effective_access: :ordinary,
          timeout_ms: 30_000,
          idempotency_key: "key"
        },
        Map.new(attrs)
      )
    )
  end
end
