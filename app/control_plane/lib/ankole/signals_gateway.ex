defmodule Ankole.SignalsGateway do
  @moduledoc """
  Boundary between signal ingress, actor input handoff, and provider outbox.
  """

  import Ecto.Query, warn: false

  alias Ecto.Adapters.SQL
  alias Ankole.ActorRuntime.ActivationManager
  alias Ankole.AIAgent.Schemas.Conversation
  alias Ankole.AIAgent.Schemas.Message
  alias Ankole.Actors
  alias Ankole.Actors.ActorInput
  alias Ankole.Repo
  alias Ankole.SignalsGateway.ActorInputTypes
  alias Ankole.SignalsGateway.Commands
  alias Ankole.SignalsGateway.IngressPipeline
  alias Ankole.SignalsGateway.InputTombstone
  alias Ankole.SignalsGateway.JsonPayload
  alias Ankole.SignalsGateway.OutboxAdapter
  alias Ankole.SignalsGateway.OutboxEntry
  alias Ankole.SignalsGateway.Sanitizer
  alias Ankole.SignalsGateway.SignalBinding
  alias Ankole.SignalsGateway.SignalChannel
  alias Ankole.SignalsGateway.SignalEntry

  @tombstone_ttl_seconds 24 * 60 * 60
  @ambient_hard_cap_ms 60_000
  @ambient_recall_max_rows 80

  @type ingress_result :: {:ok, map()} | {:error, term()}

  @outbox_base_retry_seconds 5
  @outbox_max_retry_seconds 5 * 60

  @doc """
  Creates or updates a per-agent signal binding.
  """
  @spec upsert_binding(map()) :: {:ok, SignalBinding.t()} | {:error, term()}
  def upsert_binding(attrs) when is_map(attrs) do
    %SignalBinding{}
    |> SignalBinding.changeset(attrs)
    |> Repo.insert(
      on_conflict: {:replace_all_except, [:inserted_at]},
      conflict_target: [:agent_uid, :name],
      returning: true
    )
  end

  @doc """
  Loads an enabled binding by route key.
  """
  @spec get_binding(String.t(), String.t()) :: {:ok, SignalBinding.t()} | {:error, term()}
  def get_binding(agent_uid, binding_name) do
    case Repo.get_by(SignalBinding, agent_uid: normalize_uid(agent_uid), name: binding_name) do
      %SignalBinding{enabled: true, unavailable_reason: reason} when is_binary(reason) ->
        {:error, {:binding_unavailable, reason}}

      %SignalBinding{enabled: true} = binding ->
        {:ok, binding}

      %SignalBinding{enabled: false} ->
        {:error, :binding_disabled}

      nil ->
        {:error, :binding_not_found}
    end
  end

  @doc """
  Concrete adapter API for a provider entry receive.
  """
  @spec emit_entry(String.t(), String.t(), map(), keyword()) :: ingress_result()
  def emit_entry(agent_uid, binding_name, input, options \\ []) when is_map(input) do
    now = Keyword.get(options, :now, DateTime.utc_now(:microsecond))

    with {:ok, binding} <- get_binding(agent_uid, binding_name),
         {:ok, fact} <-
           IngressPipeline.construct(:entry, binding, input, now, &normalize_entry_fact/3),
         :match <- IngressPipeline.filter(binding, fact) do
      binding
      |> accept_entry(fact, options, now)
      |> wake_actor_runtime()
    else
      :no_match -> {:ok, %{status: :filtered}}
      {:error, _reason} = error -> error
    end
  end

  @doc """
  Concrete adapter API for a provider entry delete.
  """
  @spec emit_entry_deleted(String.t(), String.t(), map(), keyword()) :: ingress_result()
  def emit_entry_deleted(agent_uid, binding_name, input, options \\ []) do
    emit_lifecycle(agent_uid, binding_name, input, :deleted, options)
  end

  @doc """
  Concrete adapter API for a provider entry recall.
  """
  @spec emit_entry_recalled(String.t(), String.t(), map(), keyword()) :: ingress_result()
  def emit_entry_recalled(agent_uid, binding_name, input, options \\ []) do
    emit_lifecycle(agent_uid, binding_name, input, :recalled, options)
  end

  @doc """
  Concrete adapter API for reaction changes.
  """
  @spec emit_reaction(String.t(), String.t(), map(), keyword()) :: ingress_result()
  def emit_reaction(agent_uid, binding_name, input, options \\ []) when is_map(input) do
    now = Keyword.get(options, :now, DateTime.utc_now(:microsecond))

    with {:ok, binding} <- get_binding(agent_uid, binding_name),
         {:ok, fact} <-
           IngressPipeline.construct(:reaction, binding, input, now, &normalize_reaction_fact/3),
         :match <- IngressPipeline.filter(binding, fact) do
      Repo.transact(fn repo ->
        with :ok <- lock_entry(repo, fact) do
          case repo.get_by(SignalEntry,
                 signal_channel_id: fact.signal_channel_id,
                 provider_entry_id: fact.provider_entry_id
               ) do
            %SignalEntry{} = entry ->
              entry
              |> SignalEntry.changeset(reaction_entry_attrs(entry, fact, now))
              |> repo.update()
              |> reaction_result()

            nil ->
              {:ok, %{status: :ignored_unknown_entry}}
          end
        end
      end)
    else
      :no_match -> {:ok, %{status: :filtered}}
      {:error, _reason} = error -> error
    end
  end

  @doc """
  Concrete adapter API for provider actions such as card clicks.
  """
  @spec emit_action(String.t(), String.t(), map(), keyword()) :: ingress_result()
  def emit_action(agent_uid, binding_name, input, options \\ []) when is_map(input) do
    now = Keyword.get(options, :now, DateTime.utc_now(:microsecond))

    with {:ok, binding} <- get_binding(agent_uid, binding_name),
         {:ok, fact} <-
           IngressPipeline.construct(:action, binding, input, now, &normalize_action_fact/3),
         :match <- IngressPipeline.filter(binding, fact) do
      Repo.transact(fn repo ->
        with {:ok, channel} <- maybe_upsert_channel(repo, fact, now),
             {:ok, actor_input} <-
               append_actor_input(binding, fact, fact.actor_input_type, channel, nil, now) do
          {:ok, %{status: :accepted, actor_input: actor_input, signal_channel: channel}}
        end
      end)
      |> wake_actor_runtime()
    else
      :no_match -> {:ok, %{status: :filtered}}
      {:error, _reason} = error -> error
    end
  end

  @doc """
  Appends an internal ActorInput, such as a timer fire, without provider mirroring.
  """
  @spec emit_internal(String.t(), String.t(), map(), keyword()) :: ingress_result()
  def emit_internal(agent_uid, binding_name, input, options \\ []) when is_map(input) do
    now = Keyword.get(options, :now, DateTime.utc_now(:microsecond))

    with {:ok, binding} <- get_binding(agent_uid, binding_name),
         {:ok, fact} <-
           IngressPipeline.construct(:internal, binding, input, now, &normalize_internal_fact/3),
         :match <- IngressPipeline.filter(binding, fact) do
      Repo.transact(fn _repo ->
        with {:ok, actor_input} <-
               append_actor_input(binding, fact, fact.actor_input_type, nil, nil, now) do
          {:ok, %{status: :accepted, actor_input: actor_input}}
        end
      end)
      |> wake_actor_runtime()
    else
      :no_match -> {:ok, %{status: :filtered}}
      {:error, _reason} = error -> error
    end
  end

  @doc """
  Records a provider-visible outbox intent committed by the actor runtime.
  """
  @spec commit_outbox(map()) :: {:ok, OutboxEntry.t()} | {:error, term()}
  def commit_outbox(attrs) when is_map(attrs) do
    %OutboxEntry{}
    |> OutboxEntry.changeset(default_outbox_attrs(attrs))
    |> Repo.insert(
      on_conflict: :nothing,
      conflict_target: [:agent_uid, :binding_name, :outbound_key],
      returning: true
    )
    |> outbox_insert_result(attrs)
  end

  @doc """
  Chooses the provider-visible reply operation for an actor input.
  """
  @spec outbox_operation_for_actor_input(ActorInput.t(), module()) :: atom()
  def outbox_operation_for_actor_input(%ActorInput{} = actor_input, repo \\ Repo) do
    with %SignalChannel{} = channel <- repo.get(SignalChannel, actor_input.signal_channel_id),
         %SignalBinding{} = binding <-
           repo.get_by(SignalBinding,
             agent_uid: actor_input.agent_uid,
             name: actor_input.binding_name
           ) do
      choose_outbox_operation(
        channel,
        adapter_outbound_capabilities(binding.adapter),
        actor_input
      )
    else
      _value -> fallback_outbox_operation(actor_input)
    end
  end

  @doc """
  Dispatches one outbox row through a concrete adapter runtime.
  """
  @spec dispatch_outbox(String.t(), String.t(), String.t(), map(), keyword()) ::
          {:ok, OutboxEntry.t()} | {:error, term()}
  def dispatch_outbox(agent_uid, binding_name, outbound_key, adapter, options \\ []) do
    now = Keyword.get(options, :now, DateTime.utc_now(:microsecond))

    case prepare_outbox_dispatch(agent_uid, binding_name, outbound_key, adapter, now) do
      {:ok, {:send, outbox, channel, adapter}} ->
        adapter
        |> call_adapter_send(outbox)
        |> finalize_outbox_send(outbox, channel, now)

      {:ok, {:reconcile, outbox, channel, adapter}} ->
        adapter
        |> call_adapter_reconcile(outbox)
        |> finalize_outbox_reconcile(outbox, channel, now)

      {:ok, %OutboxEntry{} = outbox} ->
        {:ok, outbox}

      {:error, _reason} = error ->
        error
    end
  end

  @doc """
  Lists outbox rows that are ready for a dispatch attempt.
  """
  @spec list_due_outbox(DateTime.t(), pos_integer()) :: [OutboxEntry.t()]
  def list_due_outbox(now \\ DateTime.utc_now(:microsecond), limit \\ 50)
      when is_integer(limit) and limit > 0 do
    OutboxEntry
    |> where([entry], entry.status == :created)
    |> or_where(
      [entry],
      entry.status == :failed and not is_nil(entry.next_attempt_at) and
        entry.next_attempt_at <= ^now and entry.attempt_count < entry.max_attempts
    )
    |> order_by([entry], asc: entry.inserted_at)
    |> limit(^limit)
    |> Repo.all()
  end

  @doc """
  Dispatches due outbox rows with a code-owned adapter resolver.
  """
  @spec dispatch_due_outbox(
          (OutboxEntry.t() -> {:ok, map()} | map() | {:error, term()}),
          keyword()
        ) ::
          [term()]
  def dispatch_due_outbox(adapter_resolver, options \\ [])
      when is_function(adapter_resolver, 1) do
    now = Keyword.get(options, :now, DateTime.utc_now(:microsecond))
    limit = Keyword.get(options, :limit, 50)

    now
    |> list_due_outbox(limit)
    |> Enum.map(&dispatch_due_outbox_entry(&1, adapter_resolver, now))
  end

  defp prepare_outbox_dispatch(agent_uid, binding_name, outbound_key, adapter, now) do
    with {:ok, adapter} <- OutboxAdapter.normalize(adapter) do
      Repo.transact(fn repo ->
        with %OutboxEntry{} = outbox <-
               fetch_outbox_for_update(repo, agent_uid, binding_name, outbound_key),
             {:ok, channel} <- outbox_channel(repo, outbox) do
          case in_flight_recovery_action(outbox, adapter) do
            {:reconcile, outbox} ->
              {:ok, {:reconcile, outbox, channel, adapter}}

            {:unknown, outbox, reason} ->
              mark_outbox_unknown(repo, outbox, reason)

            :continue ->
              prepare_fresh_outbox_dispatch(repo, outbox, channel, adapter, now)
          end
        else
          nil -> {:error, :outbox_not_found}
          {:unsupported, outbox} -> mark_outbox_unsupported(repo, outbox)
          {:error, _reason} = error -> error
        end
      end)
    end
  end

  @doc """
  Removes expired SignalsGateway TTL state.
  """
  @spec cleanup_expired_state(DateTime.t()) :: %{tombstones: non_neg_integer()}
  def cleanup_expired_state(now \\ DateTime.utc_now(:microsecond)) do
    {tombstones, _} =
      InputTombstone
      |> where([tombstone], tombstone.tombstoned_until <= ^now)
      |> Repo.delete_all()

    %{tombstones: tombstones}
  end

  @doc """
  Default actor session id derived from a signal channel.
  """
  @spec signal_session_id(String.t()) :: String.t()
  def signal_session_id(signal_channel_id), do: "signal-channel:#{signal_channel_id}"

  defp wake_actor_runtime({:ok, %{status: :accepted}} = result) do
    ActivationManager.wake()
    result
  end

  defp wake_actor_runtime(result), do: result

  defp emit_lifecycle(agent_uid, binding_name, input, kind, options) do
    now = Keyword.get(options, :now, DateTime.utc_now(:microsecond))

    with {:ok, binding} <- get_binding(agent_uid, binding_name),
         constructor <- lifecycle_constructor(kind),
         {:ok, fact} <- IngressPipeline.construct(:lifecycle, binding, input, now, constructor),
         :match <- IngressPipeline.filter(binding, fact) do
      binding
      |> accept_lifecycle(fact, kind, now)
      |> wake_actor_runtime()
    else
      :no_match -> {:ok, %{status: :filtered}}
      {:error, _reason} = error -> error
    end
  end

  defp accept_entry(binding, fact, options, now) do
    Repo.transact(fn repo ->
      with :ok <- lock_entry(repo, fact) do
        case active_tombstone?(repo, fact, now) do
          true ->
            {:ok, %{status: :dropped_tombstoned}}

          false ->
            with {:ok, policy} <- entry_policy(binding, fact, options),
                 {:ok, result} <- apply_entry_policy(repo, binding, fact, policy, now) do
              {:ok, result}
            end
        end
      end
    end)
  end

  defp lifecycle_constructor(kind) do
    fn binding, input, now -> normalize_lifecycle_fact(binding, input, kind, now) end
  end

  defp accept_lifecycle(binding, fact, kind, now) do
    Repo.transact(fn repo ->
      with {:ok, channel} <- upsert_channel(repo, fact, now),
           :ok <- lock_entry(repo, fact),
           {:ok, tombstone} <- upsert_tombstone(repo, fact, kind, now),
           {deleted_count, _rows} <- delete_mirror_entry(repo, fact),
           canceled_count <-
             Actors.cancel_pending_inputs(
               fact.agent_uid,
               fact.binding_name,
               fact.signal_channel_id,
               fact.provider_entry_id
             ),
           consumed_inputs <-
             Actors.consumed_inputs_for_entry(
               fact.agent_uid,
               fact.binding_name,
               fact.signal_channel_id,
               fact.provider_entry_id
             ),
           {:ok, lifecycle_inputs} <-
             append_lifecycle_inputs(binding, fact, consumed_inputs, channel, now) do
        {:ok,
         %{
           status: :accepted,
           tombstone: tombstone,
           deleted_mirror_entries: deleted_count,
           canceled_actor_inputs: canceled_count,
           lifecycle_inputs: lifecycle_inputs
         }}
      end
    end)
  end

  defp normalize_entry_fact(%SignalBinding{} = binding, input, now) do
    with {:ok, ingress_event_id} <- required_text(input, :ingress_event_id),
         {:ok, signal_channel_id} <- required_text(input, :signal_channel_id),
         {:ok, provider_entry_id} <- required_text(input, :provider_entry_id),
         {:ok, attachments} <- normalize_attachments(input) do
      channel = fetch_map(input, :channel, %{})

      {:ok,
       %{
         agent_uid: binding.agent_uid,
         binding_name: binding.name,
         adapter: binding.adapter,
         ingress_event_id: ingress_event_id,
         signal_channel_id: signal_channel_id,
         provider_entry_id: provider_entry_id,
         provider_thread_id: optional_text(input, :provider_thread_id),
         channel_kind:
           normalize_channel_kind(
             fetch_value(channel, :kind) || fetch_value(input, :channel_kind)
           ),
         reply_mode:
           normalize_reply_mode(
             fetch_value(channel, :reply_mode) || fetch_value(input, :reply_mode)
           ),
         channel_name: optional_text(channel, :name) || optional_text(input, :channel_name),
         channel_title: optional_text(channel, :title) || optional_text(input, :channel_title),
         channel_visibility:
           optional_text(channel, :visibility) || optional_text(input, :channel_visibility),
         channel_metadata: fetch_map(channel, :metadata, %{}),
         channel_raw_payload: fetch_map(channel, :raw_payload, fetch_map(channel, :raw, %{})),
         text: optional_text(input, :text),
         formatted_content: fetch_map(input, :formatted_content, %{}),
         attachments: attachments,
         links: fetch_list(input, :links),
         author: fetch_map(input, :author, %{}),
         mentions: normalize_mentions(fetch_list(input, :mentions)),
         metadata: fetch_map(input, :metadata, %{}),
         raw_payload: fetch_map(input, :raw_payload, fetch_map(input, :raw, %{})),
         provider_time: fetch_datetime(input, :provider_time),
         explicit?:
           truthy?(fetch_value(input, :explicit)) ||
             structured_agent_mention?(input, binding.agent_uid),
         mirror_only?: truthy?(fetch_value(input, :mirror_only)),
         actor_input_type: optional_text(input, :actor_input_type),
         command_prefixes: fetch_list(input, :structured_mention_prefixes),
         sender_key: sender_key(input),
         gateway_time: now
       }}
    end
  end

  defp normalize_lifecycle_fact(%SignalBinding{} = binding, input, kind, now) do
    with {:ok, ingress_event_id} <- required_text(input, :ingress_event_id),
         {:ok, signal_channel_id} <- required_text(input, :signal_channel_id),
         {:ok, provider_entry_id} <- required_text(input, :provider_entry_id) do
      channel = fetch_map(input, :channel, %{})

      {:ok,
       %{
         agent_uid: binding.agent_uid,
         binding_name: binding.name,
         adapter: binding.adapter,
         ingress_event_id: ingress_event_id,
         signal_channel_id: signal_channel_id,
         provider_entry_id: provider_entry_id,
         provider_thread_id: optional_text(input, :provider_thread_id),
         channel_kind:
           normalize_channel_kind(
             fetch_value(channel, :kind) || fetch_value(input, :channel_kind)
           ),
         reply_mode:
           normalize_reply_mode(
             fetch_value(channel, :reply_mode) || fetch_value(input, :reply_mode)
           ),
         channel_name: optional_text(channel, :name) || optional_text(input, :channel_name),
         channel_title: optional_text(channel, :title) || optional_text(input, :channel_title),
         channel_visibility:
           optional_text(channel, :visibility) || optional_text(input, :channel_visibility),
         channel_metadata: fetch_map(channel, :metadata, %{}),
         channel_raw_payload: fetch_map(channel, :raw_payload, fetch_map(channel, :raw, %{})),
         metadata: fetch_map(input, :metadata, %{}),
         raw_payload: fetch_map(input, :raw_payload, fetch_map(input, :raw, %{})),
         provider_time: fetch_datetime(input, :provider_time),
         lifecycle_kind: kind,
         gateway_time: now
       }}
    end
  end

  defp normalize_reaction_fact(%SignalBinding{} = binding, input, now) do
    with {:ok, signal_channel_id} <- required_text(input, :signal_channel_id),
         {:ok, provider_entry_id} <- required_text(input, :provider_entry_id),
         {:ok, reaction_key} <- required_text(input, :reaction_key),
         {:ok, actor_key} <- required_text(input, :actor_key) do
      {:ok,
       %{
         agent_uid: binding.agent_uid,
         binding_name: binding.name,
         adapter: binding.adapter,
         ingress_event_id: optional_text(input, :ingress_event_id),
         signal_channel_id: signal_channel_id,
         provider_entry_id: provider_entry_id,
         reaction_key: reaction_key,
         actor_key: actor_key,
         action: normalize_reaction_action(fetch_value(input, :action)),
         raw_reaction_key: optional_text(input, :raw_reaction_key) || reaction_key,
         provider_time: fetch_datetime(input, :provider_time),
         gateway_time: now
       }}
    end
  end

  defp normalize_action_fact(%SignalBinding{} = binding, input, now) do
    with {:ok, ingress_event_id} <- required_text(input, :ingress_event_id),
         {:ok, session_id} <- action_session_id(input),
         {:ok, action_id} <- required_text(input, :action_id) do
      signal_channel_id = optional_text(input, :signal_channel_id)
      channel = fetch_map(input, :channel, %{})

      {:ok,
       %{
         agent_uid: binding.agent_uid,
         binding_name: binding.name,
         adapter: binding.adapter,
         ingress_event_id: ingress_event_id,
         action_id: action_id,
         session_id: session_id,
         signal_channel_id: signal_channel_id,
         provider_entry_id: optional_text(input, :provider_entry_id),
         provider_thread_id: optional_text(input, :provider_thread_id),
         sender_key: nil,
         channel_kind:
           normalize_channel_kind(
             fetch_value(channel, :kind) || fetch_value(input, :channel_kind)
           ),
         reply_mode:
           normalize_reply_mode(
             fetch_value(channel, :reply_mode) || fetch_value(input, :reply_mode)
           ),
         channel_name: optional_text(channel, :name) || optional_text(input, :channel_name),
         channel_title: optional_text(channel, :title) || optional_text(input, :channel_title),
         channel_visibility:
           optional_text(channel, :visibility) || optional_text(input, :channel_visibility),
         channel_metadata: fetch_map(channel, :metadata, %{}),
         channel_raw_payload: fetch_map(channel, :raw_payload, fetch_map(channel, :raw, %{})),
         actor_input_type: optional_text(input, :actor_input_type) || "signal.action.invoked",
         action: fetch_map(input, :action, input),
         raw_payload: fetch_map(input, :raw_payload, fetch_map(input, :raw, %{})),
         gateway_time: now
       }}
    end
  end

  defp normalize_internal_fact(%SignalBinding{} = binding, input, now) do
    with {:ok, ingress_event_id} <- required_text(input, :ingress_event_id),
         {:ok, session_id} <- required_text(input, :session_id) do
      actor_input_type =
        optional_text(input, :actor_input_type) || optional_text(input, :type) || "timer.fired"

      {:ok,
       %{
         agent_uid: binding.agent_uid,
         binding_name: binding.name,
         adapter: binding.adapter,
         ingress_event_id: ingress_event_id,
         session_id: session_id,
         signal_channel_id: nil,
         provider_entry_id: nil,
         provider_thread_id: nil,
         sender_key: nil,
         actor_input_type: actor_input_type,
         timer_id: optional_text(input, :timer_id),
         internal_subject: optional_text(input, :subject),
         internal: fetch_map(input, :internal, input),
         raw_payload: fetch_map(input, :raw_payload, fetch_map(input, :raw, %{})),
         gateway_time: now
       }}
    end
  end

  defp entry_policy(%SignalBinding{} = binding, fact, options) do
    cond do
      fact.mirror_only? ->
        {:ok, :record_only}

      command = command_payload(fact) ->
        {:ok, {:actor_input, "command.#{command["name"]}", command}}

      fact.actor_input_type ->
        {:ok, {:actor_input, fact.actor_input_type, nil}}

      explicit_im_entry?(fact) ->
        {:ok, {:actor_input, "im.message.addressed", nil}}

      clarify_reply?(binding, fact, options) ->
        {:ok, {:actor_input, "im.message.addressed", nil}}

      fact.channel_kind == :im_group ->
        group_policy(binding.unaddressed_group_message_policy)

      true ->
        {:error, :missing_actor_input_type}
    end
  end

  defp group_policy(:ignore), do: {:ok, :ignore}
  defp group_policy(:record_only), do: {:ok, :record_only}
  defp group_policy(:may_intervene), do: {:ok, {:actor_input, "im.message.may_intervene", nil}}

  defp explicit_im_entry?(%{channel_kind: :im_dm}), do: true
  defp explicit_im_entry?(%{channel_kind: :im_group, explicit?: true}), do: true
  defp explicit_im_entry?(_fact), do: false

  defp clarify_reply?(_binding, %{channel_kind: channel_kind}, _options)
       when channel_kind != :im_group,
       do: false

  defp clarify_reply?(_binding, %{text: text}, _options) when not is_binary(text), do: false

  defp clarify_reply?(binding, fact, options) do
    case Keyword.get(options, :clarify_lookup) do
      lookup when is_function(lookup, 2) -> lookup.(binding, fact) == true
      lookup when is_function(lookup, 1) -> lookup.(fact) == true
      _lookup -> false
    end
  end

  defp command_payload(fact) do
    case explicit_im_entry?(fact) do
      true ->
        case Commands.classify(fact.text,
               strip_leading_structured_mention: fact.explicit?,
               structured_mention_prefixes: fact.command_prefixes
             ) do
          {:ok, command} -> command
          :not_command -> nil
        end

      false ->
        nil
    end
  end

  defp apply_entry_policy(_repo, _binding, _fact, :ignore, _now) do
    {:ok, %{status: :ignored}}
  end

  defp apply_entry_policy(repo, _binding, fact, :record_only, now) do
    with {:ok, channel} <- upsert_channel(repo, fact, now),
         {:ok, entry} <- mirror_receive_entry(repo, fact, now) do
      {:ok, %{status: :recorded, signal_channel: channel, signal_entry: entry}}
    end
  end

  defp apply_entry_policy(repo, binding, fact, {:actor_input, type, command_payload}, now) do
    fact = Map.put(fact, :command_payload, command_payload)

    with {:ok, channel} <- upsert_channel(repo, fact, now),
         {:ok, entry} <- mirror_receive_entry(repo, fact, now),
         {:ok, actor_input} <- append_actor_input(binding, fact, type, channel, entry, now),
         :ok <- refresh_batch_readiness(type, fact, actor_input) do
      {:ok,
       %{
         status: :accepted,
         signal_channel: channel,
         signal_entry: entry,
         actor_input: actor_input
       }}
    end
  end

  defp maybe_upsert_channel(_repo, %{signal_channel_id: nil}, _now), do: {:ok, nil}
  defp maybe_upsert_channel(repo, fact, now), do: upsert_channel(repo, fact, now)

  defp upsert_channel(repo, fact, now) do
    attrs = %{
      id: fact.signal_channel_id,
      kind: fact.channel_kind,
      reply_mode: fact.reply_mode,
      name: fact.channel_name,
      title: fact.channel_title,
      visibility: fact.channel_visibility,
      metadata: fact.channel_metadata,
      raw_payload: fact.channel_raw_payload,
      first_seen_at: now,
      last_seen_at: now
    }

    case repo.get(SignalChannel, fact.signal_channel_id) do
      %SignalChannel{} = channel ->
        channel
        |> SignalChannel.changeset(merge_channel_attrs(channel, attrs))
        |> repo.update()

      nil ->
        %SignalChannel{}
        |> SignalChannel.changeset(attrs)
        |> repo.insert()
    end
  end

  defp merge_channel_attrs(%SignalChannel{} = channel, attrs) do
    %{
      attrs
      | kind: preserve_enum(attrs.kind, :unknown, channel.kind),
        reply_mode: preserve_enum(attrs.reply_mode, :none, channel.reply_mode),
        name: attrs.name || channel.name,
        title: attrs.title || channel.title,
        visibility: attrs.visibility || channel.visibility,
        metadata: preserve_empty_map(attrs.metadata, channel.metadata),
        raw_payload: preserve_empty_map(attrs.raw_payload, channel.raw_payload),
        first_seen_at: channel.first_seen_at
    }
  end

  defp preserve_enum(incoming, sparse_value, existing) when incoming == sparse_value, do: existing
  defp preserve_enum(incoming, _sparse_value, _existing), do: incoming

  defp preserve_empty_map(map, existing) when map == %{}, do: existing || %{}
  defp preserve_empty_map(map, _existing), do: map

  defp mirror_receive_entry(repo, fact, now) do
    with :ok <- lock_entry(repo, fact) do
      attrs = receive_entry_attrs(fact, now)

      case repo.get_by(SignalEntry,
             signal_channel_id: fact.signal_channel_id,
             provider_entry_id: fact.provider_entry_id
           ) do
        %SignalEntry{} = entry ->
          case stale_provider_time?(entry.provider_time, fact.provider_time) do
            true ->
              {:ok, entry}

            false ->
              entry
              |> SignalEntry.changeset(%{
                attrs
                | first_seen_at: entry.first_seen_at,
                  reactions: entry.reactions || %{},
                  raw_reaction_keys: entry.raw_reaction_keys || %{}
              })
              |> repo.update()
          end

        nil ->
          %SignalEntry{}
          |> SignalEntry.changeset(attrs)
          |> repo.insert()
      end
    end
  end

  defp receive_entry_attrs(fact, now) do
    search_text = Map.get(fact, :text) || Map.get(fact, :fallback_visible_text)
    metadata_text = metadata_text(fact)

    %{
      signal_channel_id: fact.signal_channel_id,
      provider_entry_id: fact.provider_entry_id,
      text: fact.text,
      formatted_content: fact.formatted_content,
      attachments: fact.attachments,
      links: fact.links,
      author: fact.author,
      mentions: fact.mentions,
      metadata: signal_entry_metadata(fact),
      raw_payload: fact.raw_payload,
      provider_time: fact.provider_time,
      fallback_visible_text: fact.text,
      reactions: %{},
      raw_reaction_keys: %{},
      document_id: document_id(fact.signal_channel_id, fact.provider_entry_id),
      search_text: search_text,
      metadata_text: metadata_text,
      content_hash:
        content_hash([
          search_text,
          metadata_text,
          fact.formatted_content,
          fact.attachments,
          fact.links
        ]),
      first_seen_at: now,
      last_seen_at: now
    }
  end

  defp append_actor_input(binding, fact, type, channel, entry, now) do
    session_id = Map.get(fact, :session_id) || signal_session_id(fact.signal_channel_id)
    readiness = ActorInputTypes.readiness(type, actor_readiness_input(binding, fact), now)

    attrs = %{
      agent_uid: binding.agent_uid,
      binding_name: binding.name,
      session_id: session_id,
      ingress_event_id: fact.ingress_event_id,
      signal_channel_id: fact.signal_channel_id,
      provider_thread_id: fact.provider_thread_id,
      provider_entry_id: fact.provider_entry_id,
      type: type,
      available_at: readiness.available_at,
      batch_scope: readiness.batch_scope,
      sender_key: readiness.sender_key
    }

    payload =
      binding
      |> actor_envelope(fact, type, channel, entry, now)
      |> maybe_ambient_batch_payload(type, attrs, now)

    attrs = Map.put(attrs, :payload, payload)

    case type do
      "im.message.may_intervene" -> append_or_merge_ambient_input(attrs, payload, now)
      _type -> Actors.append_actor_input(attrs)
    end
  end

  defp append_or_merge_ambient_input(attrs, event_payload, now) do
    case Repo.get_by(ActorInput,
           agent_uid: attrs.agent_uid,
           binding_name: attrs.binding_name,
           ingress_event_id: attrs.ingress_event_id
         ) do
      %ActorInput{} = input ->
        {:ok, input}

      nil ->
        case open_ambient_batch_input(attrs) do
          %ActorInput{} = input -> merge_ambient_input(input, attrs, event_payload, now)
          nil -> Actors.append_actor_input(attrs)
        end
    end
  end

  defp open_ambient_batch_input(attrs) do
    ActorInput
    |> where([input], input.agent_uid == ^attrs.agent_uid)
    |> where([input], input.binding_name == ^attrs.binding_name)
    |> where([input], input.session_id == ^attrs.session_id)
    |> where([input], input.signal_channel_id == ^attrs.signal_channel_id)
    |> where_provider_thread(attrs.provider_thread_id)
    |> where([input], input.type == "im.message.may_intervene")
    |> where([input], input.input_state == "open")
    |> order_by([input], asc: input.broker_sequence)
    |> limit(1)
    |> Repo.one()
  end

  defp merge_ambient_input(%ActorInput{} = input, attrs, event_payload, now) do
    payload = append_ambient_batch_event(input.payload || %{}, attrs, event_payload, now)

    input
    |> ActorInput.changeset(%{
      available_at: attrs.available_at,
      payload: payload
    })
    |> Repo.update()
  end

  defp maybe_ambient_batch_payload(payload, "im.message.may_intervene", attrs, now) do
    refresh_ambient_batch_payload(payload, attrs, [ambient_batch_entry(payload)], now)
  end

  defp maybe_ambient_batch_payload(payload, _type, _attrs, _now), do: payload

  defp append_ambient_batch_event(payload, attrs, event_payload, now) do
    entries =
      payload
      |> get_in(["data", "entries"])
      |> case do
        values when is_list(values) -> values
        _value -> [ambient_batch_entry(payload)]
      end
      |> Kernel.++([ambient_batch_entry(event_payload)])
      |> Enum.uniq_by(& &1["provider_entry_id"])

    refresh_ambient_batch_payload(payload, attrs, entries, now)
  end

  defp refresh_ambient_batch_payload(payload, attrs, entries, now) do
    payload
    |> put_in(["data", "entry"], batch_entry_summary(entries))
    |> put_in(["data", "entries"], entries)
    |> put_in(["data", "observed_messages"], ambient_observed_messages(attrs, entries))
    |> put_in(["data", "ambient_batch"], %{
      "size" => length(entries),
      "first_provider_entry_id" => entries |> List.first() |> Map.get("provider_entry_id"),
      "last_provider_entry_id" => entries |> List.last() |> Map.get("provider_entry_id"),
      "updated_at" => DateTime.to_iso8601(now)
    })
  end

  defp ambient_batch_entry(payload) do
    entry = get_in(payload, ["data", "entry"]) || %{}

    %{
      "signal_channel_id" => entry["signal_channel_id"],
      "provider_entry_id" => entry["provider_entry_id"],
      "provider_thread_id" => entry["provider_thread_id"],
      "text" => entry["text"],
      "author" => entry["author"],
      "sent_at" => entry["provider_time"] || payload["time"],
      "time" => entry["provider_time"] || payload["time"]
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp batch_entry_summary(entries) do
    text =
      entries
      |> Enum.map(& &1["text"])
      |> Enum.filter(&is_binary/1)
      |> Enum.join("\n")

    entries
    |> List.last()
    |> Kernel.||(%{})
    |> Map.put("text", text)
  end

  # Ambient recognition needs the room scene, not just the events that happened
  # to reach this gateway instance. We therefore snapshot the channel mirror for
  # the micro-batch boundary while the batch is being merged. The worker consumes
  # this immutable view and does not run a second DB recall path.
  defp ambient_observed_messages(attrs, entries) do
    case ambient_batch_boundary(attrs, entries) do
      nil ->
        entries
        |> Enum.map(&ambient_observed_message_from_entry/1)
        |> Enum.reject(&is_nil/1)

      boundary ->
        attrs
        |> recall_signal_observed_messages(boundary)
        |> Kernel.++(recall_conversation_observed_messages(attrs, boundary))
        |> Kernel.++(Enum.map(entries, &ambient_observed_message_from_entry/1))
        |> Enum.reject(&is_nil/1)
        |> dedupe_ambient_observed_messages()
        |> Enum.sort_by(&ambient_observed_sort_key/1)
        |> Enum.take(@ambient_recall_max_rows)
    end
  end

  defp ambient_batch_boundary(attrs, entries) do
    times =
      entries
      |> Enum.flat_map(fn entry ->
        case parse_iso8601(entry["sent_at"] || entry["time"]) do
          %DateTime{} = sent_at -> [sent_at]
          nil -> []
        end
      end)

    signal_channel_id =
      entries
      |> Enum.map(& &1["signal_channel_id"])
      |> Enum.find(&is_binary/1) ||
        attrs.signal_channel_id

    case {signal_channel_id, times} do
      {channel_id, [_ | _]} when is_binary(channel_id) ->
        %{
          signal_channel_id: channel_id,
          provider_thread_id: attrs.provider_thread_id,
          start_at: Enum.min_by(times, &DateTime.to_unix(&1, :microsecond)),
          end_at: Enum.max_by(times, &DateTime.to_unix(&1, :microsecond))
        }

      _value ->
        nil
    end
  end

  defp recall_signal_observed_messages(attrs, boundary) do
    SignalEntry
    |> where([entry], entry.signal_channel_id == ^boundary.signal_channel_id)
    |> where(
      [entry],
      fragment(
        "COALESCE(?, ?, ?) >= ?",
        entry.provider_time,
        entry.last_seen_at,
        entry.inserted_at,
        ^boundary.start_at
      )
    )
    |> where(
      [entry],
      fragment(
        "COALESCE(?, ?, ?) <= ?",
        entry.provider_time,
        entry.last_seen_at,
        entry.inserted_at,
        ^boundary.end_at
      )
    )
    |> order_by([entry],
      asc:
        fragment("COALESCE(?, ?, ?)", entry.provider_time, entry.last_seen_at, entry.inserted_at)
    )
    |> limit(@ambient_recall_max_rows)
    |> Repo.all()
    |> Enum.filter(&same_provider_thread?(&1, boundary.provider_thread_id))
    |> Enum.map(&ambient_observed_message_from_signal_entry(&1, attrs.provider_thread_id))
  end

  defp recall_conversation_observed_messages(attrs, boundary) do
    with %Conversation{} = conversation <- active_conversation(attrs.agent_uid, attrs.session_id) do
      Message
      |> where([message], message.conversation_id == ^conversation.id)
      |> where([message], message.role in ["assistant", "tool", "im_ambient"])
      |> where([message], message.inserted_at >= ^boundary.start_at)
      |> where([message], message.inserted_at <= ^boundary.end_at)
      |> order_by([message], asc: message.inserted_at)
      |> limit(@ambient_recall_max_rows)
      |> Repo.all()
      |> Enum.filter(&message_in_ambient_boundary?(&1, boundary))
      |> Enum.map(&ambient_observed_message_from_conversation/1)
    else
      nil -> []
    end
  end

  defp active_conversation(agent_uid, session_id) do
    Conversation
    |> where([conversation], conversation.agent_uid == ^normalize_uid(agent_uid))
    |> where([conversation], conversation.conversation_key == ^session_id)
    |> where([conversation], is_nil(conversation.ended_at))
    |> Repo.one()
  end

  defp message_in_ambient_boundary?(%Message{} = message, boundary) do
    with true <- message_signal_channel_id(message) == boundary.signal_channel_id,
         true <- message_provider_thread_matches?(message, boundary.provider_thread_id),
         %DateTime{} = sent_at <- message_sent_at(message) do
      DateTime.compare(sent_at, boundary.start_at) != :lt and
        DateTime.compare(sent_at, boundary.end_at) != :gt
    else
      _value -> false
    end
  end

  defp same_provider_thread?(_entry, nil), do: true

  defp same_provider_thread?(%SignalEntry{} = entry, provider_thread_id) do
    case signal_entry_provider_thread_id(entry) do
      nil -> true
      ^provider_thread_id -> true
      _other -> false
    end
  end

  defp message_provider_thread_matches?(_message, nil), do: true

  defp message_provider_thread_matches?(%Message{} = message, provider_thread_id) do
    case message_provider_thread_id(message) do
      nil -> true
      ^provider_thread_id -> true
      _other -> false
    end
  end

  defp ambient_observed_message_from_entry(entry) when is_map(entry) do
    text = optional_text(entry, :text)
    sent_at = optional_text(entry, :sent_at) || optional_text(entry, :time)

    case {text, sent_at} do
      {text, sent_at} when is_binary(text) and is_binary(sent_at) ->
        %{
          "id" => "batch:#{entry["provider_entry_id"] || :erlang.phash2(entry)}",
          "source" => "ambient_batch",
          "role" => "ambient_human",
          "kind" => "normal",
          "speaker" => speaker_name(entry["author"]),
          "sent_at" => sent_at,
          "text" => text,
          "signal_channel_id" => entry["signal_channel_id"],
          "provider_entry_id" => entry["provider_entry_id"],
          "provider_thread_id" => entry["provider_thread_id"]
        }
        |> Enum.reject(fn {_key, value} -> is_nil(value) end)
        |> Map.new()

      _value ->
        nil
    end
  end

  defp ambient_observed_message_from_entry(_entry), do: nil

  defp ambient_observed_message_from_signal_entry(%SignalEntry{} = entry, provider_thread_id) do
    text = entry.text || entry.fallback_visible_text

    case text do
      text when is_binary(text) ->
        %{
          "id" => "signal:#{entry.signal_channel_id}:#{entry.provider_entry_id}",
          "source" => "signal_entry",
          "role" => signal_entry_role(entry),
          "kind" => "normal",
          "speaker" => speaker_name(entry.author),
          "sent_at" => DateTime.to_iso8601(signal_entry_sent_at(entry)),
          "text" => text,
          "signal_channel_id" => entry.signal_channel_id,
          "provider_entry_id" => entry.provider_entry_id,
          "provider_thread_id" => signal_entry_provider_thread_id(entry) || provider_thread_id
        }
        |> Enum.reject(fn {_key, value} -> is_nil(value) end)
        |> Map.new()

      _value ->
        nil
    end
  end

  defp ambient_observed_message_from_conversation(%Message{} = message) do
    text = message_text(message)

    case text do
      text when is_binary(text) ->
        %{
          "id" => "conversation:#{message.id}",
          "source" => "ai_agent_messages",
          "role" => conversation_observed_role(message),
          "kind" => message.kind,
          "speaker" => message_speaker(message),
          "sent_at" => message_sent_at(message) |> DateTime.to_iso8601(),
          "text" => text,
          "signal_channel_id" => message_signal_channel_id(message),
          "provider_entry_id" => message_provider_entry_id(message),
          "provider_thread_id" => message_provider_thread_id(message)
        }
        |> Enum.reject(fn {_key, value} -> is_nil(value) end)
        |> Map.new()

      _value ->
        nil
    end
  end

  defp dedupe_ambient_observed_messages(messages) do
    messages
    |> Enum.reverse()
    |> Enum.uniq_by(fn message ->
      provider_key =
        case {message["signal_channel_id"], message["provider_entry_id"]} do
          {channel_id, entry_id} when is_binary(channel_id) and is_binary(entry_id) ->
            "#{channel_id}:#{entry_id}"

          _value ->
            nil
        end

      provider_key || message["id"]
    end)
    |> Enum.reverse()
  end

  defp ambient_observed_sort_key(message) do
    case parse_iso8601(message["sent_at"]) do
      %DateTime{} = sent_at -> DateTime.to_unix(sent_at, :microsecond)
      nil -> 0
    end
  end

  defp signal_entry_metadata(fact) do
    fact.metadata
    |> Map.put_new("provider_thread_id", Map.get(fact, :provider_thread_id))
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp signal_entry_role(%SignalEntry{author: author}) when is_map(author) do
    case optional_text(author, :agent_uid) do
      nil -> "ambient_human"
      _agent_uid -> "agent"
    end
  end

  defp signal_entry_role(_entry), do: "ambient_human"

  defp signal_entry_sent_at(%SignalEntry{provider_time: %DateTime{} = sent_at}), do: sent_at
  defp signal_entry_sent_at(%SignalEntry{last_seen_at: %DateTime{} = sent_at}), do: sent_at
  defp signal_entry_sent_at(%SignalEntry{inserted_at: %DateTime{} = sent_at}), do: sent_at
  defp signal_entry_sent_at(%SignalEntry{first_seen_at: %DateTime{} = sent_at}), do: sent_at
  defp signal_entry_sent_at(_entry), do: DateTime.utc_now(:microsecond)

  defp signal_entry_provider_thread_id(%SignalEntry{} = entry) do
    optional_text(entry.metadata || %{}, :provider_thread_id) ||
      optional_text(entry.raw_payload || %{}, :provider_thread_id)
  end

  defp conversation_observed_role(%Message{role: "assistant"}), do: "agent"
  defp conversation_observed_role(%Message{role: "tool"}), do: "tool"

  defp conversation_observed_role(%Message{role: "im_ambient", kind: "introspection"}),
    do: "runtime"

  defp conversation_observed_role(%Message{role: "im_ambient"}), do: "ambient_human"
  defp conversation_observed_role(%Message{}), do: "human"

  defp message_speaker(%Message{role: "assistant", agent_uid: agent_uid}), do: agent_uid
  defp message_speaker(%Message{role: "tool"}), do: "tool"

  defp message_speaker(%Message{role: "im_ambient", kind: "introspection"}),
    do: "Ankole runtime"

  defp message_speaker(%Message{metadata: metadata}) do
    speaker_name(
      get_in(metadata || %{}, ["message_context", "actor"]) ||
        Map.get(metadata || %{}, "actor")
    )
  end

  defp message_text(%Message{content: content}) when is_list(content) do
    content
    |> Enum.flat_map(fn
      text when is_binary(text) -> [text]
      %{"text" => text} when is_binary(text) -> [text]
      %{text: text} when is_binary(text) -> [text]
      _block -> []
    end)
    |> Enum.join("\n")
    |> String.trim()
    |> case do
      "" -> nil
      text -> text
    end
  end

  defp message_text(_message), do: nil

  defp message_signal_channel_id(%Message{metadata: metadata}) do
    metadata = metadata || %{}

    optional_text(metadata, :signal_channel_id) ||
      get_in(metadata, ["provider_refs", "room_id"]) ||
      get_in(metadata, ["route", "provider_room_id"]) ||
      get_in(metadata, ["message_context", "room", "id"])
  end

  defp message_provider_entry_id(%Message{metadata: metadata}) do
    metadata = metadata || %{}

    optional_text(metadata, :provider_entry_id) ||
      get_in(metadata, ["provider_refs", "provider_message_id"])
  end

  defp message_provider_thread_id(%Message{metadata: metadata}) do
    metadata = metadata || %{}

    optional_text(metadata, :provider_thread_id) ||
      get_in(metadata, ["provider_refs", "thread_id"]) ||
      get_in(metadata, ["route", "provider_thread_id"])
  end

  defp message_sent_at(%Message{metadata: metadata, inserted_at: inserted_at}) do
    metadata_sent_at = get_in(metadata || %{}, ["message_context", "time", "sent_at"])

    parse_iso8601(metadata_sent_at) || inserted_at || DateTime.utc_now(:microsecond)
  end

  defp speaker_name(author) when is_map(author) do
    optional_text(author, :display_name) ||
      optional_text(author, :fullName) ||
      optional_text(author, :userName) ||
      optional_text(author, :name) ||
      optional_text(author, :principal_uid) ||
      optional_text(author, :agent_uid) ||
      "unknown speaker"
  end

  defp speaker_name(_author), do: "unknown speaker"

  defp parse_iso8601(%DateTime{} = datetime), do: datetime

  defp parse_iso8601(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> datetime
      _error -> nil
    end
  end

  defp parse_iso8601(_value), do: nil

  defp actor_readiness_input(binding, fact) do
    %{
      binding_name: binding.name,
      signal_channel_id: fact.signal_channel_id,
      provider_thread_id: fact.provider_thread_id,
      sender_key: Map.get(fact, :sender_key)
    }
  end

  defp refresh_batch_readiness("im.message.addressed", fact, %ActorInput{} = actor_input) do
    ActorInput
    |> where([input], input.agent_uid == ^fact.agent_uid)
    |> where([input], input.binding_name == ^fact.binding_name)
    |> where([input], input.signal_channel_id == ^fact.signal_channel_id)
    |> where_provider_thread(fact.provider_thread_id)
    |> where([input], input.type == "im.message.addressed")
    |> Repo.update_all(set: [available_at: actor_input.available_at])

    :ok
  end

  defp refresh_batch_readiness("im.message.may_intervene", fact, %ActorInput{} = actor_input) do
    due_at = ambient_due_at(fact, actor_input)

    ActorInput
    |> where([input], input.agent_uid == ^fact.agent_uid)
    |> where([input], input.binding_name == ^fact.binding_name)
    |> where([input], input.signal_channel_id == ^fact.signal_channel_id)
    |> where_provider_thread(fact.provider_thread_id)
    |> where([input], input.type == "im.message.may_intervene")
    |> where([input], input.input_state == "open")
    |> Repo.update_all(set: [available_at: due_at])

    :ok
  end

  defp refresh_batch_readiness(_type, _fact, _actor_input), do: :ok

  # Mirrors BullX's ambient debounce without introducing Redis: every new room
  # observation slides the PG queue wake forward by the batch window, bounded by
  # the oldest unprocessed row so a busy room cannot postpone recognition forever.
  defp ambient_due_at(fact, %ActorInput{} = actor_input) do
    oldest_inserted_at =
      ActorInput
      |> where([input], input.agent_uid == ^fact.agent_uid)
      |> where([input], input.binding_name == ^fact.binding_name)
      |> where([input], input.signal_channel_id == ^fact.signal_channel_id)
      |> where_provider_thread(fact.provider_thread_id)
      |> where([input], input.type == "im.message.may_intervene")
      |> where([input], input.input_state == "open")
      |> select([input], min(input.inserted_at))
      |> Repo.one()

    sliding_due_at = actor_input.available_at

    hard_cap_at =
      case oldest_inserted_at || actor_input.inserted_at do
        %DateTime{} = inserted_at -> DateTime.add(inserted_at, @ambient_hard_cap_ms, :millisecond)
        _value -> actor_input.available_at
      end

    min_datetime(sliding_due_at, hard_cap_at)
  end

  defp min_datetime(%DateTime{} = left, %DateTime{} = right) do
    case DateTime.compare(left, right) do
      :gt -> right
      _other -> left
    end
  end

  defp actor_envelope(binding, fact, type, channel, entry, now) do
    data =
      %{
        "session" => %{
          "agent_uid" => binding.agent_uid,
          "session_id" => Map.get(fact, :session_id) || signal_session_id(fact.signal_channel_id),
          "binding_name" => binding.name
        },
        "channel" => channel_payload(channel),
        "entry" => entry_payload(entry || fact, fact),
        "mentions" => Map.get(fact, :mentions),
        "raw" => Map.get(fact, :raw_payload),
        "command" => Map.get(fact, :command_payload),
        "action" => Map.get(fact, :action),
        "internal" => Map.get(fact, :internal)
      }
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)
      |> Map.new()

    %{
      "specversion" => "1.0",
      "id" => fact.ingress_event_id,
      "source" => envelope_source(binding, fact),
      "subject" => envelope_subject(fact),
      "time" => DateTime.to_iso8601(now),
      "type" => type,
      "data" => data
    }
  end

  defp channel_payload(nil), do: nil

  defp channel_payload(%SignalChannel{} = channel) do
    %{
      "id" => channel.id,
      "kind" => Atom.to_string(channel.kind),
      "reply_mode" => Atom.to_string(channel.reply_mode),
      "name" => channel.name,
      "title" => channel.title,
      "visibility" => channel.visibility
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp entry_payload(%SignalEntry{} = entry, fact) do
    %{
      "signal_channel_id" => entry.signal_channel_id,
      "provider_entry_id" => entry.provider_entry_id,
      "provider_thread_id" => Map.get(fact, :provider_thread_id),
      "text" => entry.text,
      "attachments" => entry.attachments,
      "links" => entry.links,
      "author" => entry.author,
      "document_id" => entry.document_id,
      "provider_time" => datetime_iso8601(entry.provider_time)
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp entry_payload(fact, _fact_context) when is_map(fact) do
    %{
      "signal_channel_id" => Map.get(fact, :signal_channel_id),
      "provider_entry_id" => Map.get(fact, :provider_entry_id),
      "provider_thread_id" => Map.get(fact, :provider_thread_id),
      "text" => Map.get(fact, :text),
      "provider_time" => datetime_iso8601(Map.get(fact, :provider_time))
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp envelope_source(binding, %{signal_channel_id: nil, session_id: session_id}) do
    "internal://#{binding.name}/#{session_id}"
  end

  defp envelope_source(binding, fact) do
    "signal://#{binding.adapter}/#{URI.encode_www_form(fact.signal_channel_id)}"
  end

  defp envelope_subject(%{action_id: action_id}) when is_binary(action_id),
    do: "signal_actions:#{action_id}"

  defp envelope_subject(%{timer_id: timer_id}) when is_binary(timer_id),
    do: "timers:#{timer_id}"

  defp envelope_subject(%{internal_subject: subject}) when is_binary(subject), do: subject

  defp envelope_subject(%{provider_entry_id: provider_entry_id})
       when is_binary(provider_entry_id), do: "signal_entries:#{provider_entry_id}"

  defp envelope_subject(_fact), do: nil

  defp datetime_iso8601(%DateTime{} = datetime), do: DateTime.to_iso8601(datetime)
  defp datetime_iso8601(_value), do: nil

  defp upsert_tombstone(repo, fact, _kind, now) do
    attrs = %{
      agent_uid: fact.agent_uid,
      binding_name: fact.binding_name,
      signal_channel_id: fact.signal_channel_id,
      provider_entry_id: fact.provider_entry_id,
      tombstoned_until: DateTime.add(now, @tombstone_ttl_seconds, :second)
    }

    case repo.get_by(InputTombstone,
           agent_uid: fact.agent_uid,
           binding_name: fact.binding_name,
           signal_channel_id: fact.signal_channel_id,
           provider_entry_id: fact.provider_entry_id
         ) do
      %InputTombstone{} = tombstone ->
        tombstone
        |> InputTombstone.changeset(attrs)
        |> repo.update()

      nil ->
        %InputTombstone{}
        |> InputTombstone.changeset(attrs)
        |> repo.insert()
    end
  end

  defp active_tombstone?(repo, fact, now) do
    case repo.get_by(InputTombstone,
           agent_uid: fact.agent_uid,
           binding_name: fact.binding_name,
           signal_channel_id: fact.signal_channel_id,
           provider_entry_id: fact.provider_entry_id
         ) do
      %InputTombstone{tombstoned_until: tombstoned_until} ->
        case DateTime.compare(tombstoned_until, now) do
          :gt -> true
          _other -> false
        end

      nil ->
        false
    end
  end

  defp delete_mirror_entry(repo, fact) do
    SignalEntry
    |> where([entry], entry.signal_channel_id == ^fact.signal_channel_id)
    |> where([entry], entry.provider_entry_id == ^fact.provider_entry_id)
    |> repo.delete_all()
  end

  defp append_lifecycle_inputs(_binding, _fact, [], _channel, _now), do: {:ok, []}

  defp append_lifecycle_inputs(binding, fact, consumed_inputs, channel, now) do
    type =
      case fact.lifecycle_kind do
        :deleted -> "signal.entry.deleted"
        :recalled -> "signal.entry.recalled"
      end

    consumed_inputs
    |> Enum.map(fn consumed_input ->
      lifecycle_fact =
        fact
        |> Map.put(:session_id, consumed_input.session_id)
        |> Map.put(:provider_thread_id, consumed_input.provider_thread_id)
        |> Map.put(:metadata, Map.get(fact, :metadata, %{}))
        |> Map.put(:text, nil)
        |> Map.put(:mentions, [])
        |> Map.put(:command_payload, nil)
        |> Map.put(:action, nil)

      append_actor_input(binding, lifecycle_fact, type, channel, nil, now)
    end)
    |> collect_results()
  end

  defp reaction_entry_attrs(%SignalEntry{} = entry, fact, now) do
    {reactions, raw_reaction_keys} =
      update_reactions(
        entry.reactions || %{},
        entry.raw_reaction_keys || %{},
        fact.action,
        fact.reaction_key,
        fact.actor_key,
        fact.raw_reaction_key
      )

    %{
      reactions: reactions,
      raw_reaction_keys: raw_reaction_keys,
      last_seen_at: now
    }
  end

  defp update_reactions(
         reactions,
         raw_reaction_keys,
         :add,
         reaction_key,
         actor_key,
         raw_reaction_key
       ) do
    actors =
      reactions
      |> Map.get(reaction_key, [])
      |> List.wrap()
      |> MapSet.new()
      |> MapSet.put(actor_key)
      |> MapSet.to_list()
      |> Enum.sort()

    {
      Map.put(reactions, reaction_key, actors),
      Map.put(raw_reaction_keys, reaction_key, raw_reaction_key)
    }
  end

  defp update_reactions(
         reactions,
         raw_reaction_keys,
         :remove,
         reaction_key,
         actor_key,
         raw_reaction_key
       ) do
    actors =
      reactions
      |> Map.get(reaction_key, [])
      |> List.wrap()
      |> MapSet.new()
      |> MapSet.delete(actor_key)
      |> MapSet.to_list()
      |> Enum.sort()

    next_reactions =
      case actors do
        [] -> Map.delete(reactions, reaction_key)
        [_ | _] -> Map.put(reactions, reaction_key, actors)
      end

    {
      next_reactions,
      Map.put(raw_reaction_keys, reaction_key, raw_reaction_key)
    }
  end

  defp reaction_result({:ok, entry}), do: {:ok, %{status: :mirrored, signal_entry: entry}}
  defp reaction_result({:error, _changeset} = error), do: error

  defp stale_provider_time?(%DateTime{} = stored_time, %DateTime{} = incoming_time) do
    DateTime.compare(incoming_time, stored_time) == :lt
  end

  defp stale_provider_time?(_stored_time, _incoming_time), do: false

  defp lock_entry(repo, fact) do
    key =
      Enum.join(
        [fact.signal_channel_id, fact.provider_entry_id],
        "|"
      )

    SQL.query!(repo, "SELECT pg_advisory_xact_lock(hashtext($1))", [key])
    :ok
  end

  defp default_outbox_attrs(attrs) do
    attrs
    |> Map.put_new(:status, :created)
    |> Map.put_new(:payload, %{})
    |> Map.put_new(:attempt_count, 0)
    |> Map.put_new(:max_attempts, 10)
    |> Map.put_new(:last_error, %{})
    |> Map.put_new(:recovery_state, %{})
    |> normalize_agent_uid_attr()
  end

  defp outbox_insert_result({:ok, %OutboxEntry{agent_uid: nil}}, attrs) do
    attrs = default_outbox_attrs(attrs)

    case Repo.get_by(OutboxEntry,
           agent_uid: attrs.agent_uid,
           binding_name: attrs.binding_name,
           outbound_key: attrs.outbound_key
         ) do
      %OutboxEntry{} = entry -> {:ok, entry}
      nil -> {:error, :outbox_entry_not_found}
    end
  end

  defp outbox_insert_result({:ok, %OutboxEntry{} = entry}, _attrs), do: {:ok, entry}
  defp outbox_insert_result({:error, _changeset} = error, _attrs), do: error

  defp choose_outbox_operation(
         %SignalChannel{reply_mode: :entry},
         capabilities,
         %ActorInput{provider_entry_id: provider_entry_id}
       )
       when is_binary(provider_entry_id) do
    case MapSet.member?(capabilities, "reply_entry") do
      true -> :reply
      false -> post_or_fallback(capabilities, :reply)
    end
  end

  defp choose_outbox_operation(%SignalChannel{reply_mode: mode}, capabilities, actor_input)
       when mode in [:channel, :entry] do
    post_or_fallback(capabilities, fallback_outbox_operation(actor_input))
  end

  defp choose_outbox_operation(_channel, _capabilities, actor_input) do
    fallback_outbox_operation(actor_input)
  end

  defp post_or_fallback(capabilities, fallback) do
    case MapSet.member?(capabilities, "post_entry") do
      true -> :post
      false -> fallback
    end
  end

  defp fallback_outbox_operation(%ActorInput{provider_entry_id: provider_entry_id})
       when is_binary(provider_entry_id),
       do: :reply

  defp fallback_outbox_operation(_actor_input), do: :post

  defp adapter_outbound_capabilities(adapter_id) when is_binary(adapter_id) do
    case Process.whereis(Ankole.Plugins.Registry) do
      nil ->
        MapSet.new()

      _pid ->
        "signals_gateway.adapter"
        |> Ankole.Plugins.adapter_declarations()
        |> Enum.find(fn declaration ->
          declaration[:id] == adapter_id or declaration["id"] == adapter_id
        end)
        |> case do
          nil ->
            MapSet.new()

          declaration ->
            MapSet.new(
              declaration[:outbound_capabilities] || declaration["outbound_capabilities"] || []
            )
        end
    end
  end

  defp adapter_outbound_capabilities(_adapter_id), do: MapSet.new()

  defp fetch_outbox_for_update(repo, agent_uid, binding_name, outbound_key) do
    OutboxEntry
    |> where([entry], entry.agent_uid == ^normalize_uid(agent_uid))
    |> where([entry], entry.binding_name == ^binding_name)
    |> where([entry], entry.outbound_key == ^outbound_key)
    |> lock("FOR UPDATE")
    |> repo.one()
  end

  defp dispatch_due_outbox_entry(%OutboxEntry{} = outbox, adapter_resolver, now) do
    with {:ok, adapter} <- resolve_outbox_adapter(adapter_resolver, outbox) do
      dispatch_outbox(outbox.agent_uid, outbox.binding_name, outbox.outbound_key, adapter,
        now: now
      )
    end
  end

  defp resolve_outbox_adapter(adapter_resolver, %OutboxEntry{} = outbox) do
    case adapter_resolver.(outbox) do
      {:ok, adapter} when is_map(adapter) or is_atom(adapter) -> {:ok, adapter}
      adapter when is_map(adapter) or is_atom(adapter) -> {:ok, adapter}
      {:error, _reason} = error -> error
      _other -> {:error, :invalid_outbox_adapter}
    end
  end

  defp outbox_channel(_repo, %OutboxEntry{signal_channel_id: nil}), do: {:ok, nil}

  defp outbox_channel(repo, %OutboxEntry{signal_channel_id: signal_channel_id}) do
    case repo.get(SignalChannel, signal_channel_id) do
      %SignalChannel{} = channel -> {:ok, channel}
      nil -> {:error, :signal_channel_not_found}
    end
  end

  defp prepare_fresh_outbox_dispatch(repo, outbox, channel, adapter, now) do
    with :ok <- dispatchable_outbox?(outbox, now),
         :ok <- outbox_supported?(outbox, channel, adapter),
         {:ok, sending_outbox} <- mark_outbox_sending(repo, outbox, now) do
      {:ok, {:send, sending_outbox, channel, adapter}}
    else
      {:unsupported, outbox} -> mark_outbox_unsupported(repo, outbox)
      {:error, _reason} = error -> error
    end
  end

  defp dispatchable_outbox?(%OutboxEntry{status: :created}, _now), do: :ok

  defp dispatchable_outbox?(
         %OutboxEntry{status: :failed, attempt_count: attempts, max_attempts: max},
         _now
       )
       when attempts >= max,
       do: {:error, :outbox_attempts_exhausted}

  defp dispatchable_outbox?(%OutboxEntry{status: :failed, next_attempt_at: nil}, _now),
    do: :ok

  defp dispatchable_outbox?(
         %OutboxEntry{status: :failed, next_attempt_at: %DateTime{} = next_attempt_at},
         now
       ) do
    case DateTime.compare(next_attempt_at, now) do
      :gt -> {:error, :outbox_not_due}
      _ready -> :ok
    end
  end

  defp dispatchable_outbox?(%OutboxEntry{status: :sending}, _now),
    do: {:error, :outbox_send_in_progress}

  defp dispatchable_outbox?(%OutboxEntry{}, _now), do: {:error, :outbox_not_dispatchable}

  defp outbox_supported?(%OutboxEntry{} = outbox, channel, adapter) do
    capabilities = OutboxAdapter.capabilities(adapter)

    case outbox.operation do
      :post ->
        require_channel_surface(outbox, channel, capabilities, :post_entry)

      :reply ->
        with :ok <- require_reply_surface(outbox, channel, capabilities) do
          require_text(outbox.source_provider_entry_id, outbox)
        end

      :edit ->
        require_capability_and_target(outbox, capabilities, :edit_entry)

      :delete ->
        require_capability_and_target(outbox, capabilities, :delete_entry)

      :reaction_add ->
        require_capability_and_target(outbox, capabilities, :add_reaction)

      :reaction_remove ->
        require_capability_and_target(outbox, capabilities, :remove_reaction)

      :divider ->
        with :ok <- require_fallback_text(outbox),
             :ok <- require_channel_surface(outbox, channel, capabilities, :post_entry) do
          require_capability(outbox, capabilities, :divider)
        end

      :card ->
        with :ok <- require_fallback_text(outbox),
             :ok <- require_channel_surface(outbox, channel, capabilities, :post_entry) do
          require_capability(outbox, capabilities, :card)
        end
    end
  end

  defp require_channel_surface(
         outbox,
         %SignalChannel{reply_mode: reply_mode},
         capabilities,
         capability
       )
       when reply_mode in [:channel, :entry] do
    require_capability(outbox, capabilities, capability)
  end

  defp require_channel_surface(outbox, _channel, _capabilities, _capability),
    do: {:unsupported, outbox}

  defp require_reply_surface(outbox, %SignalChannel{reply_mode: :entry}, capabilities) do
    require_capability(outbox, capabilities, :reply_entry)
  end

  defp require_reply_surface(outbox, _channel, _capabilities), do: {:unsupported, outbox}

  defp require_capability_and_target(outbox, capabilities, capability) do
    with :ok <- require_capability(outbox, capabilities, capability) do
      require_text(outbox.target_provider_entry_id, outbox)
    end
  end

  defp require_capability(outbox, capabilities, capability) do
    case MapSet.member?(capabilities, capability) do
      true -> :ok
      false -> {:unsupported, outbox}
    end
  end

  defp require_text(value, _outbox) when is_binary(value), do: :ok
  defp require_text(_value, outbox), do: {:unsupported, outbox}

  defp require_fallback_text(%OutboxEntry{fallback_visible_text: text}) when is_binary(text),
    do: :ok

  defp require_fallback_text(outbox), do: {:unsupported, outbox}

  defp in_flight_recovery_action(
         %OutboxEntry{
           status: :sending,
           platform_send_started_at: %DateTime{},
           provider_entry_id: provider_entry_id
         } = outbox,
         adapter
       )
       when is_binary(provider_entry_id) do
    capabilities = OutboxAdapter.capabilities(adapter)

    case MapSet.member?(capabilities, :outbound_reconciliation) do
      true -> {:reconcile, outbox}
      false -> {:unknown, outbox, %{"reason" => "provider send started before restart"}}
    end
  end

  defp in_flight_recovery_action(
         %OutboxEntry{status: :sending, platform_send_started_at: %DateTime{}} = outbox,
         _adapter
       ),
       do:
         {:unknown, outbox,
          %{
            "reason" => "provider send started without provider entry id"
          }}

  defp in_flight_recovery_action(_outbox, _adapter), do: :continue

  defp mark_outbox_sending(repo, outbox, now) do
    outbox
    |> OutboxEntry.changeset(%{
      status: :sending,
      platform_send_started_at: now,
      last_attempted_at: now,
      attempt_count: outbox.attempt_count + 1,
      next_attempt_at: nil
    })
    |> repo.update()
  end

  defp mark_outbox_unsupported(repo, outbox) do
    outbox
    |> OutboxEntry.changeset(%{status: :unsupported})
    |> repo.update()
  end

  defp call_adapter_send(adapter, outbox), do: OutboxAdapter.deliver(adapter, outbox)

  defp call_adapter_reconcile(adapter, outbox), do: OutboxAdapter.reconcile(adapter, outbox)

  defp finalize_outbox_send(send_result, outbox, channel, now) do
    Repo.transact(fn repo ->
      with %OutboxEntry{} = current_outbox <- fetch_outbox_for_update(repo, outbox) do
        case send_result do
          {:ok, result} ->
            with {:ok, mirrored_outbox} <- mark_outbox_succeeded(repo, current_outbox, result),
                 :ok <- mirror_outbox_success(repo, mirrored_outbox, channel, result, now) do
              {:ok, mirrored_outbox}
            end

          {:error, reason} ->
            mark_outbox_failed(repo, current_outbox, reason, now)

          :unknown ->
            mark_outbox_unknown(repo, current_outbox, %{
              "reason" => "adapter returned unknown_after_send"
            })
        end
      else
        nil -> {:error, :outbox_not_found}
      end
    end)
  end

  defp finalize_outbox_reconcile(reconcile_result, outbox, channel, now) do
    Repo.transact(fn repo ->
      with %OutboxEntry{} = current_outbox <- fetch_outbox_for_update(repo, outbox) do
        case reconcile_result do
          {:ok, result} ->
            with {:ok, recovered_outbox} <- mark_outbox_succeeded(repo, current_outbox, result),
                 :ok <- mirror_outbox_success(repo, recovered_outbox, channel, result, now) do
              {:ok, recovered_outbox}
            end

          {:error, reason} ->
            mark_outbox_unknown(repo, current_outbox, %{
              "reason" => "reconciliation adapter error",
              "error" => reason
            })

          :unknown ->
            mark_outbox_unknown(repo, current_outbox, %{
              "reason" => "reconciliation could not confirm provider send"
            })
        end
      else
        nil -> {:error, :outbox_not_found}
      end
    end)
  end

  defp fetch_outbox_for_update(repo, %OutboxEntry{} = outbox) do
    fetch_outbox_for_update(repo, outbox.agent_uid, outbox.binding_name, outbox.outbound_key)
  end

  defp mark_outbox_succeeded(repo, outbox, result) do
    recovery_state = fetch_value(result, :recovery_state) || %{}

    with {:ok, recovery_state} <-
           JsonPayload.normalize_map(recovery_state, allow_datetime: true) do
      outbox
      |> OutboxEntry.changeset(%{
        status: :succeeded,
        provider_entry_id: provider_entry_id_after_success(outbox, result),
        last_error: %{},
        next_attempt_at: nil,
        recovery_state: recovery_state
      })
      |> repo.update()
    end
  end

  defp mark_outbox_failed(repo, outbox, reason, now) do
    outbox
    |> OutboxEntry.changeset(%{
      status: :failed,
      last_error: %{"reason" => Sanitizer.transport(reason)},
      next_attempt_at: next_outbox_attempt_at(outbox, now)
    })
    |> repo.update()
  end

  defp mark_outbox_unknown(repo, outbox, reason) do
    outbox
    |> OutboxEntry.changeset(%{
      status: :unknown_after_send,
      last_error: Sanitizer.transport(reason),
      next_attempt_at: nil
    })
    |> repo.update()
  end

  defp provider_entry_id_after_success(%OutboxEntry{} = outbox, result) do
    optional_text(result, :provider_entry_id) ||
      outbox.provider_entry_id ||
      stable_local_provider_entry_id(outbox)
  end

  defp stable_local_provider_entry_id(%OutboxEntry{operation: operation} = outbox)
       when operation in [:post, :reply, :divider, :card] do
    "local-outbox:#{outbox.idempotency_key || outbox.outbound_key}"
  end

  defp stable_local_provider_entry_id(%OutboxEntry{}), do: nil

  defp next_outbox_attempt_at(%OutboxEntry{attempt_count: attempts, max_attempts: max}, _now)
       when attempts >= max,
       do: nil

  defp next_outbox_attempt_at(%OutboxEntry{attempt_count: attempts}, now) do
    delay_seconds =
      attempts
      |> max(1)
      |> then(&(@outbox_base_retry_seconds * Integer.pow(2, &1 - 1)))
      |> min(@outbox_max_retry_seconds)

    DateTime.add(now, delay_seconds, :second)
  end

  defp mirror_outbox_success(
         repo,
         %OutboxEntry{operation: operation} = outbox,
         channel,
         result,
         now
       )
       when operation in [:post, :reply, :divider, :card] do
    case optional_text(result, :provider_entry_id) || outbox.provider_entry_id do
      nil ->
        :ok

      provider_entry_id ->
        fact = %{
          signal_channel_id: outbox.signal_channel_id,
          provider_entry_id: provider_entry_id,
          provider_thread_id: outbox.provider_thread_id,
          text: outbox.fallback_visible_text,
          fallback_visible_text: outbox.fallback_visible_text,
          formatted_content: fetch_map(outbox.payload, :formatted_content, %{}),
          attachments: [],
          links: [],
          author: %{"agent_uid" => outbox.agent_uid},
          mentions: [],
          metadata: fetch_map(outbox.payload, :metadata, %{}),
          raw_payload: fetch_map(result, :raw_payload, %{}),
          provider_time: fetch_datetime(result, :provider_time),
          channel_name: channel && channel.name,
          channel_title: channel && channel.title
        }

        case mirror_receive_entry(repo, fact, now) do
          {:ok, _entry} -> :ok
          {:error, _changeset} = error -> error
        end
    end
  end

  defp mirror_outbox_success(
         repo,
         %OutboxEntry{operation: :edit} = outbox,
         _channel,
         _result,
         now
       ) do
    case repo.get_by(SignalEntry,
           signal_channel_id: outbox.signal_channel_id,
           provider_entry_id: outbox.target_provider_entry_id
         ) do
      %SignalEntry{} = entry ->
        entry
        |> SignalEntry.changeset(%{
          text: outbox.fallback_visible_text,
          fallback_visible_text: outbox.fallback_visible_text,
          search_text: outbox.fallback_visible_text,
          last_seen_at: now
        })
        |> repo.update()
        |> case do
          {:ok, _entry} -> :ok
          {:error, _changeset} = error -> error
        end

      nil ->
        :ok
    end
  end

  defp mirror_outbox_success(
         repo,
         %OutboxEntry{operation: :delete} = outbox,
         _channel,
         _result,
         _now
       ) do
    SignalEntry
    |> where([entry], entry.signal_channel_id == ^outbox.signal_channel_id)
    |> where([entry], entry.provider_entry_id == ^outbox.target_provider_entry_id)
    |> repo.delete_all()

    :ok
  end

  defp mirror_outbox_success(
         repo,
         %OutboxEntry{operation: operation} = outbox,
         _channel,
         _result,
         now
       )
       when operation in [:reaction_add, :reaction_remove] do
    case repo.get_by(SignalEntry,
           signal_channel_id: outbox.signal_channel_id,
           provider_entry_id: outbox.target_provider_entry_id
         ) do
      %SignalEntry{} = entry ->
        fact = %{
          action: if(operation == :reaction_add, do: :add, else: :remove),
          reaction_key: outbox.payload["reaction_key"] || outbox.payload[:reaction_key],
          actor_key: outbox.payload["actor_key"] || outbox.agent_uid,
          raw_reaction_key:
            outbox.payload["raw_reaction_key"] || outbox.payload[:raw_reaction_key]
        }

        entry
        |> SignalEntry.changeset(reaction_entry_attrs(entry, fact, now))
        |> repo.update()
        |> case do
          {:ok, _entry} -> :ok
          {:error, _changeset} = error -> error
        end

      nil ->
        :ok
    end
  end

  defp normalize_agent_uid_attr(%{agent_uid: agent_uid} = attrs) when is_binary(agent_uid) do
    %{attrs | agent_uid: normalize_uid(agent_uid)}
  end

  defp normalize_agent_uid_attr(attrs), do: attrs

  defp action_session_id(input) do
    case optional_text(input, :session_id) || optional_text(input, :signal_channel_id) do
      nil ->
        {:error, :missing_session_id}

      session_or_channel ->
        {:ok, optional_text(input, :session_id) || signal_session_id(session_or_channel)}
    end
  end

  defp structured_agent_mention?(input, agent_uid) do
    input
    |> fetch_list(:mentions)
    |> Enum.any?(fn mention ->
      structured_mention?(mention, agent_uid)
    end)
  end

  defp structured_mention?(mention, agent_uid) when is_map(mention) do
    structured? =
      truthy?(fetch_value(mention, :structured)) ||
        fetch_value(mention, :kind) in [:agent, "agent", :bot, "bot"]

    mentioned_agent = optional_text(mention, :agent_uid)
    structured? and (is_nil(mentioned_agent) or normalize_uid(mentioned_agent) == agent_uid)
  end

  defp structured_mention?(_mention, _agent_uid), do: false

  defp normalize_mentions(mentions) do
    Enum.map(mentions, fn
      %{} = mention -> update_enum_text(mention, :kind)
      mention -> mention
    end)
  end

  defp update_enum_text(map, key) do
    case fetch_value(map, key) do
      value when is_atom(value) -> Map.put(map, key, Atom.to_string(value))
      _value -> map
    end
  end

  defp sender_key(input) do
    author = fetch_map(input, :author, %{})

    optional_text(input, :sender_key) ||
      optional_text(author, :principal_uid) ||
      optional_text(author, :platform_subject) ||
      optional_text(author, :external_id) ||
      optional_text(author, :id)
  end

  defp normalize_attachments(input) do
    input
    |> fetch_list(:attachments)
    |> Enum.map(&normalize_attachment/1)
    |> collect_results()
  end

  defp normalize_attachment(%{} = attachment) do
    case JsonPayload.normalize_map(attachment, allow_datetime: true) do
      {:ok, normalized} ->
        case durable_attachment?(normalized) do
          true -> {:ok, normalized}
          false -> {:error, {:attachment_not_materialized, Sanitizer.transport(normalized)}}
        end

      {:error, _reason} ->
        {:error, {:invalid_attachment_payload, Sanitizer.transport(attachment)}}
    end
  end

  defp normalize_attachment(attachment),
    do: {:error, {:invalid_attachment_payload, Sanitizer.transport(attachment)}}

  defp durable_attachment?(attachment) do
    Enum.any?(
      [
        "provider_ref",
        "provider_file_id",
        "provider_uri",
        "blob_ref",
        "storage_ref",
        "agent_computer_path"
      ],
      &present_text?(attachment, &1)
    ) || agent_computer_visible_file_path?(attachment)
  end

  defp present_text?(map, key) do
    case Map.get(map, key) do
      value when is_binary(value) -> String.trim(value) != ""
      _value -> false
    end
  end

  defp agent_computer_visible_file_path?(attachment) do
    case Map.get(attachment, "file_path") do
      path when is_binary(path) ->
        String.starts_with?(path, "/workspace/") ||
          Map.get(attachment, "visible_to") == "agent_computer"

      _path ->
        false
    end
  end

  defp metadata_text(fact) do
    [fact.author, fact.metadata, fact.channel_name, fact.channel_title]
    |> List.flatten()
    |> Enum.map(&metadata_text_part/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n")
  end

  defp metadata_text_part(value) when is_binary(value), do: value

  defp metadata_text_part(value) when is_map(value),
    do: value |> Map.values() |> Enum.map(&metadata_text_part/1) |> Enum.join(" ")

  defp metadata_text_part(value) when is_list(value),
    do: value |> Enum.map(&metadata_text_part/1) |> Enum.join(" ")

  defp metadata_text_part(value) when is_number(value), do: to_string(value)
  defp metadata_text_part(_value), do: ""

  defp document_id(signal_channel_id, provider_entry_id) do
    "signal-entry:" <> digest([signal_channel_id, provider_entry_id])
  end

  defp content_hash(parts), do: digest(parts)

  defp digest(parts) do
    parts
    |> :erlang.term_to_binary()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.url_encode64(padding: false)
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

  defp fetch_value(map, key) when is_map(map),
    do: Map.get(map, key) || Map.get(map, Atom.to_string(key))

  defp fetch_value(_map, _key), do: nil

  defp fetch_map(map, key, default) do
    case fetch_value(map, key) do
      value when is_map(value) -> value
      _value -> default
    end
  end

  defp fetch_list(map, key) do
    case fetch_value(map, key) do
      value when is_list(value) -> value
      nil -> []
      value -> [value]
    end
  end

  defp required_text(map, key) do
    case optional_text(map, key) do
      nil -> {:error, {:missing_required_text, key}}
      value -> {:ok, value}
    end
  end

  defp optional_text(map, key) when is_map(map) do
    case fetch_value(map, key) do
      value when is_binary(value) ->
        case String.trim(value) do
          "" -> nil
          trimmed -> trimmed
        end

      nil ->
        nil

      value when is_atom(value) ->
        Atom.to_string(value)

      value when is_integer(value) ->
        Integer.to_string(value)

      _value ->
        nil
    end
  end

  defp optional_text(_map, _key), do: nil

  defp fetch_datetime(map, key) do
    case fetch_value(map, key) do
      %DateTime{} = datetime -> datetime
      _value -> nil
    end
  end

  defp normalize_channel_kind(value) when value in [:im_dm, "im_dm"], do: :im_dm
  defp normalize_channel_kind(value) when value in [:im_group, "im_group"], do: :im_group

  defp normalize_channel_kind(value) when value in [:webhook_endpoint, "webhook_endpoint"],
    do: :webhook_endpoint

  defp normalize_channel_kind(value) when value in [:issue, "issue"], do: :issue

  defp normalize_channel_kind(value) when value in [:alert_stream, "alert_stream"],
    do: :alert_stream

  defp normalize_channel_kind(_value), do: :unknown

  defp normalize_reply_mode(value) when value in [:channel, "channel"], do: :channel
  defp normalize_reply_mode(value) when value in [:entry, "entry"], do: :entry
  defp normalize_reply_mode(_value), do: :none

  defp normalize_reaction_action(value) when value in [:remove, "remove", :deleted, "deleted"],
    do: :remove

  defp normalize_reaction_action(_value), do: :add

  defp where_provider_thread(query, nil),
    do: where(query, [input], is_nil(input.provider_thread_id))

  defp where_provider_thread(query, provider_thread_id),
    do: where(query, [input], input.provider_thread_id == ^provider_thread_id)

  defp truthy?(value) when value in [true, "true", 1, "1"], do: true
  defp truthy?(_value), do: false

  defp normalize_uid(uid) when is_binary(uid), do: uid |> String.trim() |> String.downcase()
  defp normalize_uid(uid), do: uid
end
