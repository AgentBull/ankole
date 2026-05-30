defmodule BullX.AIAgent.PromptRenderer do
  @moduledoc """
  Request-time projection from Conversation / Message truth to `req_llm` input.
  """

  alias BullX.AIAgent.{
    Compression,
    Conversation,
    Conversations,
    Message,
    MessageContextBuilder,
    Profile,
    SystemPromptBuilder
  }

  alias BullX.Principals
  alias BullX.Principals.Principal
  alias ReqLLM.Message.ContentPart

  @type render_result :: {:ok, map()} | {:error, term()}

  @spec render(Conversation.t(), Profile.t(), Message.t(), keyword()) :: render_result()
  def render(
        %Conversation{} = conversation,
        %Profile{} = profile,
        %Message{} = trigger_message,
        opts \\ []
      ) do
    transcript = Conversations.render_transcript(conversation)
    ambient_context = Keyword.get(opts, :ambient_context, [])
    sections = system_sections(profile)
    template = system_template(conversation, profile, Keyword.get(opts, :agent_tool_names, []))

    with {:ok, system} <- SystemPromptBuilder.render(sections, template: template),
         {:ok, messages} <-
           render_transcript_messages(
             conversation,
             transcript,
             profile,
             trigger_message,
             ambient_context
           ),
         messages <- Compression.compact_large_results(messages, profile: profile),
         :ok <- validate_tool_pairs(messages) do
      {:ok,
       %{
         messages: [%ReqLLM.Message{role: :system, content: system.system_content} | messages],
         system_prompt: system,
         diagnostics: %{
           transcript_message_count: length(transcript),
           provider_message_count: length(messages) + 1
         }
       }}
    end
  end

  defp system_sections(%Profile{} = profile) do
    [
      %SystemPromptBuilder.Section{
        id: "profile.instructions",
        kind: :profile,
        stability: :stable,
        priority: 30,
        tag: "instructions",
        content: nil_if_empty(profile.instructions)
      }
    ]
  end

  defp system_template(%Conversation{} = conversation, %Profile{} = profile, agent_tool_names) do
    [
      SystemPromptBuilder.text("""
      You are #{agent_display_name(conversation)}, an AI colleague powered by BullX.
      """),
      SystemPromptBuilder.text("""
      #{profile.soul}
      """),
      SystemPromptBuilder.optional("profile.mission", profile.mission, fn mission ->
        """
        Your mission is:

        #{mission}
        """
      end),
      SystemPromptBuilder.optional(
        "runtime.tool_guidance",
        tool_guidance(agent_tool_names),
        & &1
      ),
      SystemPromptBuilder.sections()
    ]
  end

  defp tool_guidance(agent_tool_names) do
    agent_tool_names
    |> Enum.uniq()
    |> case do
      [] ->
        nil

      names ->
        """
        This AIAgent may be given tool schemas such as: #{Enum.join(names, ", ")}.

        The tool schemas attached to the current provider request are authoritative for this generation. Use tools when they materially improve correctness or grounding. Do not describe a tool action you can perform without calling the tool in that generation. Use web tools for current external facts or source content when they are present. Use clarify only when missing information changes the next action and cannot be inferred or retrieved; after requesting clarification, wait for later user input.
        """
    end
  end

  defp nil_if_empty(""), do: nil
  defp nil_if_empty(value), do: value

  defp agent_display_name(%Conversation{agent: %{principal: %Principal{} = principal}}),
    do: principal_display_name(principal)

  defp agent_display_name(%Conversation{agent_uid: agent_uid}) do
    case Principals.get_principal(agent_uid) do
      {:ok, principal} -> principal_display_name(principal)
      {:error, :not_found} -> "BullX AIAgent"
    end
  end

  defp principal_display_name(%Principal{display_name: display_name, uid: uid}) do
    case nil_if_empty(display_name) do
      nil -> uid || "BullX AIAgent"
      name -> name
    end
  end

  defp render_transcript_messages(
         _conversation,
         transcript,
         profile,
         trigger_message,
         ambient_context
       ) do
    transcript
    |> Enum.reduce_while({:ok, [], []}, fn
      %Message{role: :user, kind: :introspection} = message, {:ok, acc, pending} ->
        {:cont, {:ok, acc, [message | pending]}}

      message, {:ok, acc, pending} ->
        pending_messages = Enum.reverse(pending)
        consume_pending? = match?(%Message{role: :user, kind: :normal}, message)

        case render_message_with_pending(
               message,
               profile,
               trigger_message,
               ambient_context,
               pending_messages
             ) do
          {:ok, nil} ->
            {:cont, {:ok, acc, pending}}

          {:ok, rendered} when is_list(rendered) ->
            {:cont,
             {:ok, Enum.reduce(rendered, acc, &[&1 | &2]),
              next_pending(pending, consume_pending?)}}

          {:ok, rendered} ->
            {:cont, {:ok, [rendered | acc], next_pending(pending, consume_pending?)}}
        end
    end)
    |> case do
      {:ok, messages, _pending} -> {:ok, Enum.reverse(messages)}
      {:error, _reason} = error -> error
    end
  end

  defp next_pending(_pending, true), do: []
  defp next_pending(pending, false), do: pending

  defp render_message_with_pending(
         %Message{role: :user, kind: :normal} = message,
         profile,
         trigger_message,
         ambient_context,
         pending
       ) do
    prefixes = prefixes_for(message, profile, trigger_message, ambient_context)
    {:ok, %ReqLLM.Message{role: :user, content: text_parts(prefixes, pending, message)}}
  end

  defp render_message_with_pending(message, profile, trigger_message, ambient_context, _pending) do
    render_message(message, profile, trigger_message, ambient_context)
  end

  defp render_message(%Message{kind: :error}, _profile, _trigger_message, _ambient_context),
    do: {:ok, nil}

  defp render_message(
         %Message{role: :im_ambient, kind: :normal},
         _profile,
         _trigger_message,
         _ambient_context
       ),
       do: {:ok, nil}

  defp render_message(
         %Message{role: :user, kind: :normal} = message,
         profile,
         trigger_message,
         ambient_context
       ) do
    prefixes = prefixes_for(message, profile, trigger_message, ambient_context)
    {:ok, %ReqLLM.Message{role: :user, content: text_parts(prefixes, message)}}
  end

  defp render_message(
         %Message{role: :user, kind: :introspection},
         _profile,
         _trigger_message,
         _ambient_context
       ),
       do: {:ok, nil}

  defp render_message(
         %Message{role: :im_ambient, kind: :introspection} = message,
         profile,
         trigger_message,
         ambient_context
       ) do
    prefixes = prefixes_for(message, profile, trigger_message, ambient_context)
    {:ok, %ReqLLM.Message{role: :user, content: text_parts(prefixes, message)}}
  end

  defp render_message(
         %Message{role: :assistant, kind: :normal} = message,
         _profile,
         _trigger_message,
         _ambient_context
       ) do
    tool_calls =
      message.content
      |> Enum.filter(&(Map.get(&1, "type") == "tool_call"))
      |> Enum.map(
        &ReqLLM.ToolCall.new(
          &1["tool_call_id"],
          &1["name"],
          Jason.encode!(&1["arguments"] || %{})
        )
      )

    {:ok,
     %ReqLLM.Message{
       role: :assistant,
       content: text_content_parts(message),
       tool_calls: if(tool_calls == [], do: nil, else: tool_calls)
     }}
  end

  defp render_message(
         %Message{role: :assistant, kind: :summary} = message,
         _profile,
         _trigger_message,
         _ambient_context
       ) do
    {:ok, %ReqLLM.Message{role: :assistant, content: summary_parts(message)}}
  end

  defp render_message(
         %Message{role: :tool, kind: :normal} = message,
         _profile,
         _trigger_message,
         _ambient_context
       ) do
    results = Enum.filter(message.content, &(Map.get(&1, "type") == "tool_result"))
    steering_parts = Enum.filter(message.content, &(Map.get(&1, "type") == "human_steering_note"))

    results
    |> case do
      [] ->
        {:ok, nil}

      results ->
        {:ok,
         results
         |> Enum.with_index()
         |> Enum.map(fn {result, index} ->
           %ReqLLM.Message{
             role: :tool,
             tool_call_id: result["tool_call_id"],
             content: tool_result_content(result, index == length(results) - 1, steering_parts)
           }
         end)}
    end
  end

  defp render_message(_message, _profile, _trigger_message, _ambient_context), do: {:ok, nil}

  defp tool_result_content(result, attach_steering?, steering_parts) do
    payload =
      case result do
        %{"is_error" => true, "error" => error} ->
          %{"ok" => false, "error" => error}

        %{"result" => value} ->
          %{"ok" => true, "result" => value}

        _other ->
          %{"ok" => false, "error" => %{"code" => "tool_result_malformed"}}
      end

    [ContentPart.text(Jason.encode!(payload))] ++
      steering_content_parts(attach_steering?, steering_parts)
  end

  defp steering_content_parts(true, steering_parts) do
    Enum.map(steering_parts, fn %{"text" => text, "command_entry_id" => command_entry_id} ->
      ContentPart.text(
        "\n<human_steering_note command_entry_id=\"#{command_entry_id}\">#{text}</human_steering_note>"
      )
    end)
  end

  defp steering_content_parts(_attach?, _steering_parts), do: []

  defp prefixes_for(message, profile, trigger_message, ambient_context) do
    context =
      case message.id == trigger_message.id do
        true -> ambient_context
        false -> []
      end

    message
    |> MessageContextBuilder.build(profile: profile, ambient_context: context)
    |> Map.fetch!(:message_prefix)
    |> Enum.map(& &1.text)
  end

  defp text_parts(prefixes, message), do: text_parts(prefixes, [], message)

  defp text_parts(prefixes, pending_messages, message) do
    body =
      pending_messages
      |> Enum.map(&message_text/1)
      |> Kernel.++([message_text(message)])
      |> Enum.reject(&(&1 == ""))
      |> Enum.join("\n")

    text =
      case prefixes do
        [] -> body
        [_ | _] -> Enum.join(prefixes, "\n") <> "\n" <> body
      end

    [ContentPart.text(text)]
  end

  defp message_text(message) do
    message.content
    |> Enum.filter(&(Map.get(&1, "type") in ["text", "human_steering_note"]))
    |> Enum.map_join("\n", &block_text/1)
  end

  defp text_content_parts(message) do
    message.content
    |> Enum.filter(&(Map.get(&1, "type") == "text"))
    |> Enum.map(&ContentPart.text(&1["text"]))
  end

  defp summary_parts(message) do
    message.content
    |> Enum.filter(&(Map.get(&1, "type") == "summary_text"))
    |> Enum.map(&ContentPart.text(&1["text"]))
  end

  defp block_text(%{"type" => "text", "text" => text}), do: text

  defp block_text(%{"type" => "human_steering_note", "text" => text}),
    do: "\n<human_steering_note>#{text}</human_steering_note>"

  defp block_text(_block), do: ""

  defp validate_tool_pairs(messages) do
    {pending, _seen, valid?} =
      Enum.reduce(messages, {%{}, %{}, true}, fn
        %ReqLLM.Message{role: :assistant, tool_calls: tool_calls}, {_pending, seen, valid?}
        when is_list(tool_calls) ->
          pending =
            Enum.reduce(tool_calls, %{}, fn call, acc ->
              Map.put(acc, call.id, true)
            end)

          seen = Enum.reduce(tool_calls, seen, fn call, acc -> Map.put(acc, call.id, true) end)

          {pending, seen, valid?}

        %ReqLLM.Message{role: :tool, tool_call_id: tool_call_id}, {pending, seen, valid?} ->
          {Map.delete(pending, tool_call_id), seen, valid? and Map.has_key?(seen, tool_call_id)}

        %ReqLLM.Message{role: role}, {pending, seen, valid?} when map_size(pending) > 0 ->
          {pending, seen, valid? and role == :tool}

        _message, {pending, seen, valid?} ->
          {pending, seen, valid?}
      end)

    case valid? and map_size(pending) == 0 do
      true -> :ok
      false -> {:error, :invalid_tool_call_result_pairing}
    end
  end
end
