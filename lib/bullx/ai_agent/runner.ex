defmodule BullX.AIAgent.Runner do
  @moduledoc """
  Shared AIAgent generation runner — the model/tool loop.

  Familiar shape: call the model → if it returned tool calls, execute them →
  append results → re-prompt → repeat until no tool calls. What makes this
  different from a typical OpenClaw / Hermes-Agent / Claude Code agentic loop
  is what happens between steps:

  * **Each step is committed before the next runs.** Assistant messages, tool
    results, and summaries are persisted as `Message` rows on the Conversation
    branch *before* the loop advances. A crashed runner resumes from the last
    committed step instead of replaying from the user input, and a transcript
    is never a separate artifact — it *is* the branch.
  * **A database-backed generation lease guards the Conversation.** Two
    Events arriving concurrently for the same Conversation never both fire
    the model: one runner holds the lease, the other waits or is preempted.
    Heartbeats extend the lease while the model streams; a dead runner's
    lease naturally expires and the next event takes over without manual
    cleanup.

  ## Internal contract

  The runner owns the model/tool loop for one user-like trigger Message. It
  keeps provider calls, tool execution, and visible delivery behind
  Conversation persistence and ACL checks.
  """

  import Ecto.Query

  require Logger

  alias BullX.AIAgent.{
    ACL,
    Commands,
    Compression,
    Conversation,
    Conversations,
    Event,
    Message,
    MessageContextBuilder,
    Profile,
    PromptRenderer,
    Tools
  }

  alias BullX.AIAgent.Tools.Dispatcher
  alias BullX.EventBus.{ChannelAdapter, TargetSessionEntry}
  alias BullX.LLM
  alias BullX.LLM.Catalog
  alias BullX.Repo

  @max_auto_compression_attempts 3
  @finish_reason_aliases %{
    "stop" => "stop",
    "completed" => "stop",
    "end_turn" => "stop",
    "tool_calls" => "tool_calls",
    "tool_use" => "tool_calls",
    "length" => "length",
    "max_tokens" => "length",
    "content_filter" => "content_filter",
    "cancelled" => "cancelled",
    "incomplete" => "incomplete"
  }
  @provider_diagnostic_keys [
    "request_id",
    "response_id",
    "correlation_id",
    "x_request_id",
    "x-request-id",
    "log_id"
  ]

  @spec run(Conversation.t(), Message.t(), Profile.t(), map()) :: :ok | {:error, term()}
  def run(
        %Conversation{} = conversation,
        %Message{} = trigger_message,
        %Profile{} = profile,
        context
      )
      when is_map(context) do
    # Retry/replay safety: if a completed assistant message already exists for this
    # trigger Message, resume from after-generation steps (re-deliver, finish unfinished tool
    # results) instead of generating again. `force_generation?` bypasses the check
    # for explicit user-initiated retries.
    case {Map.get(context, :force_generation?, false),
          Conversations.complete_assistant_for_trigger(trigger_message.id)} do
      {true, _assistant_message} ->
        start_generation(conversation, trigger_message, profile, context)

      {false, %Message{} = assistant_message} ->
        recover_generated_output(
          conversation,
          trigger_message,
          assistant_message,
          profile,
          context
        )

      {false, nil} ->
        start_generation(conversation, trigger_message, profile, context)
    end
  end

  defp recover_generated_output(
         conversation,
         trigger_message,
         assistant_message,
         profile,
         context
       ) do
    now = DateTime.utc_now(:microsecond)

    owner = %{
      "owner_trigger_type" => context.trigger_type,
      "owner_trigger_id" => context.trigger_id,
      "trigger_message_id" => trigger_message.id,
      "generation_lease_ttl_ms" => profile.generation.generation_lease_ttl_ms,
      "generation_heartbeat_interval_ms" => profile.generation.generation_heartbeat_interval_ms,
      "generation_max_runtime_ms" => profile.generation.generation_max_runtime_ms
    }

    with :allowed <-
           ACL.authorize(
             context.caller_principal_id,
             context.agent_principal_id,
             :ordinary,
             Map.get(context, :acl_context, %{})
           ),
         {:ok, leased_conversation, lease_id} <-
           Conversations.acquire_generation_lease(conversation, owner, now),
         context <- Map.put(context, :lease_id, lease_id),
         {:ok, active_conversation} <- ensure_owned_active(leased_conversation.id, lease_id),
         :ok <- maybe_recover_delivery(assistant_message, context),
         :ok <-
           maybe_recover_tool_results(
             active_conversation,
             trigger_message,
             assistant_message,
             profile,
             context
           ),
         {:ok, _conversation} <-
           Conversations.clear_generation_lease(active_conversation, lease_id) do
      :ok
    else
      {:denied, _reason} -> :ok
      {:error, :generation_active} -> :ok
      {:error, :generation_inactive} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp start_generation(conversation, trigger_message, profile, context) do
    case Map.get(context, :lease_id) do
      lease_id when is_binary(lease_id) ->
        run_existing_lease(conversation, trigger_message, profile, context, lease_id)

      _missing ->
        acquire_and_run_generation(conversation, trigger_message, profile, context)
    end
  end

  defp acquire_and_run_generation(conversation, trigger_message, profile, context) do
    now = DateTime.utc_now(:microsecond)

    owner = %{
      "owner_trigger_type" => context.trigger_type,
      "owner_trigger_id" => context.trigger_id,
      "trigger_message_id" => trigger_message.id,
      "generation_lease_ttl_ms" => profile.generation.generation_lease_ttl_ms,
      "generation_heartbeat_interval_ms" => profile.generation.generation_heartbeat_interval_ms,
      "generation_max_runtime_ms" => profile.generation.generation_max_runtime_ms
    }

    with :allowed <-
           ACL.authorize(
             context.caller_principal_id,
             context.agent_principal_id,
             :ordinary,
             Map.get(context, :acl_context, %{})
           ),
         {:ok, leased_conversation, lease_id} <-
           Conversations.acquire_generation_lease(conversation, owner, now),
         context <- Map.put(context, :lease_id, lease_id),
         run_result <-
           (case prepare_visible_stream(context) do
              {:ok, context} -> loop(leased_conversation, trigger_message, profile, context, 0)
              {:error, reason} -> {:error, reason}
            end),
         {:ok, _conversation} <-
           Conversations.clear_generation_lease(leased_conversation, lease_id) do
      run_result
    else
      {:denied, _reason} ->
        write_acl_denial(conversation, trigger_message, context)

      {:error, :generation_active} ->
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp run_existing_lease(conversation, trigger_message, profile, context, lease_id) do
    with :allowed <-
           ACL.authorize(
             context.caller_principal_id,
             context.agent_principal_id,
             :ordinary,
             Map.get(context, :acl_context, %{})
           ),
         {:ok, leased_conversation} <- ensure_owned_active(conversation.id, lease_id),
         context <- Map.put(context, :lease_id, lease_id),
         run_result <-
           (case prepare_visible_stream(context) do
              {:ok, context} -> loop(leased_conversation, trigger_message, profile, context, 0)
              {:error, reason} -> {:error, reason}
            end),
         {:ok, _conversation} <-
           Conversations.clear_generation_lease(leased_conversation, lease_id) do
      run_result
    else
      {:denied, _reason} ->
        write_acl_denial(conversation, trigger_message, context)

      {:error, :generation_inactive} ->
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp write_acl_denial(conversation, trigger_message, %{trigger_type: "ambient_batch"} = context) do
    :telemetry.execute([:bullx, :ai_agent, :acl_denied], %{}, %{
      trigger_type: context.trigger_type,
      trigger_id: context.trigger_id,
      agent_principal_id: context.agent_principal_id,
      trigger_message_id: trigger_message.id
    })

    :ok = maybe_clear_context_lease(conversation, context)
  end

  defp write_acl_denial(conversation, trigger_message, context) do
    write_error(conversation, trigger_message, context, "acl_denied", "AIAgent access denied.")
    maybe_clear_context_lease(conversation, context)
  end

  defp maybe_clear_context_lease(conversation, context) do
    case Map.get(context, :lease_id) do
      lease_id when is_binary(lease_id) ->
        case Conversations.clear_generation_lease(conversation, lease_id) do
          {:ok, _conversation} -> :ok
          {:error, _reason} -> :ok
        end

      _missing ->
        :ok
    end
  end

  defp loop(conversation, trigger_message, profile, context, turn) do
    case turn >= profile.context.max_turns do
      true ->
        result = write_turn_limit_error(conversation, trigger_message, context)
        finish_visible_stream(context, :failed, "max_turns_exceeded")
        result

      false ->
        do_loop(conversation, trigger_message, profile, context, turn)
    end
  end

  defp do_loop(conversation, trigger_message, profile, context, turn) do
    conversation = BullX.Repo.get!(Conversation, conversation.id)

    # Each loop iteration is gated by `owned_active_lease?` and every persist that
    # follows re-checks via `ensure_owned_active`. The invariant: if the lease has
    # been preempted (TTL expired, another runner took over), no new Messages get
    # appended, and the loop falls through to `:ok` without writing an error.
    with true <-
           Conversations.owned_active_lease?(
             conversation,
             context.lease_id,
             DateTime.utc_now(:microsecond)
           ),
         ambient_context <- ambient_context(conversation, trigger_message),
         tool_runtime_seed <- tool_runtime_seed(context),
         tools <-
           Tools.enabled_tools(
             profile,
             context.caller_principal_id,
             context.agent_principal_id,
             Map.get(context, :acl_context, %{}),
             tool_runtime_seed
           ),
         agent_tool_names <- Enum.map(tools, & &1.entry.name),
         {:ok, result} <-
           render_and_call_model(
             conversation,
             trigger_message,
             profile,
             context,
             ambient_context,
             tools,
             agent_tool_names
           ),
         {:ok, conversation} <- ensure_owned_active(conversation.id, context.lease_id),
         {:ok, assistant_message} <-
           persist_assistant_result(conversation, trigger_message, result, context),
         {:ok, conversation} <- ensure_owned_active(conversation.id, context.lease_id),
         tool_calls <- normalize_tool_calls(result.tool_calls) do
      case tool_calls do
        [] ->
          finish_visible_stream(context, :completed, "completed")
          assistant_message = finalize_visible_stream_delivery(assistant_message, context)
          maybe_deliver(assistant_message, context)

        [_ | _] ->
          with {:ok, conversation} <- ensure_owned_active(conversation.id, context.lease_id),
               {:ok, tool_message} <-
                 with_heartbeat(conversation, context, profile, fn ->
                   persist_tool_results(
                     conversation,
                     trigger_message,
                     assistant_message,
                     tool_calls,
                     profile,
                     context
                   )
                 end) do
            case maybe_handle_clarify_needs_input(tool_message, context) do
              :continue ->
                loop(conversation, trigger_message, profile, context, turn + 1)

              :needs_input ->
                finish_visible_stream(context, :interrupted, "needs_input")
                :ok
            end
          else
            {:error, :generation_inactive} ->
              finish_visible_stream(context, :interrupted, "generation_inactive")
              :ok

            {:error, reason} = error ->
              finish_visible_stream(context, :failed, safe_stream_reason(reason))
              error
          end
      end
    else
      false ->
        :ok

      {:error, :generation_inactive} ->
        :ok

      {:error, reason} ->
        case ensure_owned_active(conversation.id, context.lease_id) do
          {:ok, active_conversation} ->
            write_result =
              write_error(
                active_conversation,
                trigger_message,
                context,
                "generation_failed",
                "AIAgent generation failed.",
                %{"safe_error_reason" => safe_error_reason(reason)}
              )

            finish_visible_stream(context, :failed, safe_stream_reason(reason))

            case write_result do
              {:ok, _conversation, _message} -> :ok
              {:error, _write_reason} -> {:error, reason}
            end

          {:error, :generation_inactive} ->
            finish_visible_stream(context, :interrupted, "generation_inactive")
            :ok
        end
    end
  end

  defp render_and_call_model(
         conversation,
         trigger_message,
         profile,
         context,
         ambient_context,
         tools,
         agent_tool_names,
         attempt \\ 0
       ) do
    with {:ok, rendered} <-
           render_with_budget(
             conversation,
             trigger_message,
             profile,
             context,
             ambient_context,
             agent_tool_names,
             attempt
           ) do
      rendered = Compression.apply_prompt_cache_hints(rendered, profile: profile)
      opts = call_opts(profile, tools, rendered)

      case with_heartbeat(conversation, context, profile, fn ->
             call_model(conversation, trigger_message, profile, context, rendered, opts)
           end) do
        {:ok, result} ->
          {:ok, result}

        {:error, reason} ->
          maybe_compress_and_retry_provider_call(
            conversation,
            trigger_message,
            profile,
            context,
            ambient_context,
            tools,
            agent_tool_names,
            attempt,
            reason
          )
      end
    end
  end

  defp maybe_compress_and_retry_provider_call(
         conversation,
         trigger_message,
         profile,
         context,
         ambient_context,
         tools,
         agent_tool_names,
         attempt,
         reason
       ) do
    cond do
      not Compression.context_overflow_error?(reason) ->
        {:error, reason}

      attempt >= @max_auto_compression_attempts ->
        {:error, :context_overflow_after_compression}

      true ->
        context
        |> Map.put(:profile, profile)
        |> Map.put(:compression_trigger, "provider_context_overflow")
        |> then(&Compression.auto_compress(conversation, &1, attempt))
        |> retry_provider_call_after_compression(
          conversation,
          trigger_message,
          profile,
          context,
          ambient_context,
          tools,
          agent_tool_names,
          attempt
        )
    end
  end

  defp retry_provider_call_after_compression(
         {:ok, %{status: :ok}},
         conversation,
         trigger_message,
         profile,
         context,
         ambient_context,
         tools,
         agent_tool_names,
         attempt
       ) do
    with {:ok, active_conversation} <- ensure_owned_active(conversation.id, context.lease_id) do
      render_and_call_model(
        active_conversation,
        trigger_message,
        profile,
        context,
        ambient_context,
        tools,
        agent_tool_names,
        attempt + 1
      )
    end
  end

  defp retry_provider_call_after_compression(
         {:ok, %{status: :diagnostic, reason: "branch_changed"}},
         _conversation,
         _trigger_message,
         _profile,
         _context,
         _ambient_context,
         _tools,
         _agent_tool_names,
         _attempt
       ),
       do: {:error, :context_branch_changed}

  defp retry_provider_call_after_compression(
         {:ok, _diagnostic},
         _conversation,
         _trigger_message,
         _profile,
         _context,
         _ambient_context,
         _tools,
         _agent_tool_names,
         _attempt
       ),
       do: {:error, :context_overflow_after_compression}

  defp retry_provider_call_after_compression(
         {:error, reason},
         _conversation,
         _trigger_message,
         _profile,
         _context,
         _ambient_context,
         _tools,
         _agent_tool_names,
         _attempt
       ),
       do: {:error, reason}

  defp call_model(conversation, trigger_message, profile, context, rendered, opts) do
    case stream_requested?(context) do
      true -> stream_model_call(conversation, trigger_message, profile, context, rendered, opts)
      false -> LLM.chat(profile.main_llm, rendered.messages, opts)
    end
  end

  defp prepare_visible_stream(%{visible_stream: %{stream_id: stream_id}} = context)
       when is_binary(stream_id),
       do: {:ok, context}

  defp prepare_visible_stream(context) do
    if stream_requested?(context) do
      create_visible_stream(context)
    else
      {:ok, context}
    end
  end

  defp create_visible_stream(context) do
    output = context.output

    case output.create_stream(context.target_session_id, context.target_session_entry_id) do
      {:ok, stream_id} ->
        case start_stream_consumer(context.reply_channel, stream_id) do
          :ok ->
            {:ok,
             Map.put(context, :visible_stream, %{
               stream_id: stream_id,
               started_at: DateTime.to_iso8601(DateTime.utc_now(:microsecond))
             })}

          {:error, reason} ->
            finish_stream(output, stream_id, :failed, safe_stream_reason(reason))
            {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp stream_model_call(conversation, _trigger_message, profile, context, rendered, opts) do
    case Map.get(context, :visible_stream) do
      %{stream_id: stream_id} when is_binary(stream_id) ->
        LLM.stream_chat(profile.main_llm, rendered.messages, opts,
          on_result: stream_chunk_callback(conversation.id, context, context.output, stream_id)
        )

      _missing ->
        LLM.chat(profile.main_llm, rendered.messages, opts)
    end
  end

  defp stream_requested?(%{reply_channel: %{} = reply_channel} = context) do
    is_binary(Map.get(context, :target_session_id)) and
      is_atom(Map.get(context, :output)) and
      stream_requested_by_reply_channel?(reply_channel)
  end

  defp stream_requested?(_context), do: false

  defp stream_requested_by_reply_channel?(reply_channel) do
    Map.get(reply_channel, "stream") == true or Map.get(reply_channel, :stream) == true or
      Map.get(reply_channel, "delivery_mode") == "stream" or
      Map.get(reply_channel, :delivery_mode) == "stream"
  end

  defp persist_assistant_result(conversation, trigger_message, result, context)
       when is_map(result) do
    persist_assistant(conversation, trigger_message, result, context)
  end

  defp start_stream_consumer(reply_channel, stream_id) do
    parent = self()

    opts = [
      delivery_update_fun: fn result ->
        send(parent, {:ai_agent_stream_delivery_result, stream_id, result})
        :ok
      end
    ]

    case Task.start(fn -> ChannelAdapter.consume_stream(reply_channel, stream_id, opts) end) do
      {:ok, _pid} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp stream_chunk_callback(conversation_id, context, output, stream_id) do
    fn
      "" ->
        :ok

      chunk_text when is_binary(chunk_text) ->
        # Raising here is deliberate: ReqLLM's stream pipeline turns this into a
        # stream-level error, which the loop catches as `{:error, reason}` and
        # converts into a failed-stream finalization. Returning `{:error, _}`
        # would silently drop subsequent chunks while the model kept generating.
        with :ok <- maybe_cancel_for_pending_stop(conversation_id, context),
             {:ok, _conversation} <- ensure_owned_active(conversation_id, context.lease_id),
             {:ok, _offset} <- output.append_chunk(stream_id, chunk_text) do
          :ok
        else
          {:error, reason} -> raise "ai_agent_stream_append_failed: #{safe_stream_reason(reason)}"
        end
    end
  end

  defp maybe_cancel_for_pending_stop(conversation_id, context) do
    case pending_authorized_stop_entry(context) do
      %TargetSessionEntry{} = entry ->
        now = DateTime.utc_now(:microsecond)

        case Conversations.cancel_generation_lease(
               conversation_id,
               context.lease_id,
               "stop",
               now,
               %{
                 "cancelled_by_command_entry_id" => entry.id
               }
             ) do
          {:ok, _conversation} -> :ok
          {:error, :generation_inactive} -> :ok
          {:error, reason} -> {:error, reason}
        end

      nil ->
        :ok
    end
  end

  defp pending_authorized_stop_entry(context) do
    with target_session_id when is_binary(target_session_id) <-
           Map.get(context, :target_session_id),
         current_entry_id when is_binary(current_entry_id) <-
           Map.get(context, :target_session_entry_id),
         %TargetSessionEntry{} = current_entry <- Repo.get(TargetSessionEntry, current_entry_id) do
      target_session_id
      |> pending_entries_after(current_entry.entry_seq)
      |> Enum.find(&authorized_stop_entry?(&1, context))
    else
      _missing -> nil
    end
  end

  defp pending_entries_after(target_session_id, current_entry_seq) do
    TargetSessionEntry
    |> where([e], e.target_session_id == ^target_session_id)
    |> where([e], e.entry_seq > ^current_entry_seq)
    |> order_by([e], asc: e.entry_seq)
    |> limit(10)
    |> Repo.all()
  end

  defp authorized_stop_entry?(%TargetSessionEntry{} = entry, context) do
    case {stop_command_entry?(entry), Event.trigger_principal_id(entry.routing_context)} do
      {true, caller_principal_id} when is_binary(caller_principal_id) ->
        ACL.authorize(
          caller_principal_id,
          context.agent_principal_id,
          :ordinary,
          pending_command_acl_context(entry)
        ) == :allowed

      _other ->
        false
    end
  end

  defp stop_command_entry?(
         %TargetSessionEntry{cloud_event: %{"type" => "bullx.command.invoked"}} =
           entry
       ) do
    entry.cloud_event
    |> Event.data()
    |> Commands.command_event_name()
    |> Kernel.==("stop")
  end

  defp stop_command_entry?(
         %TargetSessionEntry{cloud_event: %{"type" => "bullx.im.message.addressed"}} = entry
       ) do
    entry.cloud_event
    |> Event.data()
    |> Event.text_content()
    |> Commands.detect_text()
    |> case do
      {:command, "stop", _args} -> true
      _other -> false
    end
  end

  defp stop_command_entry?(_entry), do: false

  defp pending_command_acl_context(entry) do
    %{
      input_mode: "command",
      trigger_type: "target_session_entry",
      trigger_id: entry.id,
      channel_kind: get_in(entry.cloud_event, ["data", "channel", "kind"])
    }
  end

  defp finish_stream(output, stream_id, status, reason) do
    case output.finish_stream(stream_id, status, reason) do
      :ok -> :ok
      {:error, _reason} -> :ok
    end
  end

  defp finish_visible_stream(context, status, reason) do
    case Map.get(context, :visible_stream) do
      %{stream_id: stream_id} when is_binary(stream_id) ->
        finish_stream(context.output, stream_id, status, reason)

      _missing ->
        :ok
    end
  end

  defp finalize_visible_stream_delivery(%Message{} = message, context) do
    case Map.get(context, :visible_stream) do
      %{stream_id: stream_id} when is_binary(stream_id) ->
        stream =
          (message.metadata["stream"] || %{})
          |> Map.merge(%{
            "stream_id" => stream_id,
            "started_at" => Map.get(context.visible_stream, :started_at),
            "finished_at" => DateTime.to_iso8601(DateTime.utc_now(:microsecond)),
            "status" => "completed"
          })

        metadata =
          message.metadata
          |> Map.put("delivery", final_stream_delivery(stream_id, context, message.id))
          |> Map.put("stream", stream)

        case Conversations.update_message(message, %{metadata: metadata}) do
          {:ok, message} -> message
          {:error, _reason} -> message
        end

      _missing ->
        message
    end
  end

  defp final_stream_delivery(stream_id, context, assistant_message_id) do
    delivery = stream_delivery_metadata(stream_id, context, assistant_message_id)

    case receive_stream_delivery_result(stream_id) do
      {:ok, result} ->
        Map.merge(delivery, %{
          "status" => "sent",
          "adapter_result_ref" => safe_adapter_result_ref(result),
          "safe_error_code" => nil,
          "delivered_at" => DateTime.to_iso8601(DateTime.utc_now(:microsecond))
        })

      :missing ->
        delivery
    end
  end

  defp receive_stream_delivery_result(stream_id) do
    receive do
      {:ai_agent_stream_delivery_result, ^stream_id, result} -> {:ok, result}
    after
      250 -> :missing
    end
  end

  defp stream_delivery_metadata(stream_id, context, assistant_message_id \\ nil) do
    reply_channel = context.reply_channel

    %{
      "mode" => "stream",
      "stream_id" => stream_id,
      "adapter" => Map.get(reply_channel, "adapter") || Map.get(reply_channel, :adapter),
      "reply_channel_identity" => reply_channel_identity(reply_channel),
      "idempotency_key" =>
        Tools.idempotency_key(%{
          assistant_message_id: assistant_message_id || stream_id,
          trigger_id: context.trigger_id,
          reply_channel: reply_channel_identity(reply_channel)
        }),
      "status" => "unknown",
      "adapter_result_ref" => nil,
      "safe_error_code" => nil,
      "delivered_at" => nil
    }
  end

  defp safe_stream_reason(reason), do: safe_error_reason(reason)

  defp safe_error_reason(reason) do
    reason
    |> format_error_reason()
    |> normalize_error_reason()
  end

  defp format_error_reason(nil), do: "nil"
  defp format_error_reason(reason) when is_atom(reason), do: Atom.to_string(reason)

  defp format_error_reason(reason) when is_binary(reason) do
    case String.valid?(reason) do
      true -> reason
      false -> inspect(reason, limit: :infinity, printable_limit: :infinity)
    end
  end

  defp format_error_reason(%{__exception__: true} = exception) do
    "#{inspect(exception.__struct__)}: #{Exception.message(exception)}"
  end

  defp format_error_reason(reason),
    do: inspect(reason, limit: :infinity, printable_limit: :infinity)

  defp normalize_error_reason(reason) do
    case String.trim(reason) do
      "" -> "unknown_error"
      normalized -> normalized
    end
  end

  defp render_with_budget(
         conversation,
         trigger_message,
         profile,
         context,
         ambient_context,
         agent_tool_names,
         attempt
       ) do
    with {:ok, rendered} <-
           PromptRenderer.render(conversation, profile, trigger_message,
             ambient_context: ambient_context,
             agent_tool_names: agent_tool_names
           ) do
      cond do
        not Compression.over_budget?(rendered, profile) ->
          {:ok, rendered}

        attempt >= @max_auto_compression_attempts ->
          {:error, :context_over_budget}

        true ->
          case Compression.auto_compress(
                 conversation,
                 Map.put(context, :profile, profile),
                 attempt
               ) do
            {:ok, %{status: :ok}} ->
              render_with_budget(
                conversation,
                trigger_message,
                profile,
                context,
                ambient_context,
                agent_tool_names,
                attempt + 1
              )

            {:ok, %{status: :diagnostic, reason: "branch_changed"}} ->
              {:error, :context_branch_changed}

            {:ok, _diagnostic} ->
              {:error, :context_over_budget}

            {:error, reason} ->
              {:error, reason}
          end
      end
    end
  end

  defp ensure_owned_active(conversation_id, lease_id) do
    conversation = BullX.Repo.get!(Conversation, conversation_id)

    cond do
      not is_nil(conversation.ended_at) ->
        {:error, :generation_inactive}

      Conversations.owned_active_lease?(conversation, lease_id, DateTime.utc_now(:microsecond)) ->
        {:ok, conversation}

      true ->
        {:error, :generation_inactive}
    end
  end

  defp with_heartbeat(conversation, context, profile, fun) when is_function(fun, 0) do
    lease_id = Map.get(context, :lease_id)
    interval_ms = profile.generation.generation_heartbeat_interval_ms

    if Application.get_env(:bullx, :ai_agent_async_heartbeat, true) do
      parent = self()
      ref = make_ref()

      # Heartbeat death is not catastrophic: the lease just stops being extended
      # and naturally expires, which the next `ensure_owned_active` after `fun.()`
      # catches as `:generation_inactive`. So this spawn is intentionally bare.
      pid =
        spawn(fn ->
          heartbeat_loop(parent, ref, conversation.id, lease_id, interval_ms)
        end)

      try do
        fun.()
      after
        send(pid, {:stop, ref})
      end
    else
      Conversations.heartbeat_generation_lease(
        conversation.id,
        lease_id,
        DateTime.utc_now(:microsecond)
      )

      fun.()
    end
  end

  defp heartbeat_loop(parent, ref, conversation_id, lease_id, interval_ms) do
    receive do
      {:stop, ^ref} ->
        :ok
    after
      interval_ms ->
        case Conversations.heartbeat_generation_lease(
               conversation_id,
               lease_id,
               DateTime.utc_now(:microsecond)
             ) do
          {:ok, _conversation} ->
            heartbeat_loop(parent, ref, conversation_id, lease_id, interval_ms)

          {:error, reason} ->
            Logger.warning(
              "ai_agent generation heartbeat failed; lease will not be extended " <>
                "(conversation_id=#{conversation_id} reason=#{inspect(reason)})"
            )

            send(parent, {:ai_agent_generation_heartbeat_failed, ref, reason})
        end
    end
  end

  defp maybe_recover_delivery(%Message{} = assistant_message, context) do
    case get_in(assistant_message.metadata, ["delivery", "status"]) do
      "sent" -> :ok
      _other -> maybe_deliver(assistant_message, context)
    end
  end

  defp maybe_recover_tool_results(
         conversation,
         trigger_message,
         assistant_message,
         profile,
         context
       ) do
    tool_calls = assistant_message.content |> tool_calls_from_content()

    cond do
      tool_calls == [] ->
        :ok

      Conversations.tool_result_for_assistant?(assistant_message.id) ->
        loop(conversation, trigger_message, profile, context, 0)

      true ->
        with {:ok, _message} <-
               persist_tool_results(
                 conversation,
                 trigger_message,
                 assistant_message,
                 tool_calls,
                 profile,
                 context
               ) do
          loop(conversation, trigger_message, profile, context, 0)
        end
    end
  end

  defp tool_calls_from_content(content) when is_list(content) do
    content
    |> Enum.filter(&(Map.get(&1, "type") == "tool_call"))
    |> Enum.map(fn block ->
      %{
        id: block["tool_call_id"],
        name: block["name"],
        arguments: block["arguments"] || %{}
      }
    end)
  end

  defp tool_runtime_seed(context) do
    %{}
    |> put_present(:reply_channel, Map.get(context, :reply_channel))
    |> put_present(:clarify_mode, Map.get(context, :clarify_mode))
    |> put_present(:web_req_options, Map.get(context, :web_req_options))
    |> put_present(:plugin_registry, Map.get(context, :plugin_registry))
  end

  defp put_present(map, _key, nil), do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)

  defp ambient_context(
         %Conversation{agent_principal_id: agent_principal_id},
         %Message{metadata: metadata} = trigger_message
       ) do
    case get_in(metadata, ["scene"]) do
      %{} = scene ->
        MessageContextBuilder.ambient_recall(agent_principal_id, scene, trigger_message)

      _other ->
        []
    end
  end

  defp call_opts(%Profile{} = profile, tools, rendered) do
    provider_options = prompt_cache_provider_options(profile, rendered)

    opts = [tools: Enum.map(tools, & &1.tool)]

    case provider_options do
      [] -> opts
      [_ | _] -> Keyword.put(opts, :provider_options, provider_options)
    end
  end

  defp prompt_cache_provider_options(%Profile{context: %{prompt_cache: true}} = profile, rendered) do
    cond do
      prompt_cache_boundary_supported?(profile, rendered) and
          rendered.system_prompt.stable_prefix.stable_section_count > 0 ->
        [anthropic_prompt_cache: true]

      true ->
        []
    end
  end

  defp prompt_cache_provider_options(_profile, _rendered), do: []

  defp prompt_cache_boundary_supported?(profile, rendered) do
    with {:ok, resolved} <- Catalog.resolve_model_config(profile.main_llm),
         true <- resolved.req_llm_provider in [:anthropic, "anthropic"],
         stable_index when is_integer(stable_index) <-
           rendered.system_prompt.stable_prefix.content_part_index do
      stable_index == length(rendered.system_prompt.system_content) - 1 and
        rendered.system_prompt.diagnostics.volatile_suffix_size == 0
    else
      _other -> false
    end
  end

  defp persist_assistant(conversation, trigger_message, result, context) do
    attrs = %{
      conversation_id: conversation.id,
      role: :assistant,
      kind: :normal,
      status: :complete,
      content: assistant_content(result),
      target_session_id: Map.get(context, :target_session_id),
      target_session_entry_id: Map.get(context, :target_session_entry_id),
      metadata:
        trigger_message
        |> generation_metadata(context, result_metadata(result))
        |> maybe_put_visible_stream_metadata(result, context)
    }

    case Conversations.append_message(conversation, attrs) do
      {:ok, _conversation, message} -> {:ok, message}
      {:error, reason} -> {:error, reason}
    end
  end

  defp maybe_put_visible_stream_metadata(metadata, result, context) do
    with %{stream_id: stream_id} <- Map.get(context, :visible_stream),
         true <- final_visible_stream_result?(result) do
      Map.merge(metadata, %{
        "delivery" => stream_delivery_metadata(stream_id, context),
        "stream" => %{
          "stream_id" => stream_id,
          "started_at" => Map.get(context.visible_stream, :started_at),
          "status" => "open"
        }
      })
    else
      _other -> metadata
    end
  end

  defp final_visible_stream_result?(result) do
    assistant_result_text(result) != "" and normalize_tool_calls(result.tool_calls) == []
  end

  defp assistant_result_text(%{text: text}) when is_binary(text), do: String.trim(text)
  defp assistant_result_text(_result), do: ""

  defp assistant_content(result) do
    tool_blocks =
      result.tool_calls
      |> normalize_tool_calls()
      |> Enum.map(fn call ->
        %{
          "type" => "tool_call",
          "tool_call_id" => call.id,
          "name" => call.name,
          "arguments" => call.arguments || %{}
        }
      end)

    text_blocks =
      case result.text do
        "" -> []
        text -> [%{"type" => "text", "text" => text}]
      end

    text_blocks ++ tool_blocks
  end

  defp persist_tool_results(
         conversation,
         trigger_message,
         assistant_message,
         tool_calls,
         profile,
         context
       ) do
    seed =
      %{
        caller_principal_id: context.caller_principal_id,
        agent_principal_id: context.agent_principal_id,
        conversation_id: conversation.id,
        trigger_type: context.trigger_type,
        trigger_id: context.trigger_id,
        deadline_at_ms: generation_deadline_at_ms(conversation),
        acl_context: Map.get(context, :acl_context, %{}),
        metadata: tool_runtime_seed(context)
      }
      |> put_present(:plugin_registry, Map.get(context, :plugin_registry))

    result_blocks =
      profile
      |> execute_tool_calls(tool_calls, seed, assistant_message)
      |> maybe_attach_steering(context)

    attrs = %{
      conversation_id: conversation.id,
      role: :tool,
      kind: :normal,
      status: :complete,
      content: result_blocks,
      target_session_id: Map.get(context, :target_session_id),
      target_session_entry_id: Map.get(context, :target_session_entry_id),
      metadata:
        generation_metadata(trigger_message, context, %{
          "root_assistant_message_id" => assistant_message.id
        })
    }

    case Conversations.append_message(conversation, attrs) do
      {:ok, _conversation, message} -> {:ok, message}
      {:error, reason} -> {:error, reason}
    end
  end

  defp write_error(conversation, trigger_message, context, code, message, extra \\ %{}) do
    error_metadata = Map.put(extra, "safe_error_code", code)

    attrs = %{
      conversation_id: conversation.id,
      role: :assistant,
      kind: :error,
      status: :complete,
      content: [Message.error_block(code, message, false)],
      target_session_id: Map.get(context, :target_session_id),
      target_session_entry_id: Map.get(context, :target_session_entry_id),
      metadata: generation_metadata(trigger_message, context, error_metadata)
    }

    Conversations.append_message(conversation, attrs)
  end

  defp write_turn_limit_error(conversation, trigger_message, context) do
    case ensure_owned_active(conversation.id, context.lease_id) do
      {:ok, active_conversation} ->
        case write_error(
               active_conversation,
               trigger_message,
               context,
               "max_turns_exceeded",
               "AIAgent generation reached the configured turn limit."
             ) do
          {:ok, _conversation, _message} -> :ok
          {:error, reason} -> {:error, reason}
        end

      {:error, :generation_inactive} ->
        :ok
    end
  end

  defp generation_metadata(trigger_message, context, extra) do
    %{
      "generation" =>
        %{
          "lease_id" => Map.get(context, :lease_id),
          "trigger_message_id" => trigger_message.id,
          "trigger_type" => context.trigger_type,
          "trigger_id" => context.trigger_id,
          "root_assistant_message_id" => Map.get(extra, "root_assistant_message_id")
        }
        |> Enum.reject(fn {_key, value} -> is_nil(value) end)
        |> Map.new()
    }
    |> maybe_put_retry_metadata(context)
    |> Map.merge(Map.delete(extra, "root_assistant_message_id"))
  end

  defp result_metadata(result) do
    metadata = %{
      "provider_id" => result.provider_id,
      "model_id" => result.model_id,
      "usage" => result.usage,
      "usage_source" => usage_source(result.usage),
      "finish_reason" => normalize_finish_reason(result.finish_reason)
    }

    case provider_diagnostics(result.provider_meta) do
      diagnostics when diagnostics == %{} -> metadata
      diagnostics -> Map.put(metadata, "provider_diagnostics", diagnostics)
    end
  end

  defp usage_source(nil), do: "estimated"
  defp usage_source(_usage), do: "provider_reported"

  defp generation_deadline_at_ms(%Conversation{generation: %{"max_expires_at" => max_expires_at}})
       when is_binary(max_expires_at) do
    case DateTime.from_iso8601(max_expires_at) do
      {:ok, deadline, _offset} -> DateTime.to_unix(deadline, :millisecond)
      _other -> nil
    end
  end

  defp generation_deadline_at_ms(%Conversation{}), do: nil

  defp execute_tool_calls(profile, tool_calls, seed, assistant_message) do
    if parallel_tool_calls?(profile, tool_calls, seed) do
      results =
        Task.async_stream(
          tool_calls,
          &Dispatcher.execute_call(profile, &1, seed, assistant_message),
          ordered: true,
          timeout: parallel_tool_timeout(tool_calls, profile, seed),
          on_timeout: :kill_task
        )

      tool_calls
      |> Enum.zip(results)
      |> Enum.map(fn
        {_tool_call, {:ok, result}} -> result
        {tool_call, {:exit, _reason}} -> tool_execution_failed_block(tool_call)
      end)
    else
      Enum.map(tool_calls, &Dispatcher.execute_call(profile, &1, seed, assistant_message))
    end
  end

  defp parallel_tool_calls?(_profile, [_single], _seed), do: false

  defp parallel_tool_calls?(profile, [_first, _second | _rest] = tool_calls, seed) do
    Enum.all?(tool_calls, &parallel_safe_tool_call?(profile, &1, seed))
  end

  defp parallel_tool_calls?(_profile, _tool_calls, _seed), do: false

  defp parallel_safe_tool_call?(profile, tool_call, seed) do
    tool_name = tool_call[:name] || tool_call["name"]

    case Tools.effective_tool(profile, tool_name, seed) do
      {:ok, entry, _access} -> Map.get(entry, :parallel_safe, false)
      {:error, _reason} -> false
    end
  end

  defp parallel_tool_timeout(tool_calls, profile, seed) do
    tool_calls
    |> Enum.map(fn tool_call ->
      tool_name = tool_call[:name] || tool_call["name"]

      case Tools.effective_tool(profile, tool_name, seed) do
        {:ok, entry, _access} -> entry.timeout_ms
        {:error, _reason} -> 30_000
      end
    end)
    |> Enum.max(fn -> 30_000 end)
  end

  defp tool_execution_failed_block(tool_call) do
    tool_call_id = tool_call[:id] || tool_call["id"] || "missing_tool_call_id"
    Message.tool_result_error_block(tool_call_id, "tool_failed", "Tool failed.")
  end

  defp maybe_put_retry_metadata(metadata, context) do
    case {Map.get(context, :retry_of_message_id), Map.get(context, :retry_command_entry_id)} do
      {retry_of_message_id, retry_command_entry_id}
      when is_binary(retry_of_message_id) and is_binary(retry_command_entry_id) ->
        metadata
        |> Map.put("retry_of_message_id", retry_of_message_id)
        |> Map.put("retry_command_entry_id", retry_command_entry_id)

      _other ->
        metadata
    end
  end

  defp normalize_tool_calls(nil), do: []
  defp normalize_tool_calls(tool_calls), do: Enum.map(tool_calls, &ReqLLM.ToolCall.from_map/1)

  defp normalize_finish_reason(nil), do: nil

  defp normalize_finish_reason(value) when is_atom(value) or is_binary(value) do
    key =
      value
      |> to_string()
      |> String.downcase()

    Map.get(@finish_reason_aliases, key, String.slice(key, 0, 120))
  end

  defp normalize_finish_reason(_value), do: "unknown"

  defp provider_diagnostics(provider_meta) when is_map(provider_meta) do
    @provider_diagnostic_keys
    |> Enum.reduce(%{}, fn key, acc ->
      case Map.get(provider_meta, key) || Map.get(provider_meta, String.to_atom(key)) do
        value when is_binary(value) and value != "" ->
          Map.put(acc, key, String.slice(value, 0, 120))

        value when is_integer(value) ->
          Map.put(acc, key, Integer.to_string(value))

        value when is_atom(value) ->
          Map.put(acc, key, Atom.to_string(value))

        _value ->
          acc
      end
    end)
  end

  defp provider_diagnostics(_provider_meta), do: %{}

  defp maybe_deliver(assistant_message, context) do
    text = assistant_visible_text(assistant_message)

    cond do
      text == "" ->
        :ok

      streamed_delivery?(assistant_message) ->
        :ok

      not is_map(Map.get(context, :reply_channel)) ->
        update_delivery_metadata(assistant_message, %{
          "mode" => "outbound",
          "status" => "failed",
          "safe_error_code" => "missing_reply_channel",
          "delivered_at" => nil
        })

      true ->
        reply_channel = context.reply_channel
        idempotency_key = delivery_idempotency_key(assistant_message, context, reply_channel)

        outbound = %{
          "id" => idempotency_key,
          "op" => "send",
          "content" => [%{"kind" => "text", "body" => %{"text" => text}}]
        }

        delivery_base = %{
          "mode" => "outbound",
          "adapter" => Map.get(reply_channel, "adapter") || Map.get(reply_channel, :adapter),
          "reply_channel_identity" => reply_channel_identity(reply_channel),
          "idempotency_key" => idempotency_key
        }

        case ChannelAdapter.deliver(reply_channel, outbound) do
          {:ok, result} ->
            update_delivery_metadata(
              assistant_message,
              Map.merge(delivery_base, %{
                "status" => "sent",
                "adapter_result_ref" => safe_adapter_result_ref(result),
                "safe_error_code" => nil,
                "delivered_at" => DateTime.to_iso8601(DateTime.utc_now(:microsecond))
              })
            )

          {:error, reason} ->
            update_delivery_metadata(
              assistant_message,
              Map.merge(delivery_base, %{
                "status" => "failed",
                "adapter_result_ref" => nil,
                "safe_error_code" => safe_delivery_error(reason),
                "delivered_at" => nil
              })
            )
        end
    end
  end

  defp maybe_handle_clarify_needs_input(%Message{} = tool_message, context) do
    case clarify_control_result(tool_message.content) do
      nil ->
        :continue

      %{"status" => "requested"} = result ->
        deliver_clarify_request(tool_message, result, context)

      %{"status" => "no_response"} ->
        record_clarify_no_response(tool_message)
        :needs_input
    end
  end

  defp clarify_control_result(content) when is_list(content) do
    Enum.find_value(content, fn
      %{"type" => "tool_result", "is_error" => false, "result" => %{"kind" => kind} = result}
      when kind in ["clarify.requested", "clarify.no_response"] ->
        result

      %{"type" => "tool_result", "is_error" => false, "result" => %{"status" => status} = result}
      when status in ["requested", "no_response"] ->
        result

      _block ->
        nil
    end)
  end

  defp clarify_control_result(_content), do: nil

  defp deliver_clarify_request(%Message{} = tool_message, result, context) do
    case Map.get(context, :reply_channel) do
      %{} = reply_channel ->
        idempotency_key = clarify_delivery_idempotency_key(tool_message, result, reply_channel)
        outbound = clarify_outbound(reply_channel, result, idempotency_key)

        delivery_base = %{
          "mode" => "clarify",
          "adapter" => Map.get(reply_channel, "adapter") || Map.get(reply_channel, :adapter),
          "reply_channel_identity" => reply_channel_identity(reply_channel),
          "idempotency_key" => idempotency_key,
          "correlation_id" => result["correlation_id"]
        }

        case ChannelAdapter.deliver(reply_channel, outbound) do
          {:ok, delivery_result} ->
            update_delivery_metadata(
              tool_message,
              Map.merge(delivery_base, %{
                "status" => "sent",
                "adapter_result_ref" => safe_adapter_result_ref(delivery_result),
                "safe_error_code" => nil,
                "delivered_at" => DateTime.to_iso8601(DateTime.utc_now(:microsecond))
              })
            )

          {:error, reason} ->
            update_delivery_metadata(
              tool_message,
              Map.merge(delivery_base, %{
                "status" => "failed",
                "adapter_result_ref" => nil,
                "safe_error_code" => safe_delivery_error(reason),
                "delivered_at" => nil
              })
            )
        end

        :needs_input

      _missing ->
        record_clarify_no_response(tool_message)
        :needs_input
    end
  end

  defp record_clarify_no_response(%Message{} = tool_message) do
    update_delivery_metadata(tool_message, %{
      "mode" => "clarify",
      "status" => "no_response",
      "adapter_result_ref" => nil,
      "safe_error_code" => nil,
      "delivered_at" => nil
    })
  end

  defp clarify_outbound(reply_channel, result, idempotency_key) do
    %{
      "id" => idempotency_key,
      "op" => "send",
      "content" => [clarify_content_block(reply_channel, result)]
    }
  end

  defp clarify_content_block(reply_channel, result) do
    case feishu_reply_channel?(reply_channel) do
      true ->
        %{
          "kind" => "card",
          "body" => %{
            "format" => "feishu.card.v2",
            "payload" => clarify_feishu_card(result)
          }
        }

      false ->
        %{"kind" => "text", "body" => %{"text" => clarify_text(result)}}
    end
  end

  defp feishu_reply_channel?(reply_channel) do
    (Map.get(reply_channel, "adapter") || Map.get(reply_channel, :adapter)) in ["feishu", :feishu]
  end

  defp clarify_feishu_card(result) do
    choices = result["choices"] || []
    correlation_id = result["correlation_id"]

    elements =
      [
        %{
          "tag" => "div",
          "text" => %{"tag" => "lark_md", "content" => result["question"] || "Please clarify."}
        },
        %{
          "tag" => "div",
          "text" => %{
            "tag" => "plain_text",
            "content" => "Reply in this chat if none of the choices fit."
          }
        }
      ] ++ choice_action_elements(choices, correlation_id)

    %{
      "schema" => "2.0",
      "config" => %{"update_multi" => true},
      "header" => %{
        "title" => %{"tag" => "plain_text", "content" => "Clarification needed"}
      },
      "body" => %{
        "direction" => "vertical",
        "padding" => "12px 12px 12px 12px",
        "elements" => elements
      }
    }
  end

  defp choice_action_elements([], _correlation_id), do: []

  defp choice_action_elements(choices, correlation_id) do
    [
      %{
        "tag" => "action",
        "actions" =>
          choices
          |> Enum.with_index()
          |> Enum.map(fn {choice, index} -> choice_button(choice, index, correlation_id) end)
      }
    ]
  end

  defp choice_button(choice, index, correlation_id) do
    %{
      "tag" => "button",
      "text" => %{"tag" => "plain_text", "content" => choice},
      "type" => "primary",
      "value" => %{
        "bullx_action" => "clarify_answer",
        "correlation_id" => correlation_id,
        "choice_index" => index,
        "choice_value" => choice
      }
    }
  end

  defp clarify_text(result) do
    choices = result["choices"] || []

    case choices do
      [] ->
        result["question"] || "Please clarify."

      [_ | _] ->
        [
          result["question"] || "Please clarify.",
          "\n",
          choices
          |> Enum.with_index(1)
          |> Enum.map_join("\n", fn {choice, index} -> "#{index}. #{choice}" end)
        ]
        |> IO.iodata_to_binary()
    end
  end

  defp clarify_delivery_idempotency_key(%Message{} = tool_message, result, reply_channel) do
    Tools.idempotency_key(%{
      tool_message_id: tool_message.id,
      correlation_id: result["correlation_id"],
      reply_channel: reply_channel_identity(reply_channel)
    })
  end

  defp streamed_delivery?(%Message{metadata: %{"delivery" => %{"mode" => "stream"}}}), do: true
  defp streamed_delivery?(_message), do: false

  defp maybe_attach_steering([], _context), do: []

  defp maybe_attach_steering(result_blocks, context) do
    case BullX.AIAgent.Steering.pop(Map.get(context, :lease_id)) do
      nil ->
        result_blocks

      %{text: text, command_entry_id: command_entry_id} ->
        result_blocks ++
          [
            %{
              "type" => "human_steering_note",
              "text" => text,
              "command_entry_id" => command_entry_id
            }
          ]
    end
  end

  defp assistant_visible_text(%Message{content: content}) do
    content
    |> Enum.filter(&(Map.get(&1, "type") == "text"))
    |> Enum.map_join("\n", &(Map.get(&1, "text") || ""))
    |> String.trim()
  end

  defp update_delivery_metadata(assistant_message, delivery) do
    metadata = Map.put(assistant_message.metadata, "delivery", delivery)

    case Conversations.update_message(assistant_message, %{metadata: metadata}) do
      {:ok, _message} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp delivery_idempotency_key(assistant_message, context, reply_channel) do
    Tools.idempotency_key(%{
      assistant_message_id: assistant_message.id,
      trigger_id: context.trigger_id,
      reply_channel: reply_channel_identity(reply_channel)
    })
  end

  defp reply_channel_identity(reply_channel) do
    reply_channel
    |> Map.take(["adapter", "channel_id", "thread_id", :adapter, :channel_id, :thread_id])
    |> Jason.encode!()
    |> BullX.Ext.generic_hash()
    |> then(&("sha256:" <> &1))
  end

  defp safe_adapter_result_ref(result) when is_map(result) do
    result
    |> Map.take([
      "delivery_id",
      "primary_external_id",
      "external_message_ids",
      "message_id",
      "external_id",
      "id",
      :delivery_id,
      :primary_external_id,
      :external_message_ids,
      :message_id,
      :external_id,
      :id
    ])
    |> case do
      empty when map_size(empty) == 0 -> nil
      safe -> safe |> stringify_keys() |> Jason.encode!()
    end
  end

  defp safe_adapter_result_ref(_result), do: nil

  defp safe_delivery_error(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp safe_delivery_error(%{"kind" => kind}) when is_binary(kind), do: String.slice(kind, 0, 120)
  defp safe_delivery_error(%{kind: kind}) when is_binary(kind), do: String.slice(kind, 0, 120)

  defp safe_delivery_error({kind, _detail}) when is_atom(kind), do: Atom.to_string(kind)
  defp safe_delivery_error(_reason), do: "delivery_failed"

  defp stringify_keys(map), do: Map.new(map, fn {key, value} -> {to_string(key), value} end)
end
