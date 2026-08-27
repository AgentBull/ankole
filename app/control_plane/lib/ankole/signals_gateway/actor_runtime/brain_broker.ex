defmodule Ankole.SignalsGateway.ActorRuntime.BrainBroker do
  @moduledoc """
  RuntimeFabric RPC entry point for the Brain memory tools.

  Every operation runs as the Turn's Agent: the Agent is the querier for the
  knowledge boundary, and the current conversation supplies the disclosure
  recipients — the asking human plus, in strict mode on a group channel, the
  channel member set; a scheduled Turn that has no asker takes its
  recipients from the channel it delivers into. `remember` commits
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
  alias Ankole.Brain.Objects
  alias Ankole.Brain.Recall
  alias Ankole.Brain.Scope
  alias Ankole.Brain.Synthesis
  alias Ankole.AIGateway.Conversations
  alias Ankole.AIGateway.Schemas.Conversation
  alias Ankole.AIGateway.Schemas.Message
  alias Ankole.JSON
  alias Ankole.Principals.Agent
  alias Ankole.Principals.Principal
  alias Ankole.Repo
  alias Ankole.RuntimeFabric.V1, as: FabricProto
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
           {:ok, scope} <- required(params, "scope"),
           {:ok, provenance} <- required(params, "provenance") do
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

        attrs = put_parent(base, turn_ref, params["entity"])

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
      with {:ok, params} <- decode_params(request),
           :ok <- ensure_enabled(),
           {:ok, name} <- required(params, "name"),
           {:ok, access} <- Access.for_querier(turn_ref.agent_uid) do
        disclosure = turn_disclosure(turn_ref)

        case Objects.resolve_reference(name) do
          {:ok, object} ->
            card =
              ContextPack.entity_card(
                object.slug,
                access,
                disclosure,
                Config.forgetting(),
                DateTime.utc_now(),
                turn_channel_id(turn_ref)
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

  # ── Context pack slot ───────────────────────────────────────────

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

  # ── Turn context ────────────────────────────────────────────────

  # The disclosure recipients come from the Turn's channel: the asking
  # sender always, plus every channel-group member in strict mode. Private
  # chats carry only the asker, so both modes behave the same there.
  #
  # A scheduled Turn — a cron fire, a check-back wakeup — has no sender and
  # still delivers into a channel, so its recipients come from the channel
  # itself and every one of them is checked. Relaxed mode narrows the check
  # to the asker because the asker drives the Turn; with no asker there is
  # nothing to relax to, and the empty recipient set protects nobody. A
  # channel kind that is not an IM conversation has no recipient to protect
  # and keeps the empty set.
  defp turn_disclosure(%TurnRef{} = turn_ref) do
    mode = agent_disclosure_mode(turn_ref.agent_uid)
    event = actor_event(turn_ref)
    asker = event && event.sender_key
    channel = event && event.signal_channel_id && Repo.get(Channel, event.signal_channel_id)

    cond do
      is_nil(channel) ->
        %{mode: mode, asker_uid: asker, present_uids: []}

      is_nil(asker) ->
        %{mode: :strict, asker_uid: nil, present_uids: channel_recipient_uids(channel)}

      mode == :strict ->
        %{mode: :strict, asker_uid: asker, present_uids: channel_group_member_uids(channel)}

      true ->
        %{mode: :relaxed, asker_uid: asker, present_uids: []}
    end
  end

  # Who receives what this channel delivers, without an asking sender: the
  # member group of a group chat, and the humans who have spoken in a
  # private chat.
  defp channel_recipient_uids(%Channel{kind: :im_group} = channel),
    do: channel_group_member_uids(channel)

  defp channel_recipient_uids(%Channel{kind: :im_dm, id: channel_id}),
    do: human_speaker_uids(channel_id)

  defp channel_recipient_uids(%Channel{}), do: []

  defp channel_group_member_uids(%Channel{kind: :im_group, principal_group_id: group_id})
       when is_binary(group_id),
       do: group_member_uids(group_id)

  defp channel_group_member_uids(%Channel{}), do: []

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
      {:ok, members} -> Enum.map(members, & &1.principal.uid)
      {:error, _missing_or_computed} -> []
    end
  end

  # remember parents on the named entity when it uniquely resolves, then the
  # Turn's channel, then the Agent's own canonical page for channel-less
  # sessions. The channel fallback for an unresolved or ambiguous name is
  # the documented tool behavior, and the response reports the parent it
  # landed on.
  defp put_parent(attrs, turn_ref, entity) do
    resolved =
      case entity do
        entity when is_binary(entity) and entity != "" ->
          case Objects.resolve_reference(entity) do
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

  # ── Shared plumbing ─────────────────────────────────────────────

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
