defmodule Ankole.SignalsGateway.Ingress do
  @moduledoc false

  alias Ankole.ActorRuntime.ActivationManager
  alias Ankole.ActorRuntime.TurnRetry
  alias Ankole.Actors
  alias Ankole.Actors.ActorInput
  alias Ankole.Repo
  alias Ankole.SignalsGateway.ActorInputEnvelope
  alias Ankole.SignalsGateway.Bindings
  alias Ankole.SignalsGateway.Commands
  alias Ankole.SignalsGateway.FactNormalizer
  alias Ankole.SignalsGateway.InboundBatches
  alias Ankole.SignalsGateway.IngressPipeline
  alias Ankole.SignalsGateway.Projection
  alias Ankole.SignalsGateway.SignalBinding
  alias Ankole.SignalsGateway.SignalEntry

  import Ankole.SignalsGateway.Utils,
    only: [
      collect_results: 1,
      fetch_value: 2,
      normalize_provider_lifecycle_kind: 1
    ]

  @type ingress_result :: {:ok, map()} | {:error, term()}

  @doc """
  Concrete adapter API for a provider entry receive.

  The main ingress path for an inbound message. Follows the fixed pipeline:
  resolve binding → construct fact → filter → accept. A filtered signal returns
  `{:ok, %{status: :filtered}}` (a successful no-op, not an error), and the actor
  runtime is woken only when the signal actually produced new actor input.
  """
  @spec emit_entry(String.t(), String.t(), map(), keyword()) :: ingress_result()
  def emit_entry(agent_uid, binding_name, input, options \\ []) when is_map(input) do
    now = Keyword.get(options, :now, DateTime.utc_now(:microsecond))

    with {:ok, binding} <- Bindings.get_binding(agent_uid, binding_name),
         {:ok, fact} <-
           IngressPipeline.construct(:entry, binding, input, now, &FactNormalizer.entry/3),
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
        fetch_value(input, :provider_lifecycle_kind)

    provider_lifecycle_kind = normalize_provider_lifecycle_kind(provider_lifecycle_kind)

    emit_lifecycle(agent_uid, binding_name, input, provider_lifecycle_kind, options)
  end

  @doc """
  Concrete adapter API for reaction changes.

  Reactions only update the mirror — they never create actor input — so this
  path stays self-contained: lock the entry, fold the add/remove into its
  reaction map, done. A reaction on an entry we never mirrored is ignored
  (`:ignored_unknown_entry`) rather than treated as an error, since the gateway
  has no entry to attach it to.
  """
  @spec emit_reaction(String.t(), String.t(), map(), keyword()) :: ingress_result()
  def emit_reaction(agent_uid, binding_name, input, options \\ []) when is_map(input) do
    now = Keyword.get(options, :now, DateTime.utc_now(:microsecond))

    with {:ok, binding} <- Bindings.get_binding(agent_uid, binding_name),
         {:ok, fact} <-
           IngressPipeline.construct(:reaction, binding, input, now, &FactNormalizer.reaction/3),
         :match <- IngressPipeline.filter(binding, fact) do
      Repo.transact(fn repo ->
        # Advisory lock on the entry key serializes concurrent reaction folds for
        # the same message so two simultaneous add/removes can't clobber the
        # reactions map.
        with :ok <- Projection.lock_entry(repo, fact) do
          case repo.get_by(SignalEntry,
                 signal_channel_id: fact.signal_channel_id,
                 provider_entry_id: fact.provider_entry_id
               ) do
            %SignalEntry{} = entry ->
              entry
              |> SignalEntry.changeset(Projection.reaction_entry_attrs(entry, fact, now))
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
         {:ok, fact} <-
           IngressPipeline.construct(:action, binding, input, now, &FactNormalizer.action/3),
         :match <- IngressPipeline.filter(binding, fact) do
      Repo.transact(fn repo ->
        with {:ok, channel} <- Projection.maybe_upsert_channel(repo, fact, now),
             {:ok, append_result} <-
               ActorInputEnvelope.append_actor_input(
                 binding,
                 fact,
                 fact.actor_input_type,
                 channel,
                 nil,
                 now
               ) do
          {:ok, actor_input_append_result(append_result, %{signal_channel: channel})}
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

  Internal sources (timers, system-generated events) have no provider channel or
  entry to mirror, so this path skips the channel/entry write entirely and goes
  straight to actor input. It is how Ankole feeds itself — e.g. a fired reminder
  becomes input to the session that scheduled it.
  """
  @spec emit_internal(String.t(), String.t(), map(), keyword()) :: ingress_result()
  def emit_internal(agent_uid, binding_name, input, options \\ []) when is_map(input) do
    now = Keyword.get(options, :now, DateTime.utc_now(:microsecond))

    with {:ok, binding} <- Bindings.get_binding(agent_uid, binding_name),
         {:ok, fact} <-
           IngressPipeline.construct(:internal, binding, input, now, &FactNormalizer.internal/3),
         :match <- IngressPipeline.filter(binding, fact) do
      Repo.transact(fn _repo ->
        with {:ok, append_result} <-
               ActorInputEnvelope.append_actor_input(
                 binding,
                 fact,
                 fact.actor_input_type,
                 nil,
                 nil,
                 now
               ) do
          {:ok, actor_input_append_result(append_result)}
        end
      end)
      |> wake_actor_runtime()
    else
      :no_match -> {:ok, %{status: :filtered}}
      {:error, _reason} = error -> error
    end
  end

  defp wake_actor_runtime({:ok, %{status: :accepted}} = result) do
    ActivationManager.wake()
    result
  end

  defp wake_actor_runtime(result), do: result

  defp emit_lifecycle(agent_uid, binding_name, input, provider_lifecycle_kind, options) do
    now = Keyword.get(options, :now, DateTime.utc_now(:microsecond))

    with {:ok, binding} <- Bindings.get_binding(agent_uid, binding_name),
         constructor <- lifecycle_constructor(provider_lifecycle_kind),
         {:ok, fact} <- IngressPipeline.construct(:lifecycle, binding, input, now, constructor),
         :match <- IngressPipeline.filter(binding, fact) do
      binding
      |> accept_lifecycle(fact, now)
      |> TurnRetry.dispatch_retry_controls()
      |> wake_actor_runtime()
    else
      :no_match -> {:ok, %{status: :filtered}}
      {:error, _reason} = error -> error
    end
  end

  # Whole acceptance runs in one transaction behind the per-entry advisory lock,
  # so concurrent receives for the same message serialize and the
  # tombstone-check → mirror → actor-input sequence is atomic. The tombstone
  # check comes first: if the human already removed this entry, drop the
  # late receive before writing anything.
  defp accept_entry(binding, fact, options, now) do
    Repo.transact(fn repo ->
      with :ok <- Projection.lock_entry(repo, fact) do
        case Projection.active_tombstone?(repo, fact, now) do
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

  defp lifecycle_constructor(provider_lifecycle_kind) do
    fn binding, input, now ->
      FactNormalizer.lifecycle(binding, input, provider_lifecycle_kind, now)
    end
  end

  # Removal is the inverse of accept and does several things atomically:
  # 1) drop a tombstone so a re-delivered receive can't resurrect the entry,
  # 2) remove the source from any open inbound batch, 3) remove the mirror row,
  # 4) cancel any still-pending actor input for that entry, and 5) for input the
  # agent ALREADY consumed, append a lifecycle "removed" input that
  # ActorRuntime consumes into an introspection note. Steps 2-4 cover work that
  # has not committed yet; step 5 covers committed actor state.
  defp accept_lifecycle(binding, fact, now) do
    Repo.transact(fn repo ->
      with {:ok, channel} <- Projection.upsert_channel(repo, fact, now),
           :ok <- Projection.lock_entry(repo, fact),
           :ok <- Projection.lock_inbound_batch(repo, fact),
           {:ok, tombstone} <- Projection.upsert_tombstone(repo, fact, now),
           {:ok, updated_batches} <- InboundBatches.remove_pending_inbound_entry(repo, fact, now),
           {deleted_count, _rows} <- Projection.delete_mirror_entry(repo, fact),
           {:ok, runtime_retractions} <-
             TurnRetry.retract_source_entry_in_tx(repo, fact, :removed, now),
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
           updated_inbound_batches: length(updated_batches),
           deleted_mirror_entries: deleted_count,
           canceled_actor_inputs: runtime_retractions.canceled_actor_inputs,
           retried_actor_inputs: runtime_retractions.retried_actor_inputs,
           runtime_retractions: runtime_retractions,
           lifecycle_inputs: lifecycle_inputs
         }}
      end
    end)
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

  # "Explicit" = the agent is unambiguously being talked to: every DM qualifies,
  # and a group message qualifies only if it @-mentions the agent. This gates
  # both command parsing and the default addressed-message path.
  defp explicit_im_entry?(%{channel_kind: :im_dm}), do: true
  defp explicit_im_entry?(%{channel_kind: :im_group, explicit?: true}), do: true
  defp explicit_im_entry?(_fact), do: false

  # Lets a human answer the agent's clarifying question in a group without having
  # to re-@-mention it. Only relevant for group text messages; the actual "did
  # the agent recently ask something here" check is injected by the caller as
  # `clarify_lookup` (kept out of the gateway so this module stays free of
  # conversation-history queries). Accepts a 1- or 2-arity lookup for caller
  # convenience.
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

  # Commands are only honored when the agent is explicitly addressed, so a "/stop"
  # overheard in an unaddressed group line is not treated as a command. The
  # leading @-mention is stripped before classification so "@agent /stop" parses.
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

  # The direct accept path is for non-IM inputs and typed command events. IM text
  # and attachment traffic has already been diverted into pending inbound batches.
  defp apply_entry_policy(repo, binding, fact, {:actor_input, "im.message.addressed", nil}, now)
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
         {:actor_input, "im.message.may_intervene", nil},
         now
       )
       when fact.channel_kind == :im_group do
    InboundBatches.apply_im_entry_policy(repo, binding, fact, :may_intervene, nil, now)
  end

  defp apply_entry_policy(repo, binding, fact, {:actor_input, type, command_payload}, now) do
    fact = Map.put(fact, :command_payload, command_payload)

    with {:ok, channel} <- Projection.upsert_channel(repo, fact, now),
         {:ok, entry} <- Projection.mirror_receive_entry(repo, fact, now),
         {:ok, append_result} <-
           ActorInputEnvelope.append_actor_input(binding, fact, type, channel, entry, now) do
      {:ok,
       actor_input_append_result(append_result, %{
         signal_channel: channel,
         signal_entry: entry
       })}
    end
  end

  defp actor_input_append_result(append_result, extra \\ %{})

  defp actor_input_append_result(%ActorInput{} = actor_input, extra) do
    extra
    |> Map.merge(%{status: :accepted, actor_input: actor_input})
  end

  defp append_lifecycle_inputs(_binding, _fact, [], _channel, _now), do: {:ok, []}

  defp append_lifecycle_inputs(binding, fact, consumed_inputs, channel, now) do
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

      ActorInputEnvelope.append_actor_input(
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
