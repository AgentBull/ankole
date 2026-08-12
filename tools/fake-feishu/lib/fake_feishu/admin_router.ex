defmodule FakeFeishu.AdminRouter do
  @moduledoc """
  JSON admin surface of the standalone fake Feishu server, under `/sim/v1`.

  This is the seam the `fake-feishu` CLI drives: it plays the user side of a
  conversation (send, recall, react, card actions), inspects platform state
  (chats, transcripts, uploads), injects faults, and follows the live event
  feed over SSE. It intentionally does not exist on the real platform, so the
  path prefix is collision-free with `/open-apis`.
  """

  use Plug.Router

  alias FakeFeishu.EventHub
  alias FakeFeishu.Sim
  alias FakeFeishu.State

  plug(:match)

  plug(Plug.Parsers,
    parsers: [:json],
    json_decoder: JSON,
    pass: ["*/*"]
  )

  plug(:dispatch)

  @impl true
  def call(conn, opts) do
    conn = put_private(conn, :fake_feishu_state, Keyword.fetch!(opts, :state))
    super(conn, opts)
  end

  get "/sim/v1/status" do
    state = state(conn)

    send_json(conn, 200, %{
      "apps" =>
        Map.new(State.apps(state), fn {app_id, app} ->
          {app_id, %{"bot_open_id" => app.bot_open_id}}
        end),
      "connections" => State.connection_count(state),
      "chats" => length(State.chats(state)),
      "pings" => State.ping_count(state)
    })
  end

  get "/sim/v1/chats" do
    send_json(conn, 200, Sim.chat_views(state(conn)))
  end

  post "/sim/v1/chats" do
    members =
      Enum.map(conn.params["users"] || [], &%{"type" => "user", "name" => &1}) ++
        Enum.map(conn.params["bots"] || [], &%{"type" => "bot", "app_id" => &1}) ++
        (conn.params["members"] || [])

    attrs =
      conn.params
      |> Map.take(["id", "type", "name"])
      |> Map.put("members", members)

    {:ok, chat} = State.put_chat(state(conn), attrs)
    send_json(conn, 200, Sim.chat_view(chat))
  end

  post "/sim/v1/chats/:chat_id/members" do
    case State.add_chat_member(state(conn), chat_id, conn.params) do
      {:ok, _member} -> send_json(conn, 200, %{"ok" => true})
      {:error, reason} -> send_error(conn, reason)
    end
  end

  delete "/sim/v1/chats/:chat_id/members/:member_key" do
    case State.remove_chat_member(state(conn), chat_id, member_key) do
      :ok -> send_json(conn, 200, %{"ok" => true})
      {:error, reason} -> send_error(conn, reason)
    end
  end

  get "/sim/v1/chats/:chat_id/messages" do
    send_json(conn, 200, Sim.transcript(state(conn), chat_id))
  end

  post "/sim/v1/chats/:chat_id/messages" do
    case Sim.send_user_message(state(conn), chat_id, conn.params) do
      {:ok, ids} -> send_json(conn, 200, ids)
      {:error, reason} -> send_error(conn, reason)
    end
  end

  get "/sim/v1/messages/:message_id" do
    state = state(conn)

    case State.message(state, message_id) do
      nil ->
        send_error(conn, :message_not_found)

      message ->
        send_json(conn, 200, %{
          "message_id" => message.id,
          "chat_id" => message.chat_id,
          "sender" => Atom.to_string(message.sender),
          "msg_type" => message.msg_type,
          "content" => message.content,
          "text" => State.rendered_message_text(state, message.id),
          "card_id" => message.card_id,
          "reply_to" => message.reply_to,
          "recalled" => message.recalled,
          "deleted" => message.deleted,
          "reactions" => Enum.map(message.reactions, & &1.key)
        })
    end
  end

  post "/sim/v1/messages/:message_id/recall" do
    case Sim.recall_message(state(conn), message_id) do
      {:ok, result} -> send_json(conn, 200, result)
      {:error, reason} -> send_error(conn, reason)
    end
  end

  post "/sim/v1/messages/:message_id/reactions" do
    case Sim.react(state(conn), message_id, conn.params, :add) do
      {:ok, result} -> send_json(conn, 200, result)
      {:error, reason} -> send_error(conn, reason)
    end
  end

  delete "/sim/v1/messages/:message_id/reactions" do
    case Sim.react(state(conn), message_id, conn.params, :remove) do
      {:ok, result} -> send_json(conn, 200, result)
      {:error, reason} -> send_error(conn, reason)
    end
  end

  post "/sim/v1/messages/:message_id/card-action" do
    case Sim.card_action(state(conn), message_id, conn.params) do
      {:ok, result} -> send_json(conn, 200, result)
      {:error, reason} -> send_error(conn, reason)
    end
  end

  get "/sim/v1/files/:file_key" do
    case State.uploaded_file(state(conn), file_key) do
      nil ->
        send_error(conn, :file_not_found)

      %{name: name, content: content} ->
        conn
        |> put_resp_content_type("application/octet-stream")
        |> put_resp_header("content-disposition", ~s(attachment; filename="#{name}"))
        |> send_resp(200, content)
    end
  end

  get "/sim/v1/images/:image_key" do
    case State.uploaded_image(state(conn), image_key) do
      nil ->
        send_error(conn, :image_not_found)

      %{content: content} ->
        conn
        |> put_resp_content_type("application/octet-stream")
        |> send_resp(200, content)
    end
  end

  post "/sim/v1/faults" do
    case arm_fault(state(conn), conn.params) do
      :ok -> send_json(conn, 200, %{"ok" => true})
      {:error, reason} -> send_error(conn, reason)
    end
  end

  get "/sim/v1/events" do
    conn = fetch_query_params(conn)
    since = parse_int(conn.query_params["since"], 0)
    send_json(conn, 200, EventHub.events_since(since))
  end

  get "/sim/v1/events/stream" do
    conn = fetch_query_params(conn)
    since = parse_int(conn.query_params["since"], 0)

    conn =
      conn
      |> put_resp_content_type("text/event-stream")
      |> put_resp_header("cache-control", "no-cache")
      |> send_chunked(200)

    :ok = EventHub.subscribe(EventHub, since)
    stream_events(conn)
  end

  match _ do
    send_json(conn, 404, %{"error" => "no such admin endpoint"})
  end

  # -- SSE loop ---------------------------------------------------------------

  defp stream_events(conn) do
    receive do
      {:hub_backlog, events} ->
        case push_sse(conn, events) do
          {:ok, conn} -> stream_events(conn)
          {:error, _closed} -> conn
        end

      {:hub_event, event} ->
        case push_sse(conn, [event]) do
          {:ok, conn} -> stream_events(conn)
          {:error, _closed} -> conn
        end
    after
      15_000 ->
        # Comment heartbeat keeps proxies and the client read loop alive.
        case chunk(conn, ": keep-alive\n\n") do
          {:ok, conn} -> stream_events(conn)
          {:error, _closed} -> conn
        end
    end
  end

  defp push_sse(conn, events) do
    Enum.reduce_while(events, {:ok, conn}, fn event, {:ok, conn} ->
      case chunk(conn, "data: #{JSON.encode!(event)}\n\n") do
        {:ok, conn} -> {:cont, {:ok, conn}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  # -- helpers ------------------------------------------------------------------

  defp state(conn), do: conn.private.fake_feishu_state

  defp arm_fault(state, params) do
    with {:ok, op} <- fault_op(params["op"] || "post_message") do
      case params do
        %{"delay_ms" => ms} when is_integer(ms) -> State.delay_next(state, op, ms)
        %{"error" => "http_500"} -> State.fail_next(state, op, :http_500)
        %{"error" => "rate_limited"} -> State.fail_next(state, op, :rate_limited)
        %{"error" => "token_invalid"} -> State.fail_next(state, op, :token_invalid)
        %{"code" => code} when is_integer(code) -> State.fail_next(state, op, {:code, code})
        _invalid -> {:error, :invalid_fault}
      end
    end
  end

  # Fault ops are the finite set State documents; an unknown name must not
  # mint a new atom.
  defp fault_op(op) when is_binary(op) do
    {:ok, String.to_existing_atom(op)}
  rescue
    ArgumentError -> {:error, :unknown_fault_op}
  end

  defp fault_op(_op), do: {:error, :unknown_fault_op}

  defp parse_int(value, default) do
    case Integer.parse(to_string(value || "")) do
      {parsed, _rest} -> parsed
      :error -> default
    end
  end

  defp send_error(conn, :no_ws_connections) do
    send_json(conn, 409, %{
      "error" =>
        "no live bot WS connection for this chat's app — " <>
          "is the control plane running and pointed at this server?"
    })
  end

  defp send_error(conn, reason) do
    send_json(conn, 422, %{"error" => inspect(reason)})
  end

  defp send_json(conn, status, body) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, JSON.encode!(body))
  end
end
