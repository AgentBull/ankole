defmodule Ankole.E2E.FakeOpenAIPlug do
  @moduledoc """
  Small OpenAI-compatible streaming upstream used behind AIGateway.

  The test still exercises the real Docker worker and the real AIGateway HTTP
  client. This plug only controls upstream provider behavior so chaos cases are
  deterministic and do not depend on live model availability.
  """

  import Plug.Conn

  alias Ankole.JSON
  alias Ankole.E2E.FakeOpenAIScenarios
  alias Ankole.E2E.FakeOpenAIState

  def init(opts), do: opts

  def call(%Plug.Conn{method: "POST", request_path: "/chat/completions"} = conn, _opts) do
    {:ok, body, conn} = read_body(conn, length: 5_000_000, read_length: 1_000_000)
    request = JSON.decode!(body)
    kind = FakeOpenAIScenarios.classify(request)
    count = FakeOpenAIState.record(kind, request)

    case FakeOpenAIScenarios.action_for(kind, count, request) do
      :rate_limit ->
        rate_limit(conn)

      :malformed_stream ->
        malformed_stream(conn, request)

      :slow_stop_stream ->
        slow_stop_stream(conn, request)

      {:delayed_completion, text, delay_ms} ->
        delayed_completion(conn, request, text, delay_ms)

      {:tool_call, tool_call} ->
        maybe_stream_tool_call(conn, request, tool_call)

      {:delayed_tool_call, tool_call, delay_ms} ->
        Process.sleep(delay_ms)
        maybe_stream_tool_call(conn, request, tool_call)

      {:completion, text, opts} ->
        maybe_stream_completion(conn, request, text, opts)
    end
  end

  def call(conn, _opts) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(404, JSON.encode!(%{"error" => %{"message" => "not found"}}))
  end

  defp rate_limit(conn) do
    conn
    |> put_resp_header("retry-after-ms", "10")
    |> put_resp_content_type("application/json")
    |> send_resp(
      429,
      JSON.encode!(%{
        "error" => %{
          "message" => "chaos transient upstream 429",
          "type" => "rate_limit_error",
          "code" => "chaos_429"
        }
      })
    )
  end

  defp malformed_stream(conn, request) do
    conn =
      conn
      |> put_resp_header("cache-control", "no-cache")
      |> put_resp_header("connection", "keep-alive")
      |> put_resp_content_type("text/event-stream")
      |> send_chunked(200)

    id = "chatcmpl-chaos-bad-#{System.unique_integer([:positive])}"
    model = request["model"] || "fake-model"
    conn = emit_event(conn, chunk(id, model, %{"role" => "assistant"}, nil), split?: false)
    {:ok, conn} = Plug.Conn.chunk(conn, "data: {\"id\":")
    Process.sleep(20)
    {:ok, conn} = Plug.Conn.chunk(conn, "\n\n")
    {:ok, conn} = Plug.Conn.chunk(conn, "data: [DONE]\n\n")
    conn
  end

  defp slow_stop_stream(conn, request) do
    conn =
      conn
      |> put_resp_header("cache-control", "no-cache")
      |> put_resp_header("connection", "keep-alive")
      |> put_resp_content_type("text/event-stream")
      |> send_chunked(200)

    id = "chatcmpl-chaos-slow-stop-#{System.unique_integer([:positive])}"
    model = request["model"] || "fake-model"

    with {:ok, conn} <- safe_emit_event(conn, chunk(id, model, %{"role" => "assistant"}, nil)),
         {:ok, conn} <- slow_stop_chunks(conn, id, model, 200) do
      safe_chunk(conn, "data: [DONE]\n\n")
      conn
    else
      {:error, _reason, conn} ->
        conn
    end
  end

  defp slow_stop_chunks(conn, _id, _model, 0), do: {:ok, conn}

  defp slow_stop_chunks(conn, id, model, remaining) do
    Process.sleep(250)

    case safe_emit_event(conn, chunk(id, model, %{"content" => "still running "}, nil)) do
      {:ok, conn} -> slow_stop_chunks(conn, id, model, remaining - 1)
      {:error, reason, conn} -> {:error, reason, conn}
    end
  end

  defp delayed_completion(conn, request, text, delay_ms) do
    Process.sleep(delay_ms)
    maybe_stream_completion(conn, request, text)
  end

  defp maybe_stream_completion(conn, request, text, opts \\ []) do
    if stream_requested?(request) do
      stream_completion(conn, request, text, opts)
    else
      json_completion(conn, request, text)
    end
  end

  defp maybe_stream_tool_call(conn, request, tool_call) do
    if stream_requested?(request) do
      stream_tool_call(conn, request, tool_call)
    else
      json_tool_call(conn, request, tool_call)
    end
  end

  # Chaos scenarios kill the worker mid tool-call stream, so every write must
  # tolerate a closed connection instead of crashing the Bandit handler.
  defp stream_tool_call(conn, request, tool_call) do
    conn =
      conn
      |> put_resp_header("cache-control", "no-cache")
      |> put_resp_header("connection", "keep-alive")
      |> put_resp_content_type("text/event-stream")
      |> send_chunked(200)

    id = "chatcmpl-chaos-tool-#{System.unique_integer([:positive])}"
    model = request["model"] || "fake-model"
    arguments = JSON.encode!(tool_call.arguments)
    {left, right} = split_binary(arguments)

    opening =
      chunk(
        id,
        model,
        %{
          "tool_calls" => [
            %{
              "index" => 0,
              "id" => tool_call.id,
              "type" => "function",
              "function" => %{"name" => tool_call.name, "arguments" => left}
            }
          ]
        },
        nil
      )

    continuation =
      chunk(
        id,
        model,
        %{"tool_calls" => [%{"index" => 0, "function" => %{"arguments" => right}}]},
        nil
      )

    with {:ok, conn} <-
           safe_emit_event(conn, chunk(id, model, %{"role" => "assistant"}, nil), split?: false),
         {:ok, conn} <- safe_emit_event(conn, opening, split?: true),
         {:ok, conn} <- safe_emit_event(conn, continuation, split?: true),
         {:ok, conn} <- safe_emit_event(conn, chunk(id, model, %{}, "tool_calls"), split?: false),
         {:ok, conn} <- safe_chunk(conn, "data: [DONE]\n\n") do
      conn
    else
      {:error, _reason, conn} -> conn
    end
  end

  defp stream_completion(conn, request, text, opts) do
    conn =
      conn
      |> put_resp_header("cache-control", "no-cache")
      |> put_resp_header("connection", "keep-alive")
      |> put_resp_content_type("text/event-stream")
      |> send_chunked(200)

    id = "chatcmpl-chaos-#{System.unique_integer([:positive])}"
    model = request["model"] || "fake-model"
    split_text? = Keyword.get(opts, :split_text?, true)

    with {:ok, conn} <-
           safe_emit_event(conn, chunk(id, model, %{"role" => "assistant"}, nil),
             split?: split_text?
           ),
         {:ok, conn} <-
           text
           |> String.graphemes()
           |> text_chunks(split_text?)
           |> Enum.reduce_while({:ok, conn}, fn part, {:ok, acc} ->
             Process.sleep(10)

             case safe_emit_event(acc, chunk(id, model, %{"content" => part}, nil),
                    split?: split_text?
                  ) do
               {:ok, conn} -> {:cont, {:ok, conn}}
               {:error, reason, conn} -> {:halt, {:error, reason, conn}}
             end
           end),
         {:ok, conn} <- safe_emit_event(conn, chunk(id, model, %{}, "stop"), split?: false),
         {:ok, conn} <- safe_chunk(conn, "data: [DONE]\n\n") do
      conn
    else
      {:error, _reason, conn} ->
        conn
    end
  end

  defp json_completion(conn, request, text) do
    id = "chatcmpl-chaos-#{System.unique_integer([:positive])}"
    model = request["model"] || "fake-model"

    body = %{
      "id" => id,
      "object" => "chat.completion",
      "created" => System.system_time(:second),
      "model" => model,
      "choices" => [
        %{
          "index" => 0,
          "message" => %{"role" => "assistant", "content" => text},
          "finish_reason" => "stop"
        }
      ],
      "usage" => %{"prompt_tokens" => 12, "completion_tokens" => 4, "total_tokens" => 16}
    }

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, JSON.encode!(body))
  end

  defp json_tool_call(conn, request, tool_call) do
    id = "chatcmpl-chaos-tool-#{System.unique_integer([:positive])}"
    model = request["model"] || "fake-model"

    body = %{
      "id" => id,
      "object" => "chat.completion",
      "created" => System.system_time(:second),
      "model" => model,
      "choices" => [
        %{
          "index" => 0,
          "message" => %{
            "role" => "assistant",
            "content" => nil,
            "tool_calls" => [
              %{
                "id" => tool_call.id,
                "type" => "function",
                "function" => %{
                  "name" => tool_call.name,
                  "arguments" => JSON.encode!(tool_call.arguments)
                }
              }
            ]
          },
          "finish_reason" => "tool_calls"
        }
      ],
      "usage" => %{"prompt_tokens" => 12, "completion_tokens" => 4, "total_tokens" => 16}
    }

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, JSON.encode!(body))
  end

  defp stream_requested?(%{"stream" => true}), do: true
  defp stream_requested?(_request), do: false

  defp text_chunks(graphemes, true),
    do: graphemes |> Enum.chunk_every(5) |> Enum.map(&Enum.join/1)

  defp text_chunks(graphemes, false), do: [Enum.join(graphemes)]

  defp chunk(id, model, delta, finish_reason) do
    %{
      "id" => id,
      "object" => "chat.completion.chunk",
      "created" => System.system_time(:second),
      "model" => model,
      "choices" => [%{"index" => 0, "delta" => delta, "finish_reason" => finish_reason}],
      "usage" => %{"prompt_tokens" => 12, "completion_tokens" => 4, "total_tokens" => 16}
    }
  end

  defp split_binary(binary) do
    split_at = max(1, div(byte_size(binary), 2))
    <<left::binary-size(^split_at), right::binary>> = binary
    {left, right}
  end

  defp emit_event(conn, payload, opts) do
    data = "data: #{JSON.encode!(payload)}\n\n"

    case Keyword.get(opts, :split?, false) and byte_size(data) > 12 do
      true ->
        split_at = div(byte_size(data), 2)
        <<left::binary-size(^split_at), right::binary>> = data
        {:ok, conn} = Plug.Conn.chunk(conn, left)
        Process.sleep(5)
        {:ok, conn} = Plug.Conn.chunk(conn, right)
        conn

      false ->
        {:ok, conn} = Plug.Conn.chunk(conn, data)
        conn
    end
  end

  defp safe_emit_event(conn, payload, opts \\ []) do
    data = "data: #{JSON.encode!(payload)}\n\n"

    case Keyword.get(opts, :split?, false) and byte_size(data) > 12 do
      true ->
        split_at = div(byte_size(data), 2)
        <<left::binary-size(^split_at), right::binary>> = data

        with {:ok, conn} <- safe_chunk(conn, left),
             _sleep <- Process.sleep(5),
             {:ok, conn} <- safe_chunk(conn, right) do
          {:ok, conn}
        end

      false ->
        safe_chunk(conn, data)
    end
  end

  defp safe_chunk(conn, data) do
    case Plug.Conn.chunk(conn, data) do
      {:ok, conn} -> {:ok, conn}
      {:error, reason} -> {:error, reason, conn}
    end
  end
end
