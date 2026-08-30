defmodule Ankole.SignalsGateway.ActorRuntime.BrainBroker do
  @moduledoc """
  RuntimeFabric RPC entry point for the Brain memory tools.

  Every operation runs as the Turn's Agent: the Agent is the querier for the
  knowledge boundary, and the current conversation supplies the disclosure
  recipients — the asking human plus, in strict mode on a group channel, the
  channel member set; a scheduled Turn that has no asker takes its recipients
  from every channel it delivers into. An unresolved IM recipient set
  discloses nothing. `remember` commits
  synchronously inside the tool call; a later Turn failure or retry does not
  revert it.
  """

  import Ecto.Query, warn: false

  alias Ankole.Brain.Access
  alias Ankole.Brain.Claims
  alias Ankole.Brain.Config
  alias Ankole.Brain.ContextPack
  alias Ankole.Brain.Experts
  alias Ankole.Brain.Forget
  alias Ankole.Brain.GetPage
  alias Ankole.Brain.LazySkillVisibility
  alias Ankole.Brain.Objects
  alias Ankole.Brain.Recall
  alias Ankole.Brain.Scope
  alias Ankole.Brain.SourceLearning
  alias Ankole.Brain.Sources
  alias Ankole.Brain.Synthesis
  alias Ankole.AIGateway.Conversations
  alias Ankole.AIGateway.Schemas.Conversation
  alias Ankole.AIGateway.Schemas.Message
  alias Ankole.JSON
  alias Ankole.Principals.Agent
  alias Ankole.Principals.Principal
  alias Ankole.Repo
  alias Ankole.RuntimeFabric.V1, as: FabricProto
  alias Ankole.Schedule.Delivery
  alias Ankole.SignalsGateway.AIGatewayLink
  alias Ankole.SignalsGateway.ActorEvent
  alias Ankole.SignalsGateway.ActorRuntime.RPCWire
  alias Ankole.SignalsGateway.ActorRuntime.TurnRef
  alias Ankole.SignalsGateway.Channel
  alias Ankole.SignalsGateway.Entry

  @type ctx :: %{route: String.t(), request_id: String.t()}

  @spec handle_remember(TurnRef.t(), FabricProto.BrainRequest.t(), ctx()) ::
          {:ok, map()} | {:error, map()}
  def handle_remember(%TurnRef{} = turn_ref, request, ctx) do
    respond(ctx, "brain_rpc_failed", fn ->
      with {:ok, params} <- decode_params(request),
           :ok <- ensure_enabled(),
           {:ok, claim_text} <- required(params, "claim"),
           {:ok, scope} <- conversation_write_scope(params["scope"], turn_ref),
           {:ok, provenance} <- required(params, "provenance"),
           {:ok, visibility} <- LazySkillVisibility.for_querier(turn_ref.agent_uid) do
        kind = params["kind"] || "fact"
        holder = params["holder"] || "agents/" <> turn_ref.agent_uid

        base = %{
          claim: claim_text,
          kind: kind,
          holder: holder,
          audience_scope: scope,
          context: params["context"],
          provenance: provenance
        }

        attrs = put_parent(base, turn_ref, params["entity"], visibility)

        result =
          cond do
            kind in Claims.fact_kinds() and is_nil(params["until_date"]) ->
              attrs =
                Map.merge(attrs, %{
                  notability: params["notability"] || "medium",
                  confidence: params["confidence"] || 0.75,
                  valid_from: DateTime.utc_now(:microsecond)
                })

              Claims.write_fact(attrs, turn_ref.agent_uid)

            kind in Claims.fact_kinds() ->
              {:error, :until_date_only_for_takes}

            true ->
              with :ok <- validate_until_date(params["until_date"]) do
                attrs =
                  attrs
                  |> Map.delete(:context)
                  |> Map.merge(%{
                    weight: params["weight"] || 0.6,
                    until_date: params["until_date"]
                  })

                case Claims.write_take(attrs, turn_ref.agent_uid) do
                  {:ok, claim} -> {:ok, %{claim: claim, status: :inserted}}
                  {:error, _reason} = error -> error
                end
              end
          end

        with {:ok, %{claim: claim} = outcome} <- result do
          # The resolved parent goes back to the model: an entity that did
          # not resolve filed to the channel, and silence about that would
          # let the model keep misspelling the entity forever.
          {:ok,
           %{
             "status" => to_string(outcome[:status] || :inserted),
             "claim_id" => claim.id,
             "superseded_claim_id" => outcome[:superseded_claim_id],
             "audience_scope" => claim.audience_scope,
             "object_slug" => claim.object_slug,
             "signal_gateway_channel_id" => claim.signal_gateway_channel_id
           }}
        end
      end
    end)
  end

  @spec handle_learn_source(TurnRef.t(), FabricProto.BrainRequest.t(), ctx()) ::
          {:ok, map()} | {:error, map()}
  def handle_learn_source(%TurnRef{} = turn_ref, request, ctx) do
    respond(ctx, "brain_rpc_failed", fn ->
      with {:ok, params} <- decode_params(request),
           :ok <- ensure_enabled(),
           {:ok, url} <- required(params, "url"),
           :ok <- validate_learnable_url(url),
           {:ok, scope} <- conversation_write_scope(params["scope"], turn_ref),
           {:ok, source} <- find_or_register_url_source(url, scope),
           {:ok, _enqueued} <- SourceLearning.enqueue_learn(source.id) do
        {:ok,
         %{
           "status" => "learning",
           "source_id" => source.id,
           "audience_scope" => source.default_audience_scope
         }}
      end
    end)
  end

  @spec handle_recall(TurnRef.t(), FabricProto.BrainRequest.t(), ctx()) ::
          {:ok, map()} | {:error, map()}
  def handle_recall(%TurnRef{} = turn_ref, request, ctx) do
    respond(ctx, "brain_rpc_failed", fn ->
      with {:ok, params} <- decode_params(request),
           :ok <- ensure_enabled(),
           {:ok, query} <- required(params, "query") do
        disclosure = turn_disclosure(turn_ref)

        Recall.recall(
          turn_ref.agent_uid,
          %{
            query: query,
            entity: params["entity"],
            budget_tokens: params["budget_tokens"]
          },
          disclosure: disclosure
        )
        |> entity_resolution_payload()
      end
    end)
  end

  @spec handle_get_page(TurnRef.t(), FabricProto.BrainRequest.t(), ctx()) ::
          {:ok, map()} | {:error, map()}
  def handle_get_page(%TurnRef{} = turn_ref, request, ctx) do
    respond(ctx, "brain_rpc_failed", fn ->
      with {:ok, params} <- decode_params(request),
           :ok <- ensure_enabled(),
           {:ok, reference} <- required(params, "reference") do
        case GetPage.get_page(turn_ref.agent_uid, reference,
               disclosure: turn_disclosure(turn_ref)
             ) do
          {:ok, page} -> {:ok, %{"page" => JSON.plain(page)}}
          {:ambiguous, candidates} -> {:ok, %{"candidates" => JSON.plain(candidates)}}
          {:error, :not_found} -> {:ok, %{"error" => "not_found"}}
          {:error, _reason} = error -> error
        end
      end
    end)
  end

  @spec handle_forget(TurnRef.t(), FabricProto.BrainRequest.t(), ctx()) ::
          {:ok, map()} | {:error, map()}
  def handle_forget(%TurnRef{} = turn_ref, request, ctx) do
    respond(ctx, "brain_rpc_failed", fn ->
      with {:ok, params} <- decode_params(request),
           :ok <- ensure_enabled(),
           {:ok, reason} <- required(params, "reason") do
        result =
          case params["claim_id"] do
            claim_id when is_binary(claim_id) and claim_id != "" ->
              Forget.forget_claim(claim_id, reason, turn_ref.agent_uid)

            _missing ->
              with {:ok, slug} <- required(params, "slug") do
                Forget.forget_object(slug, reason, turn_ref.agent_uid)
              end
          end

        with {:ok, _forgotten} <- result do
          {:ok, %{"status" => "forgotten"}}
        end
      end
    end)
  end

  @spec handle_entity(TurnRef.t(), FabricProto.BrainRequest.t(), ctx()) ::
          {:ok, map()} | {:error, map()}
  def handle_entity(%TurnRef{} = turn_ref, request, ctx) do
    respond(ctx, "brain_rpc_failed", fn ->
      disclosure = turn_disclosure(turn_ref)

      with {:ok, params} <- decode_params(request),
           :ok <- ensure_enabled(),
           {:ok, name} <- required(params, "name"),
           {:ok, access} <- Access.for_readers(turn_ref.agent_uid, disclosure),
           {:ok, visibility} <- LazySkillVisibility.for_querier(turn_ref.agent_uid) do
        case Objects.resolve_reference(name, lazy_skill_visibility: visibility) do
          {:ok, object} ->
            card =
              ContextPack.entity_card(
                object.slug,
                access,
                disclosure,
                Config.forgetting(),
                DateTime.utc_now(),
                turn_channel_id(turn_ref),
                visibility
              )

            {:ok, %{"entity" => JSON.plain(card)}}

          {:ambiguous, candidates} ->
            {:ok, %{"candidates" => JSON.plain(candidates)}}

          {:error, :not_found} ->
            {:ok, %{"error" => "not_found"}}
        end
      end
    end)
  end

  @spec handle_whoknows(TurnRef.t(), FabricProto.BrainRequest.t(), ctx()) ::
          {:ok, map()} | {:error, map()}
  def handle_whoknows(%TurnRef{} = turn_ref, request, ctx) do
    respond(ctx, "brain_rpc_failed", fn ->
      with {:ok, params} <- decode_params(request),
           :ok <- ensure_enabled(),
           {:ok, topic} <- required(params, "topic"),
           {:ok, experts} <-
             Experts.who_knows(turn_ref.agent_uid, topic,
               limit: params["limit"] || 5,
               disclosure: turn_disclosure(turn_ref)
             ) do
        {:ok, %{"experts" => JSON.plain(experts)}}
      end
    end)
  end

  @spec handle_synthesize(TurnRef.t(), FabricProto.BrainRequest.t(), ctx()) ::
          {:ok, map()} | {:error, map()}
  def handle_synthesize(%TurnRef{} = turn_ref, request, ctx) do
    respond(ctx, "brain_rpc_failed", fn ->
      with {:ok, params} <- decode_params(request),
           :ok <- ensure_enabled(),
           {:ok, question} <- required(params, "question"),
           {:ok, result} <-
             Synthesis.synthesize(turn_ref.agent_uid, question,
               disclosure: turn_disclosure(turn_ref)
             ) do
        {:ok, JSON.plain(result)}
      end
    end)
  end

  @spec handle_delta(TurnRef.t(), FabricProto.BrainRequest.t(), ctx()) ::
          {:ok, map()} | {:error, map()}
  def handle_delta(%TurnRef{} = turn_ref, request, ctx) do
    respond(ctx, "brain_rpc_failed", fn ->
      with {:ok, params} <- decode_params(request),
           :ok <- ensure_enabled(),
           {:ok, since} <- optional_datetime(params, "since"),
           {:ok, until_at} <- optional_datetime(params, "until") do
        Synthesis.delta(
          turn_ref.agent_uid,
          %{entity: params["entity"], since: since, until: until_at},
          disclosure: turn_disclosure(turn_ref)
        )
        |> entity_resolution_payload()
      end
    end)
  end

  # An unparseable instant is an explicit error: silently treating it as
  # absent would widen the report to all history behind the caller's back.
  defp optional_datetime(params, key) do
    case Map.get(params, key) do
      empty when empty in [nil, ""] ->
        {:ok, nil}

      value when is_binary(value) ->
        case parse_datetime(value) do
          nil -> {:error, {:invalid_datetime, key}}
          datetime -> {:ok, datetime}
        end

      _value ->
        {:error, {:invalid_datetime, key}}
    end
  end

  # An entity reference the model gave that does not resolve comes back as a
  # correctable result payload with candidates, mirroring get_page, instead
  # of an opaque RPC error.
  defp entity_resolution_payload(result) do
    case result do
      {:ok, payload} ->
        {:ok, JSON.plain(payload)}

      {:error, {:ambiguous_entity, candidates}} ->
        {:ok, %{"error" => "ambiguous_entity", "candidates" => JSON.plain(candidates)}}

      {:error, {:entity_not_found, entity}} ->
        {:ok, %{"error" => "entity_not_found", "entity" => entity}}

      {:error, _reason} = error ->
        error
    end
  end

  @spec handle_context_pack(TurnRef.t(), FabricProto.BrainRequest.t(), ctx()) ::
          {:ok, map()} | {:error, map()}
  def handle_context_pack(%TurnRef{} = turn_ref, request, ctx) do
    respond(ctx, "brain_rpc_failed", fn ->
      with {:ok, params} <- decode_params(request) do
        case context_pack_slot(turn_ref) do
          {:claim, conversation, checkpoint} ->
            pack =
              ContextPack.context_pack(
                turn_ref.agent_uid,
                %{
                  participant_uids: List.wrap(params["participant_uids"] || []),
                  recent_text: params["recent_text"] || "",
                  channel_id: turn_channel_id(turn_ref)
                },
                disclosure: turn_disclosure(turn_ref)
              )

            record_context_pack_marker(conversation, checkpoint, turn_ref.actor_event_id)
            {:ok, JSON.plain(pack)}

          :skip ->
            {:ok, %{"entities" => [], "open_threads" => []}}
        end
      end
    end)
  end

  @spec handle_volunteer_pointers(TurnRef.t(), FabricProto.BrainRequest.t(), ctx()) ::
          {:ok, map()} | {:error, map()}
  def handle_volunteer_pointers(%TurnRef{} = turn_ref, request, ctx) do
    respond(ctx, "brain_rpc_failed", fn ->
      with {:ok, params} <- decode_params(request) do
        pointers =
          ContextPack.volunteer_pointers(
            turn_ref.agent_uid,
            params["message_text"] || "",
            disclosure: turn_disclosure(turn_ref)
          )

        {:ok, %{"pointers" => JSON.plain(pointers)}}
      end
    end)
  end

  # Context pack slot

  @context_pack_marker "brain_context_pack_at"
  @context_pack_event_marker "brain_context_pack_event"

  # The design injects one pack at conversation start and one after each
  # compaction. The conversation row and its compaction checkpoints are
  # control-plane state, so the broker owns the trigger: the Worker calls
  # context_pack on every Text Turn, and this check claims the slot only
  # when no pack was recorded since the newest compaction checkpoint — or
  # ever, for a fresh conversation. The marker stores the checkpoint instant
  # the pack covered, not the broker's clock, so the comparison does not
  # depend on clock alignment between the two writers, plus the claiming
  # actor event: a retry of the same event re-claims the slot, so a Worker
  # that died between the marker commit and the model request does not lose
  # the injection forever. Each slot records exactly one best-effort
  # attempt: assembly never raises out of ContextPack (a failure degrades to
  # an empty pack), so the marker commits either way, and the injection
  # contract is degrade-to-empty, not reliable delivery. A successor
  # conversation in the same session is a new row and starts with an empty
  # slot. Turns of one session are serialized by the actor runtime, so the
  # read-then-write is safe.
  defp context_pack_slot(%TurnRef{} = turn_ref) do
    case AIGatewayLink.active_conversation(turn_ref.agent_uid, turn_ref.session_id) do
      %Conversation{} = conversation ->
        metadata = conversation.metadata || %{}
        marker = parse_datetime(Map.get(metadata, @context_pack_marker))
        marker_event = Map.get(metadata, @context_pack_event_marker)
        checkpoint = newest_checkpoint_at(conversation.id)

        cond do
          marker == nil ->
            {:claim, conversation, checkpoint}

          checkpoint != nil and DateTime.compare(checkpoint, marker) == :gt ->
            {:claim, conversation, checkpoint}

          is_binary(marker_event) and marker_event == turn_ref.actor_event_id ->
            {:claim, conversation, checkpoint}

          true ->
            :skip
        end

      nil ->
        :skip
    end
  end

  defp newest_checkpoint_at(conversation_id) do
    Message
    |> where(
      [message],
      message.conversation_id == ^conversation_id and message.type == "checkpoint"
    )
    |> order_by([message], desc: message.inserted_at)
    |> limit(1)
    |> select([message], message.inserted_at)
    |> Repo.one()
  end

  defp record_context_pack_marker(%Conversation{} = conversation, checkpoint, actor_event_id) do
    covered = checkpoint || DateTime.utc_now()

    metadata =
      (conversation.metadata || %{})
      |> Map.put(@context_pack_marker, DateTime.to_iso8601(covered))
      |> Map.put(@context_pack_event_marker, actor_event_id)

    {:ok, _updated} =
      Conversations.update_conversation_metadata_in_tx(Repo, conversation, metadata)

    :ok
  end

  # Turn context

  defp turn_disclosure(%TurnRef{} = turn_ref) do
    case actor_event(turn_ref) do
      nil -> Access.open_disclosure()
      %ActorEvent{} = event -> event_disclosure(event, agent_disclosure_mode(turn_ref.agent_uid))
    end
  end

  # Relaxed mode is asker-only by contract. A Turn without an asker always
  # uses strict disclosure because its final text can still go to a channel.
  defp event_disclosure(%ActorEvent{sender_key: asker}, :relaxed) when is_binary(asker) do
    %{mode: :relaxed, asker_uid: asker, present_uids: []}
  end

  defp event_disclosure(%ActorEvent{} = event, _mode) do
    asker = event.sender_key

    with {:ok, channels} <- disclosure_channels(event),
         {:ok, present_uids} <- strict_present_uids(channels, asker) do
      if is_nil(asker) and not Enum.any?(channels, &im_channel?/1) do
        Access.open_disclosure()
      else
        %{mode: :strict, asker_uid: asker, present_uids: present_uids}
      end
    else
      {:error, _unresolved_recipient_set} -> closed_disclosure()
    end
  end

  defp disclosure_channels(%ActorEvent{} = event) do
    with {:ok, channel_ids} <- disclosure_channel_ids(event) do
      channels =
        Channel
        |> where([channel], channel.id in ^channel_ids)
        |> Repo.all()

      if length(channels) == length(channel_ids),
        do: {:ok, channels},
        else: {:error, :disclosure_channel_not_found}
    end
  end

  defp disclosure_channel_ids(%ActorEvent{} = event) do
    case ActorEvent.scheduled_delivery_snapshot(event) do
      %{} = delivery ->
        with {:ok, targets} <- Delivery.targets(delivery, event.binding_name) do
          {:ok, targets |> Enum.map(& &1["signal_channel_id"]) |> Enum.uniq()}
        end

      _no_scheduled_delivery ->
        {:ok, List.wrap(event.signal_channel_id)}
    end
  end

  defp strict_present_uids(channels, asker) do
    Enum.reduce_while(channels, {:ok, []}, fn channel, {:ok, acc} ->
      case strict_channel_recipient_uids(channel, asker) do
        {:ok, recipients} -> {:cont, {:ok, recipients ++ acc}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> then(fn
      {:ok, recipients} -> {:ok, Enum.uniq(recipients)}
      {:error, _reason} = error -> error
    end)
  end

  defp strict_channel_recipient_uids(%Channel{kind: :im_group} = channel, _asker) do
    with {:ok, recipients} <- channel_group_member_uids(channel),
         true <- recipients != [] do
      {:ok, recipients}
    else
      false -> {:error, :empty_group_recipient_set}
      {:error, _reason} = error -> error
    end
  end

  defp strict_channel_recipient_uids(%Channel{kind: :im_dm}, asker) when is_binary(asker),
    do: {:ok, [asker]}

  defp strict_channel_recipient_uids(%Channel{kind: :im_dm, id: channel_id}, nil) do
    case human_speaker_uids(channel_id) do
      [] -> {:error, :empty_dm_recipient_set}
      recipients -> {:ok, recipients}
    end
  end

  defp strict_channel_recipient_uids(%Channel{}, _asker), do: {:ok, []}

  defp channel_group_member_uids(%Channel{kind: :im_group, principal_group_id: group_id})
       when is_binary(group_id),
       do: group_member_uids(group_id)

  defp channel_group_member_uids(%Channel{kind: :im_group}),
    do: {:error, :group_recipient_set_unavailable}

  defp im_channel?(%Channel{kind: kind}), do: kind in [:im_dm, :im_group]

  defp closed_disclosure, do: %{mode: :strict, asker_uid: nil, present_uids: []}

  defp human_speaker_uids(channel_id) do
    Entry
    |> join(:inner, [entry], principal in Principal,
      on: principal.uid == fragment("?->>'principal_uid'", entry.author)
    )
    |> where([entry, _principal], entry.signal_channel_id == ^channel_id)
    |> where([_entry, principal], principal.type == :human)
    |> select([_entry, principal], principal.uid)
    |> distinct(true)
    |> Repo.all()
  end

  defp agent_disclosure_mode(agent_uid) do
    case Repo.get(Agent, agent_uid) do
      %Agent{group_memory_disclosure_mode: mode} -> mode
      nil -> :strict
    end
  end

  defp actor_event(%TurnRef{actor_event_id: nil}), do: nil

  defp actor_event(%TurnRef{actor_event_id: actor_event_id}),
    do: Repo.get(ActorEvent, actor_event_id)

  defp turn_channel_id(%TurnRef{} = turn_ref) do
    event = actor_event(turn_ref)
    event && event.signal_channel_id
  end

  defp group_member_uids(group_id) do
    case Ankole.AuthZ.list_group_members(group_id) do
      {:ok, members} -> {:ok, Enum.map(members, & &1.principal.uid)}
      {:error, _missing_or_computed} = error -> error
    end
  end

  # remember parents on the named entity when it uniquely resolves, then the
  # Turn's channel, then the Agent's own canonical page for channel-less
  # sessions. The channel fallback for an unresolved or ambiguous name is
  # the documented tool behavior, and the response reports the parent it
  # landed on.
  defp put_parent(attrs, turn_ref, entity, visibility) do
    resolved =
      case entity do
        entity when is_binary(entity) and entity != "" ->
          case Objects.resolve_reference(entity, lazy_skill_visibility: visibility) do
            {:ok, object} -> {:object, object.slug}
            _ambiguous_or_missing -> nil
          end

        _missing ->
          nil
      end

    case resolved do
      {:object, slug} ->
        Map.put(attrs, :object_slug, slug)

      nil ->
        event = actor_event(turn_ref)

        case event && event.signal_channel_id do
          channel_id when is_binary(channel_id) ->
            Map.put(attrs, :signal_gateway_channel_id, channel_id)

          _missing ->
            # The Turn's Agent Principal exists by construction; a missing
            # canonical page is a broken invariant, not a fallback case.
            {:ok, slug} = Scope.canonical_slug(turn_ref.agent_uid)
            Map.put(attrs, :object_slug, slug)
        end
    end
  end

  defp validate_learnable_url("http://" <> _rest), do: :ok
  defp validate_learnable_url("https://" <> _rest), do: :ok
  defp validate_learnable_url(_url), do: {:error, :invalid_url}

  # The conversation's audience is the default write scope, mirroring the
  # Signals-processing defaults: a DM learns for its asker, a member-backed
  # group learns for its member Group. Everything else — scheduled turns,
  # non-IM channels — falls back to the Agent's own principal scope. `world`
  # is an explicit model choice, never a default: the derived default also
  # bounds how far a poisoned claim or misjudged source can reach.
  defp conversation_write_scope(explicit, %TurnRef{} = turn_ref)
       when is_binary(explicit) and explicit != "" do
    with :ok <- Scope.validate_writable(explicit, turn_ref.agent_uid), do: {:ok, explicit}
  end

  defp conversation_write_scope(_missing, %TurnRef{} = turn_ref) do
    with {:ok, scope} <- derived_conversation_scope(actor_event(turn_ref), turn_ref.agent_uid),
         :ok <- Scope.validate_writable(scope, turn_ref.agent_uid) do
      {:ok, scope}
    end
  end

  defp derived_conversation_scope(nil, agent_uid), do: {:ok, Scope.principal(agent_uid)}

  defp derived_conversation_scope(%ActorEvent{} = event, agent_uid) do
    channel = event.signal_channel_id && Repo.get(Channel, event.signal_channel_id)

    case channel do
      %Channel{kind: :im_group, principal_group_id: group_id} when is_binary(group_id) ->
        case Ankole.AuthZ.get_principal_group(group_id) do
          {:ok, group} -> {:ok, Scope.group(group.name)}
          {:error, :not_found} -> {:error, :im_group_without_member_group}
        end

      %Channel{kind: :im_group} ->
        # No member Group means no derivable group audience. An explicit
        # scope is the way through, so the error names the real blocker.
        {:error, :im_group_without_member_group}

      %Channel{kind: :im_dm} when is_binary(event.sender_key) ->
        {:ok, Scope.principal(event.sender_key)}

      _other ->
        {:ok, Scope.principal(agent_uid)}
    end
  end

  # First registration wins the default scope; a later call with another
  # scope reuses the Source unchanged, and the response reports the scope
  # that actually applies. Changing it afterwards is a Console decision.
  defp find_or_register_url_source(url, scope) do
    case Sources.get_or_create(%{
           kind: "url",
           upstream_id: url,
           name: url,
           default_audience_scope: scope
         }) do
      {:ok, source} -> {:ok, source}
      {:error, %Ecto.Changeset{}} -> {:error, :source_registration_failed}
      {:error, _reason} = error -> error
    end
  end

  # Shared plumbing

  defp decode_params(%FabricProto.BrainRequest{params_json: params_json}) do
    case params_json do
      empty when empty in [nil, ""] ->
        {:ok, %{}}

      json ->
        case JSON.decode(json) do
          {:ok, params} when is_map(params) -> {:ok, params}
          _invalid -> {:error, :invalid_params_json}
        end
    end
  end

  defp ensure_enabled do
    if Config.enabled?(), do: :ok, else: {:error, :brain_disabled}
  end

  # `until_date` gates the take into Dreaming's due-date grading, so a value
  # that grade_takes cannot parse must be rejected at write time.
  defp validate_until_date(nil), do: :ok

  defp validate_until_date(value) when is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, _date} -> :ok
      {:error, _reason} -> {:error, :invalid_until_date}
    end
  end

  defp validate_until_date(_value), do: {:error, :invalid_until_date}

  defp required(params, key) do
    case Map.get(params, key) do
      value when is_binary(value) ->
        case String.trim(value) do
          "" -> {:error, {:missing, key}}
          text -> {:ok, text}
        end

      _value ->
        {:error, {:missing, key}}
    end
  end

  # A plain ISO 8601 date is a natural model input for delta; it reads as
  # midnight UTC of that day.
  defp parse_datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} ->
        datetime

      {:error, _reason} ->
        case Date.from_iso8601(value) do
          {:ok, date} -> DateTime.new!(date, ~T[00:00:00], "Etc/UTC")
          {:error, _reason} -> nil
        end
    end
  end

  defp parse_datetime(_value), do: nil

  defp respond(ctx, fallback_code, fun) do
    case fun.() do
      {:ok, payload} ->
        {:ok, payload}

      {:error, reason} ->
        {:error,
         RPCWire.error_payload(ctx.request_id, reason,
           fallback_code: fallback_code,
           details_json: %{"reason" => inspect(reason)}
         )}
    end
  end
end
