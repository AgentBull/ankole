defmodule BullX.AIAgent.Runner do
  @moduledoc """
  Shared AIAgent generation runner.

  The runner owns the model/tool loop for one user-like source Message. It keeps
  provider calls, tool execution, and visible delivery behind Conversation
  persistence and ACL checks.
  """

  alias BullX.AIAgent.{
    ACL,
    Compression,
    Conversation,
    Conversations,
    Message,
    MessageContextBuilder,
    Profile,
    PromptRenderer,
    Tools
  }

  alias BullX.AIAgent.Tools.Dispatcher
  alias BullX.EventBus.ChannelAdapter
  alias BullX.LLM
  alias BullX.LLM.Catalog

  @max_auto_compression_attempts 3

  @spec run(Conversation.t(), Message.t(), Profile.t(), map()) :: :ok | {:error, term()}
  def run(
        %Conversation{} = conversation,
        %Message{} = source_message,
        %Profile{} = profile,
        context
      )
      when is_map(context) do
    case {Map.get(context, :force_generation?, false),
          Conversations.complete_assistant_for_source(source_message.id)} do
      {true, _assistant_message} ->
        start_generation(conversation, source_message, profile, context)

      {false, %Message{} = assistant_message} ->
        recover_generated_output(
          conversation,
          source_message,
          assistant_message,
          profile,
          context
        )

      {false, nil} ->
        start_generation(conversation, source_message, profile, context)
    end
  end

  defp recover_generated_output(conversation, source_message, assistant_message, profile, context) do
    now = DateTime.utc_now(:microsecond)

    owner = %{
      "owner_source_type" => context.source_type,
      "owner_source_id" => context.source_id,
      "source_message_id" => source_message.id,
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
             source_message,
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

  defp start_generation(conversation, source_message, profile, context) do
    case Map.get(context, :lease_id) do
      lease_id when is_binary(lease_id) ->
        run_existing_lease(conversation, source_message, profile, context, lease_id)

      _missing ->
        acquire_and_run_generation(conversation, source_message, profile, context)
    end
  end

  defp acquire_and_run_generation(conversation, source_message, profile, context) do
    now = DateTime.utc_now(:microsecond)

    owner = %{
      "owner_source_type" => context.source_type,
      "owner_source_id" => context.source_id,
      "source_message_id" => source_message.id,
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
         run_result <-
           loop(
             leased_conversation,
             source_message,
             profile,
             Map.put(context, :lease_id, lease_id),
             0
           ),
         {:ok, _conversation} <-
           Conversations.clear_generation_lease(leased_conversation, lease_id) do
      run_result
    else
      {:denied, _reason} ->
        write_acl_denial(conversation, source_message, context)

      {:error, :generation_active} ->
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp run_existing_lease(conversation, source_message, profile, context, lease_id) do
    with :allowed <-
           ACL.authorize(
             context.caller_principal_id,
             context.agent_principal_id,
             :ordinary,
             Map.get(context, :acl_context, %{})
           ),
         {:ok, leased_conversation} <- ensure_owned_active(conversation.id, lease_id),
         run_result <- loop(leased_conversation, source_message, profile, context, 0),
         {:ok, _conversation} <-
           Conversations.clear_generation_lease(leased_conversation, lease_id) do
      run_result
    else
      {:denied, _reason} ->
        write_acl_denial(conversation, source_message, context)

      {:error, :generation_inactive} ->
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp write_acl_denial(conversation, source_message, %{source_type: "ambient_batch"} = context) do
    :telemetry.execute([:bullx, :ai_agent, :acl_denied], %{}, %{
      source_type: context.source_type,
      source_id: context.source_id,
      agent_principal_id: context.agent_principal_id,
      source_message_id: source_message.id
    })

    :ok = maybe_clear_context_lease(conversation, context)
  end

  defp write_acl_denial(conversation, source_message, context) do
    write_error(conversation, source_message, context, "acl_denied", "AIAgent access denied.")
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

  defp loop(conversation, source_message, profile, context, turn) do
    case turn >= profile.context.max_turns do
      true -> write_turn_limit_error(conversation, source_message, context)
      false -> do_loop(conversation, source_message, profile, context, turn)
    end
  end

  defp do_loop(conversation, source_message, profile, context, turn) do
    conversation = BullX.Repo.get!(Conversation, conversation.id)

    with true <-
           Conversations.owned_active_lease?(
             conversation,
             context.lease_id,
             DateTime.utc_now(:microsecond)
           ),
         ambient_context <- ambient_context(conversation, source_message),
         {:ok, rendered} <-
           render_with_budget(conversation, source_message, profile, context, ambient_context),
         rendered <- Compression.apply_prompt_cache_hints(rendered, profile: profile),
         tools <-
           Tools.enabled_tools(
             profile,
             context.caller_principal_id,
             context.agent_principal_id,
             Map.get(context, :acl_context, %{})
           ),
         opts <- call_opts(profile, tools, rendered),
         {:ok, result} <-
           with_heartbeat(conversation, context, profile, fn ->
             call_model(conversation, source_message, profile, context, rendered, opts)
           end),
         {:ok, conversation} <- ensure_owned_active(conversation.id, context.lease_id),
         {:ok, assistant_message} <-
           persist_assistant_result(conversation, source_message, result, context),
         {:ok, conversation} <- ensure_owned_active(conversation.id, context.lease_id),
         tool_calls <- normalize_tool_calls(result.tool_calls) do
      case tool_calls do
        [] ->
          maybe_deliver(assistant_message, context)

        [_ | _] ->
          with {:ok, conversation} <- ensure_owned_active(conversation.id, context.lease_id),
               {:ok, _tool_message} <-
                 with_heartbeat(conversation, context, profile, fn ->
                   persist_tool_results(
                     conversation,
                     source_message,
                     assistant_message,
                     tool_calls,
                     profile,
                     context
                   )
                 end) do
            loop(conversation, source_message, profile, context, turn + 1)
          else
            {:error, :generation_inactive} -> :ok
            {:error, _reason} = error -> error
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
            case write_error(
                   active_conversation,
                   source_message,
                   context,
                   "generation_failed",
                   "AIAgent generation failed."
                 ) do
              {:ok, _conversation, _message} -> :ok
              {:error, _write_reason} -> {:error, reason}
            end

          {:error, :generation_inactive} ->
            :ok
        end
    end
  end

  defp call_model(conversation, source_message, profile, context, rendered, opts) do
    case stream_requested?(context) do
      true -> stream_model_call(conversation, source_message, profile, context, rendered, opts)
      false -> LLM.chat(profile.main_model, rendered.messages, opts)
    end
  end

  defp stream_model_call(conversation, source_message, profile, context, rendered, opts) do
    output = context.output
    reply_channel = context.reply_channel

    case output.create_stream(context.target_session_id, context.target_session_entry_id) do
      {:ok, stream_id} ->
        do_stream_model_call(
          conversation,
          source_message,
          profile,
          context,
          rendered,
          opts,
          reply_channel,
          output,
          stream_id
        )

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp do_stream_model_call(
         conversation,
         source_message,
         profile,
         context,
         rendered,
         opts,
         reply_channel,
         output,
         stream_id
       ) do
    with {:ok, generating_message} <-
           persist_generating_assistant(conversation, source_message, context, stream_id),
         :ok <- start_stream_consumer(reply_channel, stream_id) do
      case LLM.stream_chat(profile.main_model, rendered.messages, opts,
             on_result: stream_chunk_callback(conversation.id, context, output, stream_id)
           ) do
        {:ok, result} ->
          with {:ok, _active_conversation} <-
                 ensure_owned_active(conversation.id, context.lease_id),
               {:ok, complete_message} <-
                 complete_streaming_assistant(
                   generating_message,
                   source_message,
                   result,
                   context
                 ),
               :ok <- finish_stream(output, stream_id, :completed, "completed") do
            {:ok, Map.put(result, :persisted_assistant_message_id, complete_message.id)}
          else
            {:error, :generation_inactive} ->
              finish_stream(output, stream_id, :interrupted, "generation_inactive")
              {:error, :generation_inactive}

            {:error, reason} ->
              finish_stream(output, stream_id, :failed, safe_stream_reason(reason))
              {:error, reason}
          end

        {:error, reason} ->
          finish_stream(output, stream_id, :failed, safe_stream_reason(reason))
          mark_streaming_assistant_failed(generating_message, reason)
          {:error, reason}
      end
    else
      {:error, reason} ->
        finish_stream(output, stream_id, :failed, safe_stream_reason(reason))
        {:error, reason}
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

  defp persist_generating_assistant(conversation, source_message, context, stream_id) do
    attrs = %{
      conversation_id: conversation.id,
      role: :assistant,
      kind: :normal,
      status: :generating,
      content: [],
      target_session_id: Map.get(context, :target_session_id),
      target_session_entry_id: Map.get(context, :target_session_entry_id),
      metadata:
        generation_metadata(source_message, context, %{
          "delivery" => stream_delivery_metadata(stream_id, context),
          "stream" => %{
            "stream_id" => stream_id,
            "started_at" => DateTime.to_iso8601(DateTime.utc_now(:microsecond))
          }
        })
    }

    case Conversations.append_message(conversation, attrs) do
      {:ok, _conversation, message} ->
        update_stream_delivery_metadata(message, context, stream_id)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp update_stream_delivery_metadata(message, context, stream_id) do
    metadata =
      put_in(
        message.metadata,
        ["delivery"],
        stream_delivery_metadata(stream_id, context, message.id)
      )

    Conversations.update_message(message, %{metadata: metadata})
  end

  defp persist_assistant_result(conversation, source_message, result, context)
       when is_map(result) do
    case Map.get(result, :persisted_assistant_message_id) do
      message_id when is_binary(message_id) ->
        case BullX.Repo.get(Message, message_id) do
          %Message{} = message -> {:ok, message}
          nil -> {:error, :streaming_assistant_message_missing}
        end

      _missing ->
        persist_assistant(conversation, source_message, result, context)
    end
  end

  defp complete_streaming_assistant(
         generating_message,
         source_message,
         result,
         context
       ) do
    metadata =
      generating_message.metadata
      |> Map.merge(generation_metadata(source_message, context, result_metadata(result)))
      |> put_in(["stream", "finished_at"], DateTime.to_iso8601(DateTime.utc_now(:microsecond)))
      |> put_in(["stream", "status"], "completed")

    Conversations.update_message(generating_message, %{
      status: :complete,
      content: assistant_content(result),
      metadata: metadata
    })
  end

  defp mark_streaming_assistant_failed(generating_message, reason) do
    metadata =
      generating_message.metadata
      |> put_in(["stream", "status"], "failed")
      |> put_in(["stream", "safe_error_code"], safe_stream_reason(reason))

    Conversations.update_message(generating_message, %{
      role: :assistant,
      kind: :error,
      status: :complete,
      content: [
        Message.error_block("stream_failed", "AIAgent streaming generation failed.", true)
      ],
      metadata: metadata
    })
  end

  defp start_stream_consumer(reply_channel, stream_id) do
    case Task.start(fn -> ChannelAdapter.consume_stream(reply_channel, stream_id) end) do
      {:ok, _pid} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp stream_chunk_callback(conversation_id, context, output, stream_id) do
    fn
      "" ->
        :ok

      chunk_text when is_binary(chunk_text) ->
        with {:ok, _conversation} <- ensure_owned_active(conversation_id, context.lease_id),
             {:ok, _offset} <- output.append_chunk(stream_id, chunk_text) do
          :ok
        else
          {:error, reason} -> raise "ai_agent_stream_append_failed: #{safe_stream_reason(reason)}"
        end
    end
  end

  defp finish_stream(output, stream_id, status, reason) do
    case output.finish_stream(stream_id, status, reason) do
      :ok -> :ok
      {:error, _reason} -> :ok
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
          source_id: context.source_id,
          reply_channel: reply_channel_identity(reply_channel)
        }),
      "status" => "unknown",
      "adapter_result_ref" => nil,
      "safe_error_code" => nil,
      "delivered_at" => nil
    }
  end

  defp safe_stream_reason(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp safe_stream_reason(%RuntimeError{message: message}), do: String.slice(message, 0, 120)
  defp safe_stream_reason(_reason), do: "stream_failed"

  defp render_with_budget(
         conversation,
         source_message,
         profile,
         context,
         ambient_context,
         attempt \\ 0
       ) do
    with {:ok, rendered} <-
           PromptRenderer.render(conversation, profile, source_message,
             ambient_context: ambient_context,
             runtime_context: runtime_context(context)
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
                source_message,
                profile,
                context,
                ambient_context,
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
         source_message,
         assistant_message,
         profile,
         context
       ) do
    tool_calls = assistant_message.content |> tool_calls_from_content()

    cond do
      tool_calls == [] ->
        :ok

      Conversations.tool_result_for_assistant?(assistant_message.id) ->
        loop(conversation, source_message, profile, context, 0)

      true ->
        with {:ok, _message} <-
               persist_tool_results(
                 conversation,
                 source_message,
                 assistant_message,
                 tool_calls,
                 profile,
                 context
               ) do
          loop(conversation, source_message, profile, context, 0)
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

  defp runtime_context(context) do
    %{
      source_type: context.source_type,
      source_id: context.source_id,
      target_session_id: Map.get(context, :target_session_id)
    }
  end

  defp ambient_context(
         %Conversation{agent_principal_id: agent_principal_id},
         %Message{metadata: metadata} = source_message
       ) do
    case get_in(metadata, ["scene"]) do
      %{} = scene ->
        MessageContextBuilder.ambient_recall(agent_principal_id, scene, source_message)

      _other ->
        []
    end
  end

  defp call_opts(%Profile{} = profile, tools, rendered) do
    provider_options = prompt_cache_provider_options(profile, rendered)

    opts = [
      reasoning_effort: profile.main_model_reasoning_effort,
      tools: Enum.map(tools, & &1.tool)
    ]

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
    with {:ok, resolved} <- Catalog.resolve_model_spec(profile.main_model),
         true <- resolved.req_llm_provider in [:anthropic, "anthropic"],
         stable_index when is_integer(stable_index) <-
           rendered.system_prompt.stable_prefix.content_part_index do
      stable_index == length(rendered.system_prompt.system_content) - 1
    else
      _other -> false
    end
  end

  defp persist_assistant(conversation, source_message, result, context) do
    attrs = %{
      conversation_id: conversation.id,
      role: :assistant,
      kind: :normal,
      status: :complete,
      content: assistant_content(result),
      target_session_id: Map.get(context, :target_session_id),
      target_session_entry_id: Map.get(context, :target_session_entry_id),
      metadata: generation_metadata(source_message, context, result_metadata(result))
    }

    case Conversations.append_message(conversation, attrs) do
      {:ok, _conversation, message} -> {:ok, message}
      {:error, reason} -> {:error, reason}
    end
  end

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
         source_message,
         assistant_message,
         tool_calls,
         profile,
         context
       ) do
    seed = %{
      caller_principal_id: context.caller_principal_id,
      agent_principal_id: context.agent_principal_id,
      conversation_id: conversation.id,
      source_type: context.source_type,
      source_id: context.source_id,
      acl_context: Map.get(context, :acl_context, %{}),
      metadata: %{}
    }

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
        generation_metadata(source_message, context, %{
          "root_assistant_message_id" => assistant_message.id
        })
    }

    case Conversations.append_message(conversation, attrs) do
      {:ok, _conversation, message} -> {:ok, message}
      {:error, reason} -> {:error, reason}
    end
  end

  defp write_error(conversation, source_message, context, code, message) do
    attrs = %{
      conversation_id: conversation.id,
      role: :assistant,
      kind: :error,
      status: :complete,
      content: [Message.error_block(code, message, false)],
      target_session_id: Map.get(context, :target_session_id),
      target_session_entry_id: Map.get(context, :target_session_entry_id),
      metadata: generation_metadata(source_message, context, %{"safe_error_code" => code})
    }

    Conversations.append_message(conversation, attrs)
  end

  defp write_turn_limit_error(conversation, source_message, context) do
    case ensure_owned_active(conversation.id, context.lease_id) do
      {:ok, active_conversation} ->
        case write_error(
               active_conversation,
               source_message,
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

  defp generation_metadata(source_message, context, extra) do
    %{
      "generation" =>
        %{
          "lease_id" => Map.get(context, :lease_id),
          "source_message_id" => source_message.id,
          "source_type" => context.source_type,
          "source_id" => context.source_id,
          "root_assistant_message_id" => Map.get(extra, "root_assistant_message_id")
        }
        |> Enum.reject(fn {_key, value} -> is_nil(value) end)
        |> Map.new()
    }
    |> maybe_put_retry_metadata(context)
    |> Map.merge(Map.delete(extra, "root_assistant_message_id"))
  end

  defp result_metadata(result) do
    %{
      "provider_id" => result.provider_id,
      "model_id" => result.model_id,
      "usage" => result.usage,
      "usage_source" => usage_source(result.usage),
      "finish_reason" => safe_atom(result.finish_reason)
    }
  end

  defp usage_source(nil), do: "estimated"
  defp usage_source(_usage), do: "provider_reported"

  defp execute_tool_calls(profile, tool_calls, seed, assistant_message) do
    if parallel_tool_calls?(profile, tool_calls) do
      tool_calls
      |> Task.async_stream(
        &Dispatcher.execute_call(profile, &1, seed, assistant_message),
        ordered: true,
        timeout: parallel_tool_timeout(tool_calls, profile),
        on_timeout: :kill_task
      )
      |> Enum.map(fn
        {:ok, result} -> result
        {:exit, _reason} -> tool_execution_failed_block()
      end)
    else
      Enum.map(tool_calls, &Dispatcher.execute_call(profile, &1, seed, assistant_message))
    end
  end

  defp parallel_tool_calls?(_profile, [_single]), do: false

  defp parallel_tool_calls?(profile, [_first, _second | _rest] = tool_calls) do
    Enum.all?(tool_calls, &parallel_safe_tool_call?(profile, &1))
  end

  defp parallel_tool_calls?(_profile, _tool_calls), do: false

  defp parallel_safe_tool_call?(profile, tool_call) do
    tool_name = tool_call[:name] || tool_call["name"]

    case Tools.effective_tool(profile, tool_name) do
      {:ok, entry, _access} -> Map.get(entry, :parallel_safe, false)
      {:error, _reason} -> false
    end
  end

  defp parallel_tool_timeout(tool_calls, profile) do
    tool_calls
    |> Enum.map(fn tool_call ->
      tool_name = tool_call[:name] || tool_call["name"]

      case Tools.effective_tool(profile, tool_name) do
        {:ok, entry, _access} -> entry.timeout_ms
        {:error, _reason} -> 30_000
      end
    end)
    |> Enum.max(fn -> 30_000 end)
  end

  defp tool_execution_failed_block do
    %{
      "type" => "tool_result",
      "tool_call_id" => "unknown",
      "is_error" => true,
      "error" => %{
        "code" => "tool_failed",
        "message" => "Tool failed.",
        "retryable" => false
      }
    }
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

  defp safe_atom(nil), do: nil
  defp safe_atom(value) when is_atom(value), do: Atom.to_string(value)
  defp safe_atom(value) when is_binary(value), do: String.slice(value, 0, 120)
  defp safe_atom(_value), do: "unknown"

  defp maybe_deliver(assistant_message, context) do
    text = assistant_visible_text(assistant_message)

    cond do
      text == "" ->
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
      source_id: context.source_id,
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
      "message_id",
      "external_id",
      "id",
      :delivery_id,
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
