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

  test "content join and unchanged checks stay quiet while tree, metadata, and access changes are distinct",
       ctx do
    Process.flag(:trap_exit, true)
    owner = actor_fixture(ctx.owner.uid)
    {:ok, parent} = Pages.create(owner, %{})

    assert {:ok, %{}, socket} =
             subscribe_and_join(authenticated_socket(ctx.reader), PodContentChannel, "content")

    refute_push "access_changed", %{}, 100
    send(socket.channel_pid, :periodic_access)
    refute_push "access_changed", %{}, 100

    {:ok, child} = Pages.create(owner, %{parent_id: parent.id})
    parent_id = parent.id
    child_id = child.id

    assert_push "tree_changed",
                %{
                  directories: [%{parent_id: ^parent_id}],
                  parents: [%{id: ^parent_id, has_children: true}],
                  page_id: ^child_id
                },
                1_000

    refute_push "access_changed", %{}, 100

    {:ok, _} = Pages.update(owner, child.id, %{title: "Renamed", expected_title: child.title})
    assert_push "page_updated", %{id: ^child_id, title: "Renamed"}, 1_000
    refute_push "tree_changed", _, 100

    {:ok, _} =
      Ankole.Pod.PagesFixtures.set_sharing(ctx.owner.uid, parent.id, %{
        inherit_permissions: false,
        grants: [%{principal_uid: ctx.reader.uid, role: "view"}]
      })

    assert_push "access_changed", %{}, 1_000
    refute_push "access_changed", %{}, 100
    send(socket.channel_pid, :periodic_access)
    refute_push "access_changed", %{}, 100

    grant =
      Repo.get_by!(Ankole.AuthZ.Grant,
        principal_uid: ctx.reader.uid,
        target_node_id: parent.id,
        action: "node_view"
      )

    Repo.update!(Ecto.Changeset.change(grant, condition: "false"))
    send(socket.channel_pid, :periodic_access)
    assert_push "access_changed", %{}, 1_000
    send(socket.channel_pid, :periodic_access)
    refute_push "access_changed", %{}, 100
  end

  test "the content subscription closes when its authenticated account loses admission", ctx do
    assert {:ok, %{}, socket} =
             subscribe_and_join(authenticated_socket(ctx.reader), PodContentChannel, "content")

    reference = Process.monitor(socket.channel_pid)
    assert {:ok, _} = disable_principal_fixture(ctx.reader.uid)
    send(socket.channel_pid, :periodic_access)
    assert_push "access_revoked", %{}, 1_000
    assert_receive {:DOWN, ^reference, :process, _, :normal}, 1_000
  end

  test "trashing and restoring a Userset source refreshes access to dependent directories", ctx do
    owner = actor_fixture(ctx.owner.uid)
    reader = actor_fixture(ctx.reader.uid)
    {:ok, source_parent} = Pages.create(owner, %{title: "Sources"})
    {:ok, source} = Pages.create(owner, %{parent_id: source_parent.id})
    {:ok, target_parent} = Pages.create(owner, %{title: "Dependent directory"})
    {:ok, target} = Pages.create(owner, %{parent_id: target_parent.id})

    {:ok, _} =
      Ankole.Pod.PagesFixtures.set_sharing(ctx.owner.uid, target.id, %{
        inherit_permissions: false,
        grants: [%{source_node_id: source.id, source_action: "node_view", role: "view"}]
      })

    assert {:ok, %{pages: [%{id: target_id}]}} = Pages.list_children(reader, target_parent.id)
    assert target_id == target.id

    assert {:ok, %{}, socket} =
             subscribe_and_join(authenticated_socket(ctx.reader), PodContentChannel, "content")

    assert {:ok, _} = Pages.delete(owner, source.id)
    assert_push "access_changed", %{}, 1_000
    assert {:ok, %{pages: []}} = Pages.list_children(reader, target_parent.id)
    send(socket.channel_pid, :periodic_access)
    refute_push "access_changed", %{}, 100

    assert {:ok, _} = Pages.restore(owner, source.id)
    assert_push "access_changed", %{}, 1_000
    assert {:ok, %{pages: [%{id: ^target_id}]}} = Pages.list_children(reader, target_parent.id)
    send(socket.channel_pid, :periodic_access)
    refute_push "access_changed", %{}, 100
  end

  test "room changes coalesce and background Session status refreshes the sidebar", ctx do
    assert {:ok, %{}, _socket} =
             subscribe_and_join(authenticated_socket(ctx.reader), PodContentChannel, "content")

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

  test "Userset grant writes publish access changes even when the reader's context is unchanged",
       ctx do
    owner = actor_fixture(ctx.owner.uid)
    reader = actor_fixture(ctx.reader.uid)
    {:ok, source} = Pages.create(owner, %{})
    {:ok, target} = Pages.create(owner, %{})

    {:ok, _} =
      Ankole.Pod.PagesFixtures.set_sharing(ctx.owner.uid, target.id, %{
        inherit_permissions: false,
        grants: []
      })

    assert {:ok, %{}, socket} =
             subscribe_and_join(authenticated_socket(ctx.reader), PodContentChannel, "content")

    assert {:ok, grant} =
             Ankole.AuthZ.create_permission_grant(%{
               source_node_id: source.id,
               source_action: "node_view",
               resource_pattern: "drive:**:#{target.id}:node",
               target_node_id: target.id,
               target_scope: "self",
               action: "node_view"
             })

    assert_push "access_changed", %{}, 1_000
    assert {:ok, _} = Pages.authorize(reader, target.id, "node_view")
    assert {:ok, _} = Ankole.AuthZ.delete_permission_grant(grant.id)
    assert_push "access_changed", %{}, 1_000
    assert {:error, :forbidden} = Pages.authorize(reader, target.id, "node_view")
    send(socket.channel_pid, :periodic_access)
    refute_push "access_changed", %{}, 100
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
        resource_pattern: "drive:**:#{page.id}:node",
        target_node_id: page.id,
        target_scope: "self",
        action: "node_view",
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
    for type <- ["doc", "applet", "base"] do
      {:ok, page} =
        Pages.create(Ankole.PrincipalsFixtures.actor_fixture(ctx.owner.uid), %{
          type: type,
          private_owner_uid: ctx.owner.uid
        })

      {:ok, grant} =
        Ankole.AuthZ.create_permission_grant(%{
          principal_uid: ctx.reader.uid,
          resource_pattern: "drive:**:#{page.id}:node",
          target_node_id: page.id,
          target_scope: "self",
          action: "node_view",
          condition:
            ~s(context.request.ip == "10.0.0.1" && context.request.surface == "pod_browser")
        })

      {channel, topic} =
        case type do
          "doc" ->
            {PodPageChannel, "page:#{page.id}"}

          "applet" ->
            {PodRoomChannel, "applet:#{page.id}:restricted"}

          "base" ->
            {:ok, table} =
              Ankole.Pod.Bases.create_table(
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
        "changes" => [2]
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

  test "comment changes refresh connected readers independently of document revisions", ctx do
    actor = actor_fixture(ctx.owner)
    {:ok, page} = Pages.create(actor, %{private_owner_uid: ctx.owner.uid})

    {:ok, _} =
      Ankole.Pod.PagesFixtures.set_sharing(ctx.owner.uid, page.id, %{
        grants: [%{principal_uid: ctx.reader.uid, role: "view"}]
      })

    {:ok, _, socket} =
      subscribe_and_join(authenticated_socket(ctx.reader), PodPageChannel, "page:#{page.id}")

    {:ok, %{comment: root, revision: 0}} =
      Ankole.Pod.Comments.create(actor, page.id, %{body: "Review the whole page"})

    assert_push "comments_changed", %{}, 1_000

    {:ok, %{comment: updated, revision: 0}} =
      Ankole.Pod.Comments.update(actor, page.id, root.id, %{
        body: "Clarified",
        version: root.version
      })

    assert_push "comments_changed", %{}, 1_000

    assert {:error, :comment_conflict} =
             Ankole.Pod.Comments.resolve(actor, page.id, root.id, %{
               resolved: true,
               version: root.version
             })

    refute_push "comments_changed", %{}, 50

    {:ok, %{comment: resolved, revision: 0}} =
      Ankole.Pod.Comments.resolve(actor, page.id, root.id, %{
        resolved: true,
        version: updated.version
      })

    assert_push "comments_changed", %{}, 1_000

    {:ok, %{revision: 0}} =
      Ankole.Pod.Comments.delete(actor, page.id, root.id, %{version: resolved.version})

    assert_push "comments_changed", %{}, 1_000

    grant =
      Repo.get_by!(Ankole.AuthZ.Grant,
        principal_uid: ctx.reader.uid,
        target_node_id: page.id,
        action: "node_view"
      )

    Repo.delete!(grant)
    reference = Process.monitor(socket.channel_pid)
    send(socket.channel_pid, {:comments_committed, page.id})
    assert_push "access_revoked", %{}, 1_000
    assert_receive {:DOWN, ^reference, :process, _, :normal}, 1_000
    refute_push "comments_changed", %{}, 50
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

    grant =
      Repo.get_by!(Ankole.AuthZ.Grant,
        principal_uid: ctx.reader.uid,
        target_node_id: page.id,
        action: "node_view"
      )

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

  test "runtime and Pod file writes refresh the same open page, and rollback stays silent", ctx do
    alias Ankole.Files
    agent = agent_fixture().principal
    actor = actor_fixture(agent)
    file = Ankole.FilesFixtures.drive_file_fixture(agent.uid, "shared.txt", "original")

    {:ok, _} =
      Ankole.Pod.PagesFixtures.set_sharing(agent.uid, file.id, %{
        grants: [%{principal_uid: ctx.reader.uid, role: "view"}]
      })

    {:ok, before} = Pages.fetch(file.id)

    assert {:ok, _, _socket} =
             subscribe_and_join(
               authenticated_socket(ctx.reader),
               PodPageChannel,
               "page:#{file.id}"
             )

    {:ok, stored} = Files.store("path write")

    assert {:ok, %{files: [written]}} =
             Files.commit(agent.uid, [Map.put(stored, :path, "shared.txt")])

    object_id = written.object_id
    assert_push "changes", %{object_id: ^object_id}, 1_000

    assert {:ok, %{pages: [version]}} =
             Pages.reconcile_versions(actor_fixture(ctx.reader), [file.id], [])

    assert version.object_id == object_id
    assert version.revision == before.revision

    assert {:ok, node_write} = Files.write_node(actor, file.id, "node write")
    object_id = node_write.object_id
    assert_push "changes", %{object_id: ^object_id}, 1_000

    assert {:ok, uploaded} =
             Ankole.Pod.Files.upload(
               actor,
               file.id,
               "file",
               object_id,
               "shared.txt",
               "Pod upload"
             )

    object_id = uploaded.file.object_id
    assert_push "changes", %{object_id: ^object_id}, 1_000

    {:ok, pending} = Files.store("rolled back")

    assert {:error, :cancelled} =
             Repo.transact_top_level(fn ->
               assert {:ok, _} = Files.commit_node_object_in_tx(actor, file.id, pending)
               {:error, :cancelled}
             end)

    refute_push "changes", _, 100
    assert {:ok, %{object_id: ^object_id}} = Files.fetch_node(file.id)
  end

  test "applet revision notifications use the same authorized socket", ctx do
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

  test "document presence identifies principals and validates revisioned selections", ctx do
    {:ok, page} = Pages.create(actor_fixture(ctx.owner.uid), %{})

    {:ok, joined, writer} =
      subscribe_and_join(authenticated_socket(ctx.owner), PodPageChannel, "page:#{page.id}")

    {:ok, _, _reader} =
      subscribe_and_join(authenticated_socket(ctx.reader), PodPageChannel, "page:#{page.id}")

    uid = ctx.owner.uid
    name = ctx.owner.display_name
    session = joined.presence_session
    assert_push "presence_state", _, 1_000
    selection = %{"revision" => 0, "anchor" => 1, "head" => 1}

    reference =
      push(writer, "presence", %{
        "selection" => selection,
        "principal_uid" => ctx.reader.uid,
        "name" => "Forged"
      })

    assert_reply reference, :ok, _, 1_000

    assert_push "presence_diff",
                %{
                  joins: %{
                    ^uid => %{
                      metas: [
                        %{
                          name: ^name,
                          session_id: ^session,
                          selection: ^selection,
                          mode: "editing"
                        }
                        | _
                      ]
                    }
                  }
                },
                1_000

    ref = push(writer, "presence", %{"selection" => %{selection | "revision" => 10}})
    assert_reply ref, :ok, %{stale: true}, 1_000
    ref = push(writer, "presence", %{"selection" => %{selection | "anchor" => -1}})
    assert_reply ref, :error, %{reason: "invalid_request"}, 1_000
    ref = push(writer, "presence", %{"selection" => nil})
    assert_reply ref, :ok, _, 1_000

    assert_push "presence_diff",
                %{joins: %{^uid => %{metas: [%{selection: nil, mode: "viewing"} | _]}}},
                1_000
  end

  test "document presence distinguishes sessions and closes a revoked recipient", ctx do
    Process.flag(:trap_exit, true)
    {:ok, page} = Pages.create(actor_fixture(ctx.owner.uid), %{})

    {:ok, first, writer} =
      subscribe_and_join(authenticated_socket(ctx.owner), PodPageChannel, "page:#{page.id}")

    {:ok, second, _same_person} =
      subscribe_and_join(authenticated_socket(ctx.owner), PodPageChannel, "page:#{page.id}")

    refute first.presence_session == second.presence_session

    {:ok, _, reader} =
      subscribe_and_join(authenticated_socket(ctx.reader), PodPageChannel, "page:#{page.id}")

    monitor = Process.monitor(reader.channel_pid)

    {:ok, _} =
      Ankole.Pod.PagesFixtures.set_sharing(ctx.owner.uid, page.id, %{
        inherit_permissions: false,
        grants: []
      })

    send(reader.channel_pid, :recheck_access)
    assert_push "access_revoked", %{}, 1_000
    assert_receive {:DOWN, ^monitor, :process, _, :normal}, 1_000

    reference =
      push(writer, "presence", %{"selection" => %{"revision" => 0, "anchor" => 1, "head" => 1}})

    assert_reply reference, :ok, _, 1_000
  end

  test "document presence reflects an editor becoming a viewer without losing their selection",
       ctx do
    {:ok, page} = Pages.create(actor_fixture(ctx.owner.uid), %{})

    {:ok, _, viewer} =
      subscribe_and_join(authenticated_socket(ctx.reader), PodPageChannel, "page:#{page.id}")

    uid = ctx.reader.uid
    selection = %{"revision" => 0, "anchor" => 1, "head" => 1}
    reference = push(viewer, "presence", %{"selection" => selection})
    assert_reply reference, :ok, _, 1_000

    assert_push "presence_diff",
                %{joins: %{^uid => %{metas: [%{selection: ^selection, mode: "editing"} | _]}}},
                1_000

    {:ok, _} =
      Ankole.Pod.PagesFixtures.set_sharing(ctx.owner.uid, page.id, %{
        inherit_permissions: false,
        grants: [%{principal_uid: uid, role: "view"}]
      })

    send(viewer.channel_pid, :recheck_access)

    assert_push "presence_diff",
                %{joins: %{^uid => %{metas: [%{selection: ^selection, mode: "viewing"} | _]}}},
                1_000

    reference = push(viewer, "presence", %{"selection" => selection})
    assert_reply reference, :ok, _, 1_000
  end

  test "empty OT change arrays are rejected and trashing an Applet blocks applet rooms while keeping page preview",
       ctx do
    actor = actor_fixture(ctx.owner.uid)
    {:ok, doc} = Pages.create(actor, %{})

    {:ok, _, doc_socket} =
      subscribe_and_join(authenticated_socket(ctx.owner), PodPageChannel, "page:#{doc.id}")

    empty_edit =
      push(doc_socket, "changes", %{
        "base_revision" => 0,
        "client_id" => "owner",
        "client_seq" => 1,
        "changes" => []
      })

    assert_reply empty_edit, :error, %{reason: "invalid_request", details: nil}, 1_000

    {:ok, applet} = Pages.create(actor, %{type: "applet"})

    {:ok, _, applet_room} =
      subscribe_and_join(
        authenticated_socket(ctx.owner),
        PodRoomChannel,
        "applet:#{applet.id}:lobby"
      )

    {:ok, _, applet_page} =
      subscribe_and_join(authenticated_socket(ctx.owner), PodPageChannel, "page:#{applet.id}")

    room_ref = Process.monitor(applet_room.channel_pid)
    {:ok, _} = Pages.delete(actor, applet.id)

    assert_push "access_revoked", %{}, 1_000
    assert_receive {:DOWN, ^room_ref, :process, _, :normal}, 1_000
    assert Process.alive?(applet_page.channel_pid)

    assert {:error, %{reason: "not_found"}} =
             subscribe_and_join(
               authenticated_socket(ctx.owner),
               PodRoomChannel,
               "applet:#{applet.id}:lobby"
             )
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

    {:ok, %{authentication: auth}} =
      BrowserSessions.authenticate(browser_ref, %{
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
