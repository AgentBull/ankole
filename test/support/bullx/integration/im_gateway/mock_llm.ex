defmodule BullX.Integration.IMGateway.MockLLM do
  @moduledoc """
  Scriptable, process-independent test double for `BullX.LLM.Client`.

  Both scripting modes are supported (the responder wins when one is set):

    * **responder** — register `fn req -> reply_spec end` that pattern-matches on
      the rendered conversation (`req.messages`), the call index (`req.call_index`),
      or `req.opts` and returns a reply spec. Robust to a variable number of LLM
      round-trips (tool loops, compression) because each call is answered by
      inspecting state rather than by position in a queue.
    * **queue** — `push_*` reply specs popped FIFO, mirroring the existing
      `BullX.AIAgent.FakeLLMClient`. Convenient for short fixed scripts.

  Storage lives in a named `Agent` (not the process dictionary) so scripted
  replies and the recorded request log are shared regardless of which process
  runs the agent loop — important for the mailbox-driven integration path where the
  generation may run outside the test process.

  Every expected model call must be scripted. An unscripted call raises so a test
  cannot accidentally pass with a default assistant response.

  Reply specs accepted from a responder or the queue:

      "plain text"
      {:text, "plain text"}
      {:text, "with options", finish_reason: :stop, usage: %{...}}
      {:tool_calls, [%{id: "c1", name: "web_search", arguments: %{"q" => "x"}}]}
      {:text, "preamble", tool_calls: [%{id: "c1", name: "t", arguments: %{}}]}
      {:stream, ["chunk ", "by ", "chunk"]}
      {:error, %ReqLLM.Error{} | Exception.t() | term()}
  """

  @behaviour BullX.LLM.Client

  alias BullX.LLM.ResolvedModel
  alias ReqLLM.Message.ContentPart

  @name __MODULE__

  # ---------------------------------------------------------------------------
  # Lifecycle
  # ---------------------------------------------------------------------------

  def child_spec(_opts), do: %{id: @name, start: {__MODULE__, :start_link, [[]]}}

  def start_link(_opts \\ []), do: Agent.start_link(fn -> initial_state() end, name: @name)

  def reset, do: Agent.update(@name, fn _state -> initial_state() end)

  defp initial_state, do: %{responder: nil, queue: [], requests: [], call_index: 0}

  # ---------------------------------------------------------------------------
  # Scripting
  # ---------------------------------------------------------------------------

  @doc "Answer every call by invoking `fun.(req)`. Overrides queue mode."
  def set_responder(fun) when is_function(fun, 1),
    do: Agent.update(@name, &%{&1 | responder: fun})

  def push(spec), do: Agent.update(@name, &%{&1 | queue: &1.queue ++ [spec]})
  def push_text(text, opts \\ []) when is_binary(text), do: push({:text, text, opts})
  def push_tool_calls(calls, opts \\ []) when is_list(calls), do: push({:tool_calls, calls, opts})
  def push_stream(chunks, opts \\ []) when is_list(chunks), do: push({:stream, chunks, opts})
  def push_error(reason), do: push({:error, reason})

  # ---------------------------------------------------------------------------
  # Introspection (for assertions)
  # ---------------------------------------------------------------------------

  @doc "Full request log; each entry is `%{kind, resolved, messages, opts, stream_opts, call_index}`."
  def requests, do: Agent.get(@name, & &1.requests)
  def last_request, do: requests() |> List.last()
  def call_count, do: length(requests())

  @doc "Concatenated text of every message sent to the model in the most recent call."
  def last_prompt_text, do: prompt_text(last_request())

  def prompt_text(nil), do: ""
  def prompt_text(%{messages: messages}), do: messages_to_text(messages)

  @doc "Concatenated prompt text across every recorded call."
  def all_prompts_text do
    requests() |> Enum.map_join("\n----\n", &prompt_text/1)
  end

  # ---------------------------------------------------------------------------
  # BullX.LLM.Client
  # ---------------------------------------------------------------------------

  @impl BullX.LLM.Client
  def chat(%ResolvedModel{} = resolved, messages, opts) do
    req = record(:chat, resolved, messages, opts, [])

    case reply_for(req) do
      {:error, reason} -> {:error, reason}
      spec -> {:ok, to_response(spec, resolved)}
    end
  end

  @impl BullX.LLM.Client
  def stream_chat(%ResolvedModel{} = resolved, messages, opts, stream_opts) do
    req = record(:stream_chat, resolved, messages, opts, stream_opts)

    case reply_for(req) do
      {:error, reason} ->
        {:error, reason}

      spec ->
        response = to_response(spec, resolved)
        emit_stream(spec, response, stream_opts)
        {:ok, response}
    end
  end

  # ---------------------------------------------------------------------------
  # Internals
  # ---------------------------------------------------------------------------

  defp record(kind, resolved, messages, opts, stream_opts) do
    Agent.get_and_update(@name, fn state ->
      call_index = state.call_index

      req = %{
        kind: kind,
        resolved: resolved,
        messages: messages,
        opts: opts,
        stream_opts: stream_opts,
        call_index: call_index
      }

      {req, %{state | requests: state.requests ++ [req], call_index: call_index + 1}}
    end)
  end

  defp reply_for(req) do
    case Agent.get(@name, & &1.responder) do
      responder when is_function(responder, 1) ->
        responder.(req)

      nil ->
        case Agent.get_and_update(@name, fn state ->
               case state.queue do
                 [spec | rest] -> {{:ok, spec}, %{state | queue: rest}}
                 [] -> {:empty, state}
               end
             end) do
          {:ok, spec} ->
            spec

          :empty ->
            raise "unscripted MockLLM call #{req.call_index}"
        end
    end
  end

  defp to_response(spec, %ResolvedModel{} = resolved) do
    {text, tool_calls, opts} = normalize_spec(spec)

    %ReqLLM.Response{
      id: "mock-response",
      model: resolved.model_id,
      message: %ReqLLM.Message{
        role: :assistant,
        content: [ContentPart.text(text)],
        tool_calls: normalize_tool_calls(tool_calls)
      },
      context: [],
      usage: Keyword.get(opts, :usage, default_usage()),
      finish_reason:
        Keyword.get(opts, :finish_reason, if(tool_calls == [], do: :stop, else: :tool_calls)),
      provider_meta: Keyword.get(opts, :provider_meta, %{"request_id" => "mock"})
    }
  end

  # Reply-spec -> {text, tool_calls, opts}
  defp normalize_spec(text) when is_binary(text), do: {text, [], []}
  defp normalize_spec({:text, text}), do: {text, [], []}

  defp normalize_spec({:text, text, opts}) when is_list(opts),
    do: {text, Keyword.get(opts, :tool_calls, []), opts}

  defp normalize_spec({:tool_calls, calls}), do: {"", calls, []}
  defp normalize_spec({:tool_calls, calls, opts}), do: {"", calls, opts}

  defp normalize_spec({:stream, chunks}), do: {Enum.join(chunks), [], [stream_chunks: chunks]}

  defp normalize_spec({:stream, chunks, opts}),
    do: {Enum.join(chunks), Keyword.get(opts, :tool_calls, []), [{:stream_chunks, chunks} | opts]}

  defp emit_stream(spec, response, stream_opts) do
    on_result = Keyword.get(stream_opts, :on_result)

    cond do
      not is_function(on_result, 1) ->
        :ok

      stream_chunks?(spec) ->
        spec |> spec_chunks() |> Enum.each(&on_result.(&1))

      true ->
        on_result.(ReqLLM.Response.text(response) || "")
    end
  end

  defp stream_chunks?({:stream, _chunks}), do: true
  defp stream_chunks?({:stream, _chunks, _opts}), do: true
  defp stream_chunks?(_spec), do: false

  defp spec_chunks({:stream, chunks}), do: chunks
  defp spec_chunks({:stream, chunks, _opts}), do: chunks

  defp messages_to_text(messages) when is_list(messages),
    do: Enum.map_join(messages, "\n", &message_text/1)

  defp messages_to_text(_messages), do: ""

  defp message_text(%{content: content}) when is_list(content),
    do: Enum.map_join(content, "", &part_text/1)

  defp message_text(%{content: text}) when is_binary(text), do: text
  defp message_text(_message), do: ""

  defp part_text(%ContentPart{type: :text, text: text}) when is_binary(text), do: text
  defp part_text(%{text: text}) when is_binary(text), do: text
  defp part_text(_part), do: ""

  defp normalize_tool_calls([]), do: nil
  defp normalize_tool_calls(tool_calls), do: Enum.map(tool_calls, &ReqLLM.ToolCall.from_map/1)

  defp default_usage, do: %{input_tokens: 10, output_tokens: 5, total_tokens: 15}
end
