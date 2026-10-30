defmodule Ankole.Conversations.Delivery.IntentTraceTest do
  @moduledoc """
  Model-driven trace conformance for `Ankole.Conversations.Delivery.Intent`.

  `tools/formal/lean/DeliveryIntent.lean` proves the budget and absorption
  contracts over abstract states. This test drives the same transition labels
  through the production Ash actions against PostgreSQL and checks the model's
  fields after every step.
  """

  use Ankole.DataCase, async: false

  import Ankole.PrincipalsFixtures
  import Ankole.SignalsFixtures

  alias Ankole.Conversations.Delivery.Intent
  alias Ankole.Conversations.Delivery.Queries

  @moduletag :trace_conformance
  @operations [:start, :succeed, :fail_retryable, :fail_permanent, :unknown, :expire, :requeue]
  @statuses [:pending, :sent, :failed, :expired, :unknown]

  test "random intent traces preserve the modelled budget and absorption laws" do
    %{principal: agent} = agent_fixture()
    _binding = binding_fixture(agent.uid, "trace-bot", :record_only)
    :rand.seed(:exsss, {101, 202, 303})

    for run <- 1..40 do
      key = "intent-trace-#{run}-#{System.unique_integer([:positive])}"
      max_attempts = 1 + :rand.uniform(3)

      assert {:ok, intent} =
               commit_delivery(%{
                 agent_uid: agent.uid,
                 binding_name: "trace-bot",
                 outbound_key: key,
                 operation: :post,
                 delivery_class: :durable_ai_reply,
                 max_attempts: max_attempts,
                 fallback_visible_text: "trace #{run}"
               })

      Enum.reduce(1..15, intent, fn step, previous ->
        operation = Enum.at(@operations, :rand.uniform(length(@operations)) - 1)
        current = fetch!(agent.uid, key)
        assert_previous_contract!(previous, current, {run, step})

        now = DateTime.utc_now(:microsecond)
        expected = expected(operation, current, now)
        _result = run_operation(operation, current, now)

        updated = fetch!(agent.uid, key)
        assert_intent_eq!(updated, expected, {run, step, operation})
        assert_absorption!(previous, updated, {run, step, operation})
        assert_budget!(updated, {run, step, operation})
        updated
      end)
    end
  end

  test "start_attempt rejects recovery_status and possible_duplicate rows at the Ash boundary without aborting SQL transactions" do
    %{principal: agent} = agent_fixture()
    _binding = binding_fixture(agent.uid, "trace-bot", :record_only)
    now = DateTime.utc_now(:microsecond)

    {:ok, permanent} =
      commit_delivery(%{
        agent_uid: agent.uid,
        binding_name: "trace-bot",
        outbound_key: "permanent-#{System.unique_integer([:positive])}",
        operation: :post,
        delivery_class: :durable_ai_reply,
        max_attempts: 3,
        fallback_visible_text: "permanent"
      })

    {:ok, permanent} = run_operation(:fail_permanent, permanent, now)

    {:ok, duplicate} =
      commit_delivery(%{
        agent_uid: agent.uid,
        binding_name: "trace-bot",
        outbound_key: "duplicate-#{System.unique_integer([:positive])}",
        operation: :post,
        delivery_class: :durable_ai_reply,
        max_attempts: 3,
        fallback_visible_text: "duplicate"
      })

    {:ok, duplicate} =
      Ankole.Ash.update(duplicate, :fail, %{
        last_error: %{"code" => "uncertain_transport"},
        possible_duplicate: true,
        possible_duplicate_notice: "Confirm whether the message arrived before retrying."
      })

    assert {:ok, :verified} =
             Ankole.Repo.transact(fn ->
               assert {:error, _} =
                        Ankole.Ash.update(permanent, :start_attempt, %{
                          platform_send_started_at: now
                        })

               assert {:error, _} =
                        Ankole.Ash.update(duplicate, :start_attempt, %{
                          platform_send_started_at: now
                        })

               assert fetch!(agent.uid, permanent.outbound_key).attempt_count == 0
               assert fetch!(agent.uid, duplicate.outbound_key).attempt_count == 0
               {:ok, :verified}
             end)
  end

  defp run_operation(:start, intent, now) do
    Ankole.Ash.update(intent, :start_attempt, %{platform_send_started_at: now})
  end

  defp run_operation(:succeed, intent, _now) do
    Ankole.Ash.update(intent, :succeed, %{
      created_provider_message_id: "provider-#{intent.outbound_key}"
    })
  end

  defp run_operation(:fail_retryable, intent, now) do
    Ankole.Ash.update(intent, :fail, %{
      last_error: %{"code" => "retryable_failure"},
      next_attempt_at: now
    })
  end

  defp run_operation(:fail_permanent, intent, _now) do
    Ankole.Ash.update(intent, :fail, %{
      last_error: %{"code" => "permanent_failure"},
      recovery_status: :permanent,
      recovery_reason: "permanent_failure"
    })
  end

  defp run_operation(:unknown, intent, _now) do
    Ankole.Ash.update(intent, :mark_unknown, %{last_error: %{"code" => "unknown_failure"}})
  end

  defp run_operation(:expire, intent, _now), do: Ankole.Ash.update(intent, :expire, %{})

  defp run_operation(:requeue, intent, now) do
    Ankole.Ash.update(intent, :requeue, %{next_attempt_at: now})
  end

  defp expected(:start, %Intent{} = intent, now) do
    # Intent's :start_attempt action and Dispatch.dispatchable_intent?/2 both
    # enforce that a permanently failed, blocked, uncertain, or duplicate-fenced
    # failed row requires an explicit requeue before any attempt starts.
    allowed? =
      (intent.status == :pending or (intent.status == :failed and not intent.possible_duplicate)) and
        intent.attempt_count < intent.max_attempts and
        is_nil(intent.recovery_status) and
        not (intent.status == :pending and not is_nil(intent.platform_send_started_at))

    if allowed? do
      %{
        intent
        | status: :pending,
          attempt_count: intent.attempt_count + 1,
          platform_send_started_at: now,
          next_attempt_at: nil
      }
    else
      intent
    end
  end

  defp expected(:succeed, %Intent{status: :pending} = intent, _now),
    do: %{intent | status: :sent, recovery_status: nil, next_attempt_at: nil}

  defp expected(:succeed, intent, _now), do: intent

  defp expected(:fail_retryable, %Intent{status: status} = intent, now)
       when status in [:pending, :failed],
       do: %{intent | status: :failed, next_attempt_at: now}

  defp expected(:fail_retryable, intent, _now), do: intent

  defp expected(:fail_permanent, %Intent{status: status} = intent, _now)
       when status in [:pending, :failed],
       do: %{intent | status: :failed, recovery_status: :permanent}

  defp expected(:fail_permanent, intent, _now), do: intent

  defp expected(:unknown, %Intent{status: :pending} = intent, _now),
    do: %{intent | status: :unknown, next_attempt_at: nil}

  defp expected(:unknown, intent, _now), do: intent

  defp expected(:expire, %Intent{status: status} = intent, _now)
       when status in [:pending, :failed],
       do: %{intent | status: :expired, recovery_status: nil, next_attempt_at: nil}

  defp expected(:expire, intent, _now), do: intent

  defp expected(:requeue, %Intent{status: status, next_attempt_at: nil} = intent, now)
       when status in [:failed, :unknown],
       do: %{
         intent
         | status: :pending,
           max_attempts: intent.attempt_count + 1,
           next_attempt_at: now,
           recovery_status: nil,
           platform_send_started_at: nil
       }

  defp expected(:requeue, intent, _now), do: intent

  defp fetch!(agent_uid, key) do
    assert %Intent{} = intent = Queries.fetch_delivery(agent_uid, "trace-bot", key)
    intent
  end

  defp assert_intent_eq!(actual, expected, context) do
    assert actual.status in @statuses, inspect({context, actual.status})

    assert actual.status == expected.status,
           "status diverged at #{inspect(context)}: #{inspect(actual.status)} != #{inspect(expected.status)}"

    assert actual.attempt_count == expected.attempt_count,
           "attempts diverged at #{inspect(context)}"

    assert actual.max_attempts == expected.max_attempts,
           "max attempts diverged at #{inspect(context)}"

    assert actual.next_attempt_at == expected.next_attempt_at,
           "next attempt diverged at #{inspect(context)}"

    assert actual.recovery_status == expected.recovery_status,
           "recovery diverged at #{inspect(context)}"

    assert same_time?(actual.platform_send_started_at, expected.platform_send_started_at),
           "send fence diverged at #{inspect(context)}"
  end

  defp same_time?(nil, nil), do: true

  defp same_time?(%DateTime{} = left, %DateTime{} = right),
    do: DateTime.compare(left, right) == :eq

  defp same_time?(_left, _right), do: false

  # A stopped state cannot be restarted by a later provider report.
  defp assert_absorption!(%Intent{status: :sent}, actual, context) do
    assert actual.status == :sent, "sent intent changed at #{inspect(context)}"
  end

  defp assert_absorption!(%Intent{status: :expired}, actual, context) do
    assert actual.status == :expired, "expired intent changed at #{inspect(context)}"
  end

  defp assert_absorption!(%Intent{status: :unknown}, actual, context) do
    assert actual.status in [:unknown, :pending],
           "unknown intent moved to #{inspect(actual.status)} at #{inspect(context)}"
  end

  defp assert_absorption!(_previous, _actual, _context), do: :ok

  # The model's budget_preserved theorem, checked on every persisted row.
  defp assert_budget!(%Intent{} = intent, context) do
    assert intent.attempt_count >= 0
    assert intent.max_attempts >= 1
    assert intent.attempt_count <= intent.max_attempts, "budget exceeded at #{inspect(context)}"
  end

  # The previous row is the model's pre-state: attempts only grow.
  defp assert_previous_contract!(
         %Intent{attempt_count: before},
         %Intent{attempt_count: after_},
         _context
       )
       when after_ >= before,
       do: :ok

  defp assert_previous_contract!(before, after_, context) do
    flunk(
      "attempt count regressed at #{inspect(context)}: #{before.attempt_count} -> #{after_.attempt_count}"
    )
  end
end
