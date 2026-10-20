defmodule Ankole.Conversations.Delivery.PreviewState do
  import Ankole.Attrs, only: [parse_datetime: 1]
  @moduledoc "Durable provider preview state, fenced by its source Signal row."
  use Ankole.Schema, tenancy: :tenant, tenant_in_primary_key: true
  import Ecto.Query
  import Ecto.Changeset
  alias Ankole.Repo
  alias Ankole.Signals.Signal
  alias Ankole.Conversations.Delivery.{InteractionState, PreviewAdapter}
  @primary_key false
  schema "delivery_previews" do
    field :signal_id, Ankole.Ecto.UUIDv7, primary_key: true
    field :provider_message_id, :string
    field :checkpoint, :map
    field :sequence_high_water, :integer, default: 0
  end

  def changeset(preview, attrs) do
    preview
    |> cast(attrs, [:signal_id, :provider_message_id, :checkpoint, :sequence_high_water])
    |> validate_required([:signal_id, :sequence_high_water])
    |> validate_number(:sequence_high_water, greater_than_or_equal_to: 0)
    |> Ankole.Ecto.JSONPayload.validate_map(:checkpoint)
    |> foreign_key_constraint(:signal_id)
  end

  def get(signal, repo \\ Repo)
  def get(%Signal{preview: %__MODULE__{} = preview}, _repo), do: preview
  def get(%Signal{id: id}, repo), do: get(id, repo)

  def get(id, repo) when is_binary(id),
    do: repo.get_by(__MODULE__, signal_id: id) || %__MODULE__{signal_id: id}

  def load(nil, _repo), do: nil
  def load(%Signal{} = signal, repo), do: %{signal | preview: get(signal.id, repo)}

  def lock_in_tx(repo, %Signal{} = signal) do
    # Re-locking an already locked source is harmless. Every writer takes this
    # lock before creating or locking the child preview row.
    Ankole.Signals.lock_signal_in_tx(repo, signal.id)

    repo.insert_all(
      __MODULE__,
      [%{tenant_id: signal.tenant_id, signal_id: signal.id, sequence_high_water: 0}],
      on_conflict: :nothing,
      conflict_target: [:tenant_id, :signal_id]
    )

    repo.one!(from p in __MODULE__, where: p.signal_id == ^signal.id, lock: "FOR UPDATE")
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
    case Repo.transact(fn repo ->
           case Ankole.Signals.lock_signal_in_tx(repo, signal_id) do
             %Signal{} = event ->
               record_source_in_tx(repo, event, provider_message_id, provider_thread_id)

             nil ->
               {:error, :signal_not_found}
           end
         end) do
      {:ok, _result} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  def record_provider_message(_signal_id, _provider_message_id, _provider_thread_id),
    do: {:error, :invalid_reply_preview_source_entry}

  defp record_source_in_tx(repo, event, provider_message_id, provider_thread_id)
       when is_binary(provider_message_id) and provider_message_id != "" and
              (is_nil(provider_thread_id) or
                 (is_binary(provider_thread_id) and provider_thread_id != "")) do
    case lock_in_tx(repo, event) do
      %__MODULE__{provider_message_id: nil} = preview ->
        preview
        |> changeset(%{provider_message_id: provider_message_id})
        |> repo.update()
        |> case do
          {:ok, _preview} -> record_preview_thread(repo, event, provider_thread_id)
          {:error, _changeset} = error -> error
        end

      %__MODULE__{provider_message_id: ^provider_message_id} ->
        record_preview_thread(repo, event, provider_thread_id)

      %__MODULE__{} ->
        {:error, :reply_preview_source_entry_already_recorded}
    end
  end

  defp record_source_in_tx(_repo, _event, _provider_message_id, _provider_thread_id),
    do: {:error, :invalid_reply_preview_source_entry}

  defp record_preview_thread(_repo, %Signal{provider_thread_id: nil}, nil),
    do: {:ok, :already_recorded}

  defp record_preview_thread(
         repo,
         %Signal{provider_thread_id: nil} = event,
         provider_thread_id
       ) do
    event
    |> Signal.changeset(%{provider_thread_id: provider_thread_id})
    |> repo.update()
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
    case Repo.transact(fn repo ->
           with %Signal{} = event <- Ankole.Signals.lock_signal_in_tx(repo, signal_id),
                {:ok, event} <- put_checkpoint_in_tx(repo, event, checkpoint) do
             checkpoint_source_result(repo, event, source)
           else
             nil -> {:error, :signal_not_found}
             {:error, _reason} = error -> error
           end
         end) do
      {:ok, result} -> result
      {:error, _reason} = error -> error
    end
  end

  def put_checkpoint(_signal_id, _checkpoint, _source),
    do: {:error, :invalid_reply_preview_checkpoint}

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
             |> changeset(%{checkpoint: checkpoint})
             |> repo.update(),
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
    Repo.transact(fn repo ->
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
    end)
  end

  def prepare_mutation(_signal_id, _purpose, _actions_digest, _uuid),
    do: {:error, :invalid_reply_preview_mutation}

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
             |> changeset(%{checkpoint: checkpoint, sequence_high_water: sequence})
             |> repo.update(),
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
    Repo.transact(fn repo ->
      Signal
      |> join(:inner, [event], preview in __MODULE__, on: preview.signal_id == event.id)
      |> where([event], event.agent_uid == ^agent_uid)
      |> where([event], event.reply_binding_name == ^binding_name)
      |> where(
        [event, preview],
        fragment(
          "?->'recovery_state'->>'state' = 'blocked'",
          preview.checkpoint
        )
      )
      |> lock("FOR UPDATE OF s0")
      |> repo.all()
      |> Enum.reduce_while({:ok, :ok}, fn event, acc ->
        checkpoint = Map.delete(get(event, repo).checkpoint, "recovery_state")

        case put_checkpoint_in_tx(repo, event, checkpoint) do
          {:ok, _event} -> {:cont, acc}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end)
    end)
    |> case do
      {:ok, _result} -> :ok
      {:error, _reason} = error -> error
    end
  end

  def wake_blocked(_agent_uid, _binding_name),
    do: {:error, :invalid_signal_binding}

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
