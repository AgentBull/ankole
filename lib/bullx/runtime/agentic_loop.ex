defmodule BullX.Runtime.AgenticLoop do
  @moduledoc """
  Conversation runtime for `agentic_loop` Agent Principals.

  This first runtime slice handles routed inbound chat Signals: it persists the
  user turn in `agent_sessions` / `agent_messages`, calls the Agent-owned main
  LLM, persists the assistant turn, and hands the reply back to Gateway.
  """

  import Ecto.Query

  alias BullX.Gateway.JSON
  alias BullX.Principals.Agent
  alias BullX.Principals.AgentProfiles.AgenticLoop, as: AgenticLoopProfile
  alias BullX.Principals.Principal
  alias BullX.Repo
  alias BullX.Runtime.AgenticLoop.{Message, Session}
  alias BullX.Runtime.SignalRouting.RouteDecision
  alias ReqLLM.Context

  @route_decision_id_key "route_decision_id"
  @new_session_aliases ["/new", "/新会话"]
  @rendered_kinds [:normal, :summary]

  @type prepared_turn ::
          :no_reply
          | {:deliver_existing, RouteDecision.t(), Message.t()}
          | {:generate, map()}

  @spec handle_route_decision(RouteDecision.t()) :: :ok | {:error, term()}
  def handle_route_decision(%RouteDecision{route_action: :deliver_agent} = decision) do
    with {:ok, prepared} <- prepare_turn(decision) do
      run_prepared(prepared)
    end
  end

  def handle_route_decision(%RouteDecision{}), do: :ok

  defp prepare_turn(%RouteDecision{} = decision) do
    with {:ok, %{agent: agent, principal: principal}} <- fetch_agent_context(decision),
         {:ok, profile} <- AgenticLoopProfile.effective(agent.profile || %{}),
         {:ok, content_snapshot} <- content_snapshot(decision) do
      Repo.transaction(fn ->
        prepare_turn_in_transaction(decision, agent, principal, profile, content_snapshot)
      end)
    end
  end

  defp prepare_turn_in_transaction(decision, agent, principal, profile, content_snapshot) do
    case assistant_message_for_decision(decision.id) do
      %Message{} = message ->
        {:deliver_existing, decision, message}

      nil ->
        prepare_incomplete_turn(decision, agent, principal, profile, content_snapshot)
    end
  end

  defp prepare_incomplete_turn(decision, agent, principal, profile, content_snapshot) do
    case user_message_for_decision(decision.id) do
      %Message{} = message ->
        prepare_existing_user_turn(decision, agent, principal, profile, content_snapshot, message)

      nil ->
        prepare_new_user_turn(decision, agent, principal, profile, content_snapshot)
    end
  end

  defp prepare_existing_user_turn(decision, agent, principal, profile, content_snapshot, message) do
    case {message.kind, message.metadata["input_mode"]} do
      {:command, _input_mode} ->
        :no_reply

      {_kind, "observed_group"} ->
        :no_reply

      {_kind, _input_mode} ->
        {:generate,
         generation_state(decision, agent, principal, profile, content_snapshot, message)}
    end
  end

  defp prepare_new_user_turn(decision, agent, principal, profile, content_snapshot) do
    case input_mode(decision, profile) do
      :ignored_group ->
        :no_reply

      input_mode ->
        session =
          get_or_create_active_session!(
            agent.principal_id,
            conversation_key(decision),
            session_metadata(decision)
          )

        content = Map.fetch!(content_snapshot, "content")
        text = primary_text(content)

        case command_alias(text) do
          nil ->
            message =
              append_message!(session, %{
                role: :user,
                kind: :normal,
                content: content,
                metadata: user_metadata(decision, input_mode)
              })

            case input_mode do
              "observed_group" ->
                :no_reply

              _mode ->
                {:generate,
                 generation_state(decision, agent, principal, profile, content_snapshot, message)}
            end

          alias ->
            handle_new_session_command!(session, decision, content, alias, input_mode)
            :no_reply
        end
    end
  end

  defp run_prepared(:no_reply), do: :ok

  defp run_prepared(
         {:deliver_existing, %RouteDecision{} = decision, %Message{kind: :normal} = message}
       ) do
    deliver_reply(decision, message)
  end

  defp run_prepared({:deliver_existing, %RouteDecision{}, %Message{}}), do: :ok

  defp run_prepared({:generate, state}) do
    state.profile["main_llm"]
    |> BullX.LLM.chat(prompt_messages(state))
    |> case do
      {:ok, %{text: text} = response} when is_binary(text) and text != "" ->
        append_assistant_and_deliver(state, response)

      {:ok, response} ->
        append_error_message(state, {:empty_llm_response, response})

      {:error, reason} ->
        append_error_message(state, reason)
    end
  end

  defp append_assistant_and_deliver(state, response) do
    result =
      Repo.transaction(fn ->
        case assistant_message_for_decision(state.decision.id) do
          %Message{} = message ->
            message

          nil ->
            message =
              append_message!(session_for_update!(state.user_message.session_id), %{
                parent_id: state.user_message.id,
                role: :assistant,
                kind: :normal,
                content: text_content(response.text),
                metadata: assistant_metadata(state.decision, response)
              })

            update_session_leaf!(state.user_message.session_id, message.id)
            message
        end
      end)

    case result do
      {:ok, %Message{} = message} -> deliver_reply(state.decision, message)
      {:error, reason} -> {:error, reason}
    end
  end

  defp append_error_message(state, reason) do
    result =
      Repo.transaction(fn ->
        case assistant_message_for_decision(state.decision.id) do
          %Message{} = message ->
            message

          nil ->
            message =
              append_message!(session_for_update!(state.user_message.session_id), %{
                parent_id: state.user_message.id,
                role: :assistant,
                kind: :error,
                content: text_content("AgenticLoop generation failed."),
                metadata: error_metadata(state.decision, reason)
              })

            update_session_leaf!(state.user_message.session_id, message.id)
            message
        end
      end)

    case result do
      {:ok, %Message{}} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp fetch_agent_context(%RouteDecision{agent_principal_id: agent_principal_id})
       when is_binary(agent_principal_id) do
    query =
      from agent in Agent,
        join: principal in Principal,
        on: principal.id == agent.principal_id,
        where:
          agent.principal_id == ^agent_principal_id and agent.type == :agentic_loop and
            principal.type == :agent and principal.status == :active,
        select: {agent, principal}

    case Repo.one(query) do
      {%Agent{} = agent, %Principal{} = principal} ->
        {:ok, %{agent: agent, principal: principal}}

      nil ->
        {:error, {:agentic_loop_agent_unavailable, agent_principal_id}}
    end
  end

  defp fetch_agent_context(%RouteDecision{}), do: {:error, :missing_agent_principal_id}

  defp content_snapshot(%RouteDecision{content_snapshot: %{"content" => [_ | _]} = snapshot}) do
    {:ok, snapshot}
  end

  defp content_snapshot(%RouteDecision{}), do: {:error, :missing_content_snapshot}

  defp get_or_create_active_session!(agent_principal_id, conversation_key, metadata) do
    case active_session_for_update(agent_principal_id, conversation_key) do
      %Session{} = session ->
        session

      nil ->
        insert_session!(%{
          agent_principal_id: agent_principal_id,
          conversation_key: conversation_key,
          metadata: metadata
        })
    end
  end

  defp active_session_for_update(agent_principal_id, conversation_key) do
    Repo.one(
      from session in Session,
        where:
          session.agent_principal_id == ^agent_principal_id and
            session.conversation_key == ^conversation_key and is_nil(session.ended_at),
        lock: "FOR UPDATE"
    )
  end

  defp session_for_update!(session_id) do
    Repo.one!(
      from session in Session,
        where: session.id == ^session_id,
        lock: "FOR UPDATE"
    )
  end

  defp insert_session!(attrs) do
    %Session{}
    |> Session.changeset(attrs)
    |> Repo.insert!()
  end

  defp append_message!(%Session{} = session, attrs) do
    parent_id = Map.get(attrs, :parent_id, session.current_leaf_message_id)

    message =
      attrs
      |> Map.put(:session_id, session.id)
      |> Map.put(:parent_id, parent_id)
      |> put_new(:status, :complete)
      |> then(&Message.changeset(%Message{}, &1))
      |> Repo.insert!()

    update_session_leaf!(session.id, message.id)
    message
  end

  defp update_session_leaf!(session_id, message_id) do
    session_id
    |> session_for_update!()
    |> Session.changeset(%{current_leaf_message_id: message_id})
    |> Repo.update!()
  end

  defp handle_new_session_command!(session, decision, content, alias, input_mode) do
    message =
      append_message!(session, %{
        role: :user,
        kind: :command,
        content: content,
        metadata:
          user_metadata(decision, input_mode)
          |> Map.put("command_alias", alias)
      })

    now = DateTime.utc_now()

    session
    |> Session.changeset(%{
      current_leaf_message_id: message.id,
      ended_at: now,
      metadata:
        session.metadata
        |> Map.put("end_reason", "new_session")
        |> Map.put("ended_by_route_decision_id", decision.id)
    })
    |> Repo.update!()

    insert_session!(%{
      agent_principal_id: session.agent_principal_id,
      conversation_key: session.conversation_key,
      metadata:
        session.metadata
        |> Map.put("previous_session_id", session.id)
        |> Map.put("started_by_command_alias", alias)
    })
  end

  defp generation_state(decision, agent, principal, profile, content_snapshot, user_message) do
    %{
      decision: decision,
      agent: agent,
      principal: principal,
      profile: profile,
      content_snapshot: content_snapshot,
      user_message: user_message,
      active_path: active_path(user_message.session_id, user_message.id)
    }
  end

  defp active_path(session_id, leaf_message_id) do
    collect_path(session_id, leaf_message_id, [])
  end

  defp collect_path(_session_id, nil, acc), do: acc

  defp collect_path(session_id, message_id, acc) do
    case Repo.get_by(Message, id: message_id, session_id: session_id) do
      %Message{} = message -> collect_path(session_id, message.parent_id, [message | acc])
      nil -> acc
    end
  end

  defp prompt_messages(state) do
    [
      Context.system(system_prompt(state))
      | Enum.flat_map(state.active_path, &render_prompt_message/1)
    ]
  end

  defp render_prompt_message(%Message{kind: kind}) when kind not in @rendered_kinds, do: []

  defp render_prompt_message(%Message{role: :user, content: content, metadata: metadata}) do
    [Context.user(content_text(content), metadata: Map.take(metadata, ["input_mode"]))]
  end

  defp render_prompt_message(%Message{role: :assistant, content: content}) do
    [Context.assistant(content_text(content))]
  end

  defp render_prompt_message(%Message{role: :system, content: content}) do
    [Context.system(content_text(content))]
  end

  defp render_prompt_message(%Message{}), do: []

  defp system_prompt(state) do
    source = state.content_snapshot["reply_channel"] || %{}

    [
      "You are a BullX Agent Principal running inside one BullX Installation.",
      "Principal uid: #{state.principal.uid}",
      named("Display name", state.principal.display_name),
      named("Bio", state.principal.bio),
      named("Goals", state.profile["goals"]),
      named("Soul", state.profile["soul"]),
      "Source adapter: #{source["adapter"] || state.decision.adapter}",
      "Source channel: #{source["channel_id"] || state.decision.channel_id}",
      "Conversation scope: #{source["scope_id"] || state.decision.scope_id}"
    ]
    |> Enum.reject(&blank?/1)
    |> Enum.join("\n")
  end

  defp named(_label, value) when value in [nil, ""], do: nil
  defp named(label, value), do: "#{label}: #{value}"

  defp deliver_reply(%RouteDecision{} = decision, %Message{kind: :normal} = message) do
    case reply_delivery(decision, message) do
      {:ok, delivery} ->
        case BullX.Gateway.deliver(delivery) do
          {:ok, :accepted, _id} -> :ok
          {:error, error} -> {:error, {:reply_delivery_failed, error}}
        end

      :no_reply_channel ->
        :ok
    end
  end

  defp deliver_reply(%RouteDecision{}, %Message{}), do: :ok

  defp reply_delivery(%RouteDecision{} = decision, %Message{} = message) do
    case get_in(decision.content_snapshot || %{}, ["reply_channel"]) do
      %{} = reply_channel ->
        {:ok,
         %{
           "id" => message.id,
           "generation" => 0,
           "op" => "send",
           "channel" => %{
             "adapter" => reply_channel["adapter"] || decision.adapter,
             "channel_id" => reply_channel["channel_id"] || decision.channel_id
           },
           "scope_id" => reply_channel["scope_id"] || decision.scope_id,
           "thread_id" => reply_channel["thread_id"] || decision.thread_id,
           "reply_to_external_id" => reply_channel["reply_to_external_id"],
           "content" => message.content,
           "caused_by_signal_id" => decision.signal_id,
           "extensions" => %{
             "agent_principal_id" => decision.agent_principal_id,
             "agent_message_id" => message.id,
             "route_decision_id" => decision.id
           }
         }}

      _other ->
        :no_reply_channel
    end
  end

  defp conversation_key(%RouteDecision{} = decision) do
    [
      "gateway",
      decision.adapter,
      decision.channel_id,
      "scope",
      decision.scope_id,
      "thread",
      decision.thread_id || "_"
    ]
    |> Enum.map(&conversation_key_part/1)
    |> Enum.join(":")
  end

  defp conversation_key_part(nil), do: "_"
  defp conversation_key_part(value), do: URI.encode_www_form(to_string(value))

  defp session_metadata(%RouteDecision{} = decision) do
    %{
      "source" => %{
        "adapter" => decision.adapter,
        "channel_id" => decision.channel_id,
        "scope_id" => decision.scope_id,
        "thread_id" => decision.thread_id
      },
      "first_route_decision_id" => decision.id,
      "first_signal_id" => decision.signal_id
    }
  end

  defp user_metadata(%RouteDecision{} = decision, input_mode) do
    %{
      @route_decision_id_key => decision.id,
      "signal_id" => decision.signal_id,
      "signal_occurrence_key" => decision.signal_occurrence_key,
      "input_mode" => input_mode,
      "event_type" => decision.event_type,
      "event_name" => decision.event_name,
      "external_actor" => decision.external_actor || %{}
    }
    |> json_safe()
  end

  defp assistant_metadata(%RouteDecision{} = decision, response) do
    %{
      @route_decision_id_key => decision.id,
      "signal_id" => decision.signal_id,
      "provider_id" => response.provider_id,
      "model_id" => response.model_id,
      "usage" => response.usage,
      "finish_reason" => response.finish_reason,
      "provider_meta" => response.provider_meta
    }
    |> json_safe()
  end

  defp error_metadata(%RouteDecision{} = decision, reason) do
    %{
      @route_decision_id_key => decision.id,
      "signal_id" => decision.signal_id,
      "error_type" => "llm_generation_failed",
      "reason" => inspect(reason)
    }
    |> json_safe()
  end

  defp input_mode(%RouteDecision{} = decision, profile) do
    case explicit_input_mode(decision) do
      "observed_group" ->
        case profile["listen_all_group_messages"] do
          true -> "observed_group"
          _other -> :ignored_group
        end

      "direct" ->
        "direct"

      "mentioned_group" ->
        "mentioned_group"

      _other ->
        inferred_input_mode(decision)
    end
  end

  defp explicit_input_mode(%RouteDecision{} = decision) do
    get_in(decision.content_snapshot || %{}, ["event", "data", "input_mode"]) ||
      get_in(decision.content_snapshot || %{}, ["provenance", "input_mode"]) ||
      get_in(decision.routing_snapshot || %{}, ["routing_facts", "bullx.input_mode"])
  end

  defp inferred_input_mode(%RouteDecision{scope_id: nil}), do: "direct"
  defp inferred_input_mode(%RouteDecision{}), do: "mentioned_group"

  defp command_alias(text) when is_binary(text) do
    trimmed = String.trim(text)

    case trimmed in @new_session_aliases do
      true -> trimmed
      false -> nil
    end
  end

  defp command_alias(_text), do: nil

  defp user_message_for_decision(decision_id) do
    Repo.one(
      from message in Message,
        where:
          message.role == :user and
            fragment("? ->> ? = ?", message.metadata, ^@route_decision_id_key, ^decision_id),
        limit: 1
    )
  end

  defp assistant_message_for_decision(decision_id) do
    Repo.one(
      from message in Message,
        where:
          message.role == :assistant and
            fragment("? ->> ? = ?", message.metadata, ^@route_decision_id_key, ^decision_id),
        order_by: [desc: message.inserted_at],
        limit: 1
    )
  end

  defp text_content(text) do
    [%{"kind" => "text", "body" => %{"text" => text}}]
  end

  defp primary_text(content), do: content |> content_text() |> String.trim()

  defp content_text(content) when is_list(content) do
    content
    |> Enum.map(&block_text/1)
    |> Enum.reject(&blank?/1)
    |> Enum.join("\n")
  end

  defp content_text(_content), do: ""

  defp block_text(%{"kind" => "text", "body" => %{"text" => text}}) when is_binary(text) do
    text
  end

  defp block_text(%{"body" => %{"fallback_text" => text}}) when is_binary(text), do: text
  defp block_text(%{"kind" => kind}) when is_binary(kind), do: "[#{kind}]"
  defp block_text(_block), do: ""

  defp json_safe(value) do
    value
    |> stringify_atoms()
    |> JSON.stringify_keys()
    |> case do
      {:ok, value} -> value
      :error -> %{"inspect" => inspect(value)}
    end
  end

  defp stringify_atoms(value) when is_atom(value), do: Atom.to_string(value)
  defp stringify_atoms(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp stringify_atoms([_ | _] = values), do: Enum.map(values, &stringify_atoms/1)
  defp stringify_atoms([]), do: []

  defp stringify_atoms(%{} = value) do
    Map.new(value, fn {key, nested} -> {key, stringify_atoms(nested)} end)
  end

  defp stringify_atoms(value), do: value

  defp put_new(map, key, value) do
    case Map.has_key?(map, key) do
      true -> map
      false -> Map.put(map, key, value)
    end
  end

  defp blank?(value), do: is_nil(value) or value == ""
end
