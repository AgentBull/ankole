defmodule AnkoleWeb.PodSpreadsheetChannelTest do
  use AnkoleWeb.ChannelCase, async: false
  use Oban.Testing, repo: Ankole.Repo
  import Ankole.PrincipalsFixtures
  alias Ankole.{BrowserSessions, Repo}
  alias Ankole.Pod.{Files, Spreadsheets}
  alias Ankole.Pod.Jobs.CompactSpreadsheet
  alias AnkoleWeb.{PodPageChannel, PodSocket}

  setup do
    owner = human_fixture(%{display_name: "Owner Name"}).principal
    editor = human_fixture(%{display_name: "Editor Name"}).principal

    {:ok, page} =
      Spreadsheets.create_blank(actor_fixture(owner.uid), %{private_owner_uid: owner.uid})

    {:ok, _} =
      Ankole.Pod.PagesFixtures.set_sharing(owner.uid, page.id, %{
        grants: [%{principal_uid: editor.uid, role: "edit"}]
      })

    %{owner: owner, editor: editor, page: page}
  end

  defp set(cell, input),
    do: %{"type" => "cell.set", "sheet_id" => 1, "cell" => cell, "input" => input}

  defp join_sheet(principal, page) do
    {:ok, _reply, socket} =
      subscribe_and_join(authenticated_socket(principal), PodPageChannel, "page:#{page.id}")

    assert_push "presence_state", _presence, 1_000
    socket
  end

  test "editors apply operations, receive each other's commits, and catch up by revision", ctx do
    owner = join_sheet(ctx.owner, ctx.page)
    editor = join_sheet(ctx.editor, ctx.page)

    ref =
      push(owner, "sheet:apply", %{
        "base_revision" => 1,
        "client_id" => "owner-tab",
        "client_seq" => 1,
        "op" => set("A1", "季度预算")
      })

    assert_reply ref, :ok, %{revision: 2, acknowledged_revision: 2, changes: [own]}, 1_000

    assert %{
             "revision" => 2,
             "kind" => "op",
             "client_id" => "owner-tab",
             "op" => %{"cell" => "A1"}
           } = own

    assert_push "sheet:changes",
                %{revision: 2, reset_required: false, changes: [%{"client_id" => "owner-tab"}]},
                1_000

    ref =
      push(editor, "sheet:apply", %{
        "base_revision" => 1,
        "client_id" => "editor-tab",
        "client_seq" => 1,
        "op" => %{
          "type" => "line.insert",
          "sheet_id" => 1,
          "axis" => "rows",
          "at" => 0,
          "count" => 1
        }
      })

    assert_reply ref,
                 :ok,
                 %{revision: 3, acknowledged_revision: 3, changes: [_missed, _own]},
                 1_000

    ref = push(editor, "sheet:sync", %{"revision" => 1})

    assert_reply ref,
                 :ok,
                 %{
                   revision: 3,
                   reset_required: false,
                   changes: [%{"revision" => 2}, %{"revision" => 3}]
                 },
                 1_000

    assert {:ok, %{ops: [_, _]}} =
             Spreadsheets.bootstrap(actor_fixture(ctx.editor.uid), ctx.page.id)
  end

  test "a conflicting operation replies with the reason, revision, and missed changes", ctx do
    owner = join_sheet(ctx.owner, ctx.page)

    delete = %{
      "type" => "line.delete",
      "sheet_id" => 1,
      "axis" => "rows",
      "at" => 0,
      "count" => 4
    }

    ref =
      push(owner, "sheet:apply", %{
        "base_revision" => 1,
        "client_id" => "owner-tab",
        "client_seq" => 1,
        "op" => delete
      })

    assert_reply ref, :ok, %{revision: 2}, 1_000

    ref =
      push(owner, "sheet:apply", %{
        "base_revision" => 1,
        "client_id" => "owner-tab",
        "client_seq" => 2,
        "op" => set("A2", "lost")
      })

    assert_reply ref, :error, reply, 1_000

    # The reply crosses the socket as JSON.
    assert %{
             "reason" => "spreadsheet_conflict",
             "details" => %{
               "reason" => "target_deleted",
               "revision" => 2,
               "changes" => [%{"revision" => 2, "op" => %{"type" => "line.delete"}}]
             }
           } = reply |> Ankole.JSON.encode!() |> Ankole.JSON.decode!()
  end

  test "a viewer receives live cells but cannot edit or access spreadsheet versions", ctx do
    viewer = human_fixture(%{display_name: "Forecast Reviewer"}).principal

    {:ok, _} =
      Ankole.Pod.PagesFixtures.set_sharing(ctx.owner.uid, ctx.page.id, %{
        grants: [%{principal_uid: viewer.uid, role: "view"}]
      })

    owner = join_sheet(ctx.owner, ctx.page)
    reader = join_sheet(viewer, ctx.page)
    actor = actor_fixture(viewer.uid)
    assert {:ok, %{revision: 1}} = Spreadsheets.bootstrap(actor, ctx.page.id)

    ref =
      push(owner, "sheet:apply", %{
        "base_revision" => 1,
        "client_id" => "owner-tab",
        "client_seq" => 1,
        "op" => set("B2", "12500")
      })

    assert_reply ref, :ok, %{revision: 2}, 1_000
    ref = push(reader, "sheet:sync", %{"revision" => 1})

    assert_reply ref,
                 :ok,
                 %{revision: 2, changes: [%{"op" => %{"cell" => "B2", "input" => "12500"}}]},
                 1_000

    ref =
      push(reader, "sheet:apply", %{
        "base_revision" => 2,
        "client_id" => "viewer-tab",
        "client_seq" => 1,
        "op" => set("B2", "0")
      })

    assert_reply ref, :error, %{reason: "forbidden"}, 1_000
    assert {:error, :forbidden} = Spreadsheets.versions(actor, ctx.page.id)
    {:ok, [version]} = Spreadsheets.versions(actor_fixture(ctx.owner.uid), ctx.page.id)
    assert {:error, :forbidden} = Spreadsheets.restore(actor, ctx.page.id, version.id)
    assert {:ok, %{revision: 2}} = Spreadsheets.bootstrap(actor, ctx.page.id)
  end

  test "selections travel through presence and the last editor to leave wakes compaction", ctx do
    owner = join_sheet(ctx.owner, ctx.page)

    {:ok, _reply, editor} =
      subscribe_and_join(authenticated_socket(ctx.editor), PodPageChannel, "page:#{ctx.page.id}")

    assert_push "presence_state", presence, 1_000

    owner_uid = ctx.owner.uid

    assert %{metas: [%{name: "Owner Name", principal_uid: ^owner_uid, selection: nil}]} =
             presence[owner_uid]

    selection = %{"sheet_id" => 1, "active_cell" => "B2", "editing" => true}
    ref = push(owner, "sheet:presence", %{"selection" => selection})
    assert_reply ref, :ok, _reply, 1_000

    assert_push "presence_diff",
                %{joins: %{^owner_uid => %{metas: [%{selection: ^selection}]}}},
                1_000

    ref = push(owner, "sheet:presence", %{"selection" => String.duplicate("x", 5_000)})
    assert_reply ref, :error, %{reason: "invalid_request"}, 1_000

    ref =
      push(owner, "sheet:presence", %{"selection" => %{"text" => String.duplicate("x", 5_000)}})

    assert_reply ref, :error, %{reason: "invalid_request"}, 1_000

    ref =
      push(editor, "sheet:apply", %{
        "base_revision" => 1,
        "client_id" => "editor-tab",
        "client_seq" => 1,
        "op" => set("A1", "pending")
      })

    assert_reply ref, :ok, %{revision: 2}, 1_000
    args = %{"page_id" => ctx.page.id, "tenant_id" => Repo.tenant_id!()}
    [idle] = all_enqueued(worker: CompactSpreadsheet, args: args)
    assert DateTime.diff(idle.scheduled_at, DateTime.utc_now()) > 10

    Process.unlink(editor.channel_pid)
    editor_ref = Process.monitor(editor.channel_pid)
    leave(editor)
    assert_receive {:DOWN, ^editor_ref, :process, _, _}, 1_000
    [still_idle] = all_enqueued(worker: CompactSpreadsheet, args: args)
    assert DateTime.diff(still_idle.scheduled_at, DateTime.utc_now()) > 10

    assert Ankole.Eventually.eventually(fn ->
             map_size(AnkoleWeb.PodPresence.list("page:#{ctx.page.id}")) == 1
           end)

    Process.unlink(owner.channel_pid)
    owner_ref = Process.monitor(owner.channel_pid)
    leave(owner)
    assert_receive {:DOWN, ^owner_ref, :process, _, _}, 1_000
    [due] = all_enqueued(worker: CompactSpreadsheet, args: args)
    assert DateTime.diff(due.scheduled_at, DateTime.utc_now()) <= 1
  end

  test "an open file channel follows uploads into and out of spreadsheet editing", ctx do
    actor = actor_fixture(ctx.owner.uid)
    {:ok, page} = Ankole.Pod.Pages.create(actor, %{type: :file, private_owner_uid: ctx.owner.uid})

    {:ok, _reply, socket} =
      subscribe_and_join(authenticated_socket(ctx.owner), PodPageChannel, "page:#{page.id}")

    refute_push "presence_state", _presence, 100
    {:ok, %{xlsx_bytes: bytes}} = Ankole.Kernel.spreadsheet_create_blank("Forecast")
    assert {:ok, _} = Files.upload(actor, page.id, "file", nil, "Forecast.xlsx", bytes)
    assert_push "presence_state", _presence, 1_000
    assert_push "changes", %{revision: 1}, 1_000
    assert_push "sheet:changes", %{revision: 1, reset_required: true}, 1_000

    selection = %{"sheet_id" => 1, "active_cell" => "B2", "editing" => true}
    ref = push(socket, "sheet:presence", %{"selection" => selection})
    assert_reply ref, :ok, _reply, 1_000

    ref =
      push(socket, "sheet:apply", %{
        "base_revision" => 1,
        "client_id" => "upload-tab",
        "client_seq" => 1,
        "op" => set("B2", "12500")
      })

    assert_reply ref, :ok, %{revision: 2}, 1_000
    {:ok, %{files: [%{object_id: object_id}]}} = Files.manifest(actor, page.id)

    assert {:ok, _} =
             Files.upload(actor, page.id, "file", object_id, "Forecast.csv", "Budget\n12500")

    assert_push "changes", %{revision: 3}, 1_000
    assert Process.alive?(socket.channel_pid)

    assert Ankole.Eventually.eventually(fn ->
             AnkoleWeb.PodPresence.list("page:#{page.id}") == %{}
           end)

    ref = push(socket, "sheet:sync", %{"revision" => 2})
    assert_reply ref, :error, %{reason: "invalid_request"}, 1_000

    {:ok, %{files: [%{object_id: object_id}]}} = Files.manifest(actor, page.id)
    assert {:ok, _} = Files.upload(actor, page.id, "file", object_id, "Revised.xlsx", bytes)
    assert_push "presence_state", _presence, 1_000
    assert_push "sheet:changes", %{revision: 4, reset_required: true}, 1_000
    ref = push(socket, "sheet:presence", %{"selection" => selection})
    assert_reply ref, :ok, _reply, 1_000
  end

  test "documents and other files keep their events and reject spreadsheet events", ctx do
    {:ok, doc} = Ankole.Pod.Pages.create(actor_fixture(ctx.owner.uid), %{})

    {:ok, _reply, socket} =
      subscribe_and_join(authenticated_socket(ctx.owner), PodPageChannel, "page:#{doc.id}")

    assert_push "presence_state", _presence, 1_000
    ref = push(socket, "sheet:apply", %{"base_revision" => 0})
    assert_reply ref, :error, %{reason: "invalid_request"}, 1_000
    ref = push(socket, "sheet:presence", %{"selection" => nil})
    assert_reply ref, :error, %{reason: "invalid_request"}, 1_000

    {:ok, pdf} =
      Files.create_from_upload(
        actor_fixture(ctx.owner.uid),
        %{private_owner_uid: ctx.owner.uid},
        "report.pdf",
        "%PDF report",
        "application/pdf"
      )

    {:ok, _reply, file} =
      subscribe_and_join(authenticated_socket(ctx.owner), PodPageChannel, "page:#{pdf.id}")

    refute_push "presence_state", _presence, 100
    ref = push(file, "sheet:sync", %{"revision" => 0})
    assert_reply ref, :error, %{reason: "invalid_request"}, 1_000
    Ankole.Pod.Pages.broadcast(pdf.id)
    object_id = pdf.object_id
    assert_push "changes", %{revision: 0, object_id: ^object_id, changes: []}, 1_000
  end

  defp authenticated_socket(principal) do
    token = socket_token(principal)
    {:ok, tenant} = Ankole.Tenants.get(Repo.tenant_id!())
    origin = AnkoleWeb.PodURL.origin(%{scheme: :http, port: 80}, tenant)

    {:ok, socket} =
      connect(PodSocket, %{"token" => token, "ip" => "10.0.0.1"},
        connect_info: %{uri: URI.parse(origin), peer_data: %{address: {127, 0, 0, 1}}}
      )

    socket
  end

  defp socket_token(principal) do
    {:ok, browser} = BrowserSessions.create()

    {:ok, %{authentication: auth}} =
      BrowserSessions.authenticate(BrowserSessions.reference(browser), %{
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
