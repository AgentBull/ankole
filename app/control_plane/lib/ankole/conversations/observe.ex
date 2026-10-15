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
  alias Ankole.Repo
  alias Ankole.Signals.Envelope
  alias Ankole.Signals.Bindings
  alias Ankole.Signals.Commands
  alias Ankole.Conversations.FactNormalizer
  alias Ankole.Signals.BindingFilters
  alias Ankole.Signals.IdentityAdmission
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

  @type ingress_result :: {:ok, map()} | {:error, term()}

  @doc """
  Concrete adapter API for a provider entry receive.

  The main ingress path for an inbound message. Follows the fixed pipeline:
  resolve binding → construct fact → filter → accept. A filtered signal returns
  `{:ok, %{status: :filtered}}` (a successful no-op, not an error), and the actor
  runtime is woken only when the signal actually produced new Signal.
  """
  @spec emit_entry(String.t(), String.t(), map(), keyword()) :: ingress_result()
  def emit_entry(agent_uid, binding_name, input, options \\ []) when is_map(input) do
    now = Keyword.get(options, :now, DateTime.utc_now(:microsecond))

    with {:ok, binding} <- Bindings.get_binding(agent_uid, binding_name),
         {:ok, attrs} <- FactNormalizer.entry(binding, input, now),
         {:ok, fact} <- Observation.entry(attrs),
         :match <- BindingFilters.match?(binding.filters, fact) do
      fact = fact |> resolve_existing_conversation() |> then(&Reference.enrich(Repo, &1))

      case admit_entry(binding, fact, now) do
        {:ok, fact} ->
          binding
          |> accept_entry(fact, now)
          |> deliver_inputs()

        {:held, result} ->
          {:ok, result}

        {:error, _reason} = error ->
          error
      end
    else
      :no_match -> {:ok, %{status: :filtered}}
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
  @spec emit_entry_removed(String.t(), String.t(), map(), keyword()) :: ingress_result()
  def emit_entry_removed(agent_uid, binding_name, input, options \\ []) do
    provider_lifecycle_kind =
      Keyword.get(options, :provider_lifecycle_kind) ||
        Map.get(input, :provider_lifecycle_kind)

    provider_lifecycle_kind = normalize_provider_lifecycle_kind(provider_lifecycle_kind)

    emit_lifecycle(agent_uid, binding_name, input, provider_lifecycle_kind, options)
  end

  @doc """
  Concrete adapter API for reaction changes.

  Reactions only update the mirror — they never create Signal — so this
  path stays self-contained: lock the entry, fold the add/remove into its
  reaction map, done. A reaction on an entry we never mirrored is ignored
  (`:ignored_unknown_entry`) rather than treated as an error, since the gateway
  has no entry to attach it to.
  """
  @spec emit_reaction(String.t(), String.t(), map(), keyword()) :: ingress_result()
  def emit_reaction(agent_uid, binding_name, input, options \\ []) when is_map(input) do
    now = Keyword.get(options, :now, DateTime.utc_now(:microsecond))

    with {:ok, binding} <- Bindings.get_binding(agent_uid, binding_name),
         {:ok, attrs} <- FactNormalizer.reaction(binding, input, now),
         {:ok, fact} <- Observation.reaction(attrs),
         :match <- BindingFilters.match?(binding.filters, fact) do
      Repo.transact(fn repo ->
        # Advisory lock on the entry key serializes concurrent reaction folds for
        # the same message so two simultaneous add/removes can't clobber the
        # reactions map.
        with {:ok, fact} <- bind_conversation_in_tx(repo, binding, fact, now),
             {:ok, ref} <-
               External.fold_reaction_in_tx(
                 repo,
                 fact.conversation_id,
                 fact.provider_message_id,
                 fact,
                 now
               ) do
          {:ok,
           %{status: if(ref, do: :recorded, else: :ignored_unknown_entry), external_ref: ref}}
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

    with {:ok, binding} <- Bindings.get_binding(agent_uid, binding_name),
         {:ok, attrs} <- FactNormalizer.action(binding, input, now),
         {:ok, fact} <- Observation.action(attrs),
         :match <- BindingFilters.match?(binding.filters, fact) do
      Repo.transact(fn repo ->
        # Keep the same channel -> Session -> Signal lock order as
        # ordinary message ingress. Managed callbacks take the session lock so
        # an answer and a newer turn have one deterministic winner.
        with {:ok, fact} <- bind_conversation_in_tx(repo, binding, fact, now),
             {:ok, channel} <- conversation_in_tx(repo, fact),
             {:ok, acceptance} <- Interactions.accept_in_tx(repo, binding, fact, now) do
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

              append_action_event(repo, binding, fact, channel, now)

            :unmanaged ->
              append_action_event(repo, binding, fact, channel, now)
          end
        end
      end)
      |> deliver_inputs()
    else
      :no_match -> {:ok, %{status: :filtered}}
      {:error, _reason} = error -> error
    end
  end

  @doc """
  Returns whether any attachment still needs its bytes stored.

  An attachment is satisfied when the file service holds its bytes. A true
  result means the adapter must emit a `pending` observation first, download
  and store the bytes, and then emit the final observation with the same
  `observed_at`.
  """
  @spec attachments_need_bytes?([map()]) :: boolean()
  def attachments_need_bytes?(attachments) when is_list(attachments) do
    Enum.any?(attachments, &(not attachment_satisfied?(&1)))
  end

  @doc "Stores each download result and removes transient provider credentials."
  @spec materialize_attachments([map()], String.t(), (map() -> tuple()), keyword()) :: [map()]
  def materialize_attachments(attachments, adapter_id, download_fun, opts \\ []) do
    Enum.map(attachments, fn attachment ->
      result =
        if attachment_satisfied?(attachment) do
          attachment
        else
          materialize_attachment(attachment, adapter_id, download_fun, opts)
        end

      Map.drop(result, Keyword.get(opts, :drop_keys, []))
    end)
  end

  @doc "Returns the final state of an entry's attachment observation."
  @spec materialization_state([map()]) :: String.t()
  def materialization_state(attachments) do
    if Enum.all?(attachments, &attachment_satisfied?/1), do: "complete", else: "failed"
  end

  @doc "Commits pending and final attachment observations with one time anchor."
  @spec emit_entry_with_attachments(
          String.t(),
          String.t(),
          map(),
          ([map()] -> [map()]),
          keyword()
        ) ::
          ingress_result()
  def emit_entry_with_attachments(agent_uid, binding_name, input, materialize, opts \\ []) do
    if attachments_need_bytes?(input.attachments) do
      observed_at = Keyword.get(opts, :observed_at, DateTime.utc_now(:microsecond))
      pending = attachment_observation(input, "pending", observed_at)

      case emit_entry(agent_uid, binding_name, pending, opts) do
        {:ok, %{message_observation: %{message: %{attachments: attachments}}}}
        when is_list(attachments) ->
          attachments = materialize.(attachments)

          input
          |> Map.put(:attachments, attachments)
          |> attachment_observation(materialization_state(attachments), observed_at)
          |> then(&emit_entry(agent_uid, binding_name, &1, opts))

        result ->
          result
      end
    else
      emit_entry(agent_uid, binding_name, input, opts)
    end
  end

  @doc "Reuses stored media and the first observation time on provider redelivery."
  @spec reuse_stored_attachments(map(), [String.t()]) :: {map(), DateTime.t()}
  def reuse_stored_attachments(%{attachments: []} = input, _provider_fact_states),
    do: {input, DateTime.utc_now(:microsecond)}

  def reuse_stored_attachments(input, provider_fact_states) do
    conversation =
      Repo.get_by(Conversation, provider_conversation_id: input.provider_conversation_id)

    existing =
      if conversation, do: External.get_message(Repo, conversation.id, input.provider_message_id)

    case existing do
      %{message: %{attachments: stored}, external_ref: %{metadata: stored_metadata}}
      when is_list(stored) and stored != [] ->
        by_ref = Map.new(stored, &{&1["provider_ref"], &1})

        attachments =
          Enum.map(input.attachments, fn attachment ->
            case Map.get(by_ref, attachment["provider_ref"]) do
              %{"materialization_state" => "complete"} = kept ->
                if Attachments.stored?(kept), do: kept, else: attachment

              %{"materialization_state" => state} = kept ->
                if state in provider_fact_states, do: kept, else: attachment

              _missing_failed_or_unfinished ->
                attachment
            end
          end)

        observation = stored_metadata["attachment_materialization"]

        metadata =
          if is_map(observation),
            do: Map.put(input.metadata, "attachment_materialization", observation),
            else: input.metadata

        {%{input | attachments: attachments, metadata: metadata}, observation_time(observation)}

      _no_mirror ->
        {input, DateTime.utc_now(:microsecond)}
    end
  rescue
    exception ->
      Ankole.Logging.warning(
        "conversations.attachments.reuse_lookup_failed",
        "Attachment reuse lookup failed",
        %{provider_message_id: input.provider_message_id, reason: Exception.message(exception)}
      )

      {input, DateTime.utc_now(:microsecond)}
  end

  defp materialize_attachment(attachment, adapter_id, download_fun, opts) do
    with {:ok, %{body: body, filename: filename, content_type: content_type, put: put}} <-
           download_fun.(attachment),
         {:ok, stored} <-
           store_attachment(Map.merge(attachment, put), body,
             name: filename,
             content_type: content_type
           ) do
      Map.put(stored, "materialization_state", "complete")
    else
      {:error, :provider_download_limit} ->
        attachment
        |> Map.put("materialization_state", "provider_download_limit")
        |> Map.put("restriction", Keyword.fetch!(opts, :restriction))

      reason ->
        attachment_failed(attachment, adapter_id, reason)
    end
  rescue
    exception -> attachment_failed(attachment, adapter_id, exception)
  end

  defp attachment_failed(attachment, adapter_id, reason) do
    Ankole.Logging.warning(
      "conversations.attachments.materialization_failed",
      "Attachment materialization failed",
      %{
        adapter: adapter_id,
        provider_ref: attachment["provider_ref"],
        source_message_id: attachment["source_message_id"],
        reason: inspect(reason)
      }
    )

    Map.put(attachment, "materialization_state", "failed")
  end

  defp attachment_satisfied?(attachment) do
    Attachments.stored?(attachment) or
      attachment["materialization_state"] in [
        "provider_download_limit",
        "provider_external_content"
      ]
  end

  defp attachment_observation(input, state, observed_at) do
    %{input | metadata: put_attachment_materialization(input.metadata, state, observed_at)}
  end

  defp observation_time(%{"observed_at" => value}) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, observed_at, _offset} -> observed_at
      _invalid -> DateTime.utc_now(:microsecond)
    end
  end

  defp observation_time(_observation), do: DateTime.utc_now(:microsecond)

  @doc """
  Stores downloaded attachment bytes in the file service.

  `content` is a binary or `{:file, path}`. The result is the attachment with
  `blob_ref` (the SHA-256 digest), `path` (its drive path under `inbox/`), and
  `size`. `name:` overrides the attachment's own `name` in the path, and
  `content_type:` fills `content_type` when the attachment declares none.
  Every Agent that receives the attachment gets the same stored bytes, so an
  adapter stores them once whichever Agent asked first.
  """
  @spec store_attachment(map(), binary() | {:file, Path.t()}, keyword()) ::
          {:ok, map()} | {:error, term()}
  def store_attachment(attachment, content, opts \\ []) when is_map(attachment) do
    with {:ok, %{sha256: sha256, size: size}} <- Ankole.Files.store(content) do
      name = present(Keyword.get(opts, :name)) || present(attachment["name"]) || "attachment"

      attachment =
        attachment
        |> Map.put("blob_ref", sha256)
        |> Map.put("path", Ankole.Files.content_path("inbox", sha256, name))
        |> Map.put("size", size)

      attachment =
        case {Attachments.content_type(attachment), present(opts[:content_type])} do
          {nil, content_type} when is_binary(content_type) ->
            Map.put(attachment, "content_type", content_type)

          _declared_or_unknown ->
            attachment
        end

      {:ok, attachment}
    end
  end

  @doc """
  Puts the two-phase attachment observation into entry metadata.

  `state` is `"pending"` before the download and `"complete"` or `"failed"`
  after it. `observed_at` is the moment the adapter first saw the attachment.
  It anchors the inbound batch window and the materialization cap, so the
  final observation must carry the same value as the pending one.
  """
  @spec put_attachment_materialization(map(), String.t(), DateTime.t()) :: map()
  def put_attachment_materialization(metadata, state, %DateTime{} = observed_at)
      when is_map(metadata) and state in ["pending", "complete", "failed"] do
    Map.put(metadata, "attachment_materialization", %{
      "state" => state,
      "observed_at" => DateTime.to_iso8601(observed_at)
    })
  end

  defp emit_lifecycle(agent_uid, binding_name, input, provider_lifecycle_kind, options) do
    now = Keyword.get(options, :now, DateTime.utc_now(:microsecond))

    with {:ok, binding} <- Bindings.get_binding(agent_uid, binding_name),
         constructor <- lifecycle_constructor(provider_lifecycle_kind),
         {:ok, attrs} <- constructor.(binding, input, now),
         {:ok, fact} <- Observation.lifecycle(attrs),
         :match <- BindingFilters.match?(binding.filters, fact) do
      binding
      |> accept_lifecycle(fact, now)
      |> deliver_inputs()
    else
      :no_match -> {:ok, %{status: :filtered}}
      {:error, _reason} = error -> error
    end
  end

  # The durable decision is committed. The worker control and the preview
  # effects are best-effort follow-ups, in that order.
  defp deliver_inputs({:ok, result}) when is_map(result) do
    # A preview whose input is gone would keep editing cards the intent deletes.
    result
    |> Map.get(:runtime_retractions, %{})
    |> Map.get(:canceled_signal_ids, [])
    |> Enum.each(&Preview.stop/1)

    {:ok, result}
  end

  defp deliver_inputs(other), do: other

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
  defp accept_entry(binding, fact, now) do
    Repo.transact(fn repo ->
      with {:ok, fact} <- bind_conversation_in_tx(repo, binding, fact, now),
           :ok <- lock_entry(repo, fact) do
        case active_tombstone?(repo, fact, now) do
          true ->
            {:ok, %{status: :dropped_tombstoned}}

          false ->
            with :ok <- InboundBatches.promote_reference_in_tx(repo, binding, fact, now),
                 fact = Reference.enrich(repo, fact),
                 {:ok, policy} <- entry_policy(binding, fact),
                 {:ok, result} <- apply_entry_policy(repo, binding, fact, policy, now) do
              {:ok, result}
            end
        end
      end
    end)
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
  defp accept_lifecycle(binding, fact, now) do
    Repo.transact(fn repo ->
      # Match ordinary IM ingress: entry, then batch, then channel row.
      with {:ok, fact} <- bind_conversation_in_tx(repo, binding, fact, now),
           :ok <- lock_entry(repo, fact),
           :ok <- InboundBatches.lock_in_tx(repo, fact),
           {:ok, channel} <- conversation_in_tx(repo, fact),
           {:ok, tombstone} <- upsert_tombstone(repo, fact, now),
           {:ok, updated_batches} <- InboundBatches.remove_pending_inbound_entry(repo, fact, now),
           {deleted_count, _rows} <- remove_message_in_tx(repo, fact),
           completed_events <-
             Ankole.Signals.signals_for_entry_in_tx(
               repo,
               fact.agent_uid,
               fact.binding_name,
               fact.conversation_id,
               fact.provider_message_id
             ),
           {:ok, runtime_retractions} <-
             InputRevisions.retract_source_entry_in_tx(repo, fact, :removed, now),
           {:ok, lifecycle_events} <-
             append_lifecycle_events(repo, binding, fact, completed_events, channel, now) do
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
    end)
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

  defp apply_entry_policy(repo, binding, fact, :ignore, now)
       when fact.channel_kind == :im_group do
    InboundBatches.apply_im_entry_policy(repo, binding, fact, :ignore, nil, now)
  end

  defp apply_entry_policy(_repo, _binding, _fact, :ignore, _now) do
    {:ok, %{status: :ignored}}
  end

  defp apply_entry_policy(repo, binding, fact, :record_only, now)
       when fact.channel_kind in [:im_dm, :im_group] do
    InboundBatches.apply_im_entry_policy(repo, binding, fact, :record_only, nil, now)
  end

  defp apply_entry_policy(repo, _binding, fact, :record_only, now) do
    with {:ok, channel} <- conversation_in_tx(repo, fact),
         {:ok, entry} <- record_message_in_tx(repo, fact, now) do
      {:ok, %{status: :recorded, conversation: channel, message_observation: entry}}
    end
  end

  # The direct accept path is for non-IM events and typed command events. IM text
  # and attachment traffic has already been diverted into pending inbound batches.
  defp apply_entry_policy(
         repo,
         binding,
         fact,
         {:signal, "conversation.message.addressed", nil},
         now
       )
       when fact.channel_kind in [:im_dm, :im_group] do
    InboundBatches.apply_im_entry_policy(
      repo,
      binding,
      fact,
      :ignore,
      "conversation.message.addressed",
      now
    )
  end

  defp apply_entry_policy(
         repo,
         binding,
         fact,
         {:signal, "im.message.may_intervene", nil},
         now
       )
       when fact.channel_kind == :im_group do
    InboundBatches.apply_im_entry_policy(repo, binding, fact, :may_intervene, nil, now)
  end

  defp apply_entry_policy(repo, binding, fact, {:signal, type, command_payload}, now) do
    {fact, command_payload} =
      resolve_retry_target(repo, binding, fact, type, command_payload)

    fact = Map.put(fact, :command_payload, command_payload)

    with {:ok, channel} <- conversation_in_tx(repo, fact),
         {:ok, entry} <- record_message_in_tx(repo, fact, now),
         {:ok, append_result} <-
           Envelope.accept(repo, binding, fact, type, channel, entry, now) do
      {:ok,
       signal_append_result(append_result, %{
         conversation: channel,
         message_observation: entry
       })}
    end
  end

  defp resolve_retry_target(
         repo,
         binding,
         fact,
         "command.retry",
         %{"argsText" => args_text} = command
       ) do
    case retry_target_request(args_text, fact.reply_to_provider_message_id) do
      :bare ->
        {fact, command}

      {:explicit, signal_id} ->
        resolve_explicit_retry_target(repo, binding, fact, command, signal_id)

      {:reply, provider_provider_message_id} ->
        resolve_reply_retry_target(repo, binding, fact, command, provider_provider_message_id)

      :invalid ->
        unresolved_retry_target(fact, command)
    end
  end

  defp resolve_retry_target(_repo, _binding, fact, _type, command), do: {fact, command}

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

  defp resolve_explicit_retry_target(repo, binding, fact, command, signal_id) do
    case Delivery.durable_reply_surface_exists_in_tx?(
           repo,
           binding.agent_uid,
           binding.name,
           fact.conversation_id,
           signal_id
         ) do
      true -> resolved_retry_target(repo, fact, command, signal_id)
      false -> unresolved_retry_target(fact, command)
    end
  end

  defp resolve_reply_retry_target(repo, binding, fact, command, provider_provider_message_id) do
    case Delivery.resolve_durable_reply_signal_in_tx(
           repo,
           binding.agent_uid,
           binding.name,
           fact.conversation_id,
           provider_provider_message_id
         ) do
      {:ok, signal_id} -> resolved_retry_target(repo, fact, command, signal_id)
      {:error, :unresolved_reply_target} -> unresolved_retry_target(fact, command)
    end
  end

  defp resolved_retry_target(repo, fact, command, signal_id) do
    case repo.get(Signal, signal_id) do
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

  defp append_action_event(repo, binding, fact, channel, now) do
    with {:ok, append_result} <-
           Envelope.accept(
             repo,
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

  defp append_lifecycle_events(_repo, _binding, _fact, [], _channel, _now), do: {:ok, []}

  defp append_lifecycle_events(repo, binding, fact, completed_events, channel, now) do
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
        repo,
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

  defp present(value) when is_binary(value) and value != "", do: value
  defp present(_value), do: nil
  @tombstone_ttl_seconds 86_400

  def bind_conversation_in_tx(repo, binding, fact, now) do
    with {:ok, conversation} <-
           External.observe_conversation_in_tx(
             repo,
             binding,
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

  def record_message_in_tx(repo, fact, now) do
    External.observe_in_tx(
      repo,
      fact.conversation_id,
      %{
        agent_uid: fact.agent_uid,
        provider_message_id: fact.provider_message_id,
        reply_to_provider_message_id: Map.get(fact, :reply_to_provider_message_id),
        provider_thread_id: fact.provider_thread_id,
        text: fact.text,
        rich_content: Attachments.rich_content(fact.text, fact.formatted_content || %{}),
        attachments: fact.attachments || [],
        links: fact.links || [],
        author: fact.author || %{},
        mentions: fact.mentions || [],
        metadata:
          Map.merge(fact.metadata || %{}, %{
            "binding_name" => fact.binding_name,
            "sender_key" => fact.sender_key
          }),
        raw_payload: fact.raw_payload || %{},
        provider_time: fact.provider_time
      },
      now
    )
  end

  defp conversation_in_tx(_repo, %{conversation_id: nil}), do: {:ok, nil}

  defp conversation_in_tx(repo, fact),
    do: {:ok, repo.get_by(Conversation, id: fact.conversation_id)}

  defp remove_message_in_tx(repo, fact) do
    case External.remove_in_tx(repo, fact.conversation_id, fact.provider_message_id) do
      {:ok, nil} -> {0, []}
      {:ok, message} -> {1, [message]}
      {:error, reason} -> repo.rollback(reason)
    end
  end

  def upsert_tombstone(repo, fact, now) do
    attrs = %{
      conversation_id: fact.conversation_id,
      provider_message_id: fact.provider_message_id,
      tombstoned_until: DateTime.add(now, @tombstone_ttl_seconds, :second)
    }

    case repo.get_by(InputTombstone,
           conversation_id: fact.conversation_id,
           provider_message_id: fact.provider_message_id
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

  def active_tombstone?(repo, fact, now) do
    case repo.get_by(InputTombstone,
           conversation_id: fact.conversation_id,
           provider_message_id: fact.provider_message_id
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

  def lock_entry(repo, fact) do
    key =
      Enum.join(
        [fact.conversation_id, fact.provider_message_id],
        "|"
      )

    Ecto.Adapters.SQL.query!(repo, "SELECT pg_advisory_xact_lock(hashtext($1))", [key])
    :ok
  end

  defp resolve_existing_conversation(fact) do
    case External.get_conversation(Repo, fact.provider_conversation_id) do
      %Conversation{id: id} -> %{fact | conversation_id: id}
      nil -> fact
    end
  end
end
