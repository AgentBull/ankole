defmodule BullX.AIAgent do
  @moduledoc """
  Runtime that drives one BullX AI Colleague's model/tool loop in response to
  MailBox entries.

  ## For readers coming from OpenClaw / Hermes-Agent / Claude Code-style harnesses

  The inner loop looks familiar — call the model, dispatch tool calls, append
  results, re-prompt. The structural differences worth knowing before reading
  the code:

  * **Conversation is a durable business record, not a session.** A
    `BullX.AIAgent.Conversations` row is an append-only transcript in Postgres.
    There is no "session you closed" — work survives crashes, redeploys, and
    operator handoffs.
  * **One generation per Conversation, enforced at the database.** A
    Conversation holds a generation lease while the model loop runs (see
    `Runner`). Concurrent events for the same Conversation block on the lease
    instead of double-firing the model — the harness, not the prompt, owns
    concurrency.
  * **Inputs arrive as mailbox entries, not as raw user prompts.** A BullX Agent
    can be reached by Discord DMs, Slack mentions, slash commands, scheduled
    ticks, or internal callbacks through one normalized pipe.
  * **Tools are rendered from ToolSet/profile/availability state, then gated
    per-caller at execution.** Each invocation carries the triggering
    Principal; `BullX.AIAgent.Tools` builds the provider-visible schemas for
    the current Agent/Session context, and the dispatcher rechecks ACL when the
    model actually calls a tool.

  See [docs/Architecture.md](../docs/Architecture.md) and the README's "Three
  Models, One Distinction" section for the broader colleague-vs-assistant
  positioning.

  ## Internal contract

  AIAgent owns Conversation and Message business records, prompt rendering,
  ACL checks, tool-loop execution, and safe visible-output metadata.
  """

  import Ecto.Query

  alias BullX.AIAgent.{
    AmbientBatch,
    AmbientBrief,
    Commands,
    ConversationKey,
    Conversations,
    DeliveryRecall,
    Event,
    Message,
    MessageContextBuilder,
    MessageRevisions,
    Profile,
    Runner
  }

  alias BullX.IMGateway.ChannelAdapter
  alias BullX.MailBox.Entry, as: MailboxEntry
  alias BullX.Principals.{Agent, Principal}
  alias BullX.Repo

  require Logger

  @spec handle_mailbox_entry(map(), MailboxEntry.t()) :: :ok | {:error, term()}
  def handle_mailbox_entry(
        %{target_ref: agent_uid} = invocation,
        %MailboxEntry{} = entry
      )
      when is_binary(agent_uid) do
    invocation
    |> Map.put_new(:mailbox_queue_key, entry.queue_key)
    |> handle_event(mailbox_entry_event(entry))
  end

  def handle_event(%{target_ref: agent_uid} = invocation, entry)
      when is_binary(agent_uid) and is_map(entry) do
    with {:ok, principal, agent} <- load_agent(agent_uid),
         {:ok, profile} <- Profile.cast(agent.profile),
         {:ok, event_type, event_data} <- normalize_event(entry),
         caller_principal_uid <- caller_principal_uid(entry),
         :ok <-
           dispatch_event(
             event_type,
             event_data,
             principal,
             profile,
             invocation,
             entry,
             caller_principal_uid
           ) do
      maybe_close(invocation)
      :ok
    else
      {:safe_ignore, reason} ->
        emit(:ignored, %{reason: reason, target_ref: agent_uid})
        maybe_close(invocation)
        :ok

      {:safe_fail, reason} ->
        safe_fail(invocation, reason)
        :ok

      {:error, {:invalid_profile, errors}} ->
        emit(:profile_invalid, %{errors: errors, target_ref: agent_uid})
        safe_fail(invocation, :invalid_ai_agent_profile)
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  def handle_event(%{target_ref: target_ref}, _entry),
    do: {:error, {:invalid_ai_agent_target_ref, target_ref}}

  defp load_agent(agent_uid) do
    case Repo.get_by(Principal, uid: agent_uid) |> Repo.preload(:agent) do
      %Principal{type: :agent, status: :active, agent: %Agent{type: :ai_agent} = agent} =
          principal ->
        {:ok, principal, agent}

      %Principal{type: :agent, status: :active, agent: %Agent{} = agent} ->
        {:safe_fail, {:unsupported_agent_type, agent.type}}

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

  defp mailbox_entry_event(%MailboxEntry{} = entry) do
    cloud_event = entry.cloud_event || %{}

    %{
      id: entry.id,
      entry_seq: entry.entry_seq || 0,
      attention: entry.attention,
      cloud_event: cloud_event,
      routing_context: BullX.MailBox.RoutingContext.project(cloud_event),
      event_source: cloud_event["source"],
      event_id: cloud_event["id"],
      mailbox_queue_key: entry.queue_key
    }
  end

  defp dispatch_event(
         "bullx.message.received",
         event_data,
         principal,
         profile,
         invocation,
         entry,
         caller_principal_uid
       ) do
    case mailbox_attention(entry) do
      :ambient ->
        handle_ambient(event_data, principal, profile, invocation, entry, caller_principal_uid)

      :addressed ->
        handle_addressed(
          event_data,
          principal,
          profile,
          invocation,
          entry,
          caller_principal_uid
        )

      _other ->
        unsupported_event("bullx.message.received")
    end
  end

  defp dispatch_event(
         "bullx.command.invoked",
         event_data,
         principal,
         profile,
         invocation,
         entry,
         caller_principal_uid
       ) do
    handle_command_event(event_data, principal, profile, invocation, entry, caller_principal_uid)
  end

  defp dispatch_event(
         "bullx.message.edited",
         event_data,
         principal,
         _profile,
         invocation,
         entry,
         caller_principal_uid
       ) do
    MessageRevisions.handle(
      :edited,
      event_data,
      principal,
      invocation,
      entry,
      caller_principal_uid
    )
  end

  defp dispatch_event(
         "bullx.message.recalled",
         event_data,
         principal,
         _profile,
         invocation,
         entry,
         caller_principal_uid
       ) do
    MessageRevisions.handle(
      :recalled,
      event_data,
      principal,
      invocation,
      entry,
      caller_principal_uid
    )
  end

  defp dispatch_event(
         "bullx.message.deleted",
         event_data,
         principal,
         _profile,
         invocation,
         entry,
         caller_principal_uid
       ) do
    MessageRevisions.handle(
      :deleted,
      event_data,
      principal,
      invocation,
      entry,
      caller_principal_uid
    )
  end

  defp dispatch_event(
         type,
         _event_data,
         _principal,
         _profile,
         _invocation,
         _entry,
         _caller_principal_uid
       ) do
    unsupported_event(type)
  end

  defp mailbox_attention(%{attention: attention}), do: attention
  defp mailbox_attention(_entry), do: nil

  defp unsupported_event(type) do
    emit(:unsupported_event, %{event_type: type})
    :ok
  end

  defp handle_addressed(event_data, principal, profile, invocation, entry, caller_principal_uid) do
    with {:ok, conversation, key_metadata} <-
           conversation_for(profile, principal.uid, :addressed, event_data, entry) do
      append_user_and_run(
        conversation,
        key_metadata,
        event_data,
        principal,
        profile,
        invocation,
        entry,
        caller_principal_uid
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
         caller_principal_uid
       ) do
    with command_name when is_binary(command_name) <- Commands.command_event_name(event_data),
         {:ok, conversation, _key_metadata} <-
           conversation_for(profile, principal.uid, :addressed, event_data, entry) do
      case caller_principal_uid do
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
        emit(:unknown_command, %{mailbox_entry_id: entry.id})
        :ok
    end
  end

  defp handle_ambient(event_data, principal, profile, invocation, entry, _caller_principal_uid) do
    with {:ok, conversation, key_metadata} <-
           conversation_for(profile, principal.uid, :ambient, event_data, entry),
         existing? <-
           not is_nil(
             Conversations.inbound_message_for_event(
               conversation,
               entry.event_source,
               entry.event_id
             )
           ),
         {:ok, _conversation, message} <-
           append_ambient(conversation, key_metadata, event_data, invocation, entry),
         {:ok, message} <- AmbientBrief.maybe_generate(message, profile) do
      maybe_enqueue_ambient(profile, principal, conversation, message, event_data, existing?)
    end
  end

  defp conversation_for(profile, agent_uid, lane, event_data, _entry) do
    with {:ok, conversation_key, key_metadata} <-
           ConversationKey.build(profile, agent_uid, lane, event_data),
         {:ok, conversation} <-
           Conversations.find_or_create_active(agent_uid, conversation_key, key_metadata) do
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
         caller_principal_uid
       ) do
    transcript = Conversations.active_transcript(conversation)
    now = DateTime.utc_now(:microsecond)

    metadata =
      profile
      |> MessageContextBuilder.metadata_for_user_message(event_data, transcript, now)
      |> put_scene_key()
      |> Map.merge(key_metadata)
      |> Map.merge(Event.provider_ref_metadata(event_data))

    attrs = %{
      role: :user,
      kind: :normal,
      status: :complete,
      content: content_blocks(event_data),
      mailbox_queue_key: invocation.mailbox_queue_key,
      event_source: entry.event_source,
      event_id: entry.event_id,
      metadata: metadata
    }

    with {:ok, conversation, message} <-
           Conversations.append_inbound_once(conversation, attrs),
         :ok <-
           maybe_run_or_write_denial(
             conversation,
             message,
             profile,
             principal,
             invocation,
             entry,
             caller_principal_uid,
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
      |> Map.merge(Event.provider_ref_metadata(event_data))

    attrs = %{
      role: :im_ambient,
      kind: :normal,
      status: :complete,
      content: content_blocks(event_data),
      mailbox_queue_key: invocation.mailbox_queue_key,
      event_source: entry.event_source,
      event_id: entry.event_id,
      metadata: metadata
    }

    Conversations.append_inbound_once(conversation, attrs)
  end

  defp maybe_enqueue_ambient(
         %Profile{} = profile,
         %Principal{} = principal,
         conversation,
         message,
         event_data,
         existing?
       ) do
    case {ambient_handling_mode(profile, event_data), existing?} do
      {:may_intervene, false} ->
        %{
          agent_uid: conversation.agent_uid,
          ambient_conversation_id: conversation.id,
          scene_key: scene_key(event_data),
          reply_address: ambient_reply_address(Event.reply_address(event_data)),
          ambient_mode: "may_intervene",
          item: %{
            message_id: message.id,
            text: ambient_message_text(message),
            sent_at:
              get_in(message.metadata, ["time_awareness", "send_at"]) ||
                DateTime.to_iso8601(message.inserted_at)
          }
        }
        |> maybe_shorten_ambient_batch_window(principal, message)
        |> AmbientBatch.enqueue()
        |> case do
          :ok ->
            :ok

          {:error, reason} ->
            emit(:ambient_batch_dropped, %{reason: safe_reason(reason)})
            :ok
        end

      _observe_or_existing ->
        :ok
    end
  end

  defp ambient_handling_mode(_profile, %{
         "routing_facts" => %{"group_message_mode" => "engage_all"}
       }),
       do: :may_intervene

  defp ambient_handling_mode(_profile, %{
         "routing_facts" => %{"group_message_mode" => mode}
       })
       when mode in ["addressed_only", "observe_all"],
       do: :observe_only

  defp ambient_handling_mode(_profile, _event_data), do: :observe_only

  defp maybe_shorten_ambient_batch_window(batch, %Principal{} = principal, %Message{} = message) do
    case previous_assistant_answer?(message) or mentions_agent_identity?(message, principal) do
      true -> Map.put(batch, :due_in_ms, AmbientBatch.fast_window_ms())
      false -> batch
    end
  end

  defp previous_assistant_answer?(%Message{} = message) do
    Message
    |> where([m], m.conversation_id == ^message.conversation_id)
    |> where([m], m.role == :assistant and m.kind == :normal and m.status == :complete)
    |> where(
      [m],
      m.inserted_at < ^message.inserted_at or
        (m.inserted_at == ^message.inserted_at and m.id < ^message.id)
    )
    |> where([m], is_nil(fragment("?->'transcript_effect'", m.metadata)))
    |> order_by([m], desc: m.inserted_at, desc: m.id)
    |> limit(1)
    |> Repo.exists?()
  end

  defp mentions_agent_identity?(%Message{} = message, %Principal{} = principal) do
    text = raw_message_text(message)

    [principal.uid, principal.display_name]
    |> Enum.map(&safe_trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
    |> Enum.any?(&literal_keyword_match?(text, &1))
  end

  defp literal_keyword_match?(text, keyword) when is_binary(text) and is_binary(keyword) do
    text = String.downcase(text)
    keyword = String.downcase(keyword)

    Regex.match?(keyword_regex(keyword), text)
  end

  defp keyword_regex(keyword) do
    Regex.compile!("(^|[^A-Za-z0-9_])" <> Regex.escape(keyword) <> "($|[^A-Za-z0-9_])", "u")
  end

  defp safe_trim(value) when is_binary(value), do: String.trim(value)
  defp safe_trim(_value), do: ""

  defp ambient_reply_address(%{} = reply_address) do
    Map.drop(reply_address, ["reply_to_external_id", :reply_to_external_id])
  end

  defp ambient_reply_address(reply_address), do: reply_address

  defp run_command(
         command_name,
         args,
         conversation,
         principal,
         profile,
         invocation,
         entry,
         caller_principal_uid
       ) do
    Commands.run(command_name, %{
      args: args,
      conversation_id: conversation.id,
      caller_principal_uid: caller_principal_uid,
      agent_uid: principal.uid,
      profile: profile,
      trigger_type: "mailbox_entry",
      trigger_id: entry.id,
      mailbox_queue_key: invocation.mailbox_queue_key,
      mailbox_entry_id: entry.id,
      acl_context: acl_context(entry, "command"),
      feedback_fun: &send_command_feedback(entry, &1)
    })
    |> case do
      {:ok,
       %{
         status: :start_generation,
         trigger_message_id: trigger_message_id,
         retry_of_message_id: retry_of_message_id,
         lease_id: lease_id
       } = result} ->
        with %Message{} = trigger_message <- Repo.get(Message, trigger_message_id),
             :ok <-
               result
               |> recall_command_targets(entry)
               |> maybe_send_recall_fallback(entry, "retry_started"),
             :ok <-
               Runner.run(conversation, trigger_message, profile, %{
                 trigger_type: "command_retry",
                 trigger_id: entry.id,
                 lease_id: lease_id,
                 caller_principal_uid: caller_principal_uid,
                 agent_uid: principal.uid,
                 mailbox_queue_key: invocation.mailbox_queue_key,
                 mailbox_entry_id: entry.id,
                 mailbox_entry_seq: map_entry_seq(entry),
                 output: Map.get(invocation, :output),
                 reply_address: Event.reply_address(entry.cloud_event["data"] || %{}),
                 acl_context: acl_context(entry, "command"),
                 force_generation?: true,
                 retry_of_message_id: retry_of_message_id,
                 retry_command_entry_id: entry.id
               }) do
          :ok
        else
          nil -> {:error, :retry_trigger_message_not_found}
          {:error, reason} -> {:error, reason}
        end

      {:ok, %{status: :diagnostic, reason: "denied"}} ->
        write_command_error(conversation, principal, invocation, entry, "acl_denied")

      {:ok, %{status: :diagnostic, command: "compress"}} ->
        :ok

      {:ok, %{status: :diagnostic, reason: reason}} ->
        maybe_send_command_response(entry, reason)

      {:ok, %{status: :ok, command: "new"}} ->
        maybe_send_command_response(entry, "new_started")

      {:ok, %{status: :ok, command: "steer"}} ->
        maybe_send_command_response(entry, "steer_applied")

      {:ok, %{status: :ok, command: "stop"} = result} ->
        result
        |> recall_command_targets(entry)
        |> maybe_send_recall_fallback(entry, "stop_applied")

      {:ok, %{status: :ok, command: "undo"} = result} ->
        result
        |> recall_command_targets(entry)
        |> maybe_send_recall_fallback(entry, "undo_applied")

      {:ok, %{status: :ok} = result} ->
        maybe_recall_command_targets(entry, result)

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
         caller_principal_uid,
         event_data
       ) do
    case caller_principal_uid do
      caller when is_binary(caller) ->
        Runner.run(conversation, message, profile, %{
          trigger_type: "mailbox_entry",
          trigger_id: entry.id,
          caller_principal_uid: caller,
          agent_uid: principal.uid,
          mailbox_queue_key: invocation.mailbox_queue_key,
          mailbox_entry_id: entry.id,
          mailbox_entry_seq: map_entry_seq(entry),
          output: Map.get(invocation, :output),
          reply_address: Event.reply_address(event_data),
          acl_context: acl_context(entry, "addressed")
        })

      _missing ->
        write_access_denial(conversation, message, invocation, entry)
    end
  end

  defp write_access_denial(conversation, trigger_message, invocation, entry) do
    case Conversations.generated_output_for_trigger?(trigger_message.id) do
      true ->
        :ok

      false ->
        Conversations.append_message(conversation, %{
          role: :assistant,
          kind: :error,
          status: :complete,
          content: [Message.error_block("acl_denied", "AIAgent access denied.", false)],
          mailbox_queue_key: invocation.mailbox_queue_key,
          metadata: %{
            "generation" => %{
              "trigger_message_id" => trigger_message.id,
              "trigger_type" => "mailbox_entry",
              "trigger_id" => entry.id
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

  defp map_entry_seq(%{entry_seq: seq}) when is_integer(seq), do: seq
  defp map_entry_seq(%{"entry_seq" => seq}) when is_integer(seq), do: seq
  defp map_entry_seq(_entry), do: nil

  defp write_command_error(_conversation, principal, _invocation, entry, code) do
    emit(:command_diagnostic, %{
      diagnostic_code: code,
      mailbox_entry_id: entry.id,
      agent_uid: principal.uid
    })

    maybe_send_command_response(entry, code)
  end

  defp maybe_send_command_response(entry, code) do
    case Event.reply_address(entry.cloud_event["data"] || %{}) do
      %{} = reply_address ->
        outbound = %{
          "id" =>
            "sha256:" <>
              BullX.Ext.generic_hash(
                Jason.encode!(%{mailbox_entry_id: entry.id, diagnostic_code: code})
              ),
          "op" => "send",
          "content" => [command_response_content(code)]
        }

        case ChannelAdapter.deliver(reply_address, outbound) do
          {:ok, _result} -> :ok
          {:error, reason} -> emit(:command_response_failed, %{reason: safe_reason(reason)})
        end

      _missing ->
        :ok
    end
  end

  defp send_command_feedback(entry, %{command: "compress", phase: :started}) do
    send_progress_notice(entry, "compress", "started", compress_progress_notice(:running))
  end

  defp send_command_feedback(entry, %{
         command: "compress",
         phase: :finished,
         feedback_ref: feedback_ref,
         result: result
       }) do
    update_progress_notice(
      entry,
      feedback_ref,
      "compress",
      "finished",
      compress_progress_notice(compress_result_state(result))
    )
  end

  defp send_command_feedback(_entry, _payload), do: nil

  defp send_progress_notice(entry, command, phase, content) do
    case Event.reply_address(entry.cloud_event["data"] || %{}) do
      %{} = reply_address ->
        outbound = %{
          "id" => command_feedback_id(entry, command, phase),
          "op" => "send",
          "content" => [content]
        }

        case ChannelAdapter.deliver(reply_address, outbound) do
          {:ok, %{"primary_external_id" => external_id}} when is_binary(external_id) ->
            %{target_external_id: external_id}

          {:ok, _result} ->
            nil

          {:error, reason} ->
            emit(:command_feedback_failed, %{reason: safe_reason(reason)})
            nil
        end

      _missing ->
        nil
    end
  end

  defp update_progress_notice(
         entry,
         %{target_external_id: target_external_id},
         command,
         phase,
         content
       )
       when is_binary(target_external_id) and target_external_id != "" do
    case Event.reply_address(entry.cloud_event["data"] || %{}) do
      %{} = reply_address ->
        outbound = %{
          "id" => command_feedback_id(entry, command, phase),
          "op" => "edit",
          "target_external_id" => target_external_id,
          "content" => [content]
        }

        case ChannelAdapter.deliver(reply_address, outbound) do
          {:ok, _result} ->
            :ok

          {:error, reason} ->
            emit(:command_feedback_failed, %{reason: safe_reason(reason)})
            send_progress_notice(entry, command, phase, content)
        end

      _missing ->
        :ok
    end
  end

  defp update_progress_notice(entry, _feedback_ref, command, phase, content) do
    _result = send_progress_notice(entry, command, phase, content)
    :ok
  end

  defp command_feedback_id(entry, command, phase) do
    "sha256:" <>
      BullX.Ext.generic_hash(
        Jason.encode!(%{
          mailbox_entry_id: entry.id,
          command: command,
          phase: phase
        })
      )
  end

  defp maybe_recall_command_targets(entry, result) do
    _result = recall_command_targets(result, entry)
    :ok
  end

  defp maybe_send_recall_fallback(:recalled, _entry, _code), do: :ok

  defp maybe_send_recall_fallback(:not_recalled, entry, code) do
    maybe_send_command_response(entry, code)
  end

  defp recall_command_targets(%{recall_targets: targets}, entry) when is_list(targets) do
    case Event.reply_address(entry.cloud_event["data"] || %{}) do
      %{} = reply_address ->
        recall_targets(entry, reply_address, targets)

      _missing ->
        :not_recalled
    end
  end

  defp recall_command_targets(_result, _entry), do: :not_recalled

  defp recall_targets(_entry, _reply_address, []), do: :not_recalled

  defp recall_targets(entry, reply_address, targets) do
    DeliveryRecall.deliver_targets(
      reply_address,
      targets,
      %{"mailbox_entry_id" => entry.id, "reason" => "command"},
      fn reason ->
        emit(:command_recall_failed, %{reason: safe_reason(reason)})
      end
    )
  end

  defp command_response_content("new_started") do
    control_notice(
      "Started a new conversation.",
      "New Session",
      %{"zh_CN" => "新会话", "en_US" => "New Session"}
    )
  end

  defp command_response_content("acl_denied") do
    control_notice(
      "Command denied.",
      "Denied",
      %{"zh_CN" => "命令已拒绝", "en_US" => "Denied"}
    )
  end

  defp command_response_content("steer_applied") do
    control_notice(
      "Steering note received.",
      "Steered",
      %{"zh_CN" => "已收到方向调整", "en_US" => "Steered"}
    )
  end

  defp command_response_content("retry_started") do
    control_notice(
      "Retrying the last exchange.",
      "Retrying",
      %{"zh_CN" => "正在重试上一轮", "en_US" => "Retrying"}
    )
  end

  defp command_response_content("stop_applied") do
    control_notice(
      "Stopped generation.",
      "Stopped",
      %{"zh_CN" => "已停止生成", "en_US" => "Stopped"}
    )
  end

  defp command_response_content("undo_applied") do
    control_notice(
      "Undid the last exchange.",
      "Undone",
      %{"zh_CN" => "已撤销上一轮", "en_US" => "Undone"}
    )
  end

  defp command_response_content("active_generation_present") do
    control_notice(
      "A response is still being generated.",
      "Busy",
      %{"zh_CN" => "仍在生成回复", "en_US" => "Busy"}
    )
  end

  defp command_response_content("no_active_generation") do
    localized_control_notice("no_active_generation")
  end

  defp command_response_content("no_retry_target") do
    control_notice(
      "There is no previous assistant reply to retry.",
      "No Retry",
      %{"zh_CN" => "没有可重试的上一轮", "en_US" => "No Retry"}
    )
  end

  defp command_response_content("no_undo_target") do
    control_notice(
      "There is no previous exchange to undo.",
      "No Undo",
      %{"zh_CN" => "没有可撤销的上一轮", "en_US" => "No Undo"}
    )
  end

  defp command_response_content("missing_prompt") do
    control_notice(
      "Add a steering prompt after /steer.",
      "Missing Prompt",
      %{"zh_CN" => "请在 /steer 后添加方向调整内容", "en_US" => "Missing Prompt"}
    )
  end

  defp command_response_content("unknown_command") do
    control_notice(
      "Unknown command.",
      "Unknown",
      %{"zh_CN" => "未知命令", "en_US" => "Unknown"}
    )
  end

  defp command_response_content("no_compressible_interval") do
    control_notice(
      "There is no history to compress.",
      "No History",
      %{"zh_CN" => "没有可压缩的历史对话", "en_US" => "No History"}
    )
  end

  defp command_response_content("compression_failed") do
    control_notice(
      "History compression failed.",
      "Compress Failed",
      %{"zh_CN" => "历史对话压缩失败", "en_US" => "Compress Failed"}
    )
  end

  defp command_response_content(_code) do
    control_notice(
      "Command failed.",
      "Failed",
      %{"zh_CN" => "命令失败", "en_US" => "Failed"}
    )
  end

  defp control_notice(text, short_text, i18n) do
    %{
      "kind" => "control_notice",
      "body" => %{
        "text" => text,
        "short_text" => short_text,
        "i18n" => i18n
      }
    }
  end

  defp localized_control_notice(code) do
    control_notice(
      localized_command_response(code, "text"),
      localized_command_response(code, "short_text"),
      %{
        "zh_CN" => localized_command_response(code, "short_text", locale: :"zh-Hans-CN"),
        "en_US" => localized_command_response(code, "short_text", locale: :"en-US")
      }
    )
  end

  defp localized_command_response(code, field, opts \\ []) do
    BullX.I18n.t("ai_agent.commands.responses.#{code}.#{field}", %{}, opts)
  end

  defp compress_progress_notice(:running) do
    progress_notice("正在压缩历史对话...", false)
  end

  defp compress_progress_notice(:complete) do
    progress_notice("以上历史对话记录已被压缩", true)
  end

  defp compress_progress_notice(:noop) do
    progress_notice("没有可压缩的历史对话", false)
  end

  defp compress_progress_notice(:failed) do
    progress_notice("历史对话压缩失败", false)
  end

  defp progress_notice(text, show_divider?) do
    %{
      "kind" => "progress_notice",
      "body" => %{
        "text" => text,
        "fallback_text" => text,
        "show_divider" => show_divider?
      }
    }
  end

  defp compress_result_state({:ok, %{status: :ok}}), do: :complete

  defp compress_result_state({:ok, %{status: :diagnostic, reason: "no_compressible_interval"}}),
    do: :noop

  defp compress_result_state({:ok, %{status: :diagnostic}}), do: :failed
  defp compress_result_state({:error, _reason}), do: :failed
  defp compress_result_state(_result), do: :failed

  defp caller_principal_uid(entry), do: Event.trigger_principal_uid(entry.routing_context)

  defp acl_context(entry, input_mode) do
    %{
      input_mode: input_mode,
      trigger_type: "mailbox_entry",
      trigger_id: entry.id,
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

  defp raw_message_text(%Message{content: content}) do
    content
    |> Enum.filter(&(Map.get(&1, "type") == "text"))
    |> Enum.map_join("", &Map.get(&1, "text", ""))
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
