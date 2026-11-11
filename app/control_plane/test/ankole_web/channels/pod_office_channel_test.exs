defmodule AnkoleWeb.PodOfficeChannelTest do
  use AnkoleWeb.ChannelCase, async: false
  use Oban.Testing, repo: Ankole.Repo
  import Ankole.PrincipalsFixtures
  alias Ankole.{BrowserSessions, Repo}
  alias Ankole.Pod.{Files, OfficeFiles}
  alias Ankole.Pod.Jobs.CompactOfficeFile
  alias AnkoleWeb.{PodPageChannel, PodSocket}

  setup do
    owner = human_fixture(%{display_name: "Owner Name"}).principal
    editor = human_fixture(%{display_name: "Editor Name"}).principal

    {:ok, page} =
      OfficeFiles.create_blank(actor_fixture(owner.uid), %{
        format: :spreadsheet,
        private_owner_uid: owner.uid
      })

    {:ok, _} =
      Ankole.Pod.PagesFixtures.set_sharing(owner.uid, page.id, %{
        grants: [%{principal_uid: editor.uid, role: "edit"}]
      })

    %{owner: owner, editor: editor, page: page}
  end

  defp set(cell, input),
    do: %{"type" => "cell.set", "sheet_id" => 1, "cell" => cell, "input" => input}

  defp join_office(principal, page) do
    {:ok, _reply, socket} =
      subscribe_and_join(authenticated_socket(principal), PodPageChannel, "page:#{page.id}")

    assert_push "presence_state", _presence, 1_000
    socket
  end

  test "editors apply operations, receive each other's commits, and catch up by revision", ctx do
    owner = join_office(ctx.owner, ctx.page)
    editor = join_office(ctx.editor, ctx.page)

    ref =
      push(owner, "office:apply", %{
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

    assert_push "office:changes",
                %{revision: 2, reset_required: false, changes: [%{"client_id" => "owner-tab"}]},
                1_000

    ref =
      push(editor, "office:apply", %{
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

    ref = push(editor, "office:sync", %{"revision" => 1})

    assert_reply ref,
                 :ok,
                 %{
                   revision: 3,
                   reset_required: false,
                   changes: [%{"revision" => 2}, %{"revision" => 3}]
                 },
                 1_000

    assert {:ok, %{ops: [_, _]}} =
             OfficeFiles.bootstrap(actor_fixture(ctx.editor.uid), ctx.page.id)
  end

  test "a conflicting operation replies with office_conflict, revision, and missed changes",
       ctx do
    owner = join_office(ctx.owner, ctx.page)

    delete = %{
      "type" => "line.delete",
      "sheet_id" => 1,
      "axis" => "rows",
      "at" => 0,
      "count" => 4
    }

    ref =
      push(owner, "office:apply", %{
        "base_revision" => 1,
        "client_id" => "owner-tab",
        "client_seq" => 1,
        "op" => delete
      })

    assert_reply ref, :ok, %{revision: 2}, 1_000

    ref =
      push(owner, "office:apply", %{
        "base_revision" => 1,
        "client_id" => "owner-tab",
        "client_seq" => 2,
        "op" => set("A2", "lost")
      })

    assert_reply ref, :error, reply, 1_000

    # The reply crosses the socket as JSON.
    assert %{
             "reason" => "office_conflict",
             "details" => %{
               "reason" => "target_deleted",
               "revision" => 2,
               "changes" => [%{"revision" => 2, "op" => %{"type" => "line.delete"}}]
             }
           } = reply |> Ankole.JSON.encode!() |> Ankole.JSON.decode!()
  end

  test "a viewer receives live updates and viewing presence, but cannot edit or claim editing mode",
       ctx do
    viewer = human_fixture(%{display_name: "Forecast Reviewer"}).principal

    {:ok, _} =
      Ankole.Pod.PagesFixtures.set_sharing(ctx.owner.uid, ctx.page.id, %{
        grants: [%{principal_uid: viewer.uid, role: "view"}]
      })

    owner = join_office(ctx.owner, ctx.page)
    reader = join_office(viewer, ctx.page)
    actor = actor_fixture(viewer.uid)
    assert {:ok, %{revision: 1}} = OfficeFiles.bootstrap(actor, ctx.page.id)

    ref =
      push(owner, "office:apply", %{
        "base_revision" => 1,
        "client_id" => "owner-tab",
        "client_seq" => 1,
        "op" => set("B2", "12500")
      })

    assert_reply ref, :ok, %{revision: 2}, 1_000
    ref = push(reader, "office:sync", %{"revision" => 1})

    assert_reply ref,
                 :ok,
                 %{revision: 2, changes: [%{"op" => %{"cell" => "B2", "input" => "12500"}}]},
                 1_000

    # Even if a viewer passes editing: true, Presence mode stays "viewing".
    viewer_uid = viewer.uid

    ref =
      push(reader, "office:presence", %{
        "selection" => %{"sheet_id" => 1, "range" => "B2", "editing" => true}
      })

    assert_reply ref, :ok, _reply, 1_000

    assert_push "presence_diff",
                %{joins: %{^viewer_uid => %{metas: [%{mode: "viewing"}]}}},
                1_000

    ref =
      push(reader, "office:apply", %{
        "base_revision" => 2,
        "client_id" => "viewer-tab",
        "client_seq" => 1,
        "op" => set("B2", "0")
      })

    assert_reply ref, :error, %{reason: "forbidden"}, 1_000
    assert {:error, :forbidden} = OfficeFiles.versions(actor, ctx.page.id)
    {:ok, [version]} = OfficeFiles.versions(actor_fixture(ctx.owner.uid), ctx.page.id)
    assert {:error, :forbidden} = OfficeFiles.restore(actor, ctx.page.id, version.id)
    assert {:ok, %{revision: 2}} = OfficeFiles.bootstrap(actor, ctx.page.id)
  end

  test "selections distinguish viewing vs editing soft locks and the last editor to leave wakes compaction",
       ctx do
    owner = join_office(ctx.owner, ctx.page)

    {:ok, _reply, editor} =
      subscribe_and_join(authenticated_socket(ctx.editor), PodPageChannel, "page:#{ctx.page.id}")

    assert_push "presence_state", presence, 1_000

    owner_uid = ctx.owner.uid

    assert %{
             metas: [
               %{name: "Owner Name", principal_uid: ^owner_uid, selection: nil, mode: "viewing"}
             ]
           } =
             presence[owner_uid]

    # Navigation without local draft advertises mode: "viewing".
    viewing_sel = %{"sheet_id" => 1, "range" => "A1"}
    ref = push(owner, "office:presence", %{"selection" => viewing_sel})
    assert_reply ref, :ok, _reply, 1_000

    assert_push "presence_diff",
                %{
                  joins: %{^owner_uid => %{metas: [%{selection: ^viewing_sel, mode: "viewing"}]}}
                },
                1_000

    # Active uncommitted draft advertises mode: "editing" soft lock.
    editing_sel = %{"sheet_id" => 1, "active_cell" => "B2", "editing" => true}
    ref = push(owner, "office:presence", %{"selection" => editing_sel})
    assert_reply ref, :ok, _reply, 1_000

    assert_push "presence_diff",
                %{
                  joins: %{^owner_uid => %{metas: [%{selection: ^editing_sel, mode: "editing"}]}}
                },
                1_000

    ref = push(owner, "office:presence", %{"selection" => String.duplicate("x", 5_000)})
    assert_reply ref, :error, %{reason: "invalid_request"}, 1_000

    ref =
      push(owner, "office:presence", %{"selection" => %{"text" => String.duplicate("x", 5_000)}})

    assert_reply ref, :error, %{reason: "invalid_request"}, 1_000

    ref =
      push(editor, "office:apply", %{
        "base_revision" => 1,
        "client_id" => "editor-tab",
        "client_seq" => 1,
        "op" => set("A1", "pending")
      })

    assert_reply ref, :ok, %{revision: 2}, 1_000
    args = %{"page_id" => ctx.page.id, "tenant_id" => Repo.tenant_id!()}
    [idle] = all_enqueued(worker: CompactOfficeFile, args: args)
    assert DateTime.diff(idle.scheduled_at, DateTime.utc_now()) > 10

    Process.unlink(editor.channel_pid)
    editor_ref = Process.monitor(editor.channel_pid)
    leave(editor)
    assert_receive {:DOWN, ^editor_ref, :process, _, _}, 1_000
    [still_idle] = all_enqueued(worker: CompactOfficeFile, args: args)
    assert DateTime.diff(still_idle.scheduled_at, DateTime.utc_now()) > 10

    assert Ankole.Eventually.eventually(fn ->
             map_size(AnkoleWeb.PodPresence.list("page:#{ctx.page.id}")) == 1
           end)

    Process.unlink(owner.channel_pid)
    owner_ref = Process.monitor(owner.channel_pid)
    leave(owner)
    assert_receive {:DOWN, ^owner_ref, :process, _, _}, 1_000
    [due] = all_enqueued(worker: CompactOfficeFile, args: args)
    assert DateTime.diff(due.scheduled_at, DateTime.utc_now()) <= 1
  end

  test "an open file channel follows uploads across spreadsheet, word, presentation, and plain files",
       ctx do
    actor = actor_fixture(ctx.owner.uid)
    {:ok, page} = Ankole.Pod.Pages.create(actor, %{type: :file, private_owner_uid: ctx.owner.uid})

    {:ok, _reply, socket} =
      subscribe_and_join(authenticated_socket(ctx.owner), PodPageChannel, "page:#{page.id}")

    refute_push "presence_state", _presence, 100
    {:ok, %{bytes: xlsx_bytes}} = Ankole.Kernel.office_create_blank(:spreadsheet, "Forecast")
    assert {:ok, _} = Files.upload(actor, page.id, "file", nil, "Forecast.xlsx", xlsx_bytes)
    assert_push "presence_state", _presence, 1_000
    assert_push "changes", %{revision: 1}, 1_000
    assert_push "office:changes", %{revision: 1, reset_required: true}, 1_000

    selection = %{"sheet_id" => 1, "active_cell" => "B2", "editing" => true}
    ref = push(socket, "office:presence", %{"selection" => selection})
    assert_reply ref, :ok, _reply, 1_000

    ref =
      push(socket, "office:apply", %{
        "base_revision" => 1,
        "client_id" => "upload-tab",
        "client_seq" => 1,
        "op" => set("B2", "12500")
      })

    assert_reply ref, :ok, %{revision: 2}, 1_000

    # Replacing with a Word file keeps Office Presence active and pushes a reset!
    {:ok, %{files: [%{object_id: object_id}]}} = Files.manifest(actor, page.id)
    {:ok, %{bytes: docx_bytes}} = Ankole.Kernel.office_create_blank(:word, "Proposal")
    assert {:ok, _} = Files.upload(actor, page.id, "file", object_id, "Proposal.docx", docx_bytes)
    assert_push "changes", %{revision: 3}, 1_000
    assert_push "office:changes", %{revision: 3, reset_required: true}, 1_000

    # Replacing with a CSV leaves Office mode and clears Presence.
    {:ok, %{files: [%{object_id: object_id}]}} = Files.manifest(actor, page.id)

    assert {:ok, _} =
             Files.upload(actor, page.id, "file", object_id, "Forecast.csv", "Budget\n12500")

    assert_push "changes", %{revision: 4}, 1_000
    assert Process.alive?(socket.channel_pid)

    assert Ankole.Eventually.eventually(fn ->
             AnkoleWeb.PodPresence.list("page:#{page.id}") == %{}
           end)

    ref = push(socket, "office:sync", %{"revision" => 3})
    assert_reply ref, :error, %{reason: "invalid_request"}, 1_000

    {:ok, %{files: [%{object_id: object_id}]}} = Files.manifest(actor, page.id)
    {:ok, %{bytes: pptx_bytes}} = Ankole.Kernel.office_create_blank(:presentation, "Deck")
    assert {:ok, _} = Files.upload(actor, page.id, "file", object_id, "Deck.pptx", pptx_bytes)
    assert_push "presence_state", _presence, 1_000
    assert_push "office:changes", %{revision: 5, reset_required: true}, 1_000
    ref = push(socket, "office:presence", %{"selection" => %{"slide_id" => 1, "editing" => true}})
    assert_reply ref, :ok, _reply, 1_000
  end

  test "documents and other files keep their events and reject office events", ctx do
    {:ok, doc} = Ankole.Pod.Pages.create(actor_fixture(ctx.owner.uid), %{})

    {:ok, _reply, socket} =
      subscribe_and_join(authenticated_socket(ctx.owner), PodPageChannel, "page:#{doc.id}")

    assert_push "presence_state", _presence, 1_000
    ref = push(socket, "office:apply", %{"base_revision" => 0})
    assert_reply ref, :error, %{reason: "invalid_request"}, 1_000
    ref = push(socket, "office:presence", %{"selection" => nil})
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
    ref = push(file, "office:sync", %{"revision" => 0})
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
