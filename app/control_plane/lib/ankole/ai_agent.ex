defmodule Ankole.AIAgent do
  @moduledoc """
  Minimal durable AI-agent conversation, transcript, and turn API.
  """

  import Ecto.Query, warn: false

  alias Ankole.AIAgent.Schemas.Conversation
  alias Ankole.AIAgent.Schemas.LlmTurn
  alias Ankole.AIAgent.Schemas.Message
  alias Ankole.Actors.ActorInput
  alias Ankole.Repo

  @placeholder_provider "ankole-placeholder"
  @placeholder_model "ping-pong-stub"

  @type actor_key :: %{agent_uid: String.t(), session_id: String.t()}

  @doc """
  Creates or reuses the active conversation for one actor session.
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
  Starts a placeholder LLM turn for the actor inputs.
  """
  @spec start_placeholder_llm_turn(actor_key(), [ActorInput.t()], keyword()) ::
          {:ok, map()} | {:error, term()}
  def start_placeholder_llm_turn(actor_key, actor_inputs, opts \\ [])
      when is_list(actor_inputs) do
    now = Keyword.get(opts, :now, DateTime.utc_now(:microsecond))

    Repo.transact(fn repo ->
      with {:ok, conversation} <-
             ensure_conversation_in_tx(repo, actor_key.agent_uid, actor_key.session_id),
           %Conversation{} = conversation <- lock_conversation(repo, conversation.id),
           {:ok, result} <-
             start_placeholder_llm_turn_in_tx(
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
  @spec start_placeholder_llm_turn_in_tx(module(), Conversation.t(), [ActorInput.t()], keyword()) ::
          {:ok, map()} | {:error, term()}
  def start_placeholder_llm_turn_in_tx(repo, %Conversation{} = conversation, actor_inputs, opts)
      when is_list(actor_inputs) do
    now = Keyword.get(opts, :now, DateTime.utc_now(:microsecond))
    lease_seconds = Keyword.get(opts, :lease_seconds, 300)
    lease_id = Keyword.get_lazy(opts, :lease_id, fn -> "lease-" <> Ecto.UUID.generate() end)

    with :ok <- reject_live_generation(conversation, now),
         {:ok, user_messages} <- materialize_user_messages(repo, conversation, actor_inputs),
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
           insert_placeholder_turn(
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

  defp generation_expired?(%{"expires_at" => expires_at}, now) when is_binary(expires_at) do
    with {:ok, expires_at, _offset} <- DateTime.from_iso8601(expires_at) do
      DateTime.compare(expires_at, now) != :gt
    else
      _error -> false
    end
  end

  defp generation_expired?(_generation, _now), do: false

  defp materialize_user_messages(repo, conversation, actor_inputs) do
    actor_inputs
    |> Enum.map(&materialize_user_message(repo, conversation, &1))
    |> collect_results()
  end

  defp materialize_user_message(repo, %Conversation{} = conversation, %ActorInput{} = actor_input) do
    attrs = %{
      agent_uid: conversation.agent_uid,
      conversation_id: conversation.id,
      role: role_for_input(actor_input),
      kind: "normal",
      status: "complete",
      content: content_for_input(actor_input),
      event_source: "signals_gateway:#{actor_input.binding_name}",
      event_id: actor_input.ingress_event_id,
      metadata: metadata_for_input(actor_input)
    }

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

  defp insert_placeholder_turn(
         repo,
         conversation,
         actor_inputs,
         user_messages,
         lease_id,
         now,
         opts
       ) do
    kind = Keyword.get(opts, :kind) || placeholder_turn_kind(repo, conversation, actor_inputs)

    attrs = %{
      agent_uid: conversation.agent_uid,
      conversation_id: conversation.id,
      kind: kind,
      status: "started",
      profile: "light",
      provider: @placeholder_provider,
      model: @placeholder_model,
      lease_id: lease_id,
      call_index: 0,
      trigger_message_id: user_messages |> List.first() |> maybe_id(),
      trigger_event_id: actor_inputs |> List.first() |> maybe_ingress_event_id(),
      input_message_ids: Enum.map(user_messages, & &1.id),
      request_context: %{
        "actor_key" => %{
          "agent_uid" => conversation.agent_uid,
          "session_id" => conversation.conversation_key
        }
      },
      request_refs: Enum.map(actor_inputs, &actor_input_ref/1),
      request_patches: [],
      response: %{},
      tool_results: [],
      usage: %{},
      provider_metadata: %{},
      started_at: now
    }

    %LlmTurn{}
    |> LlmTurn.changeset(attrs)
    |> repo.insert()
  end

  defp placeholder_turn_kind(repo, %Conversation{} = conversation, actor_inputs) do
    case retry_generation?(repo, conversation, actor_inputs) do
      true -> "retry_generation"
      false -> "generation"
    end
  end

  defp retry_generation?(repo, %Conversation{} = conversation, actor_inputs) do
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

  defp role_for_input(%ActorInput{type: "im.message.may_intervene"}), do: "im_ambient"
  defp role_for_input(_input), do: "user"

  defp content_for_input(%ActorInput{} = actor_input) do
    text = input_text(actor_input) || ""
    [%{"type" => "text", "text" => text}]
  end

  defp metadata_for_input(%ActorInput{} = actor_input) do
    %{
      "actor_input_id" => actor_input.id,
      "actor_input_type" => actor_input.type,
      "binding_name" => actor_input.binding_name,
      "session_id" => actor_input.session_id,
      "signal_channel_id" => actor_input.signal_channel_id,
      "provider_thread_id" => actor_input.provider_thread_id,
      "provider_entry_id" => actor_input.provider_entry_id,
      "broker_sequence" => actor_input.broker_sequence
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
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

  defp error_code(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp error_code({reason, _details}) when is_atom(reason), do: Atom.to_string(reason)
  defp error_code(_reason), do: "turn_failed"

  defp blank?(nil), do: true
  defp blank?(""), do: true
  defp blank?(_value), do: false

  defp normalize_uid(value) when is_binary(value), do: String.downcase(value)
end
