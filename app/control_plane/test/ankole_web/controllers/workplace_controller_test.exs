defmodule AnkoleWeb.WorkplaceControllerTest do
  use AnkoleWeb.ConnCase, async: false

  import Ankole.PrincipalsFixtures

  alias Ankole.AppConfigure.Cache
  alias Ankole.Conversations
  alias Ankole.Repo
  alias Ankole.Setup.Config, as: SetupConfig
  alias AnkoleWeb.Session, as: WebSession
  alias AnkoleWeb.WorkplaceStream

  defmodule StreamAdapter do
    def send_chunked(state, status, headers) do
      send(state.owner, {:stream_headers, status, headers})
      Enum.each(state.events, &send(self(), &1))
      {:ok, "", state}
    end

    def chunk(%{chunks_left: 0} = state, data) do
      send(state.owner, {:stream_closed, IO.iodata_to_binary(data)})
      {:error, :closed}
    end

    def chunk(state, data) do
      send(state.owner, {:stream_frame, IO.iodata_to_binary(data)})
      {:ok, "", %{state | chunks_left: state.chunks_left - 1}}
    end
  end

  setup do
    allow_cache_database_access()
    Cache.clear_for_test()
    :ok
  end

  test "anonymous and non-administrator browser sessions cannot read Workplace", %{
    conn: conn,
    tenant: tenant
  } do
    {:ok, true} = SetupConfig.put_completed(true)
    anonymous = get(conn, ~p"/.internal-apis/workplace/agents")
    assert %{"error" => %{"code" => "unauthorized"}} = json_response(anonymous, 401)

    Repo.put_tenant_id(tenant.id)
    %{principal: human} = human_fixture()

    {:ok, non_admin, transaction} =
      conn |> Plug.Test.init_test_session(%{}) |> WebSession.begin_login(:oauth, %{})

    {:ok, _} =
      Ankole.BrowserSessions.bind_provider(
        WebSession.browser_reference(non_admin),
        transaction.id,
        "lark-main"
      )

    {:ok, non_admin, _} =
      WebSession.complete_login(non_admin, transaction.id, %{
        "principal_uid" => human.uid,
        "access_version" => human.access_version,
        "provider_id" => "lark-main",
        "external_id" => "external-human"
      })

    non_admin = get(non_admin, ~p"/.internal-apis/workplace/agents")

    assert %{"error" => %{"code" => "unauthorized"}} = json_response(non_admin, 401)
  end

  test "the API follows the shell setup gate", %{conn: conn} do
    conn = console_conn(conn)
    {:ok, false} = SetupConfig.put_completed(false)

    conn = get(conn, ~p"/.internal-apis/workplace/agents")

    assert %{"error" => %{"code" => "unauthorized"}} = json_response(conn, 401)
  end

  test "the Principal tenant owns the API even with a Console data tenant header", %{
    conn: conn,
    tenant: tenant
  } do
    local = agent_fixture(%{display_name: "Local Agent"}).principal
    other_tenant = Ankole.DataCase.create_tenant()

    foreign =
      Repo.with_tenant(other_tenant.id, fn ->
        agent_fixture(%{display_name: "Foreign Agent"}).principal
      end)

    Repo.put_tenant_id(tenant.id)

    conn =
      conn
      |> console_conn()
      |> put_req_header("x-ankole-tenant", other_tenant.id)
      |> get(~p"/.internal-apis/workplace/agents")

    assert %{"agents" => agents} = json_response(conn, 200)
    assert %{"uid" => local.uid, "displayName" => "Local Agent"} in agents
    refute Enum.any?(agents, &(&1["uid"] == foreign.uid))
    refute Map.has_key?(conn.private, :open_api_spex)
  end

  test "create, list, read, post, and idempotent retry use the browser JSON contract", %{
    conn: conn
  } do
    {conn, human_uid} = console_conn_with_principal(conn)
    agent = agent_fixture(%{display_name: "Workplace Agent"}).principal
    attrs = create_request(agent.uid, "  First question\nsecond line  ")
    pause_session(agent.uid, attrs["conversationID"])

    created = post(conn, ~p"/.internal-apis/workplace/conversations", attrs)
    detail = json_response(created, 200)
    id = attrs["conversationID"]
    message_id = attrs["messageID"]

    assert Enum.sort(Map.keys(detail)) == ["conversation", "messages", "status"]
    assert %{"state" => "queued", "retryAt" => nil} = detail["status"]

    assert %{
             "id" => ^id,
             "title" => "First question",
             "agent" => %{
               "uid" => agent_uid,
               "displayName" => "Workplace Agent",
               "active" => true
             },
             "lastActivityAt" => activity_at
           } = detail["conversation"]

    assert agent_uid == agent.uid
    assert {:ok, _, _} = DateTime.from_iso8601(activity_at)

    assert [
             %{
               "id" => ^message_id,
               "seq" => 1,
               "authorType" => "human",
               "authorUID" => ^human_uid,
               "kind" => "message",
               "text" => "  First question\nsecond line  ",
               "createdAt" => created_at,
               "replyToMessageID" => nil
             }
           ] = detail["messages"]

    assert {:ok, _, _} = DateTime.from_iso8601(created_at)

    repeated =
      created |> recycle_api() |> post(~p"/.internal-apis/workplace/conversations", attrs)

    assert json_response(repeated, 200) == detail

    listed = repeated |> recycle_api() |> get(~p"/.internal-apis/workplace/conversations")
    assert %{"conversations" => [conversation]} = json_response(listed, 200)
    assert conversation == detail["conversation"]

    shown = listed |> recycle_api() |> get(~p"/.internal-apis/workplace/conversations/#{id}")
    assert json_response(shown, 200) == detail

    message = %{"messageID" => Ecto.UUID.generate(), "text" => "Follow up"}

    posted =
      shown
      |> recycle_api()
      |> post(~p"/.internal-apis/workplace/conversations/#{id}/messages", message)

    assert %{"messages" => [_, %{"seq" => 2, "text" => "Follow up"}]} = json_response(posted, 200)

    retried =
      posted
      |> recycle_api()
      |> post(~p"/.internal-apis/workplace/conversations/#{id}/messages", message)

    assert json_response(retried, 200) == json_response(posted, 200)
  end

  test "invalid bodies, IDs, and text keep the declared error codes", %{conn: conn} do
    conn = console_conn(conn)
    agent = agent_fixture().principal
    attrs = create_request(agent.uid)

    requests = [
      {%{}, "invalid_request"},
      {Map.put(attrs, "conversationID", "invalid"), "invalid_id"},
      {Map.put(attrs, "messageID", "invalid"), "invalid_id"},
      {Map.put(attrs, "text", " \n "), "invalid_text"},
      {Map.put(attrs, "text", 123), "invalid_text"}
    ]

    Enum.each(requests, fn {body, code} ->
      response = conn |> recycle_api() |> post(~p"/.internal-apis/workplace/conversations", body)
      assert %{"error" => %{"code" => ^code}} = json_response(response, 422)
    end)

    shown = conn |> recycle_api() |> get(~p"/.internal-apis/workplace/conversations/invalid")
    assert %{"error" => %{"code" => "invalid_id"}} = json_response(shown, 422)
  end

  test "a reused ID with different facts is a conflict", %{conn: conn} do
    conn = console_conn(conn)
    agent = agent_fixture().principal
    attrs = create_request(agent.uid)
    pause_session(agent.uid, attrs["conversationID"])
    created = post(conn, ~p"/.internal-apis/workplace/conversations", attrs)
    assert json_response(created, 200)

    conflict =
      created
      |> recycle_api()
      |> post(~p"/.internal-apis/workplace/conversations", Map.put(attrs, "text", "Different"))

    assert %{"error" => %{"code" => "conversation_conflict"}} = json_response(conflict, 409)
  end

  test "disabled Agent histories stay readable and new messages are rejected", %{conn: conn} do
    conn = console_conn(conn)
    agent = agent_fixture().principal
    attrs = create_request(agent.uid)
    pause_session(agent.uid, attrs["conversationID"])
    created = post(conn, ~p"/.internal-apis/workplace/conversations", attrs)
    assert json_response(created, 200)
    {:ok, _} = disable_principal_fixture(agent.uid)
    id = attrs["conversationID"]

    shown = created |> recycle_api() |> get(~p"/.internal-apis/workplace/conversations/#{id}")
    assert %{"conversation" => %{"agent" => %{"active" => false}}} = json_response(shown, 200)

    posted =
      shown
      |> recycle_api()
      |> post(~p"/.internal-apis/workplace/conversations/#{id}/messages", %{
        "messageID" => Ecto.UUID.generate(),
        "text" => "One more"
      })

    assert %{"error" => %{"code" => "agent_unavailable"}} = json_response(posted, 409)

    attempted =
      posted
      |> recycle_api()
      |> post(~p"/.internal-apis/workplace/conversations", create_request(agent.uid))

    assert %{"error" => %{"code" => "agent_unavailable"}} = json_response(attempted, 409)
  end

  test "only the participant may read, write, or subscribe, including event-stream Accept", %{
    conn: conn
  } do
    {conn, _uid} = console_conn_with_principal(conn)
    %{principal: other_human} = human_fixture()
    agent = agent_fixture().principal
    {:ok, detail} = Conversations.create(other_human.uid, domain_request(agent.uid))
    id = detail.conversation.id

    shown = get(conn, ~p"/.internal-apis/workplace/conversations/#{id}")
    assert %{"error" => %{"code" => "conversation_not_found"}} = json_response(shown, 404)

    posted =
      shown
      |> recycle_api()
      |> post(~p"/.internal-apis/workplace/conversations/#{id}/messages", %{
        "messageID" => Ecto.UUID.generate(),
        "text" => "Forbidden"
      })

    assert %{"error" => %{"code" => "conversation_not_found"}} = json_response(posted, 404)

    events =
      posted
      |> recycle_api()
      |> put_req_header("accept", "text/event-stream")
      |> get(~p"/.internal-apis/workplace/conversations/#{id}/events")

    assert %{"error" => %{"code" => "conversation_not_found"}} = json_response(events, 404)
  end

  test "browser writes require CSRF proof", %{conn: conn} do
    conn =
      conn
      |> console_conn()
      |> delete_req_header("x-csrf-token")
      |> delete_req_header("origin")

    agent = agent_fixture().principal

    assert_raise Plug.CSRFProtection.InvalidCSRFTokenError, fn ->
      post(conn, ~p"/.internal-apis/workplace/conversations", create_request(agent.uid))
    end
  end

  test "SSE emits committed changes and model text, keeps unrelated messages, and unsubscribes",
       %{
         conn: conn
       } do
    {conn, human_uid} = active_admin_conn_with_principal(conn)
    agent = agent_fixture().principal
    {:ok, detail} = Conversations.create(human_uid, domain_request(agent.uid))
    id = detail.conversation.id
    model_id = detail.model_conversation_id
    native_message = {:conversation_event, id, :message}
    native_status = {:conversation_event, id, :status}
    signal = Repo.get_by!(Ankole.Signals.Signal, session_id: detail.session_id)
    response_id = "resp_" <> Ecto.UUID.generate()

    gateway = %{
      subject_uid: agent.uid,
      conversation_id: model_id,
      response_id: response_id,
      metadata: %{"signal_id" => signal.id},
      payload: %{text: "hello\nworld"}
    }

    unrelated_native = {:conversation_event, Ecto.UUID.generate(), :message}

    unrelated_gateway =
      {:ai_gateway_event, :response_started, %{gateway | conversation_id: Ecto.UUID.generate()}}

    events = [
      {:unrelated, :must_remain},
      unrelated_native,
      unrelated_gateway,
      {:ai_gateway_event, :reasoning_delta, gateway},
      {:ai_gateway_event, :response_started, gateway},
      {:ai_gateway_event, :output_text_delta, gateway},
      native_message,
      native_status,
      native_status
    ]

    request =
      Plug.Test.conn(:get, "/.internal-apis/workplace/conversations/#{id}/events")
      |> Plug.Test.init_test_session(get_session(conn))
      |> put_req_header("accept", "text/event-stream")

    request = %{
      request
      | adapter: {StreamAdapter, %{owner: self(), events: events, chunks_left: 5}}
    }

    assert %Plug.Conn{state: :chunked} = @endpoint.call(request, @endpoint.init([]))

    assert_receive {:stream_headers, 200, headers}
    assert {"cache-control", "no-cache"} in headers
    assert {"x-accel-buffering", "no"} in headers

    assert Enum.any?(headers, fn {key, value} ->
             key == "content-type" and String.starts_with?(value, "text/event-stream")
           end)

    assert_receive {:stream_frame, ": ping\n\n"}
    assert_receive {:stream_frame, "event: started\ndata: " <> started}

    assert Ankole.JSON.decode!(String.trim(started)) == %{
             "responseID" => response_id,
             "signalIDs" => [signal.id]
           }

    assert_receive {:stream_frame, "event: delta\ndata: " <> delta}

    assert Ankole.JSON.decode!(String.trim(delta)) == %{
             "responseID" => response_id,
             "signalIDs" => [signal.id],
             "text" => "hello\nworld"
           }

    assert_receive {:stream_frame, "event: message\ndata: {}\n\n"}
    assert_receive {:stream_frame, "event: status\ndata: {}\n\n"}
    assert_receive {:stream_closed, "event: status\ndata: {}\n\n"}
    refute_receive {:stream_frame, _}
    assert_receive {:unrelated, :must_remain}
    assert_receive ^unrelated_native
    assert_receive ^unrelated_gateway

    :ok = Conversations.publish_message(%{session_id: Ankole.Sessions.Key.conversation(id)})
    refute_receive ^native_message

    Phoenix.PubSub.local_broadcast(
      Ankole.PubSub,
      "ai_gateway:subject:#{agent.uid}:conversation:#{model_id}",
      {:ai_gateway_event, :response_started, gateway}
    )

    refute_receive {:ai_gateway_event, :response_started, ^gateway}
  end

  test "a stream that joins after started receives the future delta with its Signal inputs", %{
    conn: conn
  } do
    {_conn, human_uid} = console_conn_with_principal(conn)
    agent = agent_fixture().principal
    {:ok, detail} = Conversations.create(human_uid, domain_request(agent.uid))
    signal = Repo.get_by!(Ankole.Signals.Signal, session_id: detail.session_id)
    response_id = "resp_" <> Ecto.UUID.generate()

    gateway = %{
      subject_uid: agent.uid,
      conversation_id: detail.model_conversation_id,
      response_id: response_id,
      metadata: %{"signal_id" => signal.id},
      payload: %{text: "future tail"}
    }

    conn = %{
      build_conn()
      | adapter:
          {StreamAdapter,
           %{
             owner: self(),
             events: [
               {:ai_gateway_event, :output_text_delta, gateway},
               {:conversation_event, detail.conversation.id, :status}
             ],
             chunks_left: 2
           }}
    }

    assert {:ok, %Plug.Conn{state: :chunked}} = WorkplaceStream.open(conn, detail)
    assert_receive {:stream_frame, ": ping\n\n"}
    assert_receive {:stream_frame, "event: delta\ndata: " <> delta}

    assert Ankole.JSON.decode!(String.trim(delta)) == %{
             "responseID" => response_id,
             "signalIDs" => [signal.id],
             "text" => "future tail"
           }

    assert_receive {:stream_closed, "event: status\ndata: {}\n\n"}
  end

  @tag timeout: 25_000
  test "an idle stream sends its next ping after 15 seconds and detects a closed connection", %{
    conn: conn
  } do
    {_conn, human_uid} = console_conn_with_principal(conn)
    agent = agent_fixture().principal
    {:ok, detail} = Conversations.create(human_uid, domain_request(agent.uid))

    conn = %{
      build_conn()
      | adapter: {StreamAdapter, %{owner: self(), events: [], chunks_left: 1}}
    }

    started_at = System.monotonic_time(:millisecond)
    assert {:ok, %Plug.Conn{state: :chunked}} = WorkplaceStream.open(conn, detail)
    assert System.monotonic_time(:millisecond) - started_at >= 15_000
    assert_receive {:stream_frame, ": ping\n\n"}
    assert_receive {:stream_closed, ": ping\n\n"}
  end

  defp create_request(agent_uid, text \\ "First question") do
    %{
      "conversationID" => Ecto.UUID.generate(),
      "agentUID" => agent_uid,
      "messageID" => Ecto.UUID.generate(),
      "text" => text
    }
  end

  defp domain_request(agent_uid) do
    attrs = %{
      conversation_id: Ecto.UUID.generate(),
      agent_uid: agent_uid,
      message_id: Ecto.UUID.generate(),
      text: "First question"
    }

    pause_session(agent_uid, attrs.conversation_id)
    attrs
  end

  defp pause_session(agent_uid, conversation_id) do
    key = %{agent_uid: agent_uid, session_id: Ankole.Sessions.Key.conversation(conversation_id)}
    {:ok, driver} = Ankole.Sessions.ensure_driver(key)
    :ok = :sys.suspend(driver)

    on_exit(fn ->
      if Process.alive?(driver), do: :sys.terminate(driver, :normal, 5_000)
    end)
  end
end
