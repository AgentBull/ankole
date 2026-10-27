defmodule Ankole.Pod.FilesTest do
  use Ankole.DataCase, async: false

  import Ankole.PrincipalsFixtures
  alias Ankole.Files, as: Drive
  alias Ankole.Pod.{Files, Pages}

  setup do
    owner = human_fixture().principal
    reader = human_fixture().principal
    agent = agent_fixture().principal

    {:ok, _} =
      Ankole.AuthZ.create_permission_grant(%{
        principal_uid: owner.uid,
        resource_pattern: "tenant_console:**",
        action: "update"
      })

    %{owner: owner.uid, reader: reader.uid, agent: agent.uid}
  end

  test "file replacement commits its revision with the bytes and refuses stale writers", ctx do
    {:ok, page} =
      Pages.create(Ankole.PrincipalsFixtures.actor_fixture(ctx.owner), %{
        type: "file",
        title: "Report",
        private_owner_uid: ctx.owner
      })

    assert {:ok, first} =
             Files.upload(
               Ankole.PrincipalsFixtures.actor_fixture(ctx.owner),
               page.id,
               "file",
               0,
               "report.pdf",
               "%PDF first",
               "application/pdf"
             )

    assert first.revision == 1

    assert {:error, {:revision_conflict, 1}} =
             Files.upload(
               Ankole.PrincipalsFixtures.actor_fixture(ctx.owner),
               page.id,
               "file",
               0,
               "report.pdf",
               "stale"
             )

    assert {:ok, _, "%PDF first"} =
             Files.read(Ankole.PrincipalsFixtures.actor_fixture(ctx.owner), page.id, "report.pdf")

    assert {:error, :forbidden} =
             Files.read(
               Ankole.PrincipalsFixtures.actor_fixture(ctx.reader),
               page.id,
               "report.pdf"
             )

    assert {:ok, _} =
             Files.upload(
               Ankole.PrincipalsFixtures.actor_fixture(ctx.owner),
               page.id,
               "file",
               1,
               "replacement.pdf",
               "%PDF second"
             )

    assert {:error, :not_found} =
             Files.read(Ankole.PrincipalsFixtures.actor_fixture(ctx.owner), page.id, "report.pdf")

    assert {:ok, %{revision: 2, files: [%{path: "replacement.pdf"}]}} =
             Files.manifest(Ankole.PrincipalsFixtures.actor_fixture(ctx.owner), page.id)
  end

  test "file creation commits its name and bytes together and rolls back a failed destination",
       ctx do
    actor = actor_fixture(ctx.owner)

    assert {:ok, page} =
             Files.create_from_upload(
               actor,
               %{private_owner_uid: ctx.owner},
               "report.pdf",
               "%PDF report",
               "application/pdf"
             )

    assert page.title == "report.pdf"
    assert page.type == :file
    assert page.revision == 1
    assert {:ok, _, "%PDF report"} = Files.read(actor, page.id, "report.pdf")
    assert {:error, :file_too_large} = Files.read(actor, page.id, "report.pdf", nil, max_bytes: 5)
    assert {:ok, _, "%PDF report"} = Files.read(actor, page.id, "report.pdf", nil, max_bytes: 11)

    before = Repo.aggregate(Ankole.Pod.Page, :count)

    assert {:error, _} =
             Files.create_from_upload(
               actor,
               %{parent_id: Ecto.UUID.generate()},
               "failed.pdf",
               "failed",
               "application/pdf"
             )

    assert Repo.aggregate(Ankole.Pod.Page, :count) == before
  end

  test "document assets use their full digest and do not consume document revisions", ctx do
    {:ok, page} =
      Pages.create(Ankole.PrincipalsFixtures.actor_fixture(ctx.owner), %{title: "Images"})

    assert {:ok, %{revision: 0, src: src, file: file}} =
             Files.upload(
               Ankole.PrincipalsFixtures.actor_fixture(ctx.owner),
               page.id,
               "asset",
               nil,
               "photo.png",
               "image bytes",
               "image/png"
             )

    assert src == "ankole:asset/#{file.sha256}/photo.png"
    assert file.path == "assets/#{file.sha256}/photo.png"

    assert {:error, :invalid_file_role} =
             Files.upload(
               Ankole.PrincipalsFixtures.actor_fixture(ctx.owner),
               page.id,
               "file",
               0,
               "bad",
               "bad"
             )

    assert {:error, _} =
             Files.read(
               Ankole.PrincipalsFixtures.actor_fixture(ctx.owner),
               page.id,
               "../elsewhere"
             )
  end

  test "publication is a single authorized manifest with CAS and digest reads", ctx do
    {:ok, page} =
      Pages.create(Ankole.PrincipalsFixtures.actor_fixture(ctx.owner), %{
        type: "applet",
        title: "Tracker"
      })

    {:ok, _} =
      Ankole.Pod.PagesFixtures.set_sharing(ctx.owner, page.id, %{
        grants: [%{principal_uid: ctx.agent, role: "edit"}]
      })

    {:ok, html} = Drive.store("<script src='./app.js'></script>")
    {:ok, js} = Drive.store("exports.provider = {}")

    {:ok, _} =
      Drive.commit(ctx.agent, [
        %{path: "applet/index.html", sha256: html.sha256, source: "agent"},
        %{path: "applet/app.js", sha256: js.sha256, source: "agent"}
      ])

    manifest = [
      %{path: "src/main.tsx", sha256: js.sha256},
      %{path: "dist/index.html", sha256: html.sha256},
      %{path: "dist/app.js", sha256: js.sha256}
    ]

    assert {:ok, %{revision: 1, files: files}} =
             Files.publish(
               Ankole.PrincipalsFixtures.actor_fixture(ctx.agent),
               page.id,
               0,
               manifest
             )

    assert length(files) == 3

    assert {:error, {:revision_conflict, 1}} =
             Files.publish(
               Ankole.PrincipalsFixtures.actor_fixture(ctx.agent),
               page.id,
               0,
               manifest
             )

    assert {:ok, _, "exports.provider = {}"} =
             Files.read(
               Ankole.PrincipalsFixtures.actor_fixture(ctx.reader),
               page.id,
               "dist/app.js",
               js.sha256
             )

    assert {:error, :manifest_changed} =
             Files.read(
               Ankole.PrincipalsFixtures.actor_fixture(ctx.reader),
               page.id,
               "dist/app.js",
               html.sha256
             )

    {:ok, hidden} = Drive.store("another tenant's unshared bytes")
    refute Drive.drive_has_content?(ctx.agent, hidden.sha256)

    {:ok, before_rejection} =
      Files.manifest(Ankole.PrincipalsFixtures.actor_fixture(ctx.owner), page.id)

    bad_manifest = [
      %{path: "src/main.tsx", sha256: js.sha256},
      %{path: "dist/index.html", sha256: hidden.sha256}
    ]

    assert {:error, :unavailable_content} =
             Files.publish(
               Ankole.PrincipalsFixtures.actor_fixture(ctx.agent),
               page.id,
               1,
               bad_manifest
             )

    assert {:ok, ^before_rejection} =
             Files.manifest(Ankole.PrincipalsFixtures.actor_fixture(ctx.owner), page.id)

    replacement = Enum.reject(manifest, &(&1.path == "dist/app.js"))

    assert {:ok, %{revision: 2}} =
             Files.publish(
               Ankole.PrincipalsFixtures.actor_fixture(ctx.agent),
               page.id,
               1,
               replacement
             )

    assert {:error, :manifest_changed} =
             Files.read(
               Ankole.PrincipalsFixtures.actor_fixture(ctx.reader),
               page.id,
               "dist/app.js",
               js.sha256
             )

    assert {:error, :not_found} =
             Files.read(
               Ankole.PrincipalsFixtures.actor_fixture(ctx.reader),
               page.id,
               "dist/app.js"
             )

    local_path = Path.join(System.tmp_dir!(), "missing-applet-#{page.id}")

    assert {:error, :manifest_changed} =
             Files.read_to_file(
               Ankole.PrincipalsFixtures.actor_fixture(ctx.reader),
               page.id,
               "dist/app.js",
               local_path,
               js.sha256
             )

    {:ok, _} = Pages.delete(Ankole.PrincipalsFixtures.actor_fixture(ctx.owner), page.id)

    assert {:error, :not_found} =
             Files.read(
               Ankole.PrincipalsFixtures.actor_fixture(ctx.reader),
               page.id,
               "dist/app.js",
               js.sha256
             )
  end

  test "removing references and trashing keep bytes until the page is purged", ctx do
    {:ok, page} =
      Pages.create(Ankole.PrincipalsFixtures.actor_fixture(ctx.owner), %{title: "Report"})

    {:ok, result} =
      Files.upload(
        Ankole.PrincipalsFixtures.actor_fixture(ctx.owner),
        page.id,
        "asset",
        nil,
        "image.png",
        "persistent"
      )

    {:ok, _} = Pages.delete(Ankole.PrincipalsFixtures.actor_fixture(ctx.owner), page.id)

    assert {:error, :not_found} =
             Files.read(
               Ankole.PrincipalsFixtures.actor_fixture(ctx.owner),
               page.id,
               result.file.path
             )

    assert {:ok, _file} = Drive.fetch(:pod, "pages/#{page.id}/#{result.file.path}")
    {:ok, _} = Pages.restore(Ankole.PrincipalsFixtures.actor_fixture(ctx.owner), page.id)

    assert {:ok, _, "persistent"} =
             Files.read(
               Ankole.PrincipalsFixtures.actor_fixture(ctx.owner),
               page.id,
               result.file.path
             )
  end

  test "a Human saves their actual Agent reply attachment without permission to read the Agent drive",
       ctx do
    {agent, message, attachment} = native_attachment(ctx.reader)
    resource = "agent:#{agent}:files"
    refute Ankole.AuthZ.allowed?(ctx.reader, resource, "read")

    {:ok, page} =
      Pages.create(Ankole.PrincipalsFixtures.actor_fixture(ctx.reader), %{
        type: "file",
        private_owner_uid: ctx.reader
      })

    assert {:ok, %{revision: 1, file: file}} =
             Files.copy_from_message(
               Ankole.PrincipalsFixtures.actor_fixture(ctx.reader),
               page.id,
               0,
               message.id,
               attachment["path"]
             )

    assert file.sha256 == attachment["blob_ref"]

    assert {:ok, _, "committed report bytes"} =
             Files.read(Ankole.PrincipalsFixtures.actor_fixture(ctx.reader), page.id, file.path)

    refute Ankole.AuthZ.allowed?(ctx.reader, resource, "read")

    assert {:ok, saved} =
             Files.create_from_message(actor_fixture(ctx.reader), %{
               type: :file,
               saved_from_message_id: message.id,
               attachment_path: attachment["path"],
               private_owner_uid: ctx.reader
             })

    assert saved.saved_from_message_id == message.id
    assert saved.title == attachment["name"]
    assert saved.revision == 1

    assert {:ok, _, "committed report bytes"} =
             Files.read(actor_fixture(ctx.reader), saved.id, file.path)

    Ankole.FilesFixtures.drive_file_fixture(agent, "private/unshared.txt", "private notes")

    assert {:error, :not_found} =
             Files.copy_from_message(
               Ankole.PrincipalsFixtures.actor_fixture(ctx.reader),
               page.id,
               1,
               message.id,
               "private/unshared.txt"
             )

    assert {:ok, %{revision: 1, files: [_]}} =
             Files.manifest(Ankole.PrincipalsFixtures.actor_fixture(ctx.reader), page.id)
  end

  test "saved message content survives deletion and replacement of its original Agent drive path",
       ctx do
    {agent, message, attachment} = native_attachment(ctx.reader)

    {:ok, page} =
      Pages.create(Ankole.PrincipalsFixtures.actor_fixture(ctx.reader), %{
        type: "file",
        private_owner_uid: ctx.reader
      })

    assert {:ok, 1} = Drive.delete(agent, attachment["path"])
    assert {:error, :not_found} = Drive.fetch(agent, attachment["path"])
    digest = Base.decode16!(attachment["blob_ref"], case: :lower)
    old = DateTime.add(DateTime.utc_now(:microsecond), -2, :day)
    blob = from file in Ankole.Files.Schemas.Blob, where: file.sha256 == ^digest
    Repo.update_all(blob, set: [last_referenced_at: old])
    assert {:ok, 0} = Ankole.Files.Jobs.CollectUnreferenced.mark_unreferenced()
    Repo.update_all(blob, set: [deleting: true])
    assert Ankole.Files.Jobs.CollectUnreferenced.remove_marked(0) == 0
    assert %{deleting: false} = Repo.get!(Ankole.Files.Schemas.Blob, digest)
    assert {:ok, "committed report bytes"} = Drive.read_content(attachment["blob_ref"])

    assert {:ok, %{revision: 1, file: first}} =
             Files.copy_from_message(
               Ankole.PrincipalsFixtures.actor_fixture(ctx.reader),
               page.id,
               0,
               message.id,
               attachment["path"]
             )

    assert {:ok, _, "committed report bytes"} =
             Files.read(Ankole.PrincipalsFixtures.actor_fixture(ctx.reader), page.id, first.path)

    Ankole.FilesFixtures.drive_file_fixture(agent, attachment["path"], "changed after reply")
    assert {:ok, _, "changed after reply"} = Drive.read(agent, attachment["path"])

    assert {:ok, %{revision: 2, file: second}} =
             Files.copy_from_message(
               Ankole.PrincipalsFixtures.actor_fixture(ctx.reader),
               page.id,
               1,
               message.id,
               attachment["path"]
             )

    assert first.sha256 == attachment["blob_ref"]
    assert second.sha256 == first.sha256

    assert {:ok, _, "committed report bytes"} =
             Files.read(Ankole.PrincipalsFixtures.actor_fixture(ctx.reader), page.id, second.path)

    assert {:ok, _} =
             Ankole.Conversations.delete(
               Ankole.PrincipalsFixtures.actor_fixture(ctx.reader),
               message.conversation_id
             )

    Repo.update_all(blob, set: [last_referenced_at: old])
    assert {:ok, 0} = Ankole.Files.Jobs.CollectUnreferenced.mark_unreferenced()
    assert Ankole.Files.Jobs.CollectUnreferenced.remove_marked(0) == 0
    assert {:ok, 1} = Drive.delete(:pod, "pages/#{page.id}")
    assert {:ok, 1} = Ankole.Files.Jobs.CollectUnreferenced.mark_unreferenced()
    assert Ankole.Files.Jobs.CollectUnreferenced.remove_marked(0) == 1
    assert is_nil(Repo.get(Ankole.Files.Schemas.Blob, digest))
    assert {:error, %{"code" => "not_found"}} = Ankole.ObjectStore.read(Drive.object_key(digest))
  end

  test "an unreadable conversation cannot supply an attachment to a writable Page", ctx do
    {_agent, message, attachment} = native_attachment(ctx.owner)

    {:ok, page} =
      Pages.create(Ankole.PrincipalsFixtures.actor_fixture(ctx.reader), %{
        type: "file",
        private_owner_uid: ctx.reader
      })

    assert {:error, :conversation_not_found} =
             Ankole.Conversations.get(
               Ankole.PrincipalsFixtures.actor_fixture(ctx.reader),
               message.conversation_id
             )

    assert {:error, :conversation_not_found} =
             Files.copy_from_message(
               Ankole.PrincipalsFixtures.actor_fixture(ctx.reader),
               page.id,
               0,
               message.id,
               attachment["path"]
             )

    assert {:ok, %{revision: 0, files: []}} =
             Files.manifest(Ankole.PrincipalsFixtures.actor_fixture(ctx.reader), page.id)
  end

  test "purging an Applet removes published backend references with its frontend and source",
       ctx do
    {:ok, page} =
      Pages.create(Ankole.PrincipalsFixtures.actor_fixture(ctx.owner), %{
        type: "applet",
        private_owner_uid: ctx.owner
      })

    manifest =
      Enum.map(
        [
          {"src/main.tsx", "source"},
          {"dist/index.html", "frontend"},
          {"server/main.js", "export default {'GET /':()=>1}"}
        ],
        fn {path, bytes} ->
          {:ok, blob} = Drive.store(bytes)

          {:ok, _} =
            Drive.commit(ctx.owner, [
              %{path: "publish/#{page.id}/#{path}", sha256: blob.sha256, source: "pod"}
            ])

          %{path: path, sha256: blob.sha256}
        end
      )

    {:ok, _} =
      Files.publish(Ankole.PrincipalsFixtures.actor_fixture(ctx.owner), page.id, 0, manifest)

    assert {:ok, _} = Drive.fetch(:pod, "pages/#{page.id}/server/main.js")
    {:ok, _} = Pages.delete(Ankole.PrincipalsFixtures.actor_fixture(ctx.owner), page.id)
    page = Repo.get!(Ankole.Pod.Page, page.id)

    Ankole.Pod.PagesFixtures.update_record!(page, :begin_purge)

    assert :ok = Ankole.Pod.Jobs.PurgePage.run(%Oban.Job{args: %{"page_id" => page.id}})

    for path <- ["src/main.tsx", "dist/index.html", "server/main.js"] do
      assert {:error, :not_found} = Drive.fetch(:pod, "pages/#{page.id}/#{path}")
    end

    refute Repo.get(Ankole.Pod.Page, page.id)
  end

  defp native_attachment(human) do
    %{principal: agent} = Ankole.SessionsCase.agent_fixture(%{owner_principal_uid: human})
    conversation_id = Ankole.Kernel.gen_uuid_v7()

    {:ok, _} =
      Ankole.AuthZ.create_permission_grant(%{
        principal_uid: human,
        resource_pattern: "agent:#{agent.uid}",
        action: "chat"
      })

    {:ok, _} =
      Ankole.ConversationsFixtures.create(human, %{
        conversation_id: conversation_id,
        agent_uid: agent.uid,
        message_id: Ankole.Kernel.gen_uuid_v7(),
        text: "Produce a report attachment"
      })

    event = Repo.get_by!(Ankole.Signals.Signal, conversation_id: conversation_id)
    key = %{agent_uid: agent.uid, session_id: event.session_id}
    {:ok, run} = Ankole.Sessions.Admission.admit(key, event)
    {:ok, {:preparing, run}} = Ankole.Sessions.Model.prepare(run)

    attachment =
      Ankole.FilesFixtures.sent_attachment_fixture(
        agent.uid,
        "report.pdf",
        "committed report bytes",
        "application/pdf"
      )

    {:ok, response} =
      Ankole.AIGatewayCase.start_response_run(%{
        subject_uid: run.agent_uid,
        conversation_id: run.conversation.id,
        round_state: run,
        metadata: %{"request_metadata" => Ankole.Sessions.Run.metadata(run)}
      })

    {:ok, response} =
      Ankole.AIGateway.ResponseCommit.commit_complete(response, [
        %{
          "type" => "function_call",
          "name" => "reply_attachment",
          "call_id" => "attachment",
          "arguments" => "{}"
        },
        %{
          "type" => "function_call_output",
          "call_id" => "attachment",
          "output" =>
            Torque.encode!(%{"tool" => "reply_attachment", "attachments" => [attachment]})
        }
      ])

    {:ok, %{posted: %{messages: [message]}}} =
      Ankole.Sessions.Run.finalize(%{run | model_response: response, anchor: response.id})

    {agent.uid, message, attachment}
  end
end
