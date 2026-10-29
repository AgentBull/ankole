defmodule AnkoleWeb.PodControllerTest do
  use AnkoleWeb.ConnCase, async: false
  import AnkoleWeb.PodAPI
  @moduletag host: :pod

  import Ankole.PrincipalsFixtures

  alias Ankole.Conversations
  alias Ankole.Repo
  alias AnkoleWeb.Session, as: WebSession

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
      if after_chunk = state[:after_chunk], do: after_chunk.()
      {:ok, "", Map.delete(%{state | chunks_left: state.chunks_left - 1}, :after_chunk)}
    end
  end

  setup do
    :ok
  end

  test "anonymous access is denied and an ordinary Human can use Pod", %{
    conn: conn,
    tenant: tenant
  } do
    {:ok, true} = Ankole.AppConfigure.put_global(Ankole.Setup.Config.completed_definition(), true)
    anonymous = api_get(conn, ~p"/api/v2/pod/agents")

    assert %{"error" => %{"code" => "unauthorized"}} =
             api_response(anonymous, 401)

    Repo.put_tenant_id(tenant.id)
    %{principal: human} = human_fixture()

    non_admin = conn |> Plug.Test.init_test_session(%{}) |> WebSession.ensure_browser()

    {:ok, %{browser: browser, authentication: auth}} =
      Ankole.BrowserSessions.authenticate(WebSession.browser_reference(non_admin), :pod, %{
        "principal_uid" => human.uid,
        "access_version" => human.access_version,
        "provider_id" => "lark-main",
        "external_id" => "external-human"
      })

    non_admin = WebSession.put_authentication(non_admin, browser, auth)

    non_admin = api_get(non_admin, ~p"/api/v2/pod/agents")

    assert %{"agents" => []} = api_response(non_admin, 200)
  end

  test "the API follows the shell setup gate", %{conn: conn} do
    conn = console_conn(conn)

    {:ok, false} =
      Ankole.AppConfigure.put_global(Ankole.Setup.Config.completed_definition(), false)

    conn = api_get(conn, ~p"/api/v2/pod/agents")

    assert %{"error" => %{"code" => "unauthorized"}} =
             api_response(conn, 401)
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

    {conn, human_uid} = console_conn_with_principal(conn)
    Ankole.ConversationsFixtures.grant_chat(human_uid, local.uid)

    conn =
      conn
      |> put_req_header("x-ankole-tenant", other_tenant.id)
      |> api_get(~p"/api/v2/pod/agents")

    assert %{"agents" => agents} = api_response(conn, 200)
    assert %{"displayName" => "Local Agent"} = Enum.find(agents, &(&1["uid"] == local.uid))
    refute Enum.any?(agents, &(&1["uid"] == foreign.uid))
    refute Map.has_key?(conn.private, :open_api_spex)
  end

  test "create, list, read, post, and idempotent retry use the browser JSON contract", %{
    conn: conn
  } do
    {conn, human_uid} = console_conn_with_principal(conn)
    agent = agent_fixture(%{display_name: "Pod Agent"}).principal
    Ankole.ConversationsFixtures.grant_chat(human_uid, agent.uid)
    attrs = create_request(agent.uid, "  First question\nsecond line  ")
    pause_session(agent.uid, attrs["conversationID"])

    created = api_post(conn, ~p"/api/v2/pod/conversations", attrs)
    detail = api_response(created, 200)
    id = attrs["conversationID"]
    message_id = attrs["messageID"]

    assert Enum.sort(Map.keys(detail)) == [
             "activities",
             "artifacts",
             "conversation",
             "latestInput",
             "linkedRuns",
             "messageRange",
             "messages",
             "olderMessagesBeforeSeq",
             "pendingInteractions",
             "pendingQueues",
             "removedMessageIDs"
           ]

    assert detail["messageRange"] == %{"firstSeq" => 1, "lastSeq" => 1}
    assert detail["olderMessagesBeforeSeq"] == nil
    assert [queue] = detail["pendingQueues"]
    assert queue["agentUID"] == agent.uid
    assert queue["paused"] == false
    assert queue["retryableMessageID"] == nil

    assert [
             %{
               "messageID" => ^message_id,
               "deliveryMode" => "steer",
               "attachments" => [],
               "modelProfile" => "primary"
             }
           ] = queue["inputs"]

    assert is_binary(queue["queueVersion"])
    assert %{"state" => "queued", "retryAt" => nil} = queue["workStatus"]

    missing_target =
      created
      |> recycle_api()
      |> api_post("/api/v2/pod/conversations/#{id}/queue", %{
        action: "stop",
        commandID: Ecto.UUID.generate()
      })

    assert %{"errors" => [%{"code" => "required", "source" => %{"pointer" => "/data/agentUID"}}]} =
             api_response(missing_target, 400)

    refute Conversations.get_conversation!(id).metadata["queue_paused:" <> agent.uid] == true

    assert %{
             "id" => ^id,
             "title" => "First question",
             "agent" => %{
               "uid" => agent_uid,
               "displayName" => "Pod Agent",
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
      created |> recycle_api() |> api_post(~p"/api/v2/pod/conversations", attrs)

    assert api_response(repeated, 200) == detail

    listed = repeated |> recycle_api() |> api_get(~p"/api/v2/pod/conversations")

    assert %{"conversations" => [conversation]} =
             api_response(listed, 200)

    assert conversation == detail["conversation"]

    shown = listed |> recycle_api() |> api_get(~p"/api/v2/pod/conversations/#{id}")
    assert api_response(shown, 200) == detail

    message = %{"messageID" => Ecto.UUID.generate(), "text" => "Follow up"}

    posted =
      shown
      |> recycle_api()
      |> api_post(~p"/api/v2/pod/conversations/#{id}/messages", message)

    assert %{"messages" => [_, %{"seq" => 2, "text" => "Follow up"}]} =
             api_response(posted, 200)

    retried =
      posted
      |> recycle_api()
      |> api_post(~p"/api/v2/pod/conversations/#{id}/messages", message)

    assert api_response(retried, 200) ==
             api_response(posted, 200)
  end

  test "page chat uses the same conversation API and can be recovered by page", %{conn: conn} do
    {conn, human_uid} = console_conn_with_principal(conn)
    agent = agent_fixture().principal
    Ankole.ConversationsFixtures.grant_chat(human_uid, agent.uid)

    {:ok, page} =
      Ankole.Pod.Pages.create(Ankole.PrincipalsFixtures.actor_fixture(human_uid), %{
        title: "Current page"
      })

    attrs = Map.put(create_request(agent.uid), "pageID", page.id)
    pause_session(agent.uid, attrs["conversationID"])
    created = api_post(conn, ~p"/api/v2/pod/conversations", attrs)
    detail = api_response(created, 200)
    assert detail["conversation"]["pageID"] == page.id

    listed =
      created |> recycle_api() |> api_get(~p"/api/v2/pod/conversations", %{pageID: page.id})

    assert %{"conversations" => [conversation]} =
             api_response(listed, 200)

    assert conversation == detail["conversation"]

    shown =
      listed
      |> recycle_api()
      |> api_get(~p"/api/v2/pod/conversations/#{attrs["conversationID"]}")

    assert api_response(shown, 200) == detail
  end

  test "invalid fields cannot create a conversation and expose JSON:API validation errors", %{
    conn: conn
  } do
    {conn, uid} = console_conn_with_principal(conn)
    agent = agent_fixture().principal
    Ankole.ConversationsFixtures.grant_chat(uid, agent.uid)
    attrs = create_request(agent.uid)

    for body <- [
          %{},
          Map.put(attrs, "conversationID", "invalid"),
          Map.put(attrs, "messageID", "invalid"),
          Map.put(attrs, "text", " \n "),
          Map.put(attrs, "text", 123)
        ] do
      rejected = conn |> recycle_api() |> api_post(~p"/api/v2/pod/conversations", body)
      assert rejected.status in [400, 422]
      assert %{"errors" => [_ | _]} = api_response(rejected, rejected.status)

      refute Enum.any?(
               Conversations.list(Ankole.PrincipalsFixtures.actor_fixture(uid)),
               &(&1.id == attrs["conversationID"])
             )
    end

    shown = conn |> recycle_api() |> api_get(~p"/api/v2/pod/conversations/invalid")
    assert %{"errors" => [_ | _]} = api_response(shown, 400)
  end

  test "a reused ID with different facts is a conflict", %{conn: conn} do
    {conn, human_uid} = console_conn_with_principal(conn)
    agent = agent_fixture().principal
    Ankole.ConversationsFixtures.grant_chat(human_uid, agent.uid)
    attrs = create_request(agent.uid)
    pause_session(agent.uid, attrs["conversationID"])
    created = api_post(conn, ~p"/api/v2/pod/conversations", attrs)
    assert api_response(created, 200)

    conflict =
      created
      |> recycle_api()
      |> api_post(~p"/api/v2/pod/conversations", Map.put(attrs, "text", "Different"))

    assert %{"errors" => [%{"code" => "conversation_conflict"}]} =
             api_response(conflict, 409)
  end

  test "disabled Agent histories stay readable and new messages are rejected", %{conn: conn} do
    {conn, human_uid} = console_conn_with_principal(conn)
    agent = agent_fixture().principal
    Ankole.ConversationsFixtures.grant_chat(human_uid, agent.uid)
    attrs = create_request(agent.uid)
    pause_session(agent.uid, attrs["conversationID"])
    created = api_post(conn, ~p"/api/v2/pod/conversations", attrs)
    assert api_response(created, 200)
    {:ok, _} = disable_principal_fixture(agent.uid)
    id = attrs["conversationID"]

    shown = created |> recycle_api() |> api_get(~p"/api/v2/pod/conversations/#{id}")

    assert %{"conversation" => %{"agent" => %{"active" => false}}} =
             api_response(shown, 200)

    posted =
      shown
      |> recycle_api()
      |> api_post(~p"/api/v2/pod/conversations/#{id}/messages", %{
        "messageID" => Ecto.UUID.generate(),
        "text" => "One more"
      })

    assert %{"errors" => [%{"code" => "agent_unavailable"}]} =
             api_response(posted, 409)

    attempted =
      posted
      |> recycle_api()
      |> api_post(~p"/api/v2/pod/conversations", create_request(agent.uid))

    assert %{"errors" => [%{"code" => "agent_unavailable"}]} =
             api_response(attempted, 409)
  end

  test "only the participant may read, write, or subscribe, including event-stream Accept", %{
    conn: conn
  } do
    {conn, _uid} = console_conn_with_principal(conn)
    %{principal: other_human} = human_fixture()
    agent = agent_fixture().principal
    Ankole.ConversationsFixtures.grant_chat(other_human.uid, agent.uid)

    {:ok, detail} =
      Conversations.create(
        Ankole.PrincipalsFixtures.actor_fixture(other_human.uid),
        domain_request(agent.uid)
      )

    id = detail.conversation.id

    shown = api_get(conn, ~p"/api/v2/pod/conversations/#{id}")

    assert %{"errors" => [%{"code" => "conversation_not_found"}]} =
             api_response(shown, 404)

    posted =
      shown
      |> recycle_api()
      |> api_post(~p"/api/v2/pod/conversations/#{id}/messages", %{
        "messageID" => Ecto.UUID.generate(),
        "text" => "Forbidden"
      })

    assert %{"errors" => [%{"code" => "conversation_not_found"}]} =
             api_response(posted, 404)

    events =
      posted
      |> recycle_api()
      |> put_req_header("accept", "text/event-stream")
      |> get(~p"/api/v2/pod/conversations/#{id}/events")

    assert %{"error" => %{"code" => "conversation_not_found"}} =
             api_response(events, 404)
  end

  test "browser writes require CSRF proof", %{conn: conn} do
    conn =
      conn
      |> console_conn()
      |> delete_req_header("x-csrf-token")
      |> delete_req_header("origin")

    agent = agent_fixture().principal

    assert_raise Plug.CSRFProtection.InvalidCSRFTokenError, fn ->
      api_post(conn, ~p"/api/v2/pod/conversations", create_request(agent.uid))
    end
  end

  test "SSE emits committed changes and model text, keeps unrelated messages, and unsubscribes",
       %{
         conn: conn
       } do
    {conn, human_uid} = active_admin_conn_with_principal(conn)
    agent = agent_fixture().principal
    Ankole.ConversationsFixtures.grant_chat(human_uid, agent.uid)

    {:ok, detail} =
      Conversations.create(
        Ankole.PrincipalsFixtures.actor_fixture(human_uid),
        domain_request(agent.uid)
      )

    id = detail.conversation.id
    model_id = detail.model_conversation_id
    native_message = {:conversation_event, id, :message}
    native_status = {:session_event, agent.uid, detail.session_id, :status}
    signal = Repo.get_by!(Ankole.Signals.Signal, session_id: detail.session_id)

    completed =
      {:session_event, agent.uid, detail.session_id, {:turn_completed, signal.id, :silent}}

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
      completed
    ]

    request =
      stream_request(conn, id)

    request = %{
      request
      | adapter: {StreamAdapter, %{owner: self(), events: events, chunks_left: 4}}
    }

    assert %Plug.Conn{state: :chunked} = @endpoint.call(request, @endpoint.init([]))

    assert_receive {:stream_headers, 200, headers}
    assert {"cache-control", "private, no-store"} in headers
    assert {"x-accel-buffering", "no"} in headers

    assert Enum.any?(headers, fn {key, value} ->
             key == "content-type" and String.starts_with?(value, "text/event-stream")
           end)

    assert_receive {:stream_frame, initial}
    assert sse_payload(initial, "connected") == %{"conversationID" => id}
    assert sse_payload(initial, "activity")["agentUID"] == agent.uid
    assert_receive {:stream_frame, started}

    assert %{
             "agentUID" => agent_uid,
             "conversationID" => ^id,
             "sessionID" => session,
             "responseID" => ^response_id,
             "signalIDs" => [signal_id],
             "text" => "hello\nworld"
           } = sse_payload(started, "reasoning_delta")

    assert agent_uid == agent.uid and session == detail.session_id and signal_id == signal.id

    assert %{
             "agentUID" => ^agent_uid,
             "agentName" => name,
             "conversationID" => ^id,
             "sessionID" => ^session,
             "responseID" => ^response_id,
             "signalIDs" => [^signal_id],
             "turnStartedAt" => turn_started
           } = sse_payload(started, "started")

    assert name == agent.display_name
    assert {:ok, _, _} = DateTime.from_iso8601(turn_started)
    assert_receive {:stream_frame, changed}

    assert sse_payload(changed, "delta") == %{
             "agentUID" => agent.uid,
             "conversationID" => id,
             "sessionID" => detail.session_id,
             "responseID" => response_id,
             "signalIDs" => [signal.id],
             "text" => "hello\nworld"
           }

    assert sse_payload(changed, "conversation") == %{"conversationID" => id}
    assert_receive {:stream_frame, status}
    assert sse_payload(status, "conversation") == %{"conversationID" => id}
    assert_receive {:stream_closed, completed}
    assert sse_payload(completed, "conversation") == %{"conversationID" => id}
    refute_receive {:stream_frame, _}
    assert_receive {:unrelated, :must_remain}
    assert_receive ^unrelated_native
    assert_receive ^unrelated_gateway

    :ok =
      Ankole.Conversations.Events.publish_message(id)

    refute_receive ^native_message
    :ok = Ankole.Sessions.Events.publish_status(agent.uid, detail.session_id)
    refute_receive ^native_status

    Phoenix.PubSub.local_broadcast(
      Ankole.PubSub,
      "ai_gateway:subject:#{agent.uid}:conversation:#{model_id}",
      {:ai_gateway_event, :response_started, gateway}
    )

    refute_receive {:ai_gateway_event, :response_started, ^gateway}
  end

  for revoked <- [:authentication, :principal] do
    @tag revoked: revoked
    test "revoking #{revoked} stops disclosure of queued stream output", %{
      conn: conn,
      revoked: revoked
    } do
      {:ok, true} =
        Ankole.AppConfigure.put_global(Ankole.Setup.Config.completed_definition(), true)

      human = human_fixture().principal
      human_uid = human.uid

      authenticated_conn = conn |> Plug.Test.init_test_session(%{}) |> WebSession.ensure_browser()

      {:ok, %{browser: browser, authentication: auth}} =
        Ankole.BrowserSessions.authenticate(
          WebSession.browser_reference(authenticated_conn),
          :pod,
          %{
            "principal_uid" => human_uid,
            "access_version" => human.access_version,
            "provider_id" => "lark-main",
            "external_id" => "external-human"
          }
        )

      authenticated_conn = WebSession.put_authentication(authenticated_conn, browser, auth)

      agent = agent_fixture().principal
      Ankole.ConversationsFixtures.grant_chat(human_uid, agent.uid)

      {:ok, detail} =
        Conversations.create(
          Ankole.PrincipalsFixtures.actor_fixture(human_uid),
          domain_request(agent.uid)
        )

      signal = Repo.get_by!(Ankole.Signals.Signal, session_id: detail.session_id)

      gateway = %{
        subject_uid: agent.uid,
        conversation_id: detail.model_conversation_id,
        response_id: "resp_" <> Ecto.UUID.generate(),
        metadata: %{"signal_id" => signal.id},
        payload: %{text: "This queued text must stay private."}
      }

      browser_ref = WebSession.browser_reference(authenticated_conn)
      authentication_ref = WebSession.authentication_reference(authenticated_conn)

      revoke = fn ->
        result =
          case revoked do
            :authentication -> Ankole.BrowserSessions.revoke(browser_ref, authentication_ref)
            :principal -> disable_principal_fixture(human_uid)
          end

        assert {:ok, _} = result
      end

      request = %{
        stream_request(authenticated_conn, detail.conversation.id)
        | adapter:
            {StreamAdapter,
             %{
               owner: self(),
               events: [{:ai_gateway_event, :output_text_delta, gateway}],
               chunks_left: 5,
               after_chunk: revoke
             }}
      }

      assert %Plug.Conn{state: :chunked} = @endpoint.call(request, @endpoint.init([]))
      assert_receive {:stream_frame, initial}
      assert sse_payload(initial, "connected") == %{"conversationID" => detail.conversation.id}
      assert_receive {:stream_frame, revoked}

      assert sse_payload(revoked, "access_revoked") == %{
               "conversationID" => detail.conversation.id,
               "reason" => "access_revoked"
             }

      refute revoked =~ "This queued text must stay private."
      refute_receive {:stream_frame, _}
      refute_receive {:stream_closed, _}
    end
  end

  test "a stream that joins after started receives the future delta with its Signal inputs", %{
    conn: conn
  } do
    {authenticated_conn, human_uid} = active_admin_conn_with_principal(conn)
    agent = agent_fixture().principal
    Ankole.ConversationsFixtures.grant_chat(human_uid, agent.uid)

    {:ok, detail} =
      Conversations.create(
        Ankole.PrincipalsFixtures.actor_fixture(human_uid),
        domain_request(agent.uid)
      )

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
      stream_request(authenticated_conn, detail.conversation.id)
      | adapter:
          {StreamAdapter,
           %{
             owner: self(),
             events: [
               {:ai_gateway_event, :output_text_delta, gateway},
               {:session_event, agent.uid, detail.session_id, :status},
               {:ai_gateway_event, :response_completed, gateway}
             ],
             chunks_left: 2
           }}
    }

    assert %Plug.Conn{state: :chunked} = @endpoint.call(conn, @endpoint.init([]))
    assert_receive {:stream_frame, initial}
    assert sse_payload(initial, "connected") == %{"conversationID" => detail.conversation.id}
    assert_receive {:stream_frame, changed}

    assert sse_payload(changed, "delta") == %{
             "agentUID" => agent.uid,
             "conversationID" => detail.conversation.id,
             "sessionID" => detail.session_id,
             "responseID" => response_id,
             "signalIDs" => [signal.id],
             "text" => "future tail"
           }

    assert_receive {:stream_closed, completed}
    assert sse_payload(completed, "conversation") == %{"conversationID" => detail.conversation.id}
  end

  @tag timeout: 25_000
  test "an idle stream sends its next ping after 15 seconds and detects a closed connection", %{
    conn: conn
  } do
    {authenticated_conn, human_uid} = active_admin_conn_with_principal(conn)
    agent = agent_fixture().principal
    Ankole.ConversationsFixtures.grant_chat(human_uid, agent.uid)

    {:ok, detail} =
      Conversations.create(
        Ankole.PrincipalsFixtures.actor_fixture(human_uid),
        domain_request(agent.uid)
      )

    conn = %{
      stream_request(authenticated_conn, detail.conversation.id)
      | adapter: {StreamAdapter, %{owner: self(), events: [], chunks_left: 1}}
    }

    started_at = System.monotonic_time(:millisecond)
    assert %Plug.Conn{state: :chunked} = @endpoint.call(conn, @endpoint.init([]))
    assert System.monotonic_time(:millisecond) - started_at >= 15_000
    assert_receive {:stream_frame, initial}
    assert sse_payload(initial, "connected") == %{"conversationID" => detail.conversation.id}
    assert_receive {:stream_closed, ": ping\n\n"}
  end

  defp sse_payload(packet, name) do
    prefix = "event: #{name}\ndata: "

    frame =
      packet |> String.split("\n\n", trim: true) |> Enum.find(&String.starts_with?(&1, prefix))

    assert is_binary(frame), "missing #{name} in #{inspect(packet)}"
    frame |> String.replace_prefix(prefix, "") |> Ankole.JSON.decode!()
  end

  defp stream_request(authenticated, id) do
    request =
      Plug.Test.conn(
        :get,
        AnkoleWeb.Plugs.RequestHost.origin(authenticated) <>
          "/api/v2/pod/conversations/#{id}/events"
      )
      |> Plug.Test.init_test_session(get_session(authenticated))
      |> put_req_header("accept", "text/event-stream")

    Enum.reduce(authenticated.resp_cookies, request, fn {name, cookie}, request ->
      Plug.Test.put_req_cookie(request, name, cookie.value)
    end)
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
