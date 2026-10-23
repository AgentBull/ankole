defmodule Ankole.Conversations.Delivery.PreviewStates do
  @moduledoc """
  Reads and writes the preview state of a Signal.

  `Ankole.Conversations.Delivery.PreviewState` keeps the state. Each write
  takes the lock of the source Signal row.
  """
  import Ankole.Attrs, only: [parse_datetime: 1]

  require Ash.Query

  alias Ankole.Conversations.Delivery.{InteractionState, PreviewAdapter, PreviewState}
  alias Ankole.Signals.Signal

  @doc "Gives the preview state of a Signal, or an empty state when it has none."
  def get(%Signal{preview: %PreviewState{} = preview}), do: preview
  def get(%Signal{id: id}), do: get(id)

  def get(id) when is_binary(id),
    do:
      PreviewState |> Ash.Query.filter(signal_id == ^id) |> Ankole.Ash.read_one!() ||
        struct(PreviewState, signal_id: id)

  @doc "Gives the Signal with its preview state."
  def load(nil), do: nil
  def load(%Signal{} = signal), do: %{signal | preview: get(signal.id)}

  @doc "Reads a Signal with its preview state. The result is nil when the Signal is missing."
  def load_signal(signal_id), do: signal_id |> Ankole.Signals.get_signal!() |> load()

  def lock_in_tx(repo, %Signal{} = signal) do
    # Re-locking an already locked source is harmless. Every writer takes this
    # lock before creating or locking the child preview row.
    Ankole.Signals.lock_signal_in_tx(repo, signal.id)

    case Ankole.Ash.create(PreviewState, :ensure, %{signal_id: signal.id}) do
      {:ok, _} -> :ok
      {:error, error} -> repo.rollback(error)
    end

    PreviewState
    |> Ash.Query.filter(signal_id == ^signal.id)
    |> Ash.Query.lock(:for_update)
    |> Ankole.Ash.read_one!()
  end

  @doc """
  Records the provider entry created for one live AI reply preview.

  The provider identity belongs to this Delivery record. The first
  successful provider send wins; repeating the same value is idempotent.
  """
  @spec record_provider_message(Ecto.UUID.t(), String.t(), String.t() | nil) ::
          :ok | {:error, term()}
  def record_provider_message(
        signal_id,
        provider_message_id,
        provider_thread_id \\ nil
      )

  def record_provider_message(
        signal_id,
        provider_message_id,
        provider_thread_id
      )
      when is_binary(signal_id) and is_binary(provider_message_id) and provider_message_id != "" and
             (is_nil(provider_thread_id) or
                (is_binary(provider_thread_id) and provider_thread_id != "")) do
    signal_id
    |> Ankole.Conversations.record_preview_provider_message(
      provider_message_id,
      provider_thread_id
    )
    |> Ankole.Errors.reason()
    |> case do
      {:ok, _result} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  def record_provider_message(_signal_id, _provider_message_id, _provider_thread_id),
    do: {:error, :invalid_reply_preview_source_entry}

  @doc false
  def record_provider_message_in_tx(repo, signal_id, provider_message_id, provider_thread_id) do
    case Ankole.Signals.lock_signal_in_tx(repo, signal_id) do
      %Signal{} = event ->
        record_source_in_tx(repo, event, provider_message_id, provider_thread_id)

      nil ->
        {:error, :signal_not_found}
    end
  end

  defp record_source_in_tx(repo, event, provider_message_id, provider_thread_id)
       when is_binary(provider_message_id) and provider_message_id != "" and
              (is_nil(provider_thread_id) or
                 (is_binary(provider_thread_id) and provider_thread_id != "")) do
    case lock_in_tx(repo, event) do
      %PreviewState{provider_message_id: nil} = preview ->
        preview
        |> Ankole.Ash.update(:update_preview, %{provider_message_id: provider_message_id})
        |> case do
          {:ok, _preview} -> record_preview_thread(repo, event, provider_thread_id)
          {:error, _changeset} = error -> error
        end

      %PreviewState{provider_message_id: ^provider_message_id} ->
        record_preview_thread(repo, event, provider_thread_id)

      %PreviewState{} ->
        {:error, :reply_preview_source_entry_already_recorded}
    end
  end

  defp record_source_in_tx(_repo, _event, _provider_message_id, _provider_thread_id),
    do: {:error, :invalid_reply_preview_source_entry}

  defp record_preview_thread(_repo, %Signal{provider_thread_id: nil}, nil),
    do: {:ok, :already_recorded}

  defp record_preview_thread(
         _repo,
         %Signal{provider_thread_id: nil} = event,
         provider_thread_id
       ) do
    event
    |> Ankole.Signals.update_metadata_signal(%{provider_thread_id: provider_thread_id})
    |> case do
      {:ok, _event} -> {:ok, :thread_recorded}
      {:error, _changeset} = error -> error
    end
  end

  defp record_preview_thread(
         _repo,
         %Signal{provider_thread_id: provider_thread_id},
         provider_thread_id
       ),
       do: {:ok, :already_recorded}

  defp record_preview_thread(_repo, %Signal{}, nil), do: {:ok, :already_recorded}

  defp record_preview_thread(_repo, %Signal{}, _provider_thread_id),
    do: {:error, :reply_preview_provider_thread_already_recorded}

  @doc """
  Persists the provider-neutral recovery checkpoint for one live reply surface.

  The checkpoint contains no transient reasoning. Provider-specific sequence
  allocation remains a separate atomic operation so a restarted process can
  safely lease a strictly higher range before a provider mutation.
  """
  @spec put_checkpoint(Ecto.UUID.t(), map(), {String.t(), String.t() | nil} | nil) ::
          {:ok, Signal.t()} | {:error, term()}
  def put_checkpoint(signal_id, checkpoint, source \\ nil)

  def put_checkpoint(signal_id, checkpoint, source)
      when is_binary(signal_id) and is_map(checkpoint) do
    case signal_id
         |> Ankole.Conversations.put_preview_checkpoint(checkpoint, source)
         |> Ankole.Errors.reason() do
      {:ok, result} -> result
      {:error, _reason} = error -> error
    end
  end

  def put_checkpoint(_signal_id, _checkpoint, _source),
    do: {:error, :invalid_reply_preview_checkpoint}

  @doc false
  def put_checkpoint_by_id_in_tx(repo, signal_id, checkpoint, source) do
    with %Signal{} = event <- Ankole.Signals.lock_signal_in_tx(repo, signal_id),
         {:ok, event} <- put_checkpoint_in_tx(repo, event, checkpoint) do
      checkpoint_source_result(repo, event, source)
    else
      nil -> {:error, :signal_not_found}
      {:error, _reason} = error -> error
    end
  end

  @doc "Updates a checkpoint under its source Signal lock."
  def update_checkpoint(signal_id, update) when is_function(update, 1) do
    signal_id
    |> Ankole.Conversations.update_preview_checkpoint(update)
    |> Ankole.Errors.reason()
  end

  @doc false
  def update_checkpoint_in_tx(repo, signal_id, update) do
    with %Signal{} = event <- Ankole.Signals.lock_signal_in_tx(repo, signal_id),
         event = load(event),
         {:ok, checkpoint} <- update.(event) do
      put_checkpoint_in_tx(repo, event, checkpoint)
    else
      nil -> {:error, :signal_not_found}
      {:error, _reason} = error -> error
    end
  end

  defp checkpoint_source_result(_repo, event, nil), do: {:ok, {:ok, event}}

  defp checkpoint_source_result(repo, event, {provider_message_id, provider_thread_id}) do
    case record_source_in_tx(repo, event, provider_message_id, provider_thread_id) do
      {:ok, _recorded} ->
        {:ok, {:ok, event}}

      # Commit the checkpoint even when its source conflicts. A retry must
      # not repeat the completed provider operation.
      {:error, reason} ->
        {:ok, {:error, {:reply_preview_source_entry, reason}}}
    end
  end

  @doc false
  @spec put_checkpoint_in_tx(module(), Signal.t(), map()) ::
          {:ok, Signal.t()} | {:error, term()}
  def put_checkpoint_in_tx(repo, %Signal{} = event, checkpoint)
      when is_map(checkpoint) do
    preview = lock_in_tx(repo, event)
    existing = PreviewAdapter.adapter_checkpoint(preview.checkpoint)
    checkpoint = PreviewAdapter.adapter_checkpoint(checkpoint)
    checkpoint = preserve_reply_preview_owner_fence(existing, checkpoint)

    with :ok <- validate_reply_preview_owner_fence(event.id, existing, checkpoint) do
      surface_fun = fn merged ->
        event
        |> PreviewAdapter.for_event()
        |> PreviewAdapter.surface?(merged)
      end

      checkpoint =
        existing
        |> InteractionState.merge_checkpoint(checkpoint, surface_fun)
        |> then(fn checkpoint ->
          Map.put(
            checkpoint,
            "sequence_high_water",
            max(
              preview.sequence_high_water || 0,
              checkpoint_sequence(checkpoint)
            )
          )
        end)
        |> PreviewAdapter.persisted_checkpoint()

      with {:ok, updated} <-
             preview
             |> Ankole.Ash.update(:update_preview, %{checkpoint: checkpoint}),
           :ok <- notify_preview_in_tx(repo, updated) do
        {:ok, %{event | preview: updated}}
      end
    end
  end

  defp preserve_reply_preview_owner_fence(existing, incoming) do
    Enum.reduce(
      ["stream_signal_id", "presentation_owner", "owner_generation"],
      incoming,
      fn key, checkpoint ->
        if Map.has_key?(checkpoint, key) or not Map.has_key?(existing, key) do
          checkpoint
        else
          Map.put(checkpoint, key, existing[key])
        end
      end
    )
  end

  defp validate_reply_preview_owner_fence(signal_id, existing, incoming) do
    existing_generation = checkpoint_owner_generation(existing)
    incoming_generation = checkpoint_owner_generation(incoming)
    existing_owner? = Map.get(existing, "presentation_owner", true)
    incoming_owner? = Map.get(incoming, "presentation_owner", existing_owner?)
    incoming_state = get_in(incoming, ["presentation", "state"])

    dispatched_rebase? =
      existing_owner? == false and incoming_owner? == true and
        incoming_generation > existing_generation and
        incoming["stream_signal_id"] == signal_id and
        existing["stream_signal_id"] != signal_id

    cond do
      incoming_generation < existing_generation ->
        {:error, :stale_reply_preview_owner_generation}

      existing_owner? == false and incoming_owner? != false and not dispatched_rebase? ->
        {:error, :stale_reply_preview_owner}

      existing_owner? == false and incoming_generation == existing_generation and
          incoming_state in ["debouncing", "working"] ->
        {:error, :stale_reply_preview_owner}

      true ->
        :ok
    end
  end

  defp checkpoint_owner_generation(%{"owner_generation" => generation})
       when is_integer(generation) and generation >= 0,
       do: generation

  defp checkpoint_owner_generation(_checkpoint), do: 0

  @doc """
  Prepares one durable provider-surface mutation without allocating a second sequence on retry.

  The caller supplies a semantic purpose, an actions digest, and a fresh UUID
  candidate. If the same logical mutation is already pending, its persisted
  sequence and UUID are returned unchanged. A different desired mutation
  supersedes the pending one and receives the next sequence. The returned
  `reused` and `sequence_current` flags are transient reconciliation facts and
  are not added to the durable pending mutation.
  """
  @spec prepare_mutation(String.t(), String.t(), String.t(), String.t()) ::
          {:ok, map()} | {:error, term()}
  def prepare_mutation(signal_id, purpose, actions_digest, uuid)
      when is_binary(signal_id) and is_binary(purpose) and purpose != "" and
             is_binary(actions_digest) and actions_digest != "" and is_binary(uuid) and
             uuid != "" do
    signal_id
    |> Ankole.Conversations.prepare_preview_mutation(purpose, actions_digest, uuid)
    |> Ankole.Errors.reason()
  end

  def prepare_mutation(_signal_id, _purpose, _actions_digest, _uuid),
    do: {:error, :invalid_reply_preview_mutation}

  @doc false
  def prepare_mutation_in_tx(repo, signal_id, purpose, actions_digest, uuid) do
    case Ankole.Signals.lock_signal_in_tx(repo, signal_id) do
      %Signal{} = event ->
        preview = lock_in_tx(repo, event)
        checkpoint = PreviewAdapter.adapter_checkpoint(preview.checkpoint)

        case checkpoint["pending_mutation"] do
          %{
            "purpose" => ^purpose,
            "actions_digest" => ^actions_digest,
            "sequence" => sequence,
            "uuid" => persisted_uuid
          } = mutation
          when is_integer(sequence) and sequence > 0 and is_binary(persisted_uuid) ->
            {:ok,
             mutation
             |> Map.put("reused", true)
             |> Map.put(
               "sequence_current",
               preview.sequence_high_water == sequence
             )}

          _other ->
            case prepare_new_mutation(
                   repo,
                   event,
                   checkpoint,
                   purpose,
                   actions_digest,
                   uuid
                 ) do
              {:ok, mutation} ->
                {:ok,
                 mutation
                 |> Map.put("reused", false)
                 |> Map.put("sequence_current", true)}

              {:error, _reason} = error ->
                error
            end
        end

      nil ->
        {:error, :signal_not_found}
    end
  end

  defp prepare_new_mutation(
         repo,
         event,
         checkpoint,
         purpose,
         actions_digest,
         uuid
       ) do
    preview = lock_in_tx(repo, event)
    sequence = (preview.sequence_high_water || 0) + 1

    if sequence > 2_147_483_647 do
      {:error, :reply_preview_sequence_exhausted}
    else
      mutation = %{
        "purpose" => purpose,
        "actions_digest" => actions_digest,
        "sequence" => sequence,
        "uuid" => uuid
      }

      checkpoint =
        checkpoint
        |> Map.put("pending_mutation", mutation)
        |> Map.put("sequence_high_water", sequence)
        |> PreviewAdapter.persisted_checkpoint()

      with {:ok, updated} <-
             preview
             |> Ankole.Ash.update(:update_preview, %{
               checkpoint: checkpoint,
               sequence_high_water: sequence
             }),
           :ok <- notify_preview_in_tx(repo, updated) do
        {:ok, mutation}
      end
    end
  end

  @doc """
  Requeues reply previews that require an operator repair.

  An operator update to the binding is the explicit requeue signal: it clears
  the blocked `recovery_state` marker, and the checkpoint notification lets
  the recovery scan attempt the preview again.
  """
  @spec wake_blocked(String.t(), String.t()) :: :ok | {:error, term()}
  def wake_blocked(agent_uid, binding_name)
      when is_binary(agent_uid) and is_binary(binding_name) do
    agent_uid
    |> Ankole.Conversations.wake_blocked_previews(binding_name)
    |> Ankole.Errors.reason()
    |> case do
      {:ok, _result} -> :ok
      {:error, _reason} = error -> error
    end
  end

  def wake_blocked(_agent_uid, _binding_name),
    do: {:error, :invalid_signal_binding}

  @doc false
  def wake_blocked_in_tx(repo, agent_uid, binding_name) do
    signal_ids =
      PreviewState
      |> Ash.Query.filter(
        fragment("?->'recovery_state'->>'state' = 'blocked'", checkpoint) and
          exists(
            Signal,
            id == parent(signal_id) and agent_uid == ^agent_uid and
              reply_binding_name == ^binding_name
          )
      )
      |> Ash.Query.select([:signal_id])
      |> Ankole.Ash.read!()
      |> Enum.map(& &1.signal_id)

    repo
    |> Ankole.Signals.lock_signals_in_tx(
      [id: [in: signal_ids], agent_uid: agent_uid, reply_binding_name: binding_name],
      sort: [id: :asc]
    )
    |> Enum.reduce_while({:ok, :ok}, fn event, acc ->
      checkpoint = get(event).checkpoint || %{}

      if get_in(checkpoint, ["recovery_state", "state"]) == "blocked" do
        case put_checkpoint_in_tx(repo, event, Map.delete(checkpoint, "recovery_state")) do
          {:ok, _event} -> {:cont, acc}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      else
        {:cont, acc}
      end
    end)
  end

  @doc false
  def cleanup_at(signal),
    do: parse_datetime(get(signal).checkpoint && get(signal).checkpoint["cleanup_at"])

  defp notify_preview_in_tx(repo, event) do
    with :ok <-
           Ankole.Conversations.Delivery.Jobs.PreviewCheckpoint.schedule_in_tx(
             repo,
             %{signal_id: event.signal_id},
             DateTime.utc_now(:microsecond)
           ) do
      if cleanup_at = parse_datetime((event.checkpoint || %{})["cleanup_at"]),
        do:
          Ankole.Conversations.Delivery.Jobs.PreviewCleanup.schedule_in_tx(
            repo,
            %{signal_id: event.signal_id},
            cleanup_at
          ),
        else: :ok
    end
  end

  defp checkpoint_sequence(checkpoint) do
    case Map.get(checkpoint, "sequence_high_water") do
      value when is_integer(value) and value >= 0 -> value
      _value -> 0
    end
  end
end
