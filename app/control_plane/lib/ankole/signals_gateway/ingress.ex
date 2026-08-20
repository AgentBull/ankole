defmodule Ankole.SignalsGateway.Ingress do
  @moduledoc """
  Adapter-facing provider ingress API for SignalsGateway.

  This module is the single public surface for normalized provider facts. It
  resolves the binding route, constructs typed ingress facts, applies binding
  filters, updates the provider mirror, manages inbound batches, and appends
  actor-facing events when the accepted fact should wake an actor.

  The pipeline order is deliberate: a signal becomes a normalized fact first,
  so binding filters compare durable, atom-free fields instead of raw provider
  maps, and admission is decided before any DB write, so a rejected signal
  leaves no trace. The accept work then runs in one Repo transaction. A stored
  plan or a second queue would only add a second source of truth and a
  recovery path nobody needs.
  """

  alias Ankole.SignalsGateway.ActorRuntime.TurnRetry
  alias Ankole.SignalsGateway.Actors
  alias Ankole.SignalsGateway.ActorEvent
  alias Ankole.Repo
  alias Ankole.SignalsGateway.ActorEventEnvelope
  alias Ankole.SignalsGateway.Bindings
  alias Ankole.SignalsGateway.Commands
  alias Ankole.SignalsGateway.FactNormalizer
  alias Ankole.SignalsGateway.BindingFilters
  alias Ankole.SignalsGateway.IdentityAdmission
  alias Ankole.SignalsGateway.InboundBatches
  alias Ankole.SignalsGateway.IngressFact
  alias Ankole.SignalsGateway.Projection
  alias Ankole.SignalsGateway.ReplyReference
  alias Ankole.SignalsGateway.ReplyInteractions
  alias Ankole.SignalsGateway.Binding
  alias Ankole.SignalsGateway.Entry

  import Ankole.SignalsGateway.Utils,
    only: [
      collect_results: 1,
      normalize_provider_lifecycle_kind: 1
    ]

  @type ingress_result :: {:ok, map()} | {:error, term()}

  @doc """
  Concrete adapter API for a provider entry receive.

  The main ingress path for an inbound message. Follows the fixed pipeline:
  resolve binding → construct fact → filter → accept. A filtered signal returns
  `{:ok, %{status: :filtered}}` (a successful no-op, not an error), and the actor
  runtime is woken only when the signal actually produced new actor event.
  """
  @spec emit_entry(String.t(), String.t(), map(), keyword()) :: ingress_result()
  def emit_entry(agent_uid, binding_name, input, options \\ []) when is_map(input) do
    now = Keyword.get(options, :now, DateTime.utc_now(:microsecond))

    with {:ok, binding} <- Bindings.get_binding(agent_uid, binding_name),
         {:ok, attrs} <- FactNormalizer.entry(binding, input, now),
         {:ok, fact} <- IngressFact.entry(attrs),
         :match <- BindingFilters.match?(binding.filters, fact) do
      case IdentityAdmission.admit_entry(binding, fact, now) do
        {:ok, fact} ->
          binding
          |> accept_entry(fact, now)
          |> TurnRetry.dispatch_retry_controls()

        {:held, result} ->
          {:ok, result}
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
  contract remains `signal.entry.removed`.
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

  Reactions only update the mirror — they never create actor event — so this
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
         {:ok, fact} <- IngressFact.reaction(attrs),
         :match <- BindingFilters.match?(binding.filters, fact) do
      Repo.transact(fn repo ->
        # Advisory lock on the entry key serializes concurrent reaction folds for
        # the same message so two simultaneous add/removes can't clobber the
        # reactions map.
        with :ok <- Projection.lock_entry(repo, fact) do
          case repo.get_by(Entry,
                 signal_channel_id: fact.signal_channel_id,
                 source_entry_id: fact.source_entry_id
               ) do
            %Entry{} = entry ->
              entry
              |> Entry.changeset(Projection.reaction_entry_attrs(entry, fact, now))
              |> repo.update()
              |> Projection.reaction_result()

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

    with {:ok, binding} <- Bindings.get_binding(agent_uid, binding_name),
         {:ok, attrs} <- FactNormalizer.action(binding, input, now),
         {:ok, fact} <- IngressFact.action(attrs),
         :match <- BindingFilters.match?(binding.filters, fact) do
      Repo.transact(fn repo ->
        # Keep the same channel -> actor-session -> ActorEvent lock order as
        # ordinary message ingress. Managed callbacks take the session lock so
        # an answer and a newer turn have one deterministic winner.
        with {:ok, channel} <- Projection.maybe_upsert_channel(repo, fact, now),
             {:ok, acceptance} <- ReplyInteractions.accept_in_tx(repo, binding, fact, now) do
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
    else
      :no_match -> {:ok, %{status: :filtered}}
      {:error, _reason} = error -> error
    end
  end

  defp emit_lifecycle(agent_uid, binding_name, input, provider_lifecycle_kind, options) do
    now = Keyword.get(options, :now, DateTime.utc_now(:microsecond))

    with {:ok, binding} <- Bindings.get_binding(agent_uid, binding_name),
         constructor <- lifecycle_constructor(provider_lifecycle_kind),
         {:ok, attrs} <- constructor.(binding, input, now),
         {:ok, fact} <- IngressFact.lifecycle(attrs),
         :match <- BindingFilters.match?(binding.filters, fact) do
      binding
      |> accept_lifecycle(fact, now)
      |> TurnRetry.dispatch_retry_controls()
    else
      :no_match -> {:ok, %{status: :filtered}}
      {:error, _reason} = error -> error
    end
  end

  # Whole acceptance runs in one transaction behind the per-entry advisory lock,
  # so concurrent receives for the same message serialize and the
  # tombstone-check → mirror → actor-event sequence is atomic. The tombstone
  # check comes first: if the human already removed this entry, drop the
  # late receive before writing anything.
  defp accept_entry(binding, fact, now) do
    Repo.transact(fn repo ->
      with :ok <- Projection.lock_entry(repo, fact) do
        case Projection.active_tombstone?(repo, fact, now) do
          true ->
            {:ok, %{status: :dropped_tombstoned}}

          false ->
            fact = ReplyReference.enrich(repo, fact)

            with {:ok, policy} <- entry_policy(binding, fact),
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
  # 4) cancel or retry any still-open actor event for that entry, and 5) for an
  # event the agent already completed, append a lifecycle "removed" event that
  # ActorRuntime consumes as a no-op while cancelling related checkbacks. Steps
  # 2-4 cover committed and uncommitted internal work; step 5 records the
  # provider lifecycle edge without deriving a retraction note.
  defp accept_lifecycle(binding, fact, now) do
    Repo.transact(fn repo ->
      with {:ok, channel} <- Projection.upsert_channel(repo, fact, now),
           :ok <- Projection.lock_entry(repo, fact),
           :ok <- Projection.lock_inbound_batch(repo, fact),
           {:ok, tombstone} <- Projection.upsert_tombstone(repo, fact, now),
           {:ok, updated_batches} <- InboundBatches.remove_pending_inbound_entry(repo, fact, now),
           {deleted_count, _rows} <- Projection.delete_mirror_entry(repo, fact),
           completed_events <-
             Actors.actor_events_for_entry_in_tx(
               repo,
               fact.agent_uid,
               fact.binding_name,
               fact.signal_channel_id,
               fact.source_entry_id
             ),
           {:ok, runtime_retractions} <-
             TurnRetry.retract_source_entry_in_tx(repo, fact, :removed, now),
           {:ok, lifecycle_events} <-
             append_lifecycle_events(repo, binding, fact, completed_events, channel, now) do
        {:ok,
         %{
           status: :accepted,
           tombstone: tombstone,
           updated_inbound_batches: length(updated_batches),
           deleted_mirror_entries: deleted_count,
           canceled_actor_events: runtime_retractions.canceled_actor_events,
           retried_actor_events: runtime_retractions.retried_actor_events,
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
        {:ok, {:actor_event, command_event_type(command), command}}

      fact.actor_event_type ->
        {:ok, {:actor_event, fact.actor_event_type, nil}}

      IngressFact.addressed_im_entry?(fact) ->
        {:ok, {:actor_event, "im.message.addressed", nil}}

      fact.channel_kind == :im_group ->
        group_policy(binding.unaddressed_group_message_policy)

      true ->
        {:error, :missing_actor_event_type}
    end
  end

  defp group_policy(:ignore), do: {:ok, :ignore}
  defp group_policy(:record_only), do: {:ok, :record_only}
  defp group_policy(:may_intervene), do: {:ok, {:actor_event, "im.message.may_intervene", nil}}

  # Commands are only honored when the agent is explicitly addressed, so a "/stop"
  # overheard in an unaddressed group line is not treated as a command. The
  # leading @-mention is stripped before classification so "@agent /stop" parses.
  defp command_payload(fact) do
    case IngressFact.addressed_im_entry?(fact) do
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
    with {:ok, channel} <- Projection.upsert_channel(repo, fact, now),
         {:ok, entry} <- Projection.mirror_receive_entry(repo, fact, now) do
      {:ok, %{status: :recorded, signal_channel: channel, signal_entry: entry}}
    end
  end

  # The direct accept path is for non-IM events and typed command events. IM text
  # and attachment traffic has already been diverted into pending inbound batches.
  defp apply_entry_policy(repo, binding, fact, {:actor_event, "im.message.addressed", nil}, now)
       when fact.channel_kind in [:im_dm, :im_group] do
    InboundBatches.apply_im_entry_policy(
      repo,
      binding,
      fact,
      :ignore,
      "im.message.addressed",
      now
    )
  end

  defp apply_entry_policy(
         repo,
         binding,
         fact,
         {:actor_event, "im.message.may_intervene", nil},
         now
       )
       when fact.channel_kind == :im_group do
    InboundBatches.apply_im_entry_policy(repo, binding, fact, :may_intervene, nil, now)
  end

  defp apply_entry_policy(repo, binding, fact, {:actor_event, type, command_payload}, now) do
    fact = Map.put(fact, :command_payload, command_payload)

    with {:ok, channel} <- Projection.upsert_channel(repo, fact, now),
         {:ok, entry} <- Projection.mirror_receive_entry(repo, fact, now),
         {:ok, append_result} <-
           ActorEventEnvelope.append_actor_event(repo, binding, fact, type, channel, entry, now) do
      {:ok,
       actor_event_append_result(append_result, %{
         signal_channel: channel,
         signal_entry: entry
       })}
    end
  end

  defp actor_event_append_result(%ActorEvent{} = actor_event, extra) do
    extra
    |> Map.merge(%{status: :accepted, actor_event: actor_event})
  end

  defp append_action_event(repo, binding, fact, channel, now) do
    with {:ok, append_result} <-
           ActorEventEnvelope.append_actor_event(
             repo,
             binding,
             fact,
             fact.actor_event_type,
             channel,
             nil,
             now
           ) do
      {:ok, actor_event_append_result(append_result, %{signal_channel: channel})}
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

      ActorEventEnvelope.append_actor_event(
        repo,
        binding,
        lifecycle_fact,
        "signal.entry.removed",
        channel,
        nil,
        now
      )
    end)
    |> collect_results()
  end
end
