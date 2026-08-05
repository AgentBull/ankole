defmodule Ankole.E2E.FakeSlack.Router do
  @moduledoc false

  use Plug.Router

  alias Ankole.E2E.FakeSlack.{State, WebSocketHandler}

  plug :match

  plug Plug.Parsers,
    parsers: [:json, :urlencoded],
    json_decoder: Ankole.JSON,
    pass: ["*/*"]

  plug :dispatch

  @impl true
  def call(conn, opts) do
    conn = put_private(conn, :fake_slack_state, Keyword.fetch!(opts, :state))
    super(conn, opts)
  end

  get "/ws" do
    WebSockAdapter.upgrade(conn, WebSocketHandler, %{state: state(conn)}, [])
  end

  post "/api/apps.connections.open" do
    with_auth(conn, :app, fn conn -> ok(conn, %{"url" => "ws://127.0.0.1:#{conn.port}/ws"}) end)
  end

  post "/api/auth.test" do
    with_auth(conn, :bot, fn conn ->
      credentials = State.credentials(state(conn))

      ok(conn, %{
        "user_id" => credentials.bot_user_id,
        "bot_id" => "BFAKE",
        "team_id" => credentials.team_id
      })
    end)
  end

  post "/api/chat.postMessage" do
    with_auth(conn, :bot, fn conn ->
      {:ok, message} = State.post_message(state(conn), conn.params)
      ok(conn, %{"channel" => message["channel"], "ts" => message["ts"], "message" => message})
    end)
  end

  post "/api/chat.update" do
    with_auth(conn, :bot, fn conn ->
      {:ok, message} = State.update_message(state(conn), conn.params)
      ok(conn, %{"channel" => message["channel"], "ts" => message["ts"], "message" => message})
    end)
  end

  post "/api/chat.delete" do
    with_auth(conn, :bot, fn conn ->
      :ok = State.delete_message(state(conn), conn.params)
      ok(conn, %{})
    end)
  end

  post("/api/reactions.add", do: with_auth(conn, :bot, &ok(&1, %{})))
  post("/api/reactions.remove", do: with_auth(conn, :bot, &ok(&1, %{})))

  get "/api/files.getUploadURLExternal" do
    with_auth(conn, :bot, fn conn ->
      file_id = State.reserve_upload(state(conn), conn.params["filename"])

      ok(conn, %{
        "file_id" => file_id,
        "upload_url" => "http://127.0.0.1:#{conn.port}/upload/#{file_id}"
      })
    end)
  end

  post "/upload/:file_id" do
    {:ok, body, conn} = read_body(conn)
    :ok = State.store_upload(state(conn), file_id, body)
    send_resp(conn, 200, "ok")
  end

  post "/api/files.completeUploadExternal" do
    with_auth(conn, :bot, fn conn ->
      files =
        Enum.map(conn.params["files"] || [], fn file ->
          %{"id" => file["id"], "title" => file["title"]}
        end)

      ok(conn, %{"files" => files})
    end)
  end

  get "/files/:file_id" do
    with_auth(conn, :bot, fn conn ->
      case State.inbound_file(state(conn), file_id) do
        %{name: name, content: content} ->
          conn
          |> put_resp_content_type("application/octet-stream")
          |> put_resp_header("content-disposition", ~s(attachment; filename="#{name}"))
          |> send_resp(200, content)

        nil ->
          send_resp(conn, 404, "not found")
      end
    end)
  end

  get "/api/conversations.history" do
    with_auth(conn, :bot, fn conn ->
      latest = conn.params["latest"]

      messages =
        case Map.get(State.messages(state(conn)), latest) do
          nil -> []
          message -> [message]
        end

      ok(conn, %{"messages" => messages})
    end)
  end

  get "/api/users.conversations" do
    with_auth(
      conn,
      :bot,
      &ok(&1, %{
        "channels" => State.channels(state(conn)),
        "response_metadata" => %{"next_cursor" => ""}
      })
    )
  end

  get "/api/conversations.info" do
    with_auth(conn, :bot, fn conn ->
      channel = Enum.find(State.channels(state(conn)), &(&1["id"] == conn.params["channel"]))
      ok(conn, %{"channel" => channel})
    end)
  end

  get "/api/conversations.members" do
    with_auth(
      conn,
      :bot,
      &ok(&1, %{
        "members" => State.members(state(conn), conn.params["channel"]),
        "response_metadata" => %{"next_cursor" => ""}
      })
    )
  end

  get "/api/users.list" do
    with_auth(
      conn,
      :bot,
      &ok(&1, %{
        "members" => State.users(state(conn)),
        "response_metadata" => %{"next_cursor" => ""}
      })
    )
  end

  get "/api/users.info" do
    with_auth(conn, :bot, fn conn ->
      ok(conn, %{
        "user" => Enum.find(State.users(state(conn)), &(&1["id"] == conn.params["user"]))
      })
    end)
  end

  get "/api/usergroups.list" do
    with_auth(conn, :bot, &ok(&1, %{"usergroups" => State.usergroups(state(conn))}))
  end

  get "/api/usergroups.users.list" do
    with_auth(conn, :bot, fn conn ->
      group =
        Enum.find(State.usergroups(state(conn)), &(&1["id"] == conn.params["usergroup"])) || %{}

      ok(conn, %{"users" => Map.get(group, "users", [])})
    end)
  end

  post "/api/openid.connect.token" do
    ok(conn, %{"access_token" => "xoxp-fake", "id_token" => "fake.jwt"})
  end

  post "/api/openid.connect.userInfo" do
    ok(conn, %{
      "sub" => "U1",
      "https://slack.com/user_id" => "U1",
      "https://slack.com/team_id" => "TFAKE",
      "email" => "ada@example.com",
      "name" => "Ada"
    })
  end

  match _ do
    send_json(conn, 404, %{"ok" => false, "error" => "unknown_method"})
  end

  defp state(conn), do: conn.private.fake_slack_state

  defp with_auth(conn, kind, fun) do
    credentials = State.credentials(state(conn))
    expected = if kind == :app, do: credentials.app_token, else: credentials.bot_token

    case get_req_header(conn, "authorization") do
      ["Bearer " <> ^expected] -> fun.(conn)
      _invalid -> send_json(conn, 200, %{"ok" => false, "error" => "invalid_auth"})
    end
  end

  defp ok(conn, fields), do: send_json(conn, 200, Map.put(fields, "ok", true))

  defp send_json(conn, status, body) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Ankole.JSON.encode!(body))
  end
end
