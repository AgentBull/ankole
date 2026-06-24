defmodule Ankole.Actors do
  @moduledoc """
  Actor input store boundary shared by SignalsGateway and ActorRuntime.
  """

  import Ecto.Query, warn: false

  alias Ecto.Adapters.SQL
  alias Ankole.Actors.ActorInput
  alias Ankole.Actors.ActorInputConsumption
  alias Ankole.ActorRuntime.Schemas.ActorInputDelivery
  alias Ankole.Repo
  alias Ankole.SignalsGateway.InputTombstone
  alias Ankole.SignalsGateway.OutboxEntry

  @type actor_commit_result :: {:ok, ActorInputConsumption.t()} | {:error, term()}

  @doc """
  Appends an actor input, preserving route-scoped idempotency.
  """
  @spec append_actor_input(map()) :: {:ok, ActorInput.t()} | {:error, term()}
  def append_actor_input(attrs) when is_map(attrs) do
    Repo.transact(fn repo ->
      attrs = put_broker_sequence(repo, attrs)

      %ActorInput{}
      |> ActorInput.changeset(attrs)
      |> repo.insert(
        on_conflict: :nothing,
        conflict_target: [:agent_uid, :binding_name, :ingress_event_id],
        returning: true
      )
      |> inserted_or_existing(attrs)
    end)
  end

  @doc """
  Marks an actor input consumed if it still exists.

  Outbox intents passed through `:outbox_intents` are inserted in the same
  database transaction as the consumed-input marker.
  """
  @spec consume_actor_input(String.t(), String.t(), String.t(), keyword()) ::
          actor_commit_result()
  def consume_actor_input(agent_uid, binding_name, ingress_event_id, opts \\ []) do
    consumed_at = Keyword.get(opts, :consumed_at, DateTime.utc_now(:microsecond))

    Repo.transact(fn repo ->
      with %ActorInput{} = actor_input <-
             fetch_actor_input_for_update(repo, agent_uid, binding_name, ingress_event_id),
           {:ok, consumed_input} <-
             consume_actor_input_in_tx(repo, actor_input, opts ++ [consumed_at: consumed_at]) do
        {:ok, consumed_input}
      else
        nil -> {:error, :actor_input_not_found}
        {:error, _reason} = error -> error
      end
    end)
  end

  @doc """
  Consumes a locked actor input inside a caller-owned transaction.

  The caller owns ai-agent message and turn writes. This primitive owns the
  input tombstone check, consumption marker, optional outbox insert, and input
  compaction.
  """
  @spec consume_actor_input_in_tx(module(), ActorInput.t(), keyword()) ::
          actor_commit_result()
  def consume_actor_input_in_tx(repo, %ActorInput{} = actor_input, opts) do
    consumed_at = Keyword.get(opts, :consumed_at, DateTime.utc_now(:microsecond))

    with :ok <- reject_tombstoned_input(repo, actor_input, consumed_at),
         attrs <- consumed_attrs(actor_input, consumed_at, opts),
         {:ok, consumed_input} <- insert_consumed(repo, attrs),
         {:ok, _outbox_entries} <-
           insert_outbox_intents(repo, actor_input, Keyword.get(opts, :outbox_intents, [])),
         {:ok, _deleted} <- delete_actor_input(repo, actor_input) do
      {:ok, consumed_input}
    end
  end

  @doc """
  Removes pending actor input rows for a provider entry.
  """
  @spec cancel_pending_inputs(String.t(), String.t(), String.t(), String.t()) :: non_neg_integer()
  def cancel_pending_inputs(agent_uid, binding_name, signal_channel_id, provider_entry_id) do
    input_ids =
      ActorInput
      |> where([input], input.agent_uid == ^agent_uid)
      |> where([input], input.binding_name == ^binding_name)
      |> where([input], input.signal_channel_id == ^signal_channel_id)
      |> where([input], input.provider_entry_id == ^provider_entry_id)
      |> select([input], input.id)
      |> Repo.all()

    {count, _rows} =
      ActorInput
      |> where([input], input.agent_uid == ^agent_uid)
      |> where([input], input.binding_name == ^binding_name)
      |> where([input], input.signal_channel_id == ^signal_channel_id)
      |> where([input], input.provider_entry_id == ^provider_entry_id)
      |> Repo.delete_all()

    delete_delivery_projections(input_ids)

    count
  end

  @doc """
  Returns consumed actor inputs for a provider entry.
  """
  @spec consumed_inputs_for_entry(String.t(), String.t(), String.t(), String.t()) :: [
          ActorInputConsumption.t()
        ]
  def consumed_inputs_for_entry(agent_uid, binding_name, signal_channel_id, provider_entry_id) do
    ActorInputConsumption
    |> where([input], input.agent_uid == ^agent_uid)
    |> where([input], input.binding_name == ^binding_name)
    |> where([input], input.signal_channel_id == ^signal_channel_id)
    |> where([input], input.provider_entry_id == ^provider_entry_id)
    |> order_by([input], asc: input.consumed_at)
    |> Repo.all()
  end

  @doc """
  Reads ready actor inputs for one actor session.
  """
  @spec list_ready_inputs(String.t(), String.t(), DateTime.t()) :: [ActorInput.t()]
  def list_ready_inputs(agent_uid, session_id, now \\ DateTime.utc_now(:microsecond)) do
    ActorInput
    |> where([input], input.agent_uid == ^agent_uid)
    |> where([input], input.session_id == ^session_id)
    |> where([input], input.input_state == "open")
    |> where([input], input.available_at <= ^now)
    |> order_by([input], asc: input.broker_sequence)
    |> Repo.all()
  end

  @doc """
  Reads ready actors that currently have no live input delivery.
  """
  @spec list_ready_actor_keys(DateTime.t(), pos_integer()) :: [
          %{agent_uid: String.t(), session_id: String.t()}
        ]
  def list_ready_actor_keys(now \\ DateTime.utc_now(:microsecond), limit \\ 100)
      when is_integer(limit) and limit > 0 do
    delivery_states = ["created", "sent", "accepted"]

    ActorInput
    |> where([input], input.input_state == "open")
    |> where([input], input.available_at <= ^now)
    |> join(:left, [input], delivery in "actor_input_deliveries",
      on: delivery.actor_input_id == input.id and delivery.state in ^delivery_states
    )
    |> where([_input, delivery], is_nil(delivery.id))
    |> distinct([input], [input.agent_uid, input.session_id])
    |> order_by([input], asc: input.agent_uid, asc: input.session_id)
    |> limit(^limit)
    |> select([input], %{agent_uid: input.agent_uid, session_id: input.session_id})
    |> Repo.all()
  end

  @doc """
  Takes the contiguous same-sender prefix from already ordered ready rows.
  """
  @spec contiguous_same_sender_prefix([ActorInput.t()]) :: [ActorInput.t()]
  def contiguous_same_sender_prefix([]), do: []

  def contiguous_same_sender_prefix([%ActorInput{sender_key: nil} = input | _rest]), do: [input]

  def contiguous_same_sender_prefix([%ActorInput{sender_key: sender_key} | _rest] = inputs) do
    Enum.take_while(inputs, fn
      %ActorInput{sender_key: ^sender_key} -> true
      _input -> false
    end)
  end

  defp put_broker_sequence(_repo, %{broker_sequence: broker_sequence} = attrs)
       when is_integer(broker_sequence),
       do: attrs

  defp put_broker_sequence(repo, attrs) do
    agent_uid = Map.fetch!(attrs, :agent_uid)
    session_id = Map.fetch!(attrs, :session_id)

    SQL.query!(
      repo,
      "SELECT pg_advisory_xact_lock(hashtext($1), hashtext($2))",
      [agent_uid, session_id]
    )

    next =
      ActorInput
      |> where([input], input.agent_uid == ^agent_uid)
      |> where([input], input.session_id == ^session_id)
      |> select([input], coalesce(max(input.broker_sequence), 0) + 1)
      |> repo.one()

    Map.put(attrs, :broker_sequence, next)
  end

  defp inserted_or_existing({:ok, %ActorInput{id: nil}}, attrs), do: fetch_actor_input(attrs)
  defp inserted_or_existing({:ok, %ActorInput{} = input}, _attrs), do: {:ok, input}
  defp inserted_or_existing({:error, _changeset} = error, _attrs), do: error

  defp fetch_actor_input(%{
         agent_uid: agent_uid,
         binding_name: binding_name,
         ingress_event_id: ingress_event_id
       }) do
    case Repo.get_by(ActorInput,
           agent_uid: agent_uid,
           binding_name: binding_name,
           ingress_event_id: ingress_event_id
         ) do
      %ActorInput{} = input -> {:ok, input}
      nil -> {:error, :actor_input_not_found}
    end
  end

  defp fetch_actor_input_for_update(repo, agent_uid, binding_name, ingress_event_id) do
    ActorInput
    |> where([input], input.agent_uid == ^agent_uid)
    |> where([input], input.binding_name == ^binding_name)
    |> where([input], input.ingress_event_id == ^ingress_event_id)
    |> lock("FOR UPDATE")
    |> repo.one()
  end

  defp reject_tombstoned_input(
         _repo,
         %ActorInput{signal_channel_id: nil},
         _now
       ),
       do: :ok

  defp reject_tombstoned_input(
         _repo,
         %ActorInput{provider_entry_id: nil},
         _now
       ),
       do: :ok

  defp reject_tombstoned_input(repo, %ActorInput{} = input, now) do
    InputTombstone
    |> where([tombstone], tombstone.agent_uid == ^input.agent_uid)
    |> where([tombstone], tombstone.binding_name == ^input.binding_name)
    |> where([tombstone], tombstone.signal_channel_id == ^input.signal_channel_id)
    |> where([tombstone], tombstone.provider_entry_id == ^input.provider_entry_id)
    |> where([tombstone], tombstone.tombstoned_until > ^now)
    |> repo.exists?()
    |> case do
      true -> {:error, :actor_input_canceled}
      false -> :ok
    end
  end

  defp consumed_attrs(%ActorInput{} = input, consumed_at, opts) do
    %{
      actor_input_id: input.id,
      agent_uid: input.agent_uid,
      binding_name: input.binding_name,
      ingress_event_id: input.ingress_event_id,
      session_id: input.session_id,
      signal_channel_id: input.signal_channel_id,
      provider_thread_id: input.provider_thread_id,
      provider_entry_id: input.provider_entry_id,
      type: input.type,
      conversation_id: Keyword.get(opts, :conversation_id),
      user_message_id: Keyword.get(opts, :user_message_id),
      llm_turn_id: Keyword.fetch!(opts, :llm_turn_id),
      activation_uid: Keyword.fetch!(opts, :activation_uid),
      actor_epoch: Keyword.fetch!(opts, :actor_epoch),
      revision: Keyword.fetch!(opts, :revision),
      consumed_at: consumed_at
    }
  end

  defp insert_consumed(repo, attrs) do
    %ActorInputConsumption{}
    |> ActorInputConsumption.changeset(attrs)
    |> repo.insert(
      on_conflict: :nothing,
      conflict_target: [:actor_input_id],
      returning: true
    )
    |> consumed_insert_result(attrs)
  end

  defp consumed_insert_result({:ok, %ActorInputConsumption{agent_uid: nil}}, attrs) do
    case Repo.get_by(ActorInputConsumption, actor_input_id: attrs.actor_input_id) do
      %ActorInputConsumption{} = consumed_input -> {:ok, consumed_input}
      nil -> {:error, :consumed_input_not_found}
    end
  end

  defp consumed_insert_result({:ok, %ActorInputConsumption{} = consumed_input}, _attrs),
    do: {:ok, consumed_input}

  defp consumed_insert_result({:error, _changeset} = error, _attrs), do: error

  defp insert_outbox_intents(_repo, _actor_input, []), do: {:ok, []}

  defp insert_outbox_intents(repo, actor_input, outbox_intents) when is_list(outbox_intents) do
    outbox_intents
    |> Enum.map(&insert_outbox_intent(repo, actor_input, &1))
    |> collect_results()
  end

  defp insert_outbox_intents(_repo, _actor_input, _outbox_intents),
    do: {:error, :invalid_outbox_intents}

  defp insert_outbox_intent(repo, actor_input, attrs) when is_map(attrs) do
    attrs =
      attrs
      |> Map.put_new(:agent_uid, actor_input.agent_uid)
      |> Map.put_new(:binding_name, actor_input.binding_name)
      |> Map.put_new(:signal_channel_id, actor_input.signal_channel_id)
      |> Map.put_new(:provider_thread_id, actor_input.provider_thread_id)
      |> Map.put_new(:source_provider_entry_id, actor_input.provider_entry_id)
      |> Map.put_new(:source_actor_input_id, actor_input.id)
      |> Map.put_new(:status, :created)
      |> Map.put_new(:payload, %{})
      |> Map.put_new(:attempt_count, 0)
      |> Map.put_new(:max_attempts, 10)
      |> Map.put_new(:last_error, %{})
      |> Map.put_new(:recovery_state, %{})

    %OutboxEntry{}
    |> OutboxEntry.changeset(attrs)
    |> repo.insert(
      on_conflict: :nothing,
      conflict_target: [:agent_uid, :binding_name, :outbound_key],
      returning: true
    )
  end

  defp insert_outbox_intent(_repo, _actor_input, _attrs), do: {:error, :invalid_outbox_intent}

  defp delete_delivery_projections([]), do: :ok

  defp delete_delivery_projections(actor_input_ids) do
    ActorInputDelivery
    |> where([delivery], delivery.actor_input_id in ^actor_input_ids)
    |> Repo.delete_all()

    :ok
  end

  defp collect_results(results) do
    Enum.reduce_while(results, {:ok, []}, fn
      {:ok, value}, {:ok, acc} -> {:cont, {:ok, [value | acc]}}
      {:error, _reason} = error, _acc -> {:halt, error}
    end)
    |> case do
      {:ok, values} -> {:ok, Enum.reverse(values)}
      {:error, _reason} = error -> error
    end
  end

  defp delete_actor_input(repo, actor_input), do: repo.delete(actor_input)
end
