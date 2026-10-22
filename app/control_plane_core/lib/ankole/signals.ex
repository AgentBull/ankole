defmodule Ankole.Signals do
  @moduledoc "Accepts durable stimuli, resolves their target, and records a committed wakeup."
  import Ecto.Query
  alias Ankole.Signals.Signal
  alias Ankole.Repo
  alias Ankole.Signals.Intake

  @doc "Locks a Signal row inside the caller-owned transaction."
  def lock_signal_in_tx(repo, signal_id) do
    Ankole.Signals.Signal
    |> where([signal], signal.id == ^signal_id)
    |> lock("FOR UPDATE")
    |> repo.one(lock_identity: {"signals", signal_id})
  end

  @doc "Locks an already resolved execution target before its public Conversation row."
  def lock_target_in_tx(repo, %{agent_uid: uid, session_id: key}),
    do: Ankole.Sessions.Queue.lock_session_in_tx(repo, uid, key)

  @doc """
  Returns completed Signals for a provider entry inside a caller-owned transaction.
  """
  @spec signals_for_entry_in_tx(
          module(),
          String.t(),
          String.t(),
          String.t(),
          String.t()
        ) :: [Signal.t()]
  def signals_for_entry_in_tx(
        repo,
        agent_uid,
        binding_name,
        conversation_id,
        provider_message_id
      )
      when is_binary(provider_message_id) and provider_message_id != "" do
    Signal
    |> where([input], input.agent_uid == ^agent_uid)
    |> where([input], input.reply_binding_name == ^binding_name)
    |> where([input], input.conversation_id == ^conversation_id)
    |> where([input], input.status == :completed)
    |> where(
      [input],
      input.provider_message_id == ^provider_message_id or
        fragment(
          """
          jsonb_typeof(?->'entries') = 'array'
          AND EXISTS (
            SELECT 1
            FROM jsonb_array_elements(?->'entries') AS entry
            WHERE entry->>'provider_message_id' = ?
          )
          """,
          input.data,
          input.data,
          ^provider_message_id
        )
    )
    |> order_by([input], asc: input.available_at)
    |> repo.all()
  end

  def signals_for_entry_in_tx(
        _repo,
        _agent_uid,
        _binding_name,
        _conversation_id,
        _provider_message_id
      ),
      do: []

  @doc "Accepts one stimulus and wakes its session after the transaction commits."
  def accept(attrs) when is_map(attrs) do
    Repo.assert_outside_transaction!()

    Repo.transact(fn repo -> accept_in_tx(repo, attrs) end)
    |> case do
      {:ok, signal} = result ->
        publish_committed([signal])

        result

      error ->
        error
    end
  end

  def accept(_attrs), do: {:error, :invalid_request}

  @doc "Publishes accepted Signals returned by a committed caller-owned transaction."
  def publish_committed(signals) do
    Repo.assert_outside_transaction!()

    Enum.each(signals, fn signal ->
      Ankole.Observability.stage(
        "signal.intake.committed",
        Ankole.Observability.signal_attributes(signal),
        fn -> :ok end
      )

      Ankole.Sessions.Events.publish_status(signal.agent_uid, signal.session_id)
    end)

    Ankole.Sessions.deliver_events(signals)
    :ok
  end

  @doc "Accepts a stimulus with a durable EnsureDriver job in the caller's transaction."
  def accept_in_tx(repo, attrs) when is_map(attrs) do
    with :ok <- Repo.require_transaction(repo), do: Intake.accept(repo, attrs)
  end

  def accept_in_tx(_repo, _attrs), do: {:error, :invalid_request}
end
