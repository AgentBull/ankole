defmodule Ankole.ActorRuntimeWorkerE2E.Scenarios do
  @moduledoc """
  Shared assertions and fixtures for real Agent Computer worker e2e scenarios.

  The Docker helper owns process startup. This module owns durable scenario
  facts that multiple worker tests need to inspect after the worker commits a
  turn.
  """

  import Ecto.Query
  import ExUnit.Assertions

  alias Ankole.AIAgent.Schemas.Message
  alias Ankole.AIAgent.Schemas.LlmTurn
  alias Ankole.Actors.ActorInputConsumption
  alias Ankole.ActorRuntime.Schemas.AgentComputerWorker
  alias Ankole.Repo
  alias Ankole.Schedule.Schemas.CronSchedule
  alias Ankole.Schedule.Schemas.ScheduledEvent
  alias Ankole.SignalsGateway.OutboxEntry

  @doc """
  Inserts old transcript rows plus a large recent tail for deterministic compression.

  `/compress` keeps the recent tail and summarizes older messages. Real-provider
  tests need enough transcript mass to force the compression path without
  changing production thresholds.
  """
  @spec seed_compression_history!(String.t(), Ecto.UUID.t()) :: [Ecto.UUID.t()]
  def seed_compression_history!(agent_uid, conversation_id) do
    old_user =
      insert_transcript_message!(
        agent_uid,
        conversation_id,
        "user",
        "Compression seed: the release codename is ANKOLE_REAL_E2E."
      )

    old_assistant =
      insert_transcript_message!(
        agent_uid,
        conversation_id,
        "assistant",
        "Compression seed recorded: ANKOLE_REAL_E2E."
      )

    _recent_tail =
      insert_transcript_message!(
        agent_uid,
        conversation_id,
        "user",
        String.duplicate("Recent tail retained after compression. ", 2_500)
      )

    [old_user.id, old_assistant.id]
  end

  @doc """
  Returns true when a worker turn recorded a successful tool result.
  """
  @spec tool_result_succeeded?(term(), String.t()) :: boolean()
  def tool_result_succeeded?(tool_results, tool_name) when is_list(tool_results) do
    Enum.any?(tool_results, fn
      %{"tool_name" => ^tool_name, "is_error" => false} -> true
      _result -> false
    end)
  end

  def tool_result_succeeded?(_tool_results, _tool_name), do: false

  @doc """
  Returns true when a command tool result completed with exit code 0.
  """
  @spec command_tool_succeeded?(term()) :: boolean()
  def command_tool_succeeded?(tool_results) when is_list(tool_results) do
    Enum.any?(tool_results, fn
      %{
        "tool_name" => "command",
        "is_error" => false,
        "result" => %{"details" => %{"exitCode" => 0}}
      } ->
        true

      _result ->
        false
    end)
  end

  def command_tool_succeeded?(_tool_results), do: false

  @doc """
  Fetches the checkback row created by a worker schedule tool call.
  """
  @spec checkback_by_idempotency!(String.t(), String.t()) :: ScheduledEvent.t()
  def checkback_by_idempotency!(agent_uid, idempotency_key) do
    Repo.one!(
      from event in ScheduledEvent,
        where: event.agent_uid == ^String.downcase(agent_uid),
        where: event.kind == "check_back_later",
        where: event.idempotency_key == ^idempotency_key
    )
  end

  @doc """
  Fetches the cron schedule row created by a worker cron tool call.
  """
  @spec cron_schedule_by_idempotency!(String.t(), String.t()) :: CronSchedule.t()
  def cron_schedule_by_idempotency!(agent_uid, idempotency_key) do
    Repo.one!(
      from schedule in CronSchedule,
        where: schedule.agent_uid == ^String.downcase(agent_uid),
        where: schedule.idempotency_key == ^idempotency_key
    )
  end

  @doc """
  Fetches the first concrete scheduled event armed for a cron schedule.
  """
  @spec cron_event_for_schedule!(Ecto.UUID.t()) :: ScheduledEvent.t()
  def cron_event_for_schedule!(cron_schedule_id) do
    Repo.one!(
      from event in ScheduledEvent,
        where: event.kind == "cron_fire",
        where: event.cron_schedule_id == ^cron_schedule_id
    )
  end

  @doc """
  Builds a monotonic deadline for polling a real Docker worker e2e condition.
  """
  @spec deadline(pos_integer()) :: integer()
  def deadline(timeout_ms), do: System.monotonic_time(:millisecond) + timeout_ms

  @doc """
  Waits until the worker projection is ready and reports available capacity.
  """
  @spec wait_for_worker_projection(String.t(), map() | port(), integer()) ::
          {:ok, AgentComputerWorker.t()}
  def wait_for_worker_projection(worker_id, process, deadline) do
    case Repo.get_by(AgentComputerWorker, worker_id: worker_id) do
      %AgentComputerWorker{status: "ready"} = worker ->
        case worker_has_capacity?(worker) do
          true ->
            {:ok, worker}

          false ->
            receive_port_or_wait(process, deadline, fn ->
              wait_for_worker_projection(worker_id, process, deadline)
            end)
        end

      _worker_or_nil ->
        receive_port_or_wait(process, deadline, fn ->
          wait_for_worker_projection(worker_id, process, deadline)
        end)
    end
  end

  @doc """
  Waits for one turn to reach the requested terminal status.
  """
  @spec wait_for_turn_status(map() | port(), Ecto.UUID.t(), String.t(), integer()) ::
          {:ok, LlmTurn.t()}
  def wait_for_turn_status(process, llm_turn_id, status, deadline) do
    case Repo.get(LlmTurn, llm_turn_id) do
      %LlmTurn{status: ^status} = turn ->
        {:ok, turn}

      %LlmTurn{} ->
        receive_port_or_wait(process, deadline, fn ->
          wait_for_turn_status(process, llm_turn_id, status, deadline)
        end)

      nil ->
        receive_port_or_wait(process, deadline, fn ->
          wait_for_turn_status(process, llm_turn_id, status, deadline)
        end)
    end
  end

  @doc """
  Waits for the outbox row committed for one actor input and LLM turn.
  """
  @spec wait_for_outbox_for_input(map() | port(), Ecto.UUID.t(), integer(), Ecto.UUID.t()) ::
          {:ok, OutboxEntry.t()}
  def wait_for_outbox_for_input(process, actor_input_id, deadline, llm_turn_id) do
    case Repo.get_by(OutboxEntry, source_actor_input_id: actor_input_id, llm_turn_id: llm_turn_id) do
      %OutboxEntry{} = outbox ->
        {:ok, outbox}

      nil ->
        flunk_if_terminal_without_outbox(
          process,
          llm_turn_id,
          "outbox for actor_input_id=#{actor_input_id}",
          fn ->
            Repo.get_by(OutboxEntry,
              source_actor_input_id: actor_input_id,
              llm_turn_id: llm_turn_id
            )
          end
        )

        receive_port_or_wait(process, deadline, fn ->
          wait_for_outbox_for_input(process, actor_input_id, deadline, llm_turn_id)
        end)
    end
  end

  @doc """
  Waits for any outbox that matches a predicate, failing early if the turn ends.
  """
  @spec wait_for_outbox_matching_or_turn_terminal(
          map() | port(),
          Ecto.UUID.t(),
          integer(),
          (OutboxEntry.t() -> boolean())
        ) :: {:ok, OutboxEntry.t()}
  def wait_for_outbox_matching_or_turn_terminal(process, llm_turn_id, deadline, predicate)
      when is_function(predicate, 1) do
    case OutboxEntry |> Repo.all() |> Enum.find(predicate) do
      %OutboxEntry{} = outbox ->
        {:ok, outbox}

      nil ->
        case Repo.get(LlmTurn, llm_turn_id) do
          %LlmTurn{status: "succeeded", response: response} ->
            case OutboxEntry |> Repo.all() |> Enum.find(predicate) do
              %OutboxEntry{} = outbox ->
                {:ok, outbox}

              nil ->
                flunk(
                  "turn succeeded without matching outbox: response=#{inspect(response)} durable_state=#{inspect(durable_commit_state(llm_turn_id))} #{inspect_process(process)} #{received_process_output(process_port(process))}"
                )
            end

          %LlmTurn{status: "failed", response: response} ->
            flunk(
              "turn failed before matching outbox: response=#{inspect(response)} durable_state=#{inspect(durable_commit_state(llm_turn_id))} #{inspect_process(process)} #{received_process_output(process_port(process))}"
            )

          _turn ->
            receive_port_or_wait(process, deadline, fn ->
              wait_for_outbox_matching_or_turn_terminal(process, llm_turn_id, deadline, predicate)
            end)
        end
    end
  end

  defp insert_transcript_message!(agent_uid, conversation_id, role, text) do
    %Message{}
    |> Message.changeset(%{
      agent_uid: agent_uid,
      conversation_id: conversation_id,
      role: role,
      kind: "normal",
      status: "complete",
      content: [%{"type" => "text", "text" => text}],
      metadata: %{"e2e_seed" => "real_llm_compression"}
    })
    |> Repo.insert!()
  end

  defp worker_has_capacity?(%AgentComputerWorker{capacity: capacity, load: load}) do
    available_slots =
      integer_from_map(capacity, "available_turn_slots") ||
        case {integer_from_map(capacity, "max_turns"), integer_from_map(load, "active_turns")} do
          {max_turns, active_turns} when is_integer(max_turns) and is_integer(active_turns) ->
            max_turns - active_turns

          _value ->
            nil
        end

    case available_slots do
      slots when is_integer(slots) -> slots > 0
      nil -> true
    end
  end

  defp integer_from_map(map, key) when is_map(map) do
    case Map.get(map, key) do
      value when is_integer(value) -> value
      _value -> nil
    end
  end

  defp integer_from_map(_map, _key), do: nil

  defp flunk_if_terminal_without_outbox(process, llm_turn_id, expected, outbox_check) do
    case Repo.get(LlmTurn, llm_turn_id) do
      %LlmTurn{status: "succeeded", response: response} ->
        unless outbox_check.() do
          flunk(
            "turn succeeded without #{expected}: response=#{inspect(response)} durable_state=#{inspect(durable_commit_state(llm_turn_id))} #{inspect_process(process)} #{received_process_output(process_port(process))}"
          )
        end

      %LlmTurn{status: "failed", response: response} ->
        flunk(
          "turn failed without #{expected}: response=#{inspect(response)} durable_state=#{inspect(durable_commit_state(llm_turn_id))} #{inspect_process(process)} #{received_process_output(process_port(process))}"
        )

      _turn ->
        :ok
    end
  end

  defp durable_commit_state(llm_turn_id) do
    %{
      consumptions:
        ActorInputConsumption
        |> where([consumption], consumption.llm_turn_id == ^llm_turn_id)
        |> Repo.all()
        |> Enum.map(&Map.take(&1, [:actor_input_id, :provider_entry_id, :llm_turn_id])),
      outboxes:
        OutboxEntry
        |> where([outbox], outbox.llm_turn_id == ^llm_turn_id)
        |> Repo.all()
        |> Enum.map(
          &Map.take(&1, [
            :outbound_key,
            :source_actor_input_id,
            :source_provider_entry_id,
            :target_provider_entry_id,
            :llm_turn_id,
            :operation,
            :status,
            :payload
          ])
        )
    }
  end

  defp receive_port_or_wait(process, deadline, next) do
    if System.monotonic_time(:millisecond) > deadline do
      flunk(
        "worker e2e timed out: #{inspect_process(process)} #{received_process_output(process_port(process))}"
      )
    end

    port = process_port(process)

    receive do
      {^port, {:exit_status, status}} ->
        flunk(
          "worker exited before e2e completed: #{status} #{inspect_process(process)} #{received_process_output(port)}"
        )

      {^port, {:data, data}} ->
        remember_process_output(port, data)
        next.()

      {:fake_llm_request, _kind, _count, _request} ->
        next.()
    after
      50 ->
        next.()
    end
  end

  defp process_port(%{port: port}), do: port
  defp process_port(port) when is_port(port), do: port

  defp inspect_process(%{kind: :docker, name: name}), do: "container=#{name}"
  defp inspect_process(port) when is_port(port), do: "port=#{inspect(port)}"

  defp remember_process_output(port, data) when is_port(port) and is_binary(data) do
    key = {:worker_e2e_output, port}

    output =
      [Process.get(key, ""), data] |> IO.iodata_to_binary() |> String.slice(-48_000, 48_000)

    Process.put(key, output)
    :ok
  end

  defp received_process_output(port) when is_port(port) do
    case Process.get({:worker_e2e_output, port}, "") do
      "" -> "output=<empty>"
      output -> "output=#{inspect(output, limit: :infinity, printable_limit: :infinity)}"
    end
  end
end
