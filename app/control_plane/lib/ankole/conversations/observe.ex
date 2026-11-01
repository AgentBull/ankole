defmodule Ankole.Conversations.Observe do
  import Ankole.Attrs, only: [collect_results: 1, normalize_provider_lifecycle_kind: 1]

  @moduledoc """
  Adapter-facing API to observe external conversation facts.

  This module is the single public surface for normalized provider facts. It
  resolves the binding route, constructs typed ingress facts, applies binding
  filters, updates the provider mirror, manages inbound batches, and appends
  actor-facing events when the accepted fact should wake an actor.

  The pipeline order is deliberate: a signal becomes a normalized fact first,
  so binding filters compare durable, atom-free fields instead of raw provider
  maps. Reply references determine whether an IM message addresses the Agent
  before identity admission. Unaddressed ignored group messages skip admission
  and retain their batch data for later references. Other messages must pass
  identity admission before acceptance. The accept work runs in one Repo
  transaction behind the per-entry lock.
  """

  alias Ankole.Conversations.InputRevisions
  alias Ankole.Conversations.Delivery.Preview
  alias Ankole.Signals.Signal
  alias Ankole.I18n
  alias Ankole.Logging
  alias Ankole.Repo
  alias Ankole.Conversations.Envelope
  alias Ankole.Signals.Bindings
  alias Ankole.Signals.Commands
  alias Ankole.Conversations.FactNormalizer
  alias Ankole.Signals.BindingFilters
  alias Ankole.Conversations.IdentityAdmission
  alias Ankole.Conversations.InboundBatches
  alias Ankole.Conversations.Observation
  alias Ankole.Conversations.Delivery
  alias Ankole.Conversations.External
  alias Ankole.Conversations.Attachments
  alias Ankole.Conversations.InputTombstone
  alias Ankole.Conversations.Conversation
  alias Ankole.Conversations.Delivery.Reference
  alias Ankole.Conversations.Delivery.Interactions
  alias Ankole.Signals.Binding
  require Ash.Query

  @type ingress_result :: {:ok, map()} | {:error, term()}

  @doc """
  Concrete adapter API for a provider entry receive.

  The main ingress path for an inbound message. Follows the fixed pipeline:
  resolve binding → construct fact → filter → accept. A filtered signal returns
  `{:ok, %{status: :filtered}}` (a successful no-op, not an error), and the actor
  runtime is woken only when the signal actually produced new Signal.
  """
  @spec emit_entry(String.t(), FactNormalizer.entry_input(), keyword()) ::
          ingress_result()
  def emit_entry(binding_id, input, options \\ []) when is_map(input) do
    now = Keyword.get(options, :now, DateTime.utc_now(:microsecond))

    with {:ok, binding} <- Bindings.get_binding(binding_id),
         {:ok, attrs} <- FactNormalizer.entry(binding, input, now),
         {:ok, fact} <- Observation.entry(attrs),
         fact = fact |> resolve_existing_conversation() |> then(&Reference.enrich/1),
         :match <- BindingFilters.match?(binding.filters, fact) do
      case admit_entry(binding, fact, now) |> route_entry(binding) do
        {:ok, fact} ->
          Repo.transact_top_level(
            fn -> accept_entry_in_tx(binding, fact, now) end,
            after_commit: &__MODULE__.publish_committed/1
          )

        {:held, fact, status, notice?} ->
          if notice?, do: notify_held_sender(fact, now)
          {:ok, %{status: status}}

        {:error, _reason} = error ->
          error
      end
    else
      :no_match -> {:ok, %{status: :filtered}}
      {:ignored, status} -> {:ok, %{status: status}}
      {:error, _reason} = error -> error
    end
  end

  @doc """
  Concrete adapter API for a provider entry removal.

  Provider-specific event names such as "delete" or "recall" are source facts,
  not separate Ankole capabilities. They may be kept in
  `options[:provider_lifecycle_kind]` for diagnostics, while the actor-facing
  contract remains `conversation.message.removed`.
  """
  @spec emit_entry_removed(String.t(), FactNormalizer.removal_input(), keyword()) ::
          ingress_result()
  def emit_entry_removed(binding_id, input, options \\ []) do
    provider_lifecycle_kind =
      Keyword.get(options, :provider_lifecycle_kind) ||
        Map.get(input, :provider_lifecycle_kind)

    provider_lifecycle_kind = normalize_provider_lifecycle_kind(provider_lifecycle_kind)

    emit_lifecycle(binding_id, input, provider_lifecycle_kind, options)
  end

  @doc """
  Concrete adapter API for reaction changes.

  Reactions only update the mirror — they never create Signal — so this
  path stays self-contained: lock the entry, fold the add/remove into its
  reaction map, done. A reaction on an entry we never mirrored is ignored
  (`:ignored_unknown_entry`) rather than treated as an error, since the gateway
  has no entry to attach it to.
  """
  @spec emit_reaction(String.t(), FactNormalizer.reaction_input(), keyword()) ::
          ingress_result()
  def emit_reaction(binding_id, input, options \\ []) when is_map(input) do
    now = Keyword.get(options, :now, DateTime.utc_now(:microsecond))

    with {:ok, binding} <- Bindings.get_binding(binding_id),
         {:ok, attrs} <- FactNormalizer.reaction(binding, input, now),
         {:ok, fact} <- Observation.reaction(attrs),
         fact = resolve_existing_conversation(fact),
         :match <- BindingFilters.match?(binding.filters, fact),
         {:ok, fact} <- route_followup(binding, fact) do
      Repo.transact_top_level(fn ->
        accept_reaction_in_tx(binding, fact, now)
      end)
    else
      :no_match -> {:ok, %{status: :filtered}}
      {:ignored, status} -> {:ok, %{status: status}}
      {:error, _reason} = error -> error
    end
  end

  @doc false
  def accept_reaction_in_tx(binding, fact, now) do
    # Advisory lock on the entry key serializes concurrent reaction folds for
    # the same message so two simultaneous add/removes can't clobber the
    # reactions map.
    with {:ok, fact} <- bind_conversation_in_tx(binding, fact, now),
         {:ok, ref} <-
           External.fold_reaction_in_tx(
             fact.conversation_id,
             fact.provider_message_id,
             fact,
             now
           ) do
      {:ok, %{status: if(ref, do: :recorded, else: :ignored_unknown_entry), external_ref: ref}}
    end
  end

  @doc """
  Concrete adapter API for provider actions such as card clicks.
  """
  @spec emit_action(String.t(), FactNormalizer.action_input(), keyword()) ::
          ingress_result()
  def emit_action(binding_id, input, options \\ []) when is_map(input) do
    now = Keyword.get(options, :now, DateTime.utc_now(:microsecond))

    with {:ok, binding} <- Bindings.get_binding(binding_id),
         {:ok, attrs} <- FactNormalizer.action(binding, input, now),
         {:ok, fact} <- Observation.action(attrs),
         fact = resolve_existing_conversation(fact),
         :match <- BindingFilters.match?(binding.filters, fact),
         {:ok, fact} <- route_followup(binding, fact) do
      Repo.transact_top_level(
        fn -> accept_action_in_tx(binding, fact, now) end,
        after_commit: &__MODULE__.publish_committed/1
      )
    else
      :no_match -> {:ok, %{status: :filtered}}
      {:ignored, status} -> {:ok, %{status: status}}
      {:error, _reason} = error -> error
    end
  end

  @doc false
  def accept_action_in_tx(binding, fact, now) do
    # Keep the same tree -> channel -> root -> Principal -> Session -> Signal lock order
    # across all managed callbacks so Action Cards and ordinary answers compose cleanly.
    with :ok <- Ankole.Files.lock_tree_in_tx(),
         {:ok, fact} <- bind_conversation_in_tx(binding, fact, now),
         {:ok, channel} <- conversation_in_tx(fact) do
      if managed_action_card_callback?(fact) do
        Ankole.Conversations.ActionCards.accept_external_in_tx(binding, fact, channel, now)
      else
        with {:ok, acceptance} <- Interactions.accept_in_tx(binding, fact, now) do
          case acceptance do
            :duplicate ->
              {:ok, %{status: :duplicate_action}}

            :stale ->
              {:ok, %{status: :stale_action}}

            {:accepted, resolution} ->
              fact = %{
                fact
                | action: accepted_reply_action(fact.action, resolution),
                  sender_key: Map.get(fact.action, "operator_principal_uid")
              }

              append_action_event(binding, fact, channel, now)

            :unmanaged ->
              append_action_event(binding, fact, channel, now)
          end
        end
      end
    end
  end

  defp managed_action_card_callback?(fact) do
    value = get_in(fact.action || %{}, ["value"]) || %{}

    Map.get(value, "version") ==
      Ankole.Conversations.Delivery.ReplyPresentation.action_protocol() and
      Ankole.Conversations.ActionCards.action_card_interaction_id?(
        Map.get(value, "interactionId")
      )
  end

  @doc "Commits pending and final attachment observations with one time anchor."
  @spec emit_entry_with_attachments(
          String.t(),
          map(),
          ([map()] -> [map()]),
          keyword()
        ) ::
          ingress_result()
  def emit_entry_with_attachments(binding_id, input, materialize, opts \\ []) do
    if Attachments.attachments_need_bytes?(input.attachments) do
      observed_at = Keyword.get(opts, :observed_at, DateTime.utc_now(:microsecond))
      pending = attachment_observation(input, "pending", observed_at)

      case emit_entry(binding_id, pending, opts) do
        {:ok, %{message_observation: %{message: %{attachments: attachments}}}}
        when is_list(attachments) ->
          attachments = materialize.(attachments)

          input
          |> Map.put(:attachments, attachments)
          |> attachment_observation(Attachments.materialization_state(attachments), observed_at)
          |> then(&emit_entry(binding_id, &1, opts))

        result ->
          result
      end
    else
      emit_entry(binding_id, input, opts)
    end
  end

  @doc "Commits pending media before starting a tenant-bound download task."
  @spec emit_entry_deferred(
          FactNormalizer.entry_input(),
          (FactNormalizer.entry_input() -> ingress_result()),
          ([map()] -> [map()]),
          ((-> ingress_result()) -> {:ok, pid()} | {:error, term()}),
          [String.t()]
        ) :: ingress_result()
  def emit_entry_deferred(input, emit, materialize, start_task, provider_fact_states) do
    {input, observed_at} = Attachments.reuse_stored_attachments(input, provider_fact_states)

    if Attachments.attachments_need_bytes?(input.attachments) do
      case emit.(attachment_observation(input, "pending", observed_at)) do
        {:ok,
         %{
           message_observation: %{
             message: %Ankole.Conversations.Message{attachments: attachments}
           }
         }} = result
        when is_list(attachments) ->
          # Task start failure must fail the provider request so it can retry.
          with {:ok, _pid} <-
                 start_task.(
                   Repo.bind_tenant(fn ->
                     attachments = materialize.(attachments)

                     input
                     |> Map.put(:attachments, attachments)
                     |> attachment_observation(
                       Attachments.materialization_state(attachments),
                       observed_at
                     )
                     |> emit.()
                   end)
                 ) do
            result
          end

        result ->
          result
      end
    else
      emit.(input)
    end
  end

  defp attachment_observation(input, state, observed_at) do
    %{
      input
      | metadata: Attachments.put_attachment_materialization(input.metadata, state, observed_at)
    }
  end

  defp emit_lifecycle(binding_id, input, provider_lifecycle_kind, options) do
    now = Keyword.get(options, :now, DateTime.utc_now(:microsecond))

    with {:ok, binding} <- Bindings.get_binding(binding_id),
         constructor <- lifecycle_constructor(provider_lifecycle_kind),
         {:ok, attrs} <- constructor.(binding, input, now),
         {:ok, fact} <- Observation.lifecycle(attrs),
         fact = resolve_existing_conversation(fact),
         :match <- BindingFilters.match?(binding.filters, fact),
         {:ok, fact} <- route_followup(binding, fact) do
      Repo.transact_top_level(
        fn -> accept_lifecycle_in_tx(binding, fact, now) end,
        after_commit: &__MODULE__.publish_committed/1
      )
    else
      :no_match -> {:ok, %{status: :filtered}}
      {:ignored, status} -> {:ok, %{status: status}}
      {:error, _reason} = error -> error
    end
  end

  @doc false
  # The durable decision is committed. The preview effects are best-effort
  # follow-ups: a preview whose input is gone would keep editing cards that the
  # intent deletes.
  def publish_committed(result) when is_map(result) do
    result
    |> Map.get(:runtime_retractions, %{})
    |> Map.get(:canceled_signal_ids, [])
    |> Enum.each(&Preview.stop/1)

    if is_map(result[:action_card_outcome]) do
      Ankole.Conversations.ActionCards.publish_after_commit(result.action_card_outcome)
    end

    Envelope.publish_committed(result)
  end

  def publish_committed(_result), do: :ok

  defp admit_entry(binding, fact, now) do
    if fact.channel_kind == :im_group and entry_policy(binding, fact) == {:ok, :ignore} do
      {:ok, fact}
    else
      IdentityAdmission.admit_entry(binding, fact, now)
    end
  end

  # Whole acceptance runs in one transaction behind the per-entry advisory lock,
  # so concurrent receives for the same message serialize and the
  # tombstone-check → mirror → Signal sequence is atomic. The tombstone
  # check comes first: if the human already removed this entry, drop the
  # late receive before writing anything.
  @doc false
  def accept_entry_in_tx(binding, fact, now) do
    with :ok <- Ankole.Files.lock_tree_in_tx(),
         {:ok, fact} <- bind_conversation_in_tx(binding, fact, now),
         :ok <- lock_entry_consumers(binding, fact),
         :ok <- lock_entry(fact) do
      case active_tombstone?(fact, now) do
        true ->
          {:ok, %{status: :dropped_tombstoned}}

        false ->
          with :ok <- InboundBatches.promote_reference_in_tx(binding, fact, now),
               fact = Reference.enrich(fact),
               {:ok, policy} <- entry_policy(binding, fact),
               {:ok, result} <- apply_entry_policy(binding, fact, policy, now) do
            {:ok, result}
          end
      end
    end
  end

  defp lock_entry_consumers(binding, fact) do
    with {:ok, policy} <- entry_policy(binding, fact) do
      case policy do
        {:signal, type, command} when not is_nil(command) ->
          {target, _command} = resolve_retry_target(binding, fact, type, command)

          sessions =
            Enum.map([fact, target], fn entry ->
              {entry.agent_uid,
               Map.get(entry, :session_id) ||
                 Ankole.Sessions.Key.conversation(entry.conversation_id)}
            end)

          Ankole.Sessions.Queue.lock_sessions_in_tx(sessions)

        _ ->
          Ankole.Conversations.InputRevisions.lock_attachment_supplement_in_tx(fact)
      end
    end
  end

  defp lifecycle_constructor(provider_lifecycle_kind) do
    fn binding, input, now ->
      FactNormalizer.lifecycle(binding, input, provider_lifecycle_kind, now)
    end
  end

  # Removal is the inverse of accept and does several things atomically:
  # 1) drop a tombstone so a re-delivered receive can't resurrect the entry,
  # 2) remove the source from any open inbound batch, 3) remove the mirror row,
  # 4) cancel or retry any still-open Signal for that entry, and 5) for an
  # event the agent already completed, append a lifecycle "removed" event that
  # AgentWorkers consumes as a no-op while cancelling related checkbacks. Steps
  # 2-4 cover committed and uncommitted internal work; step 5 records the
  # provider lifecycle edge without deriving a retraction note.
  @doc false
  def accept_lifecycle_in_tx(binding, fact, now) do
    # Match ordinary IM ingress: entry, then batch, then channel row.
    with {:ok, fact} <- bind_conversation_in_tx(binding, fact, now),
         :ok <- lock_entry(fact),
         :ok <- InboundBatches.lock_in_tx(fact),
         {:ok, channel} <- conversation_in_tx(fact),
         {:ok, tombstone} <- upsert_tombstone(fact, now),
         {:ok, updated_batches} <- InboundBatches.remove_pending_inbound_entry(fact, now),
         {deleted_count, _rows} <- remove_message_in_tx(fact),
         completed_events <-
           Ankole.Signals.signals_for_entry_in_tx(
             fact.agent_uid,
             fact.binding_id,
             fact.conversation_id,
             fact.provider_message_id
           ),
         {:ok, runtime_retractions} <-
           InputRevisions.retract_source_entry_in_tx(fact, :removed, now),
         {:ok, lifecycle_events} <-
           append_lifecycle_events(binding, fact, completed_events, channel, now) do
      {:ok,
       %{
         status: :accepted,
         tombstone: tombstone,
         updated_inbound_batches: length(updated_batches),
         deleted_mirror_entries: deleted_count,
         canceled_signals: runtime_retractions.canceled_signals,
         retried_signals: runtime_retractions.retried_signals,
         runtime_retractions: runtime_retractions,
         lifecycle_events: lifecycle_events
       }}
    end
  end

  defp entry_policy(%Binding{} = binding, fact) do
    cond do
      fact.mirror_only? ->
        {:ok, :record_only}

      command = command_payload(fact) ->
        {:ok, {:signal, command_event_type(command), command}}

      fact.signal_type ->
        {:ok, {:signal, fact.signal_type, nil}}

      Observation.addressed_im_entry?(fact) ->
        {:ok, {:signal, "conversation.message.addressed", nil}}

      fact.channel_kind == :im_group ->
        group_policy(binding.unaddressed_group_message_policy)

      true ->
        {:error, :missing_signal_type}
    end
  end

  defp group_policy(:ignore), do: {:ok, :ignore}
  defp group_policy(:record_only), do: {:ok, :record_only}
  defp group_policy(:may_intervene), do: {:ok, {:signal, "im.message.may_intervene", nil}}

  # Commands are only honored when the agent is explicitly addressed, so a "/stop"
  # overheard in an unaddressed group line is not treated as a command. The
  # leading @-mention is stripped before classification so "@agent /stop" parses.
  defp command_payload(fact) do
    case Observation.addressed_im_entry?(fact) do
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

  defp command_event_type(%{"name" => "llm"} = command) do
    if Map.get(command, "modelProfile"), do: "command.llm", else: "command.llm_help"
  end

  defp command_event_type(command), do: "command.#{command["name"]}"

  defp apply_entry_policy(binding, fact, :ignore, now)
       when fact.channel_kind == :im_group do
    InboundBatches.apply_im_entry_policy(binding, fact, :ignore, nil, now)
  end

  defp apply_entry_policy(_binding, _fact, :ignore, _now) do
    {:ok, %{status: :ignored}}
  end

  defp apply_entry_policy(binding, fact, :record_only, now)
       when fact.channel_kind in [:im_dm, :im_group] do
    InboundBatches.apply_im_entry_policy(binding, fact, :record_only, nil, now)
  end

  defp apply_entry_policy(_binding, fact, :record_only, now) do
    with {:ok, channel} <- conversation_in_tx(fact),
         {:ok, entry} <- External.observe_entry_in_tx(fact, now) do
      {:ok, %{status: :recorded, conversation: channel, message_observation: entry}}
    end
  end

  # The direct accept path is for non-IM events and typed command events. IM text
  # and attachment traffic has already been diverted into pending inbound batches.
  defp apply_entry_policy(
         binding,
         fact,
         {:signal, "conversation.message.addressed", nil},
         now
       )
       when fact.channel_kind in [:im_dm, :im_group] do
    InboundBatches.apply_im_entry_policy(
      binding,
      fact,
      :ignore,
      "conversation.message.addressed",
      now
    )
  end

  defp apply_entry_policy(
         binding,
         fact,
         {:signal, "im.message.may_intervene", nil},
         now
       )
       when fact.channel_kind == :im_group do
    InboundBatches.apply_im_entry_policy(binding, fact, :may_intervene, nil, now)
  end

  defp apply_entry_policy(binding, fact, {:signal, type, command_payload}, now) do
    {fact, command_payload} =
      resolve_retry_target(binding, fact, type, command_payload)

    fact = Map.put(fact, :command_payload, command_payload)

    with {:ok, channel} <- conversation_in_tx(fact),
         {:ok, entry} <- External.observe_entry_in_tx(fact, now),
         {:ok, append_result} <-
           Envelope.accept(binding, fact, type, channel, entry, now) do
      {:ok,
       signal_append_result(append_result, %{
         conversation: channel,
         message_observation: entry
       })}
    end
  end

  defp resolve_retry_target(
         binding,
         fact,
         "command.retry",
         %{"argsText" => args_text} = command
       ) do
    case retry_target_request(args_text, fact.reply_to_provider_message_id) do
      :bare ->
        {fact, command}

      {:explicit, signal_id} ->
        resolve_explicit_retry_target(binding, fact, command, signal_id)

      {:reply, provider_provider_message_id} ->
        resolve_reply_retry_target(binding, fact, command, provider_provider_message_id)

      :invalid ->
        unresolved_retry_target(fact, command)
    end
  end

  defp resolve_retry_target(_binding, fact, _type, command), do: {fact, command}

  defp retry_target_request(args_text, reply_to_provider_message_id) do
    case String.trim(args_text) do
      "" -> reply_retry_target_request(reply_to_provider_message_id)
      signal_ref -> explicit_retry_target_request(signal_ref)
    end
  end

  defp explicit_retry_target_request("signal::" <> signal_id)
       when byte_size(signal_id) == 36 do
    case Ecto.UUID.cast(signal_id) do
      {:ok, signal_id} -> {:explicit, signal_id}
      :error -> :invalid
    end
  end

  defp explicit_retry_target_request(_signal_ref), do: :invalid

  defp reply_retry_target_request(reply_to_provider_message_id)
       when is_binary(reply_to_provider_message_id) and reply_to_provider_message_id != "",
       do: {:reply, reply_to_provider_message_id}

  defp reply_retry_target_request(_reply_to_provider_message_id), do: :bare

  defp resolve_explicit_retry_target(binding, fact, command, signal_id) do
    case Delivery.durable_reply_surface_exists_in_tx?(
           fact.agent_uid,
           binding.name,
           fact.conversation_id,
           signal_id
         ) do
      true -> resolved_retry_target(fact, command, signal_id)
      false -> unresolved_retry_target(fact, command)
    end
  end

  defp resolve_reply_retry_target(binding, fact, command, provider_provider_message_id) do
    case Delivery.resolve_durable_reply_signal_in_tx(
           fact.agent_uid,
           binding.name,
           fact.conversation_id,
           provider_provider_message_id
         ) do
      {:ok, signal_id} -> resolved_retry_target(fact, command, signal_id)
      {:error, :unresolved_reply_target} -> unresolved_retry_target(fact, command)
    end
  end

  defp resolved_retry_target(fact, command, signal_id) do
    case Ankole.Signals.get_signal!(signal_id) do
      %Signal{session_id: session_id} ->
        fact = Map.put(fact, :session_id, session_id)
        command = Map.put(command, "targetSignalId", signal_id)
        {fact, command}

      nil ->
        unresolved_retry_target(fact, command)
    end
  end

  defp unresolved_retry_target(fact, command) do
    {fact, Map.put(command, "targetSignalId", nil)}
  end

  defp signal_append_result(%Signal{} = signal, extra) do
    extra
    |> Map.merge(%{status: :accepted, signal: signal})
  end

  defp append_action_event(binding, fact, channel, now) do
    with {:ok, append_result} <-
           Envelope.accept(
             binding,
             fact,
             fact.signal_type,
             channel,
             nil,
             now
           ) do
      {:ok, signal_append_result(append_result, %{conversation: channel})}
    end
  end

  defp accepted_reply_action(action, resolution) do
    %{
      "name" => "reply_interaction",
      "value" => resolution,
      "operator_principal_uid" => Map.get(action, "operator_principal_uid")
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp append_lifecycle_events(_binding, _fact, [], _channel, _now), do: {:ok, []}

  defp append_lifecycle_events(binding, fact, completed_events, channel, now) do
    completed_events
    |> Enum.map(fn completed_event ->
      lifecycle_fact =
        fact
        |> Map.put(:session_id, completed_event.session_id)
        |> Map.put(:provider_thread_id, completed_event.provider_thread_id)
        |> Map.put(:metadata, Map.get(fact, :metadata, %{}))
        |> Map.put(:text, nil)
        |> Map.put(:mentions, [])
        |> Map.put(:command_payload, nil)
        |> Map.put(:action, nil)

      Envelope.accept(
        binding,
        lifecycle_fact,
        "conversation.message.removed",
        channel,
        nil,
        now
      )
    end)
    |> collect_results()
  end

  @tombstone_ttl_seconds 86_400

  defp bind_conversation_in_tx(_binding, fact, now) do
    with {:ok, conversation} <-
           External.observe_conversation_in_tx(
             %{agent_uid: if(fact.agent_uid == "system", do: nil, else: fact.agent_uid)},
             %{
               provider_conversation_id: fact.provider_conversation_id,
               title: fact.channel_name,
               external_kind: fact.channel_kind,
               reply_mode: fact.reply_mode,
               visibility: fact.channel_visibility,
               principal_group_id: Map.get(fact, :principal_group_id),
               metadata: fact.channel_metadata || %{},
               raw_payload: fact.channel_raw_payload || %{}
             },
             now
           ) do
      {:ok,
       %{
         fact
         | conversation_id: conversation.id,
           session_id:
             Map.get(fact, :session_id) || Ankole.Sessions.Key.conversation(conversation.id)
       }}
    end
  end

  defp conversation_in_tx(%{conversation_id: nil}), do: {:ok, nil}

  defp conversation_in_tx(%{conversation_id: id}),
    do: {:ok, Conversation |> Ash.Query.filter(id == ^id) |> Ankole.Ash.read_one!()}

  defp remove_message_in_tx(fact) do
    case External.remove_in_tx(fact.conversation_id, fact.provider_message_id) do
      {:ok, nil} -> {0, []}
      {:ok, message} -> {1, [message]}
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp upsert_tombstone(fact, now) do
    attrs = %{
      conversation_id: fact.conversation_id,
      provider_message_id: fact.provider_message_id,
      tombstoned_until: DateTime.add(now, @tombstone_ttl_seconds, :second)
    }

    Ankole.Ash.create(InputTombstone, :record, attrs)
  end

  def active_tombstone?(fact, now) do
    case InputTombstone
         |> Ash.Query.filter(
           conversation_id == ^fact.conversation_id and
             provider_message_id == ^fact.provider_message_id
         )
         |> Ankole.Ash.read_one!() do
      %InputTombstone{tombstoned_until: tombstoned_until} ->
        case DateTime.compare(tombstoned_until, now) do
          :gt -> true
          _other -> false
        end

      nil ->
        false
    end
  end

  def lock_entry(fact) do
    key =
      Enum.join(
        [fact.conversation_id, fact.provider_message_id],
        "|"
      )

    Ankole.AdvisoryLock.lock!(Repo, key)
    :ok
  end

  defp resolve_existing_conversation(fact) do
    case External.get_conversation(fact.provider_conversation_id) do
      %Conversation{} = conversation ->
        %{
          fact
          | conversation_id: conversation.id,
            channel_kind:
              if(fact.channel_kind in [nil, :unknown],
                do: conversation.external_kind,
                else: fact.channel_kind
              ),
            channel_metadata:
              Map.merge(conversation.metadata || %{}, fact.channel_metadata || %{})
        }

      nil ->
        fact
    end
  end

  defp route_entry({:ok, %{channel_kind: kind} = fact}, %Binding{
         routing_mode: :sender_personal_assistant
       })
       when kind != :im_dm,
       do: {:held, fact, :filtered, false}

  defp route_entry({:ok, fact}, %Binding{routing_mode: :sender_personal_assistant}) do
    uid = get_in(fact.author || %{}, ["principal_uid"])

    with {:ok, %{type: :human, status: :active, membership: :member}} <-
           Ankole.Principals.get_principal(uid),
         {:ok, %{principal: assistant}} <- Ankole.Principals.ensure_personal_assistant(uid) do
      {:ok, %{fact | agent_uid: assistant.uid}}
    else
      {:ok, _} -> {:held, fact, :ignored_non_member, false}
      {:error, :not_found} -> {:held, fact, :ignored_unmapped_sender, false}
      error -> error
    end
  end

  defp route_entry(result, _binding), do: result

  defp route_followup(%Binding{routing_mode: :ai_colleague}, fact), do: {:ok, fact}

  defp route_followup(binding, %Observation{kind: :action} = fact) do
    source_id = get_in(fact.action || %{}, ["value", "sourceSignalId"])

    source =
      case Ecto.UUID.cast(source_id) do
        {:ok, id} -> Ankole.Signals.get_signal!(id)
        :error -> nil
      end

    cond do
      match?(
        %Signal{reply_binding_id: id, conversation_id: conversation_id}
        when id == binding.id and conversation_id == fact.conversation_id,
        source
      ) ->
        {:ok, %{fact | agent_uid: source.agent_uid, session_id: source.session_id}}

      is_binary(source_id) ->
        {:ignored, :stale_action}

      true ->
        route_existing_assistant(fact)
    end
  end

  defp route_followup(_binding, fact), do: route_existing_assistant(fact)

  defp route_existing_assistant(fact) do
    case get_in(fact.channel_metadata || %{}, ["dm_peer_principal_uid"]) do
      uid when is_binary(uid) ->
        case Ankole.Principals.personal_assistant(uid) do
          %{uid: assistant_uid} -> {:ok, %{fact | agent_uid: assistant_uid}}
          nil -> {:ignored, :ignored_unknown_entry}
        end

      _ ->
        {:ignored, :ignored_unknown_entry}
    end
  end

  # The notice needs a channel mirror row to route the reply; the held entry
  # itself is never mirrored.
  defp notify_held_sender(fact, now) do
    # Admission notices are system messages when no assistant has been selected.
    fact =
      if is_nil(fact.agent_uid) do
        {:ok, system} = Ankole.Principals.system_principal()
        %{fact | agent_uid: system.uid}
      else
        fact
      end

    case Repo.transact_top_level(fn -> notify_held_sender_in_tx(fact, now) end) do
      {:ok, _intent} ->
        :ok

      {:error, reason} ->
        Logging.warning(
          "signals.identity_admission.notice_failed",
          "unmapped sender notice could not be committed",
          %{binding: fact.binding_name, reason: inspect(reason)}
        )

        :ok
    end
  end

  @doc false
  def notify_held_sender_in_tx(fact, now) do
    with {:ok, binding} <- Bindings.get_binding(fact.binding_id),
         {:ok, fact} <- bind_conversation_in_tx(binding, fact, now) do
      Delivery.commit_in_tx(held_notice_attrs(fact))
    end
  end

  defp held_notice_attrs(fact) do
    outbound_key = "unmapped_sender:#{fact.conversation_id}:#{fact.provider_message_id}"

    %{
      agent_uid: fact.agent_uid,
      binding_id: fact.binding_id,
      binding_name: fact.binding_name,
      outbound_key: outbound_key,
      operation: :reply,
      delivery_class: :generic,
      conversation_id: fact.conversation_id,
      provider_thread_id: fact.provider_thread_id,
      reply_to_provider_message_id: fact.provider_message_id,
      payload: %{
        "metadata" => %{
          "source" => "unmapped_sender_notice",
          "unmatched_sender" => notice_sender(fact.author)
        }
      },
      fallback_visible_text: I18n.t("conversations.delivery.reply.unmapped_sender"),
      idempotency_key: outbound_key
    }
  end

  # The notice replies to a message that is never mirrored, so an adapter
  # whose route needs a recipient reads the sender from the row itself.
  defp notice_sender(author) when is_map(author) do
    author
    |> Map.take(["platform_subject", "email", "display_name"])
    |> Enum.reject(fn {_key, value} -> not is_binary(value) end)
    |> Map.new()
  end
end
