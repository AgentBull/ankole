defmodule Ankole.Pod.GuestStreamIntegrationTest do
  use Ankole.DataCase, async: false

  import Plug.Conn

  alias Ankole.{AppConfigure, BrowserSessions, Conversations}
  alias AnkoleWeb.{Session, SessionCookies}

  @moduletag sandbox: false

  test "closing guest admission stops an open authenticated HTTP stream before its next event", %{
    tenant: tenant
  } do
    AppConfigure.Cache.clear_for_test()
    {:ok, true} = AppConfigure.put_global(Ankole.Setup.Config.completed_definition(), true)
    guest = Ankole.PrincipalsFixtures.human_fixture(%{membership: :guest}).principal
    agent = Ankole.PrincipalsFixtures.agent_fixture(%{}).principal
    Ankole.ConversationsFixtures.grant_chat(guest.uid, agent.uid)

    {:ok, detail} =
      Ankole.ConversationsFixtures.create(guest.uid, %{
        conversation_id: Ecto.UUID.generate(),
        message_id: Ecto.UUID.generate(),
        agent_uid: agent.uid,
        text: "A guest conversation"
      })

    on_exit(fn ->
      Repo.with_tenant(tenant.id, fn ->
        :ok = Ankole.PrincipalsFixtures.delete_agent_fixture_rows(agent.uid)
        cleanup_tenant!(tenant)
      end)
    end)

    origin = AnkoleWeb.PodURL.origin(AnkoleWeb.ConnCase.build_conn(), tenant)
    cookie = login_cookie(origin, guest)

    server =
      start_supervised!(
        {Bandit, plug: AnkoleWeb.Endpoint, scheme: :http, ip: {127, 0, 0, 1}, port: 0}
      )

    {:ok, {_, port}} = ThousandIsland.listener_info(server)
    {:ok, socket} = :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false])
    on_exit(fn -> :gen_tcp.close(socket) end)
    path = "/api/v2/pod/conversations/#{detail.conversation.id}/events"
    :ok = :gen_tcp.send(socket, request(origin, path, cookie))

    initial = receive_until(socket, "event: activity")
    assert initial =~ "HTTP/1.1 200"
    assert initial =~ "text/event-stream"

    {:ok, false} = AppConfigure.put_tenant_by_key("pod.allow_external_guests", false)
    :ok = Conversations.Events.publish_status(detail.conversation.id)

    final = receive_closed(socket)
    refute final =~ "event: status"
    refute final =~ "event: delta"

    {:ok, rejected} = :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false])
    on_exit(fn -> :gen_tcp.close(rejected) end)
    :ok = :gen_tcp.send(rejected, request(origin, path, cookie))
    denied = receive_closed(rejected)
    assert denied =~ "HTTP/1.1 403"
    assert denied =~ "forbidden"
    refute denied =~ "text/event-stream"
  end

  defp login_cookie(origin, principal) do
    conn =
      Plug.Test.conn(:get, origin)
      |> Map.put(:secret_key_base, AnkoleWeb.Endpoint.config(:secret_key_base))
      |> SessionCookies.call([])
      |> fetch_session()

    {:ok, conn, flow} = Session.begin_login(conn, :pod, %{})
    {:ok, _} = BrowserSessions.bind_provider(Session.browser_reference(conn), flow.id, "local")

    {:ok, conn, _} =
      Session.complete_login(conn, flow.id, %{
        "principal_uid" => principal.uid,
        "access_version" => principal.access_version,
        "provider_id" => "local",
        "external_id" => principal.uid
      })

    conn
    |> send_resp(200, "")
    |> Map.fetch!(:resp_cookies)
    |> Enum.map_join("; ", fn {name, value} -> name <> "=" <> value.value end)
  end

  defp request(origin, path, cookie) do
    authority = URI.parse(origin).authority

    "GET #{path} HTTP/1.1\r\nHost: #{authority}\r\nCookie: #{cookie}\r\nConnection: close\r\n\r\n"
  end

  defp receive_until(socket, expected, bytes \\ "") do
    if String.contains?(bytes, expected) do
      bytes
    else
      assert {:ok, next} = :gen_tcp.recv(socket, 0, 5000)
      receive_until(socket, expected, bytes <> next)
    end
  end

  defp receive_closed(socket, bytes \\ "") do
    case :gen_tcp.recv(socket, 0, 5000) do
      {:ok, next} -> receive_closed(socket, bytes <> next)
      {:error, :closed} -> bytes
      result -> flunk("The HTTP stream did not close: #{inspect(result)}")
    end
  end
end
