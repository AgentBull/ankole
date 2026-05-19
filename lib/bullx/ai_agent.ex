defmodule BullX.AIAgent do
  @moduledoc """
  `ai_agent` EventBus Target — the runtime that drives one BullX AI Colleague's
  model/tool loop in response to routed Events.

  ## For readers coming from OpenClaw / Hermes-Agent / Claude Code-style harnesses

  The inner loop looks familiar — call the model, dispatch tool calls, append
  results, re-prompt. The structural differences worth knowing before reading
  the code:

  * **Conversation is a durable business record, not a session.** A
    `BullX.AIAgent.Conversations` row is a Message tree in Postgres that can
    branch and outlive any process. There is no "session you closed" — work
    survives crashes, redeploys, and operator handoffs, and the branch is
    addressable for replay.
  * **One generation per Conversation, enforced at the database.** A
    Conversation holds a generation lease while the model loop runs (see
    `Runner`). Concurrent events for the same Conversation block on the lease
    instead of double-firing the model — the harness, not the prompt, owns
    concurrency.
  * **Events arrive via `BullX.EventBus`, not as user prompts.** A BullX Agent
    can be reached by Discord DMs, Slack mentions, slash commands, scheduled
    ticks, or internal callbacks through one normalized pipe. Group-channel
    ambient messages and direct mentions are routed to separate
    TargetSessions, so observing a noisy channel does not pollute the Agent's
    1-on-1 context.
  * **Tools are gated per-caller, not per-agent.** Each invocation carries the
    triggering Principal; the model only sees the subset of tools the caller's
    ACL tags permit (see `BullX.AIAgent.Tools`). Authorization happens at
    schema rendering, not as a runtime reject.

  See [docs/Architecture.md](../docs/Architecture.md) and the README's "Three
  Models, One Distinction" section for the broader colleague-vs-assistant
  positioning.

  ## Internal contract

  AIAgent owns Conversation and Message business records, prompt rendering,
  ACL checks, tool-loop execution, and safe visible-output metadata. EventBus
  remains only the delivery boundary that invokes this Target one side-channel
  entry at a time.
  """

  @behaviour BullX.EventBus.Target

  alias BullX.AIAgent.{
    AmbientBatch,
    AmbientBrief,
    Commands,
    ConversationKey,
    Conversations,
    Event,
    Message,
    MessageContextBuilder,
    Profile,
    Runner
  }

  alias BullX.EventBus.ChannelAdapter
  alias BullX.Principals.{Agent, Principal}
  alias BullX.Repo

  require Logger

  @impl BullX.EventBus.Target
  def handle_event(%{target_ref: agent_principal_id} = invocation, entry)
      when is_binary(agent_principal_id) and is_map(entry) do
    with {:ok, principal, agent} <- load_agent(agent_principal_id),
         {:ok, profile} <- Profile.cast(agent.profile),
         {:ok, event_type, event_data} <- normalize_event(entry),
         caller_principal_id <- caller_principal_id(entry),
         :ok <-
           dispatch_event(
             event_type,
             event_data,
             principal,
             profile,
             invocation,
             entry,
             caller_principal_id
           ) do
      maybe_close(invocation)
      :ok
    else
      {:safe_ignore, reason} ->
        emit(:ignored, %{reason: reason, target_ref: agent_principal_id})
        maybe_close(invocation)
        :ok

      {:safe_fail, reason} ->
        safe_fail(invocation, reason)
        :ok

      {:error, {:invalid_profile, errors}} ->
        emit(:profile_invalid, %{errors: errors, target_ref: agent_principal_id})
        safe_fail(invocation, :invalid_ai_agent_profile)
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  def handle_event(%{target_ref: target_ref}, _entry),
    do: {:error, {:invalid_ai_agent_target_ref, target_ref}}

  defp load_agent(agent_principal_id) do
    case Repo.get(Principal, agent_principal_id) |> Repo.preload(:agent) do
      %Principal{type: :agent, status: :active, agent: %Agent{} = agent} = principal ->
        {:ok, principal, agent}

      %Principal{type: :agent, status: :disabled} ->
        {:safe_fail, :agent_principal_disabled}

      %Principal{} ->
        {:safe_fail, :target_ref_not_active_agent_principal}

      nil ->
        {:safe_fail, :agent_principal_not_found}
    end
  end

  defp normalize_event(%{cloud_event: cloud_event}) when is_map(cloud_event) do
    case Event.type(cloud_event) do
      type when is_binary(type) -> {:ok, type, Event.data(cloud_event)}
      _other -> {:safe_ignore, :missing_event_type}
    end
  end

  defp normalize_event(_entry), do: {:safe_ignore, :missing_cloud_event}

  defp dispatch_event(
         "bullx.im.message.addressed",
         event_data,
         principal,
         profile,
         invocation,
         entry,
         caller_principal_id
       ) do
    handle_addressed(event_data, principal, profile, invocation, entry, caller_principal_id)
  end

  defp dispatch_event(
         "bullx.im.message.ambient",
         event_data,
         principal,
         profile,
         invocation,
         entry,
         caller_principal_id
       ) do
    handle_ambient(event_data, principal, profile, invocation, entry, caller_principal_id)
  end

  defp dispatch_event(
         "bullx.command.invoked",
         event_data,
         principal,
         profile,
         invocation,
         entry,
         caller_principal_id
       ) do
    handle_command_event(event_data, principal, profile, invocation, entry, caller_principal_id)
  end

  defp dispatch_event(
         "bullx.action.submitted",
         event_data,
         principal,
         profile,
         invocation,
         entry,
         caller_principal_id
       ) do
    handle_directed_action(event_data, principal, profile, invocation, entry, caller_principal_id)
  end

  defp dispatch_event(
         type,
         _event_data,
         _principal,
         _profile,
         _invocation,
         _entry,
         _caller_principal_id
       ) do
    emit(:unsupported_event, %{event_type: type})
    :ok
  end

  defp handle_addressed(event_data, principal, profile, invocation, entry, caller_principal_id) do
    with {:ok, conversation, key_metadata} <-
           conversation_for(profile, principal.id, :addressed, event_data, entry),
         text <- Event.text_content(event_data) do
      case Commands.detect_text(text) do
        {:command, command_name, args} ->
          case caller_principal_id do
            caller when is_binary(caller) ->
              run_command(
                command_name,
                args,
                conversation,
                principal,
                profile,
                invocation,
                entry,
                caller
              )

            _missing ->
              write_command_error(conversation, principal, invocation, entry, "acl_denied")
          end

        {:unknown, _token} ->
          emit(:unknown_command, %{target_session_entry_id: entry.id})
          :ok

        :not_command ->
          append_user_and_run(
            conversation,
            key_metadata,
            event_data,
            principal,
            profile,
            invocation,
            entry,
            caller_principal_id
          )
      end
    else
      {:error, :missing_conversation_key_parts} ->
        {:safe_fail, :invalid_conversation_key}

      {:error, :conversation_key_part_contains_nul} ->
        {:safe_fail, :invalid_conversation_key}
    end
  end

  defp handle_directed_action(
         event_data,
         principal,
         profile,
         invocation,
         entry,
         caller_principal_id
       ) do
    with {:ok, conversation, key_metadata} <-
           conversation_for(profile, principal.id, :addressed, event_data, entry) do
      append_user_and_run(
        conversation,
        key_metadata,
        event_data,
        principal,
        profile,
        invocation,
        entry,
        caller_principal_id
      )
    else
      {:error, :missing_conversation_key_parts} ->
        {:safe_fail, :invalid_conversation_key}

      {:error, :conversation_key_part_contains_nul} ->
        {:safe_fail, :invalid_conversation_key}
    end
  end

  defp handle_command_event(
         event_data,
         principal,
         profile,
         invocation,
         entry,
         caller_principal_id
       ) do
    with command_name when is_binary(command_name) <- Commands.command_event_name(event_data),
         {:ok, conversation, _key_metadata} <-
           conversation_for(profile, principal.id, :addressed, event_data, entry) do
      case caller_principal_id do
        caller when is_binary(caller) ->
          run_command(
            command_name,
            Commands.command_event_args(event_data),
            conversation,
            principal,
            profile,
            invocation,
            entry,
            caller
          )

        _missing ->
          write_command_error(conversation, principal, invocation, entry, "acl_denied")
      end
    else
      _other ->
        emit(:unknown_command, %{target_session_entry_id: entry.id})
        :ok
    end
  end

  defp handle_ambient(event_data, principal, profile, invocation, entry, _caller_principal_id) do
    with {:ok, conversation, key_metadata} <-
           conversation_for(profile, principal.id, :ambient, event_data, entry),
         existing? <- not is_nil(Conversations.inbound_message_for_entry(entry.id)),
         {:ok, _conversation, message} <-
           append_ambient(conversation, key_metadata, event_data, invocation, entry),
         {:ok, message} <- AmbientBrief.maybe_generate(message, profile) do
      maybe_enqueue_ambient(profile, conversation, message, event_data, existing?)
    end
  end

  defp conversation_for(profile, agent_principal_id, lane, event_data, _entry) do
    with {:ok, conversation_key, key_metadata} <-
           ConversationKey.build(profile, agent_principal_id, lane, event_data),
         {:ok, conversation} <-
           Conversations.find_or_create_active(agent_principal_id, conversation_key, key_metadata) do
      {:ok, conversation, key_metadata}
    end
  end

  defp append_user_and_run(
         conversation,
         key_metadata,
         event_data,
         principal,
         profile,
         invocation,
         entry,
         caller_principal_id
       ) do
    branch = Conversations.active_branch(conversation)
    now = DateTime.utc_now(:microsecond)

    metadata =
      profile
      |> MessageContextBuilder.metadata_for_user_message(event_data, branch, now)
      |> put_scene_key()
      |> Map.merge(key_metadata)

    attrs = %{
      conversation_id: conversation.id,
      role: :user,
      kind: :normal,
      status: :complete,
      content: content_blocks(event_data),
      target_session_id: invocation.target_session_id,
      event_source: entry.event_source,
      event_id: entry.event_id,
      metadata: metadata
    }

    with {:ok, conversation, message} <-
           Conversations.append_inbound_once(conversation, entry.id, attrs),
         :ok <-
           maybe_run_or_write_denial(
             conversation,
             message,
             profile,
             principal,
             invocation,
             entry,
             caller_principal_id,
             event_data
           ) do
      :ok
    end
  end

  defp append_ambient(conversation, key_metadata, event_data, invocation, entry) do
    send_at = Event.send_at(event_data, DateTime.utc_now(:microsecond))

    metadata =
      %{
        "actor" => get_in(event_data, ["actor"]) || %{},
        "scene" =>
          event_data
          |> ConversationKey.scene_identity()
          |> Map.put("scene_key", scene_key(event_data)),
        "time_awareness" => %{
          "send_at" => DateTime.to_iso8601(send_at),
          "injected" => false
        }
      }
      |> Map.merge(key_metadata)

    attrs = %{
      conversation_id: conversation.id,
      role: :im_ambient,
      kind: :normal,
      status: :complete,
      content: content_blocks(event_data),
      target_session_id: invocation.target_session_id,
      event_source: entry.event_source,
      event_id: entry.event_id,
      metadata: metadata
    }

    Conversations.append_inbound_once(conversation, entry.id, attrs)
  end

  defp maybe_enqueue_ambient(
         %Profile{unmentioned_group_messages: :observe_only},
         _conversation,
         _message,
         _event_data,
         _existing?
       ),
       do: :ok

  defp maybe_enqueue_ambient(
         %Profile{unmentioned_group_messages: :may_intervene},
         _conversation,
         _message,
         _event_data,
         true
       ),
       do: :ok

  defp maybe_enqueue_ambient(
         %Profile{unmentioned_group_messages: :may_intervene},
         conversation,
         message,
         event_data,
         false
       ) do
    AmbientBatch.enqueue(%{
      agent_principal_id: conversation.agent_principal_id,
      ambient_conversation_id: conversation.id,
      scene_key: scene_key(event_data),
      reply_channel: Event.reply_channel(event_data),
      item: %{
        message_id: message.id,
        text: ambient_message_text(message),
        sent_at:
          get_in(message.metadata, ["time_awareness", "send_at"]) ||
            DateTime.to_iso8601(message.inserted_at)
      }
    })
    |> case do
      :ok ->
        :ok

      {:error, reason} ->
        emit(:ambient_batch_dropped, %{reason: safe_reason(reason)})
        :ok
    end
  end

  defp run_command(
         command_name,
         args,
         conversation,
         principal,
         profile,
         invocation,
         entry,
         caller_principal_id
       ) do
    Commands.run(command_name, %{
      args: args,
      conversation_id: conversation.id,
      caller_principal_id: caller_principal_id,
      agent_principal_id: principal.id,
      profile: profile,
      source_type: "target_session_entry",
      source_id: entry.id,
      target_session_id: invocation.target_session_id,
      target_session_entry_id: entry.id,
      acl_context: acl_context(entry, "command")
    })
    |> case do
      {:ok,
       %{
         status: :start_generation,
         source_message_id: source_message_id,
         retry_of_message_id: retry_of_message_id,
         lease_id: lease_id
       }} ->
        with %Message{} = source_message <- Repo.get(Message, source_message_id),
             :ok <-
               Runner.run(conversation, source_message, profile, %{
                 source_type: "command_retry",
                 source_id: entry.id,
                 lease_id: lease_id,
                 caller_principal_id: caller_principal_id,
                 agent_principal_id: principal.id,
                 target_session_id: invocation.target_session_id,
                 target_session_entry_id: entry.id,
                 output: Map.get(invocation, :output),
                 reply_channel: Event.reply_channel(entry.cloud_event["data"] || %{}),
                 acl_context: acl_context(entry, "command"),
                 force_generation?: true,
                 retry_of_message_id: retry_of_message_id,
                 retry_command_entry_id: entry.id
               }) do
          :ok
        else
          nil -> {:error, :retry_source_message_not_found}
          {:error, reason} -> {:error, reason}
        end

      {:ok, %{status: :diagnostic, reason: "denied"}} ->
        write_command_error(conversation, principal, invocation, entry, "acl_denied")

      {:ok, _result} ->
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp content_blocks(event_data) do
    case Event.transcript_texts(event_data) do
      [] -> [%{"type" => "omitted_marker", "reason" => "empty_normalized_content"}]
      texts -> Enum.map(texts, &Message.text_block/1)
    end
  end

  defp maybe_run_or_write_denial(
         conversation,
         message,
         profile,
         principal,
         invocation,
         entry,
         caller_principal_id,
         event_data
       ) do
    case caller_principal_id do
      caller when is_binary(caller) ->
        Runner.run(conversation, message, profile, %{
          source_type: "target_session_entry",
          source_id: entry.id,
          caller_principal_id: caller,
          agent_principal_id: principal.id,
          target_session_id: invocation.target_session_id,
          target_session_entry_id: entry.id,
          output: Map.get(invocation, :output),
          reply_channel: Event.reply_channel(event_data),
          acl_context: acl_context(entry, "addressed")
        })

      _missing ->
        write_access_denial(conversation, message, invocation, entry)
    end
  end

  defp write_access_denial(conversation, source_message, invocation, entry) do
    case Conversations.generated_output_for_source?(source_message.id) do
      true ->
        :ok

      false ->
        Conversations.append_message(conversation, %{
          conversation_id: conversation.id,
          role: :assistant,
          kind: :error,
          status: :complete,
          content: [Message.error_block("acl_denied", "AIAgent access denied.", false)],
          target_session_id: invocation.target_session_id,
          target_session_entry_id: entry.id,
          metadata: %{
            "generation" => %{
              "source_message_id" => source_message.id,
              "source_type" => "target_session_entry",
              "source_id" => entry.id
            },
            "safe_error_code" => "acl_denied"
          }
        })
        |> case do
          {:ok, _conversation, _message} -> :ok
          {:error, reason} -> {:error, reason}
        end
    end
  end

  defp write_command_error(_conversation, principal, _invocation, entry, code) do
    emit(:command_diagnostic, %{
      diagnostic_code: code,
      target_session_entry_id: entry.id,
      agent_principal_id: principal.id
    })

    maybe_send_command_response(entry, code)
  end

  defp maybe_send_command_response(entry, code) do
    case Event.reply_channel(entry.cloud_event["data"] || %{}) do
      %{} = reply_channel ->
        outbound = %{
          "id" =>
            "sha256:" <>
              BullX.Ext.generic_hash(
                Jason.encode!(%{target_session_entry_id: entry.id, diagnostic_code: code})
              ),
          "op" => "send",
          "content" => [
            %{"kind" => "text", "body" => %{"text" => command_response_text(code)}}
          ]
        }

        case ChannelAdapter.deliver(reply_channel, outbound) do
          {:ok, _result} -> :ok
          {:error, reason} -> emit(:command_response_failed, %{reason: safe_reason(reason)})
        end

      _missing ->
        :ok
    end
  end

  defp command_response_text("acl_denied"), do: "Command denied."
  defp command_response_text(_code), do: "Command failed."

  defp caller_principal_id(entry), do: Event.trigger_principal_id(entry.routing_context)

  defp acl_context(entry, input_mode) do
    %{
      input_mode: input_mode,
      source_type: "target_session_entry",
      source_id: entry.id,
      channel_kind: get_in(entry.cloud_event, ["data", "channel", "kind"])
    }
  end

  defp put_scene_key(metadata) do
    update_in(metadata, ["scene"], fn
      %{} = scene -> Map.put(scene, "scene_key", MessageContextBuilder.scene_key(scene))
      other -> other
    end)
  end

  defp scene_key(event_data) do
    event_data
    |> ConversationKey.scene_identity()
    |> MessageContextBuilder.scene_key()
  end

  defp ambient_message_text(%Message{metadata: %{"brief" => brief}})
       when is_binary(brief) and brief != "" do
    String.slice(brief, 0, 2_000)
  end

  defp ambient_message_text(%Message{content: content}) do
    content
    |> Enum.filter(&(Map.get(&1, "type") == "text"))
    |> Enum.map_join("", &Map.get(&1, "text", ""))
    |> String.slice(0, 2_000)
  end

  defp maybe_close(%{close: close}) when is_function(close, 0), do: close.()
  defp maybe_close(_invocation), do: :ok

  defp safe_fail(%{fail: fail}, reason) when is_function(fail, 1), do: fail.(reason)
  defp safe_fail(_invocation, _reason), do: :ok

  defp emit(event, metadata) do
    :telemetry.execute([:bullx, :ai_agent, event], %{}, metadata)
  end

  defp safe_reason(reason) when is_atom(reason), do: reason
  defp safe_reason(_reason), do: :error
end
