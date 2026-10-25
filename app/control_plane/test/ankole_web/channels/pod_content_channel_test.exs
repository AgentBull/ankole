defmodule AnkoleWeb.PodContentChannelTest do
  use AnkoleWeb.ChannelCase, async: false
  import Ankole.PrincipalsFixtures
  alias Ankole.{BrowserSessions, Repo}
  alias Ankole.Pod.{Documents, Pages}
  alias AnkoleWeb.{PodContentChannel, PodPageChannel, PodRoomChannel, PodSocket}

  setup do
    owner = human_fixture().principal
    reader = human_fixture().principal
    %{owner: owner, reader: reader}
  end

  test "the content subscription refreshes after join and committed tree or policy changes",
       ctx do
    Process.flag(:trap_exit, true)

    assert {:ok, %{}, socket} =
             subscribe_and_join(authenticated_socket(ctx.reader), PodContentChannel, "content")

    assert_push "changed", %{}, 1_000

    assert {:ok, page} = Pages.create(Ankole.PrincipalsFixtures.actor_fixture(ctx.owner.uid), %{})
    assert_push "changed", %{}, 1_000

    assert {:ok, _} =
             Ankole.Pod.PagesFixtures.set_sharing(ctx.owner.uid, page.id, %{
               grants: [%{principal_uid: ctx.reader.uid, role: "view"}]
             })

    assert_push "changed", %{}, 1_000
    send(socket.channel_pid, :periodic_access)
    assert_push "changed", %{}, 1_000

    reference = Process.monitor(socket.channel_pid)
    leave(socket)
    assert_receive {:DOWN, ^reference, :process, _, {:shutdown, :left}}, 1_000

    assert {:ok, %{}, _socket} =
             subscribe_and_join(authenticated_socket(ctx.reader), PodContentChannel, "content")

    assert_push "changed", %{}, 1_000
  end

  test "the content subscription closes when its authenticated account loses admission", ctx do
    assert {:ok, %{}, socket} =
             subscribe_and_join(authenticated_socket(ctx.reader), PodContentChannel, "content")

    assert_push "changed", %{}, 1_000
    reference = Process.monitor(socket.channel_pid)
    assert {:ok, _} = disable_principal_fixture(ctx.reader.uid)
    send(socket.channel_pid, :periodic_access)
    assert_push "access_revoked", %{}, 1_000
    assert_receive {:DOWN, ^reference, :process, _, :normal}, 1_000
  end

  test "room changes coalesce and background Session status refreshes the sidebar", ctx do
    assert {:ok, %{}, _socket} =
             subscribe_and_join(authenticated_socket(ctx.reader), PodContentChannel, "content")

    assert_push "changed", %{}, 1_000
    for _ <- 1..10, do: Ankole.Conversations.Events.publish_rooms_changed()
    refute_push "conversations_changed", %{}, 100
    assert_push "conversations_changed", %{}, 2_000
    refute_push "conversations_changed", %{}, 100

    Ankole.Sessions.Events.publish_status(
      "background-room-agent",
      "conversation:" <> Ash.UUIDv7.generate()
    )

    assert_push "conversations_changed", %{}, 2_000
  end

  test "a Pod socket proof is valid only on its tenant host", ctx do
    token = socket_token(ctx.owner)
    {:ok, tenant} = Ankole.Tenants.get(Repo.tenant_id!())
    own_origin = AnkoleWeb.PodURL.origin(%{scheme: :http, port: 80}, tenant)
    foreign = Ankole.DataCase.create_tenant()
    origin = AnkoleWeb.PodURL.origin(%{scheme: :http, port: 80}, foreign)

    assert :error = connect(PodSocket, %{"token" => token})

    assert :error =
             connect(PodSocket, %{"token" => token}, connect_info: %{uri: URI.parse(own_origin)})

    assert :error =
             connect(PodSocket, %{"token" => token},
               connect_info: %{uri: URI.parse(origin), peer_data: %{address: {127, 0, 0, 1}}}
             )
  end

  test "socket client IP follows the endpoint's existing ingress trust policy", ctx do
    token = socket_token(ctx.owner)
    {:ok, tenant} = Ankole.Tenants.get(Repo.tenant_id!())
    origin = AnkoleWeb.PodURL.origin(%{scheme: :http, port: 80}, tenant)

    assert {:ok, socket} =
             connect(PodSocket, %{"token" => token, "ip" => "192.0.2.1"},
               connect_info: %{
                 uri: URI.parse(origin),
                 peer_data: %{address: {10, 0, 0, 2}},
                 x_headers: [{"x-forwarded-for", "10.0.0.1"}]
               }
             )

    expected =
      if Application.fetch_env!(:ankole, :edition) == :saas, do: "10.0.0.1", else: "10.0.0.2"

    assert socket.assigns.actor.authn["ip"] == expected
    assert socket.assigns.actor.authn["surface"] == "pod_browser"

    {:ok, page} =
      Pages.create(Ankole.PrincipalsFixtures.actor_fixture(ctx.owner.uid), %{
        private_owner_uid: ctx.owner.uid
      })

    {:ok, _} =
      Ankole.AuthZ.create_permission_grant(%{
        principal_uid: ctx.reader.uid,
        resource_pattern: "pod:**:#{page.id}:page",
        action: "page_view",
        condition: ~s(context.request.ip == "10.0.0.1")
      })

    reader_token = socket_token(ctx.reader)

    {:ok, reader} =
      connect(PodSocket, %{"token" => reader_token},
        connect_info: %{
          uri: URI.parse(origin),
          peer_data: %{address: {10, 0, 0, 2}},
          x_headers: [{"x-forwarded-for", "10.0.0.1"}]
        }
      )

    if Application.fetch_env!(:ankole, :edition) == :saas do
      assert {:ok, _, _} = subscribe_and_join(reader, PodPageChannel, "page:#{page.id}")
    else
      assert {:error, %{reason: "not_found"}} =
               subscribe_and_join(reader, PodPageChannel, "page:#{page.id}")
    end
  end

  test "page and room authorization use trusted socket peer IP for joins and later checks", ctx do
    for type <- ["doc", "applet", "database"] do
      {:ok, page} =
        Pages.create(Ankole.PrincipalsFixtures.actor_fixture(ctx.owner.uid), %{
          type: type,
          private_owner_uid: ctx.owner.uid
        })

      {:ok, grant} =
        Ankole.AuthZ.create_permission_grant(%{
          principal_uid: ctx.reader.uid,
          resource_pattern: "pod:**:#{page.id}:page",
          action: "page_view",
          condition:
            ~s(context.request.ip == "10.0.0.1" && context.request.surface == "pod_browser")
        })

      {channel, topic} =
        case type do
          "doc" ->
            {PodPageChannel, "page:#{page.id}"}

          "applet" ->
            {PodRoomChannel, "applet:#{page.id}:restricted"}

          "database" ->
            {:ok, table} =
              Ankole.Pod.Database.create_table(
                Ankole.PrincipalsFixtures.actor_fixture(ctx.owner.uid),
                page.id,
                %{name: "Records"}
              )

            {PodRoomChannel, "table:#{table.id}"}
        end

      assert {:error, %{reason: "not_found"}} =
               subscribe_and_join(authenticated_socket(ctx.reader, {10, 0, 0, 2}), channel, topic)

      assert {:ok, _, socket} =
               subscribe_and_join(authenticated_socket(ctx.reader, {10, 0, 0, 1}), channel, topic)

      if type == "doc" do
        ref = push(socket, "sync", %{"revision" => 0})
        assert_reply ref, :ok, %{revision: 0}, 1_000

        assert {:ok, _} =
                 Documents.write(
                   Ankole.PrincipalsFixtures.actor_fixture(ctx.owner.uid),
                   page.id,
                   0,
                   "<page><p>context</p></page>"
                 )

        assert_push "changes", %{revision: 1}, 1_000
      end

      if type == "applet" do
        ref = push(socket, "broadcast", %{"event" => "cursor", "payload" => 1})
        assert_reply ref, :ok, %{}, 1_000
        send(socket.channel_pid, {:room_event, "conditional", %{value: 1}})
        assert_push "conditional", %{value: 1}, 1_000
      end

      send(socket.channel_pid, :periodic_access)
      refute_push "access_revoked", %{}, 50

      {:ok, _} =
        Ankole.AuthZ.update_permission_grant(grant.id, %{
          condition: ~s(context.request.ip == "10.0.0.2")
        })

      send(socket.channel_pid, :periodic_access)
      assert_push "access_revoked", %{}, 1_000
    end
  end

  test "a connected reader is removed immediately when the page share is revoked", ctx do
    {:ok, page} =
      Pages.create(Ankole.PrincipalsFixtures.actor_fixture(ctx.owner.uid), %{
        private_owner_uid: ctx.owner.uid
      })

    {:ok, _} =
      Ankole.Pod.PagesFixtures.set_sharing(ctx.owner.uid, page.id, %{
        grants: [%{principal_uid: ctx.reader.uid, role: "view"}]
      })

    socket = authenticated_socket(ctx.reader)
    assert {:ok, _, socket} = subscribe_and_join(socket, PodPageChannel, "page:#{page.id}")

    edit =
      push(socket, "changes", %{
        "base_revision" => 0,
        "client_id" => "reader",
        "client_seq" => 1,
        "changes" => []
      })

    assert_reply edit, :error, %{reason: "forbidden", details: nil}, 1_000
    sync = push(socket, "sync", %{"revision" => 0})
    assert_reply sync, :ok, %{revision: 0}, 1_000
    reference = Process.monitor(socket.channel_pid)
    {:ok, _} = Ankole.Pod.PagesFixtures.set_sharing(ctx.owner.uid, page.id, %{grants: []})
    assert_push "access_revoked", %{}, 1_000
    assert_receive {:DOWN, ^reference, :process, _, :normal}, 1_000

    assert {:ok, _} =
             Documents.write(
               Ankole.PrincipalsFixtures.actor_fixture(ctx.owner.uid),
               page.id,
               0,
               "<page><p>private</p></page>"
             )

    refute_push "changes", _
  end

  test "periodic checks catch account revocation outside the page sharing API", ctx do
    {:ok, page} = Pages.create(Ankole.PrincipalsFixtures.actor_fixture(ctx.owner.uid), %{})
    socket = authenticated_socket(ctx.reader)
    assert {:ok, _, socket} = subscribe_and_join(socket, PodPageChannel, "page:#{page.id}")
    reference = Process.monitor(socket.channel_pid)
    {:ok, _} = disable_principal_fixture(ctx.reader.uid)
    send(socket.channel_pid, :periodic_access)
    assert_push "access_revoked", %{}, 1_000
    assert_receive {:DOWN, ^reference, :process, _, :normal}, 1_000
  end

  test "an incoming document request detects a removed view grant before the periodic check",
       ctx do
    {:ok, page} =
      Pages.create(Ankole.PrincipalsFixtures.actor_fixture(ctx.owner.uid), %{
        private_owner_uid: ctx.owner.uid
      })

    {:ok, _} =
      Ankole.Pod.PagesFixtures.set_sharing(ctx.owner.uid, page.id, %{
        grants: [%{principal_uid: ctx.reader.uid, role: "view"}]
      })

    assert {:ok, _, socket} =
             subscribe_and_join(
               authenticated_socket(ctx.reader),
               PodPageChannel,
               "page:#{page.id}"
             )

    reference = Process.monitor(socket.channel_pid)
    grant = Repo.get_by!(Ankole.AuthZ.Grant, principal_uid: ctx.reader.uid, action: "page_view")
    Repo.delete!(grant)
    push(socket, "sync", %{"revision" => 0})
    assert_push "access_revoked", %{}, 1_000
    assert_receive {:DOWN, ^reference, :process, _, :normal}, 1_000
  end

  test "document join and changes encode through the production JSON boundary", ctx do
    {:ok, page} = Pages.create(Ankole.PrincipalsFixtures.actor_fixture(ctx.owner.uid), %{})

    assert {:ok, joined, _socket} =
             subscribe_and_join(
               authenticated_socket(ctx.reader),
               PodPageChannel,
               "page:#{page.id}"
             )

    assert %{"page" => %{"type" => "doc", "created_at" => timestamp}} =
             joined |> Ankole.JSON.encode!() |> Ankole.JSON.decode!()

    assert {:ok, _, _} = DateTime.from_iso8601(timestamp)

    assert {:ok, _} =
             Documents.write(
               Ankole.PrincipalsFixtures.actor_fixture(ctx.owner.uid),
               page.id,
               0,
               "<page><p>new</p></page>"
             )

    assert_push "changes", changed, 1_000

    assert %{
             "revision" => 1,
             "reset_required" => false,
             "changes" => [
               %{
                 "kind" => "change",
                 "client_id" => client_id,
                 "client_seq" => 1,
                 "changes" => changes,
                 "created_at" => change_time
               }
             ]
           } =
             changed |> Ankole.JSON.encode!() |> Ankole.JSON.decode!()

    assert client_id == "server:" <> ctx.owner.uid

    assert {:ok, %{xml: "<page><p>new</p></page>"}} =
             Ankole.Kernel.page_apply("<page />", changes)

    assert {:ok, _, _} = DateTime.from_iso8601(change_time)
  end

  test "a second socket receives the committed OT batch without requesting a replay", ctx do
    {:ok, page} = Pages.create(Ankole.PrincipalsFixtures.actor_fixture(ctx.owner.uid), %{})

    {:ok, _, writer} =
      subscribe_and_join(authenticated_socket(ctx.owner), PodPageChannel, "page:#{page.id}")

    {:ok, _, _reader} =
      subscribe_and_join(authenticated_socket(ctx.reader), PodPageChannel, "page:#{page.id}")

    reference =
      push(writer, "changes", %{
        "base_revision" => 0,
        "client_id" => "two-editors",
        "client_seq" => 1,
        "changes" => [
          [1, [%{"remove" => "PagePlaceholder", "value" => nil}]],
          [0, [%{"type" => "Text", "param" => "Shared"}]],
          1
        ]
      })

    assert_reply reference, :ok, %{revision: 1, acknowledged_revision: 1}, 1_000

    assert_push "changes",
                %{
                  revision: 1,
                  changes: [%{"client_id" => "two-editors", "client_seq" => 1}]
                },
                1_000
  end

  test "document rejections expose the same stable domain codes as HTTP", ctx do
    {:ok, page} = Pages.create(Ankole.PrincipalsFixtures.actor_fixture(ctx.owner.uid), %{})

    {:ok, _, document} =
      subscribe_and_join(authenticated_socket(ctx.reader), PodPageChannel, "page:#{page.id}")

    reference = push(document, "changes", %{"base_revision" => 0, "client_seq" => 1})
    assert_reply reference, :error, %{reason: "invalid_request", details: nil}, 1_000
    assert Repo.reload!(page).revision == 0
  end

  test "applet rooms expose current presence without persisting ephemeral broadcasts", ctx do
    {:ok, page} =
      Pages.create(Ankole.PrincipalsFixtures.actor_fixture(ctx.owner.uid), %{type: "applet"})

    topic = "applet:#{page.id}:votes"

    assert {:ok, _, first} =
             subscribe_and_join(authenticated_socket(ctx.owner), PodRoomChannel, topic)

    assert_push "presence_state", first_presence, 1_000
    assert Map.has_key?(first_presence, ctx.owner.uid)

    assert {:ok, _, second} =
             subscribe_and_join(authenticated_socket(ctx.reader), PodRoomChannel, topic)

    assert_push "presence_state", second_presence, 1_000
    assert Map.has_key?(second_presence, ctx.owner.uid)
    assert Map.has_key?(second_presence, ctx.reader.uid)
    ref = push(first, "broadcast", %{"event" => "cursor", "payload" => %{"x" => 17}})
    assert_reply ref, :ok, %{}, 1_000
    assert_push "broadcast", %{event: "cursor", payload: %{"x" => 17}}, 1_000
    assert Repo.aggregate(Ankole.Pod.PageChange, :count) == 0
    leave(second)
  end

  test "Pod settings close an existing guest applet subscription before the periodic check",
       ctx do
    guest = human_fixture(%{membership: :guest}).principal

    {:ok, page} =
      Pages.create(Ankole.PrincipalsFixtures.actor_fixture(ctx.owner.uid), %{type: "applet"})

    {:ok, _} =
      Ankole.Pod.PagesFixtures.set_sharing(ctx.owner.uid, page.id, %{
        grants: [%{principal_uid: guest.uid, role: "view"}]
      })

    {:ok, _, socket} =
      subscribe_and_join(authenticated_socket(guest), PodRoomChannel, "applet:#{page.id}:room")

    assert_push "presence_state", _, 1_000
    monitor = Process.monitor(socket.channel_pid)
    {:ok, settings} = Ankole.Principals.PodAdministration.settings()

    assert {:ok, _} =
             Ankole.Principals.PodAdministration.update_settings(
               Ankole.AuthZ.Actor.new(ctx.owner),
               %{settings | allowExternalGuests: false}
             )

    assert_push "access_revoked", %{}, 1_000
    assert_receive {:DOWN, ^monitor, :process, _, :normal}, 1_000
  end

  test "applet broadcast and presence recipients recheck access before each delivery", ctx do
    for event <- ["broadcast", "presence_diff"] do
      {:ok, true} = Ankole.AppConfigure.put_tenant_by_key("pod.allow_external_guests", true)
      guest = human_fixture(%{membership: :guest}).principal

      {:ok, page} =
        Pages.create(Ankole.PrincipalsFixtures.actor_fixture(ctx.owner.uid), %{type: "applet"})

      {:ok, _} =
        Ankole.Pod.PagesFixtures.set_sharing(ctx.owner.uid, page.id, %{
          grants: [%{principal_uid: guest.uid, role: "view"}]
        })

      topic = "applet:#{page.id}:room"

      {:ok, _, socket} =
        subscribe_and_join(authenticated_socket(guest), PodRoomChannel, topic)

      assert_push "presence_state", _, 1_000
      allowed = %{value: "visible while access is allowed"}
      :ok = AnkoleWeb.Endpoint.broadcast(topic, event, allowed)
      assert_push ^event, ^allowed, 1_000

      monitor = Process.monitor(socket.channel_pid)
      {:ok, false} = Ankole.AppConfigure.put_tenant_by_key("pod.allow_external_guests", false)
      denied = %{value: "must not reach the revoked recipient"}
      :ok = AnkoleWeb.Endpoint.broadcast(topic, event, denied)

      assert_push "access_revoked", %{}, 1_000
      assert_receive {:DOWN, ^monitor, :process, _, :normal}, 1_000
      refute_push ^event, ^denied
    end
  end

  test "file and applet revision notifications use the same authorized socket", ctx do
    {:ok, page} =
      Pages.create(Ankole.PrincipalsFixtures.actor_fixture(ctx.owner.uid), %{type: "applet"})

    assert {:ok, _, _socket} =
             subscribe_and_join(
               authenticated_socket(ctx.reader),
               PodPageChannel,
               "page:#{page.id}"
             )

    Ankole.Pod.PagesFixtures.update_record!(page, :advance_revision, %{
      updated_at: DateTime.utc_now(:microsecond)
    })

    Pages.broadcast(page.id)
    assert_push "changes", %{revision: 1, changes: []}, 1_000
  end

  test "joining another tenant's page is denied", ctx do
    foreign_tenant = Ankole.DataCase.create_tenant()

    foreign =
      Repo.with_tenant(foreign_tenant.id, fn ->
        human = human_fixture().principal
        {:ok, page} = Pages.create(Ankole.PrincipalsFixtures.actor_fixture(human.uid), %{})
        page
      end)

    assert {:error, %{reason: "not_found"}} =
             subscribe_and_join(
               authenticated_socket(ctx.reader),
               PodPageChannel,
               "page:#{foreign.id}"
             )
  end

  test "ephemeral limits cover event names and document channels do not accept unused cursors",
       ctx do
    {:ok, page} =
      Pages.create(Ankole.PrincipalsFixtures.actor_fixture(ctx.owner.uid), %{type: "applet"})

    {:ok, _, room} =
      subscribe_and_join(
        authenticated_socket(ctx.owner),
        PodRoomChannel,
        "applet:#{page.id}:room"
      )

    ref = push(room, "broadcast", %{"event" => String.duplicate("x", 65_536), "payload" => nil})
    assert_reply ref, :error, _, 1_000
    ref = push(room, "broadcast", %{"event" => "cursor", "payload" => 1})
    assert_reply ref, :ok, _, 1_000
    {:ok, doc} = Pages.create(Ankole.PrincipalsFixtures.actor_fixture(ctx.owner.uid), %{})

    {:ok, _, document} =
      subscribe_and_join(authenticated_socket(ctx.owner), PodPageChannel, "page:#{doc.id}")

    ref = push(document, "presence", %{"cursor" => String.duplicate("x", 65_536)})
    assert_reply ref, :error, _, 1_000
    ref = push(document, "presence", %{"cursor" => %{"from" => 1, "to" => 1}})
    assert_reply ref, :error, %{reason: "invalid_request"}, 1_000
  end

  defp authenticated_socket(principal, ip \\ {127, 0, 0, 1}) do
    token = socket_token(principal)
    {:ok, tenant} = Ankole.Tenants.get(Repo.tenant_id!())
    origin = AnkoleWeb.PodURL.origin(%{scheme: :http, port: 80}, tenant)

    {:ok, socket} =
      connect(PodSocket, %{"token" => token, "ip" => "10.0.0.1"},
        connect_info: %{uri: URI.parse(origin), peer_data: %{address: ip}}
      )

    socket
  end

  defp socket_token(principal) do
    {:ok, browser} = BrowserSessions.create()
    browser_ref = BrowserSessions.reference(browser)
    {:ok, flow} = BrowserSessions.begin_login(browser_ref, :pod, %{})
    {:ok, _} = BrowserSessions.bind_provider(browser_ref, flow.id, "lark-main")

    {:ok, %{authentication: auth}} =
      BrowserSessions.complete_login(browser_ref, flow.id, %{
        "principal_uid" => principal.uid,
        "access_version" => principal.access_version,
        "provider_id" => "lark-main",
        "external_id" => principal.uid
      })

    Phoenix.Token.sign(AnkoleWeb.Endpoint, "pod-socket", %{
      tenant_id: Repo.tenant_id!(),
      uid: principal.uid,
      authentication: BrowserSessions.reference(auth)
    })
  end
end
