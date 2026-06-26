defmodule Ankole.AIAgent do
  @moduledoc """
  Minimal durable AI-agent conversation, transcript, and turn API.
  """

  import Ecto.Query, warn: false

  alias Ankole.AIAgent.Schemas.Conversation
  alias Ankole.AIAgent.Schemas.LlmTurn
  alias Ankole.AIAgent.Schemas.Message
  alias Ankole.AIAgent.MessageContext
  alias Ankole.AIAgent.ModelProfiles
  alias Ankole.Actors.ActorInput
  alias Ankole.Repo

  @type actor_key :: %{agent_uid: String.t(), session_id: String.t()}

  @doc """
  Creates or reuses the active conversation for one actor session.

  The conversation is the durable transcript owner. ActorRuntime owns worker
  delivery and activation fences, but it should not create a separate transcript
  model for the same user story.
  """
  @spec ensure_conversation(String.t(), String.t(), keyword()) ::
          {:ok, Conversation.t()} | {:error, term()}
  def ensure_conversation(agent_uid, session_id, opts \\ []) do
    repo = Keyword.get(opts, :repo, Repo)
    ensure_conversation_in_tx(repo, normalize_uid(agent_uid), session_id)
  end

  @doc false
  @spec ensure_conversation_in_tx(module(), String.t(), String.t()) ::
          {:ok, Conversation.t()} | {:error, term()}
  # Uses insert-then-refetch to tolerate concurrent first input for the same
  # actor session without exposing unique-constraint details to callers.
  def ensure_conversation_in_tx(repo, agent_uid, session_id) do
    agent_uid = normalize_uid(agent_uid)

    case active_conversation(repo, agent_uid, session_id) do
      %Conversation{} = conversation ->
        {:ok, conversation}

      nil ->
        %Conversation{}
        |> Conversation.changeset(%{
          agent_uid: agent_uid,
          conversation_key: session_id,
          generation: %{},
          metadata: %{}
        })
        |> repo.insert()
        |> case do
          {:ok, %Conversation{} = conversation} -> {:ok, conversation}
          {:error, _changeset} -> refetch_active_conversation(repo, agent_uid, session_id)
        end
    end
  end

  @doc """
  Starts a durable LLM turn for the actor inputs.

  The turn is created before worker delivery so retries, stale replies, and
  provider-visible side effects all share one database-owned generation fence.
  If no runtime model profile exists, no turn is started.
  """
  @spec start_llm_turn(actor_key(), [ActorInput.t()], keyword()) ::
          {:ok, map()} | {:error, term()}
  def start_llm_turn(actor_key, actor_inputs, opts \\ [])
      when is_list(actor_inputs) do
    now = Keyword.get(opts, :now, DateTime.utc_now(:microsecond))

    Repo.transact(fn repo ->
      with {:ok, conversation} <-
             ensure_conversation_in_tx(repo, actor_key.agent_uid, actor_key.session_id),
           %Conversation{} = conversation <- lock_conversation(repo, conversation.id),
           {:ok, result} <-
             start_llm_turn_in_tx(
               repo,
               conversation,
               actor_inputs,
               opts ++ [now: now]
             ) do
        {:ok, result}
      else
        nil -> {:error, :conversation_not_found}
        {:error, _reason} = error -> error
      end
    end)
  end

  @doc false
  @spec start_llm_turn_in_tx(module(), Conversation.t(), [ActorInput.t()], keyword()) ::
          {:ok, map()} | {:error, term()}
  # Starts the AI-agent side before ActorRuntime sends anything to the worker.
  # This makes delivery retry recoverable from the database instead of relying
  # on an in-memory worker-start event.
  def start_llm_turn_in_tx(repo, %Conversation{} = conversation, actor_inputs, opts)
      when is_list(actor_inputs) do
    now = Keyword.get(opts, :now, DateTime.utc_now(:microsecond))
    lease_seconds = Keyword.get(opts, :lease_seconds, 300)
    lease_id = Keyword.get_lazy(opts, :lease_id, fn -> "lease-" <> Ecto.UUID.generate() end)

    with :ok <- reject_live_generation(conversation, now),
         {:ok, user_messages} <- turn_input_messages(repo, conversation, actor_inputs, opts),
         {:ok, conversation} <-
           put_generation(
             repo,
             conversation,
             actor_inputs,
             user_messages,
             lease_id,
             now,
             lease_seconds
           ),
         {:ok, llm_turn} <-
           insert_llm_turn(
             repo,
             conversation,
             actor_inputs,
             user_messages,
             lease_id,
             now,
             opts
           ) do
      {:ok,
       %{
         conversation: conversation,
         user_messages: user_messages,
         llm_turn: llm_turn,
         lease_id: lease_id
       }}
    end
  end

  @doc """
  Marks a started turn failed and clears its conversation generation lease.
  """
  @spec mark_turn_failed(Ecto.UUID.t(), term(), keyword()) ::
          {:ok, LlmTurn.t()} | {:error, term()}
  def mark_turn_failed(llm_turn_id, reason, opts \\ []) do
    now = Keyword.get(opts, :now, DateTime.utc_now(:microsecond))

    Repo.transact(fn repo ->
      with %LlmTurn{} = turn <- lock_turn(repo, llm_turn_id),
           %Conversation{} = conversation <- lock_conversation(repo, turn.conversation_id),
           {:ok, turn} <- fail_turn_in_tx(repo, turn, reason, now),
           {:ok, _conversation} <- clear_generation_in_tx(repo, conversation, turn.lease_id) do
        {:ok, turn}
      else
        nil -> {:error, :llm_turn_not_found}
        {:error, _reason} = error -> error
      end
    end)
  end

  @doc false
  # Failing a turn keeps the error on the durable turn response so watchdog and
  # operator views can explain why the actor input became retryable.
  def fail_turn_in_tx(repo, %LlmTurn{} = turn, reason, now) do
    response =
      turn.response
      |> Map.put("error_code", error_code(reason))
      |> Map.put("error", inspect(reason))

    turn
    |> LlmTurn.changeset(%{status: "failed", response: response, completed_at: now})
    |> repo.update()
  end

  @doc false
  # A user-initiated cancellation is terminal but not an execution failure. Keep
  # the durable reason on the turn so retry/history views do not see an orphaned
  # `started` row after `/stop` or `/new` has fenced off the old generation lease.
  def cancel_turn_in_tx(repo, %LlmTurn{} = turn, reason, now) do
    response =
      turn.response
      |> Map.put("cancel_code", cancel_code(reason))
      |> Map.put("cancel_reason", inspect(reason))

    turn
    |> LlmTurn.changeset(%{status: "cancelled", response: response, completed_at: now})
    |> repo.update()
  end

  @doc false
  # Clears only the matching active generation lease. If a newer lease has been
  # installed, this older turn must not erase it.
  def clear_generation_in_tx(repo, %Conversation{} = conversation, lease_id) do
    generation = conversation.generation || %{}

    case generation["lease_id"] == lease_id do
      true ->
        conversation
        |> Conversation.changeset(%{generation: %{}})
        |> repo.update()

      false ->
        {:ok, conversation}
    end
  end

  @doc false
  def lock_conversation(repo, conversation_id) do
    Conversation
    |> where([conversation], conversation.id == ^conversation_id)
    |> lock("FOR UPDATE")
    |> repo.one()
  end

  @doc false
  def lock_turn(repo, llm_turn_id) do
    LlmTurn
    |> where([turn], turn.id == ^llm_turn_id)
    |> lock("FOR UPDATE")
    |> repo.one()
  end

  defp active_conversation(repo, agent_uid, session_id) do
    Conversation
    |> where([conversation], conversation.agent_uid == ^agent_uid)
    |> where([conversation], conversation.conversation_key == ^session_id)
    |> where([conversation], is_nil(conversation.ended_at))
    |> repo.one()
  end

  defp refetch_active_conversation(repo, agent_uid, session_id) do
    case active_conversation(repo, agent_uid, session_id) do
      %Conversation{} = conversation -> {:ok, conversation}
      nil -> {:error, :conversation_not_found}
    end
  end

  # Allows a new turn only when the conversation has no live generation lease.
  # Expired or cancelled leases are treated as recoverable gaps, not as hard
  # blockers for the user story.
  defp reject_live_generation(%Conversation{generation: generation}, now)
       when is_map(generation) do
    cond do
      blank?(generation["lease_id"]) ->
        :ok

      generation["cancelled_at"] ->
        :ok

      generation_expired?(generation, now) ->
        :ok

      true ->
        {:error, :active_turn_exists}
    end
  end

  defp reject_live_generation(_conversation, _now), do: :ok

  # Treats malformed expiry timestamps as not expired. That is conservative:
  # unknown lease state should not silently start a second generation.
  defp generation_expired?(%{"expires_at" => expires_at}, now) when is_binary(expires_at) do
    with {:ok, expires_at, _offset} <- DateTime.from_iso8601(expires_at) do
      DateTime.compare(expires_at, now) != :gt
    else
      _error -> false
    end
  end

  defp generation_expired?(_generation, _now), do: false

  # Materializes actor inputs into transcript messages before the worker turn is
  # started. The local computer can then reason from transcript history while
  # ActorRuntime still owns delivery state separately.
  defp turn_input_messages(repo, conversation, actor_inputs, opts) do
    case Keyword.get(opts, :input_messages, :materialize) do
      :materialize ->
        materialize_user_messages(repo, conversation, actor_inputs)

      {:existing, messages} when is_list(messages) ->
        {:ok, messages}

      _value ->
        {:error, :invalid_turn_input_messages}
    end
  end

  defp materialize_user_messages(repo, conversation, actor_inputs) do
    history = MessageContext.load_history(repo, conversation.id)

    Enum.reduce_while(actor_inputs, {:ok, [], history}, fn actor_input,
                                                           {:ok, messages, history} ->
      case materialize_user_message(repo, conversation, actor_input, history) do
        {:ok, %Message{} = message} ->
          {:cont,
           {:ok, [message | messages], MessageContext.append_history(history, message.metadata)}}

        {:error, _reason} = error ->
          {:halt, error}
      end
    end)
    |> case do
      {:ok, messages, _history} -> {:ok, Enum.reverse(messages)}
      {:error, _reason} = error -> error
    end
  end

  # Inserts user or ambient messages idempotently by ingress event. Provider
  # retries should not create duplicate transcript messages.
  defp materialize_user_message(
         repo,
         %Conversation{} = conversation,
         %ActorInput{} = actor_input,
         history
       ) do
    attrs = %{
      agent_uid: conversation.agent_uid,
      conversation_id: conversation.id,
      role: role_for_input(actor_input),
      kind: "normal",
      status: "complete",
      content: content_for_input(actor_input),
      event_source: "signals_gateway:#{actor_input.binding_name}",
      event_id: actor_input.ingress_event_id,
      metadata: metadata_for_input(actor_input, history)
    }

    # The conflict target must spell out the partial unique index's WHERE clause
    # verbatim (only inbound normal user/ambient rows with a real event are
    # deduplicated), so Postgres matches this insert to that exact index. On
    # conflict we keep the existing row; `message_insert_result/3` then refetches
    # it because `on_conflict: :nothing` returns a row with a nil id.
    %Message{}
    |> Message.changeset(attrs)
    |> repo.insert(
      on_conflict: :nothing,
      conflict_target:
        {:unsafe_fragment,
         "(conversation_id, event_source, event_id) WHERE role IN ('user', 'im_ambient') AND kind = 'normal' AND event_source IS NOT NULL AND event_id IS NOT NULL"},
      returning: true
    )
    |> message_insert_result(repo, attrs)
  end

  defp message_insert_result({:ok, %Message{id: nil}}, repo, attrs) do
    case repo.get_by(Message,
           conversation_id: attrs.conversation_id,
           event_source: attrs.event_source,
           event_id: attrs.event_id
         ) do
      %Message{} = message -> {:ok, message}
      nil -> {:error, :message_not_found}
    end
  end

  defp message_insert_result({:ok, %Message{} = message}, _repo, _attrs), do: {:ok, message}
  defp message_insert_result({:error, _changeset} = error, _repo, _attrs), do: error

  # Stores the active generation lease on the conversation. This is the durable
  # mutex between the AI-agent transcript and actor-runtime delivery work.
  defp put_generation(
         repo,
         conversation,
         actor_inputs,
         user_messages,
         lease_id,
         now,
         lease_seconds
       ) do
    trigger_input = List.first(actor_inputs)
    trigger_message = List.first(user_messages)

    generation = %{
      "lease_id" => lease_id,
      "trigger_message_id" => trigger_message && trigger_message.id,
      "trigger_event_id" => trigger_input && trigger_input.ingress_event_id,
      "started_at" => DateTime.to_iso8601(now),
      "heartbeat_at" => DateTime.to_iso8601(now),
      "expires_at" => now |> DateTime.add(lease_seconds, :second) |> DateTime.to_iso8601(),
      "pending_followups" => [],
      "pending_steering" => []
    }

    conversation
    |> Conversation.changeset(%{generation: generation})
    |> repo.update()
  end

  # Creates the durable turn shell consumed by Agent Computer. Provider/model
  # come from the current runtime profile; missing profiles are configuration
  # errors rather than synthetic turns.
  defp insert_llm_turn(
         repo,
         conversation,
         actor_inputs,
         user_messages,
         lease_id,
         now,
         opts
       ) do
    kind = Keyword.get(opts, :kind) || generation_turn_kind(repo, conversation, actor_inputs)

    with {:ok, model_ref} <-
           turn_model_ref(conversation.agent_uid, Keyword.get(opts, :profile, "primary")) do
      attrs = %{
        agent_uid: conversation.agent_uid,
        conversation_id: conversation.id,
        kind: kind,
        status: "started",
        profile: model_ref.profile,
        provider: model_ref.provider,
        model: model_ref.model,
        lease_id: lease_id,
        call_index: 0,
        trigger_message_id: user_messages |> List.first() |> maybe_id(),
        trigger_event_id: actor_inputs |> List.first() |> maybe_ingress_event_id(),
        input_message_ids: Enum.map(user_messages, & &1.id),
        request_context:
          request_context(conversation, model_ref, Keyword.get(opts, :request_context, %{})),
        request_refs: Enum.map(actor_inputs, &actor_input_ref/1),
        request_patches: [],
        response: %{},
        tool_results: [],
        usage: %{},
        provider_metadata: model_ref.provider_metadata,
        started_at: now
      }

      %LlmTurn{}
      |> LlmTurn.changeset(attrs)
      |> repo.insert()
    end
  end

  defp request_context(%Conversation{} = conversation, model_ref, extra_context)
       when is_map(extra_context) do
    %{
      "actor_key" => %{
        "agent_uid" => conversation.agent_uid,
        "session_id" => conversation.conversation_key
      },
      "model_ref" => %{
        "profile" => model_ref.profile,
        "provider_id" => model_ref.provider_id,
        "model" => model_ref.model
      }
    }
    |> Map.merge(extra_context)
  end

  defp request_context(%Conversation{} = conversation, model_ref, _extra_context) do
    request_context(conversation, model_ref, %{})
  end

  defp turn_model_ref(agent_uid, profile) do
    case ModelProfiles.resolve_runtime_profile(agent_uid, profile) do
      {:ok, runtime_profile} ->
        {:ok,
         %{
           profile: runtime_profile["profile"],
           provider: runtime_profile["provider_source"],
           provider_id: runtime_profile["provider_id"],
           model: runtime_profile["model"],
           provider_metadata: %{
             "provider_id" => runtime_profile["provider_id"],
             "provider_source" => runtime_profile["provider_source"],
             "adapter" => get_in(runtime_profile, ["source_metadata", "adapter"]),
             "adapter_strategy" =>
               get_in(runtime_profile, ["source_metadata", "adapter_strategy"])
           }
         }}

      {:error, reason} ->
        {:error, {:model_profile_unavailable, profile, reason}}
    end
  end

  # Labels a turn as retry when it is started for inputs that previously failed.
  # The behavior is the same, but the transcript can explain repeated attempts.
  defp generation_turn_kind(repo, %Conversation{} = conversation, actor_inputs) do
    case retry_generation?(repo, conversation, actor_inputs) do
      true -> "retry_generation"
      false -> "generation"
    end
  end

  defp retry_generation?(repo, %Conversation{} = conversation, actor_inputs) do
    if explicit_retry_input?(actor_inputs) do
      true
    else
      failed_turn_retry?(repo, conversation, actor_inputs)
    end
  end

  defp explicit_retry_input?(actor_inputs) do
    Enum.any?(actor_inputs, fn
      %ActorInput{payload: %{"data" => %{"entry" => %{"retry_of_llm_turn_id" => retry_turn_id}}}}
      when is_binary(retry_turn_id) ->
        true

      _input ->
        false
    end)
  end

  defp failed_turn_retry?(repo, %Conversation{} = conversation, actor_inputs) do
    actor_input_ids = actor_inputs |> Enum.map(& &1.id) |> MapSet.new()

    LlmTurn
    |> where([turn], turn.conversation_id == ^conversation.id)
    |> where([turn], turn.status == "failed")
    |> where([turn], turn.kind in ["generation", "retry_generation"])
    |> select([turn], turn.request_refs)
    |> repo.all()
    |> Enum.any?(&turn_refs_actor_input?(&1, actor_input_ids))
  end

  defp turn_refs_actor_input?(request_refs, actor_input_ids) when is_list(request_refs) do
    Enum.any?(request_refs, fn
      %{"actor_input_id" => actor_input_id} -> MapSet.member?(actor_input_ids, actor_input_id)
      %{actor_input_id: actor_input_id} -> MapSet.member?(actor_input_ids, actor_input_id)
      _ref -> false
    end)
  end

  defp turn_refs_actor_input?(_request_refs, _actor_input_ids), do: false

  # Ambient IM events are materialized but not treated as direct user commands.
  defp role_for_input(%ActorInput{type: "im.message.may_intervene"}), do: "im_ambient"
  defp role_for_input(_input), do: "user"

  defp content_for_input(%ActorInput{} = actor_input) do
    text = input_text(actor_input) || ""
    [%{"type" => "text", "text" => text}]
  end

  defp metadata_for_input(%ActorInput{} = actor_input, history) do
    actor = input_actor(actor_input)
    room = input_room(actor_input)
    sent_at = input_sent_at(actor_input)

    metadata =
      %{
        "actor_input_id" => actor_input.id,
        "actor_input_type" => actor_input.type,
        "binding_name" => actor_input.binding_name,
        "session_id" => actor_input.session_id,
        "signal_channel_id" => actor_input.signal_channel_id,
        "provider_thread_id" => actor_input.provider_thread_id,
        "provider_entry_id" => actor_input.provider_entry_id,
        "broker_sequence" => actor_input.broker_sequence,
        "actor" => empty_to_nil(actor),
        "provider_refs" =>
          empty_to_nil(%{
            "event_id" => actor_input.ingress_event_id,
            "provider_message_id" => actor_input.provider_entry_id,
            "room_id" => actor_input.signal_channel_id,
            "thread_id" => actor_input.provider_thread_id || actor_input.signal_channel_id
          }),
        "route" =>
          empty_to_nil(%{
            "binding_name" => actor_input.binding_name,
            "provider_room_id" => actor_input.signal_channel_id,
            "provider_thread_id" =>
              actor_input.provider_thread_id || actor_input.signal_channel_id
          })
      }
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)
      |> Map.new()

    MessageContext.merge(
      metadata,
      MessageContext.build(
        %{
          actor: actor,
          room: room,
          sent_at: sent_at,
          timezone: system_timezone()
        },
        history
      )
    )
  end

  defp input_actor(%ActorInput{payload: payload}) when is_map(payload) do
    get_in(payload, ["data", "entry", "author"]) || %{}
  end

  defp input_actor(_input), do: %{}

  defp input_room(%ActorInput{payload: payload}) when is_map(payload) do
    get_in(payload, ["data", "channel"]) || %{}
  end

  defp input_room(_input), do: %{}

  defp input_sent_at(%ActorInput{payload: %{"time" => time}}) when is_binary(time), do: time
  defp input_sent_at(%ActorInput{available_at: %DateTime{} = available_at}), do: available_at
  defp input_sent_at(_input), do: DateTime.utc_now(:microsecond)

  defp empty_to_nil(map) when is_map(map) do
    map
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
    |> case do
      empty when map_size(empty) == 0 -> nil
      value -> value
    end
  end

  defp system_timezone do
    Application.get_env(:ankole, :system_timezone) ||
      System.get_env("ANKOLE_SYSTEM_TIMEZONE") ||
      "UTC"
  end

  defp actor_input_ref(%ActorInput{} = input) do
    %{
      "actor_input_id" => input.id,
      "broker_sequence" => input.broker_sequence,
      "type" => input.type,
      "ingress_event_id" => input.ingress_event_id,
      "provider_entry_id" => input.provider_entry_id
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  # Reads text from the few ingress shapes currently produced by
  # SignalsGateway. This is intentionally narrow; richer provider parsing
  # belongs at the signal adapter boundary.
  defp input_text(%ActorInput{type: "command." <> _name, payload: payload})
       when is_map(payload) do
    get_in(payload, ["data", "command", "argsText"]) ||
      get_in(payload, ["data", "entry", "text"]) ||
      get_in(payload, ["data", "internal", "text"]) ||
      payload["subject"]
  end

  defp input_text(%ActorInput{payload: payload}) when is_map(payload) do
    get_in(payload, ["data", "entry", "text"]) ||
      get_in(payload, ["data", "command", "argsText"]) ||
      get_in(payload, ["data", "internal", "text"]) ||
      payload["subject"]
  end

  defp input_text(_input), do: nil

  defp maybe_id(nil), do: nil
  defp maybe_id(%{id: id}), do: id

  defp maybe_ingress_event_id(nil), do: nil
  defp maybe_ingress_event_id(%ActorInput{ingress_event_id: id}), do: id

  defp error_code(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp error_code({reason, _details}) when is_atom(reason), do: Atom.to_string(reason)
  defp error_code(_reason), do: "turn_failed"

  defp cancel_code(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp cancel_code(reason) when is_binary(reason), do: reason
  defp cancel_code({reason, _details}) when is_atom(reason), do: Atom.to_string(reason)
  defp cancel_code(_reason), do: "turn_cancelled"

  defp blank?(nil), do: true
  defp blank?(""), do: true
  defp blank?(_value), do: false

  defp normalize_uid(value) when is_binary(value), do: String.downcase(value)
end
