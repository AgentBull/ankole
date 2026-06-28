defmodule Ankole.ActorRuntime.ReadyInputProcessor do
  @moduledoc false

  import Ecto.Query, warn: false
  import Ankole.ActorRuntime.Common

  alias Ankole.Actors
  alias Ankole.Actors.ActorInput
  alias Ankole.ActorRuntime.EntryLifecycle
  alias Ankole.ActorRuntime.RuntimeCommand
  alias Ankole.ActorRuntime.ScheduledTurn
  alias Ankole.ActorRuntime.SessionReset
  alias Ankole.ActorRuntime.TurnLifecycle
  alias Ankole.AIAgent.Schemas.Conversation
  alias Ankole.Repo
  alias Ankole.SignalsGateway
  alias Ankole.SignalsGateway.ActorInputTypes

  @type actor_key :: %{agent_uid: String.t(), session_id: String.t()}

  @doc """
  Starts one ready actor if a worker is available.
  """
  @spec process_ready_inputs_once(keyword()) :: {:ok, map()} | {:error, term()}
  def process_ready_inputs_once(opts \\ []) do
    now = Keyword.get(opts, :now, DateTime.utc_now(:microsecond))
    {:ok, _finalized_batches} = SignalsGateway.finalize_due_inbound_batches(now: now, limit: 1)

    case Actors.list_ready_actor_keys(now, 1) do
      [%{agent_uid: agent_uid, session_id: session_id}] ->
        process_ready_inputs_for_actor(%{agent_uid: agent_uid, session_id: session_id}, opts)

      [] ->
        {:ok, %{status: :idle}}
    end
  end

  @doc """
  Starts ready actors up to the requested limit.
  """
  @spec process_ready_inputs(keyword()) :: {:ok, [map()]} | {:error, term()}
  def process_ready_inputs(opts \\ []) do
    now = Keyword.get(opts, :now, DateTime.utc_now(:microsecond))
    limit = Keyword.get(opts, :limit, 25)

    {:ok, _finalized_batches} =
      SignalsGateway.finalize_due_inbound_batches(now: now, limit: limit)

    now
    |> Actors.list_ready_actor_keys(limit)
    |> Enum.map(&process_ready_inputs_for_actor(&1, opts))
    |> collect_results()
  end

  @doc """
  Enqueues daily reset barrier inputs for sessions due at the latest local 04:30.

  The control plane owns the timer and timezone. The reset itself is still an
  ordinary `actor_inputs` row, so per-session ordering stays in one queue.
  """

  def process_ready_inputs_for_actor(actor_key, opts \\ []) do
    actor_key = normalize_actor_key(actor_key)
    now = Keyword.get(opts, :now, DateTime.utc_now(:microsecond))

    actor_key.agent_uid
    |> Actors.list_ready_inputs(actor_key.session_id, now)
    |> select_ready_inputs_for_actor(actor_key)
    |> case do
      [] ->
        {:ok, %{status: :idle}}

      [%ActorInput{type: "command.new"} = input | _inputs] ->
        RuntimeCommand.process_new_command(actor_key, input, opts)

      [%ActorInput{type: "session.reset_due"} = input | _inputs] ->
        SessionReset.process_due(actor_key, input, opts)

      [%ActorInput{type: "signal.entry.removed"} = input | _inputs] ->
        EntryLifecycle.process(actor_key, input, opts)

      [%ActorInput{type: type} = input | _inputs]
      when type in ["command.stop", "command.retry"] ->
        RuntimeCommand.process_runtime_command(actor_key, input, opts)

      [%ActorInput{type: "command.steer"} = input | _inputs] ->
        RuntimeCommand.process_steer_command(actor_key, input, opts)

      [%ActorInput{type: type} = input | _inputs]
      when type in ["check_back_later.wakeup", "cron.fire"] ->
        TurnLifecycle.start_llm_turn(actor_key, [input], ScheduledTurn.opts(input, opts))

      inputs ->
        TurnLifecycle.start_llm_turn(actor_key, inputs, opts)
    end
  end

  defp ready_input_head([input | _rest]), do: [input]

  defp select_ready_inputs_for_actor([], _actor_key), do: []

  defp select_ready_inputs_for_actor([first_input | _rest] = inputs, actor_key) do
    case active_generation_for_actor?(actor_key) do
      true ->
        cond do
          input = live_turn_command_input(inputs) ->
            [input]

          hard_queue_barrier?(first_input) ->
            [first_input]

          TurnLifecycle.live_delivery_for_session?(Repo, actor_key) ->
            []

          true ->
            [first_input]
        end

      false ->
        ready_input_head(inputs)
    end
  end

  defp live_turn_command_input(inputs) do
    inputs
    |> Enum.take_while(&(not hard_queue_barrier?(&1)))
    |> Enum.find(&live_turn_command_input?/1)
  end

  defp live_turn_command_input?(%ActorInput{type: type}) do
    ActorInputTypes.command_runtime_policy(type) in [:control_now, :checkpoint_nudge]
  end

  defp live_turn_command_input?(_input), do: false

  defp hard_queue_barrier?(%ActorInput{type: "session.reset_due"}), do: true
  defp hard_queue_barrier?(_input), do: false

  defp active_generation_for_actor?(actor_key) do
    Conversation
    |> where([conversation], conversation.agent_uid == ^actor_key.agent_uid)
    |> where([conversation], conversation.conversation_key == ^actor_key.session_id)
    |> where([conversation], is_nil(conversation.ended_at))
    |> select([conversation], conversation.generation)
    |> Repo.one()
    |> TurnLifecycle.conversation_has_active_generation?()
  end
end
