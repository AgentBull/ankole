defmodule Ankole.Actors do
  @moduledoc """
  Minimal actor-store boundary used by SignalsGateway until the full actor runtime exists.
  """

  import Ecto.Query, warn: false

  alias Ankole.Actors.ConsumedInput
  alias Ankole.Actors.MailboxInput
  alias Ankole.Repo
  alias Ankole.SignalsGateway.InputTombstone
  alias Ankole.SignalsGateway.OutboxEntry

  @type actor_commit_result :: {:ok, ConsumedInput.t()} | {:error, term()}

  @doc """
  Appends an actor mailbox input, preserving route-scoped idempotency.
  """
  @spec append_mailbox_input(map()) :: {:ok, MailboxInput.t()} | {:error, term()}
  def append_mailbox_input(attrs) when is_map(attrs) do
    %MailboxInput{}
    |> MailboxInput.changeset(attrs)
    |> Repo.insert(
      on_conflict: :nothing,
      conflict_target: [:agent_uid, :binding_name, :ingress_event_id],
      returning: true
    )
    |> inserted_or_existing(attrs)
  end

  @doc """
  Marks a mailbox input consumed if it still exists.

  Outbox intents passed through `:outbox_intents` are inserted in the same
  database transaction as the consumed-input marker.
  """
  @spec consume_mailbox_input(String.t(), String.t(), String.t(), keyword()) ::
          actor_commit_result()
  def consume_mailbox_input(agent_uid, binding_name, ingress_event_id, opts \\ []) do
    consumed_at = Keyword.get(opts, :consumed_at, DateTime.utc_now(:microsecond))

    Repo.transact(fn repo ->
      with %MailboxInput{} = mailbox_input <-
             fetch_mailbox_for_update(repo, agent_uid, binding_name, ingress_event_id),
           :ok <- reject_tombstoned_input(repo, mailbox_input, consumed_at),
           attrs <- consumed_attrs(mailbox_input, consumed_at),
           {:ok, consumed_input} <- insert_consumed(repo, attrs),
           {:ok, _outbox_entries} <-
             insert_outbox_intents(repo, mailbox_input, Keyword.get(opts, :outbox_intents, [])),
           {:ok, _deleted} <- delete_mailbox(repo, mailbox_input) do
        {:ok, consumed_input}
      else
        nil -> {:error, :mailbox_input_not_found}
        {:error, _reason} = error -> error
      end
    end)
  end

  @doc """
  Removes pending mailbox rows for a provider entry.
  """
  @spec cancel_pending_inputs(String.t(), String.t(), String.t(), String.t()) :: non_neg_integer()
  def cancel_pending_inputs(agent_uid, binding_name, signal_channel_id, provider_entry_id) do
    {count, _rows} =
      MailboxInput
      |> where([input], input.agent_uid == ^agent_uid)
      |> where([input], input.binding_name == ^binding_name)
      |> where([input], input.signal_channel_id == ^signal_channel_id)
      |> where([input], input.provider_entry_id == ^provider_entry_id)
      |> Repo.delete_all()

    count
  end

  @doc """
  Returns consumed actor inputs for a provider entry.
  """
  @spec consumed_inputs_for_entry(String.t(), String.t(), String.t(), String.t()) :: [
          ConsumedInput.t()
        ]
  def consumed_inputs_for_entry(agent_uid, binding_name, signal_channel_id, provider_entry_id) do
    ConsumedInput
    |> where([input], input.agent_uid == ^agent_uid)
    |> where([input], input.binding_name == ^binding_name)
    |> where([input], input.signal_channel_id == ^signal_channel_id)
    |> where([input], input.provider_entry_id == ^provider_entry_id)
    |> order_by([input], asc: input.consumed_at)
    |> Repo.all()
  end

  @doc """
  Reads ready mailbox rows for one actor session.
  """
  @spec list_ready_inputs(String.t(), String.t(), DateTime.t()) :: [MailboxInput.t()]
  def list_ready_inputs(agent_uid, session_id, now \\ DateTime.utc_now(:microsecond)) do
    MailboxInput
    |> where([input], input.agent_uid == ^agent_uid)
    |> where([input], input.session_id == ^session_id)
    |> where([input], input.available_at <= ^now)
    |> order_by([input], asc: input.inserted_at, asc: input.id)
    |> Repo.all()
  end

  @doc """
  Takes the contiguous same-sender prefix from already ordered ready rows.
  """
  @spec contiguous_same_sender_prefix([MailboxInput.t()]) :: [MailboxInput.t()]
  def contiguous_same_sender_prefix([]), do: []

  def contiguous_same_sender_prefix([%MailboxInput{sender_key: nil} = input | _rest]), do: [input]

  def contiguous_same_sender_prefix([%MailboxInput{sender_key: sender_key} | _rest] = inputs) do
    Enum.take_while(inputs, fn
      %MailboxInput{sender_key: ^sender_key} -> true
      _input -> false
    end)
  end

  defp inserted_or_existing({:ok, %MailboxInput{id: nil}}, attrs), do: fetch_mailbox_input(attrs)
  defp inserted_or_existing({:ok, %MailboxInput{} = input}, _attrs), do: {:ok, input}
  defp inserted_or_existing({:error, _changeset} = error, _attrs), do: error

  defp fetch_mailbox_input(%{
         agent_uid: agent_uid,
         binding_name: binding_name,
         ingress_event_id: ingress_event_id
       }) do
    case Repo.get_by(MailboxInput,
           agent_uid: agent_uid,
           binding_name: binding_name,
           ingress_event_id: ingress_event_id
         ) do
      %MailboxInput{} = input -> {:ok, input}
      nil -> {:error, :mailbox_input_not_found}
    end
  end

  defp fetch_mailbox_for_update(repo, agent_uid, binding_name, ingress_event_id) do
    MailboxInput
    |> where([input], input.agent_uid == ^agent_uid)
    |> where([input], input.binding_name == ^binding_name)
    |> where([input], input.ingress_event_id == ^ingress_event_id)
    |> lock("FOR UPDATE")
    |> repo.one()
  end

  defp reject_tombstoned_input(
         _repo,
         %MailboxInput{signal_channel_id: nil},
         _now
       ),
       do: :ok

  defp reject_tombstoned_input(
         _repo,
         %MailboxInput{provider_entry_id: nil},
         _now
       ),
       do: :ok

  defp reject_tombstoned_input(repo, %MailboxInput{} = input, now) do
    InputTombstone
    |> where([tombstone], tombstone.agent_uid == ^input.agent_uid)
    |> where([tombstone], tombstone.binding_name == ^input.binding_name)
    |> where([tombstone], tombstone.signal_channel_id == ^input.signal_channel_id)
    |> where([tombstone], tombstone.provider_entry_id == ^input.provider_entry_id)
    |> where([tombstone], tombstone.tombstoned_until > ^now)
    |> repo.exists?()
    |> case do
      true -> {:error, :mailbox_input_canceled}
      false -> :ok
    end
  end

  defp consumed_attrs(%MailboxInput{} = input, consumed_at) do
    %{
      agent_uid: input.agent_uid,
      binding_name: input.binding_name,
      ingress_event_id: input.ingress_event_id,
      session_id: input.session_id,
      signal_channel_id: input.signal_channel_id,
      provider_thread_id: input.provider_thread_id,
      provider_entry_id: input.provider_entry_id,
      type: input.type,
      consumed_at: consumed_at
    }
  end

  defp insert_consumed(repo, attrs) do
    %ConsumedInput{}
    |> ConsumedInput.changeset(attrs)
    |> repo.insert(
      on_conflict: :nothing,
      conflict_target: [:agent_uid, :binding_name, :ingress_event_id],
      returning: true
    )
    |> consumed_insert_result(attrs)
  end

  defp consumed_insert_result({:ok, %ConsumedInput{agent_uid: nil}}, attrs) do
    case Repo.get_by(ConsumedInput,
           agent_uid: attrs.agent_uid,
           binding_name: attrs.binding_name,
           ingress_event_id: attrs.ingress_event_id
         ) do
      %ConsumedInput{} = consumed_input -> {:ok, consumed_input}
      nil -> {:error, :consumed_input_not_found}
    end
  end

  defp consumed_insert_result({:ok, %ConsumedInput{} = consumed_input}, _attrs),
    do: {:ok, consumed_input}

  defp consumed_insert_result({:error, _changeset} = error, _attrs), do: error

  defp insert_outbox_intents(_repo, _mailbox_input, []), do: {:ok, []}

  defp insert_outbox_intents(repo, mailbox_input, outbox_intents) when is_list(outbox_intents) do
    outbox_intents
    |> Enum.map(&insert_outbox_intent(repo, mailbox_input, &1))
    |> collect_results()
  end

  defp insert_outbox_intents(_repo, _mailbox_input, _outbox_intents),
    do: {:error, :invalid_outbox_intents}

  defp insert_outbox_intent(repo, mailbox_input, attrs) when is_map(attrs) do
    attrs =
      attrs
      |> Map.put_new(:agent_uid, mailbox_input.agent_uid)
      |> Map.put_new(:binding_name, mailbox_input.binding_name)
      |> Map.put_new(:signal_channel_id, mailbox_input.signal_channel_id)
      |> Map.put_new(:provider_thread_id, mailbox_input.provider_thread_id)
      |> Map.put_new(:source_provider_entry_id, mailbox_input.provider_entry_id)
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

  defp insert_outbox_intent(_repo, _mailbox_input, _attrs), do: {:error, :invalid_outbox_intent}

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

  defp delete_mailbox(repo, mailbox_input), do: repo.delete(mailbox_input)
end
