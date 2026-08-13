defmodule FakeFeishu.Router do
  @moduledoc """
  Plug router for the fake Feishu REST surface.

  Implements WS endpoint discovery, tenant token auth, and the im/v1 message,
  reaction, chat, file, image, resource, and cardkit/v1 endpoints the Lark
  adapter uses. Every business endpoint verifies the Bearer tenant token so
  e2e covers the real auth chain. Responses use the provider envelope
  `{"code": 0, "data": {...}}`.
  """

  use Plug.Router

  alias FakeFeishu.State
  alias FakeFeishu.WebSocketHandler

  plug(:match)

  plug(Plug.Parsers,
    parsers: [:json, :multipart, :urlencoded],
    json_decoder: JSON,
    pass: ["*/*"]
  )

  plug(:dispatch)

  @impl true
  def call(conn, opts) do
    conn = put_private(conn, :fake_feishu_state, Keyword.fetch!(opts, :state))
    super(conn, opts)
  end

  get "/ws" do
    conn = fetch_query_params(conn)
    app_id = conn.query_params["app"]

    WebSockAdapter.upgrade(
      conn,
      WebSocketHandler,
      %{state: state(conn), app_id: app_id},
      []
    )
  end

  post "/callback/ws/endpoint" do
    with_fault(conn, :ws_endpoint, fn conn ->
      app_id = conn.params["AppID"]
      app_secret = conn.params["AppSecret"]

      case State.authenticate_app(state(conn), app_id, app_secret) do
        :ok ->
          url = "ws://127.0.0.1:#{conn.port}/ws?service_id=1001&app=#{app_id}"

          send_json(conn, 200, %{
            "code" => 0,
            "msg" => "success",
            "data" => %{"URL" => url, "ClientConfig" => State.client_config(state(conn))}
          })

        :error ->
          # 514 is one of the client's fatal endpoint-discovery codes.
          send_json(conn, 200, %{"code" => 514, "msg" => "invalid app credentials"})
      end
    end)
  end

  post "/open-apis/auth/v3/tenant_access_token/internal" do
    with_fault(conn, :tenant_token, fn conn ->
      app_id = conn.params["app_id"]
      app_secret = conn.params["app_secret"]

      case State.authenticate_app(state(conn), app_id, app_secret) do
        :ok ->
          token = State.issue_token(state(conn), app_id)

          send_json(conn, 200, %{
            "code" => 0,
            "msg" => "ok",
            "expire" => 7200,
            "tenant_access_token" => token
          })

        :error ->
          send_json(conn, 200, %{"code" => 10_003, "msg" => "invalid app credentials"})
      end
    end)
  end

  get "/open-apis/bot/v3/info" do
    authed_app(conn, fn conn, app_id ->
      send_json(conn, 200, %{
        "code" => 0,
        "msg" => "success",
        "bot" => %{"open_id" => State.bot_open_id(state(conn), app_id)}
      })
    end)
  end

  post "/open-apis/cardkit/v1/cards" do
    authed(conn, fn conn ->
      with_fault(conn, :create_card, fn conn ->
        reply_data(conn, State.cardkit_create_card(state(conn), conn.params))
      end)
    end)
  end

  put "/open-apis/cardkit/v1/cards/:card_id/elements/:element_id/content" do
    authed(conn, fn conn ->
      with_fault(conn, :card_element, fn conn ->
        reply_data(
          conn,
          State.cardkit_element_content(state(conn), card_id, element_id, conn.params)
        )
      end)
    end)
  end

  post "/open-apis/cardkit/v1/cards/:card_id/batch_update" do
    authed(conn, fn conn ->
      with_fault(conn, :card_batch, fn conn ->
        reply_data(conn, State.cardkit_batch_update(state(conn), card_id, conn.params))
      end)
    end)
  end

  get "/open-apis/im/v1/chats" do
    authed_app(conn, fn conn, app_id ->
      with_fault(conn, :list_chats, fn conn ->
        conn = fetch_query_params(conn)
        reply_data(conn, State.list_chats(state(conn), app_id, conn.query_params))
      end)
    end)
  end

  get "/open-apis/im/v1/chats/:chat_id/members" do
    authed(conn, fn conn ->
      with_fault(conn, :list_chat_members, fn conn ->
        conn = fetch_query_params(conn)
        reply_data(conn, State.list_chat_members(state(conn), chat_id, conn.query_params))
      end)
    end)
  end

  get "/open-apis/im/v1/chats/:chat_id" do
    authed(conn, fn conn ->
      with_fault(conn, :get_chat, fn conn ->
        reply_data(conn, State.get_chat(state(conn), chat_id))
      end)
    end)
  end

  post "/open-apis/im/v1/messages" do
    authed(conn, fn conn ->
      with_fault(conn, :post_message, fn conn ->
        reply_data(conn, State.bot_post_message(state(conn), conn.params))
      end)
    end)
  end

  post "/open-apis/im/v1/messages/:message_id/reply" do
    authed(conn, fn conn ->
      with_fault(conn, :reply_message, fn conn ->
        reply_data(conn, State.bot_reply_message(state(conn), message_id, conn.params))
      end)
    end)
  end

  put "/open-apis/im/v1/messages/:message_id" do
    authed(conn, fn conn ->
      with_fault(conn, :edit_message, fn conn ->
        reply_data(conn, State.bot_edit_message(state(conn), message_id, conn.params))
      end)
    end)
  end

  patch "/open-apis/im/v1/messages/:message_id" do
    authed(conn, fn conn ->
      with_fault(conn, :edit_message, fn conn ->
        reply_data(conn, State.bot_edit_message(state(conn), message_id, conn.params))
      end)
    end)
  end

  delete "/open-apis/im/v1/messages/:message_id" do
    authed(conn, fn conn ->
      with_fault(conn, :delete_message, fn conn ->
        reply_data(conn, State.bot_delete_message(state(conn), message_id))
      end)
    end)
  end

  post "/open-apis/im/v1/messages/:message_id/reactions" do
    authed(conn, fn conn ->
      with_fault(conn, :add_reaction, fn conn ->
        emoji_type = get_in(conn.params, ["reaction_type", "emoji_type"])
        reply_data(conn, State.bot_add_reaction(state(conn), message_id, emoji_type))
      end)
    end)
  end

  delete "/open-apis/im/v1/messages/:message_id/reactions/:reaction_id" do
    authed(conn, fn conn ->
      with_fault(conn, :remove_reaction, fn conn ->
        reply_data(conn, State.bot_remove_reaction(state(conn), message_id, reaction_id))
      end)
    end)
  end

  get "/open-apis/im/v1/messages/:message_id/resources/:file_key" do
    authed(conn, fn conn ->
      with_fault(conn, :download_file, fn conn ->
        case State.fetch_download(state(conn), message_id, file_key) do
          {:ok, %{content: content, name: name}} ->
            conn
            |> put_resp_content_type("application/octet-stream")
            |> put_resp_header("content-disposition", ~s(attachment; filename="#{name}"))
            |> send_resp(200, content)

          {:error, code, msg} ->
            send_json(conn, 404, %{"code" => code, "msg" => msg})
        end
      end)
    end)
  end

  get "/open-apis/im/v1/messages/:message_id" do
    authed(conn, fn conn ->
      with_fault(conn, :get_message, fn conn ->
        reply_data(conn, State.get_message(state(conn), message_id))
      end)
    end)
  end

  post "/open-apis/im/v1/files" do
    authed(conn, fn conn ->
      with_fault(conn, :upload_file, fn conn ->
        case conn.params["file"] do
          %Plug.Upload{path: path, filename: filename} ->
            name = conn.params["file_name"] || filename
            content = File.read!(path)
            reply_data(conn, State.store_upload(state(conn), name, content))

          _missing ->
            send_json(conn, 400, %{"code" => 400_001, "msg" => "file part missing"})
        end
      end)
    end)
  end

  post "/open-apis/im/v1/images" do
    authed(conn, fn conn ->
      with_fault(conn, :upload_image, fn conn ->
        case conn.params["image"] do
          %Plug.Upload{path: path, filename: filename} ->
            reply_data(conn, State.store_image(state(conn), filename, File.read!(path)))

          _missing ->
            send_json(conn, 400, %{"code" => 400_001, "msg" => "image part missing"})
        end
      end)
    end)
  end

  match _ do
    send_json(conn, 404, %{"code" => 19_001, "msg" => "fake feishu: no such endpoint"})
  end

  # -- helpers ---------------------------------------------------------------

  defp state(conn), do: conn.private.fake_feishu_state

  defp authed(conn, fun) do
    with ["Bearer " <> token] <- get_req_header(conn, "authorization"),
         {:ok, _app_id} <- State.verify_token(state(conn), token) do
      fun.(conn)
    else
      _invalid ->
        # 99991663 is a token-invalid code the SDK reacts to by dropping its
        # cached token and retrying once — the refresh chain under test.
        send_json(conn, 400, %{"code" => 99_991_663, "msg" => "tenant token invalid"})
    end
  end

  defp authed_app(conn, fun) do
    with ["Bearer " <> token] <- get_req_header(conn, "authorization"),
         {:ok, app_id} <- State.verify_token(state(conn), token) do
      fun.(conn, app_id)
    else
      _invalid ->
        send_json(conn, 400, %{"code" => 99_991_663, "msg" => "tenant token invalid"})
    end
  end

  defp with_fault(conn, op, fun) do
    case State.take_fault(state(conn), op) do
      nil ->
        fun.(conn)

      {:delay, ms} ->
        Process.sleep(ms)
        fun.(conn)

      {:fail, :http_500} ->
        send_json(conn, 500, %{"code" => 500_100, "msg" => "fake feishu injected 500"})

      {:fail, :rate_limited} ->
        conn
        |> put_resp_header("x-ogw-ratelimit-reset", "0")
        |> send_json(429, %{"code" => 99_991_400, "msg" => "fake feishu injected rate limit"})

      {:fail, :token_invalid} ->
        send_json(conn, 400, %{"code" => 99_991_663, "msg" => "fake feishu injected stale token"})

      {:fail, {:code, code}} ->
        send_json(conn, 200, %{"code" => code, "msg" => "fake feishu injected code #{code}"})

      {:fail, {:code, code, msg}} ->
        send_json(conn, 200, %{"code" => code, "msg" => msg})
    end
  end

  defp reply_data(conn, {:ok, data}),
    do: send_json(conn, 200, %{"code" => 0, "msg" => "success", "data" => data})

  defp reply_data(conn, {:error, code, msg}),
    do: send_json(conn, 200, %{"code" => code, "msg" => msg})

  defp send_json(conn, status, body) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, JSON.encode!(body))
  end
end
