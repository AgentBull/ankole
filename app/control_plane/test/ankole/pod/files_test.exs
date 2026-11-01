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

  test "contribute can create and initialize a file but cannot replace or rename it", ctx do
    owner = actor_fixture(ctx.owner)
    reader = actor_fixture(ctx.reader)

    {:ok, parent} =
      Pages.create(owner, %{type: "folder", title: "Drop folder", private_owner_uid: ctx.owner})

    for action <- ["node_view", "node_contribute"] do
      {:ok, _} =
        Ankole.AuthZ.create_permission_grant(%{
          principal_uid: ctx.reader,
          resource_pattern: "drive:**:#{parent.id}:**",
          action: action
        })
    end

    assert {:ok, page} =
             Files.create_from_upload(
               reader,
               %{parent_id: parent.id},
               "new.txt",
               "first",
               "text/plain"
             )

    assert {:ok, _, "first"} = Files.read(reader, page.id, "new.txt")

    assert {:ok, duplicate} =
             Files.create_from_upload(
               reader,
               %{parent_id: parent.id},
               "new.txt",
               "second",
               "text/plain"
             )

    assert duplicate.name == "new.txt (1)"
    assert {:ok, _, "second"} = Files.read(reader, duplicate.id, duplicate.name)

    assert {:error, :forbidden} =
             Files.upload(reader, page.id, "file", page.object_id, "new.txt", "replacement")

    {:ok, empty} = Pages.create(owner, %{type: "file", title: "empty.txt", parent_id: parent.id})

    assert {:error, :forbidden} =
             Files.upload(reader, empty.id, "file", nil, "renamed.txt", "bytes")

    assert {:ok, %{revision: 0}} =
             Files.upload(reader, empty.id, "file", nil, "empty.txt", "initial")

    assert {:ok, _, "initial"} = Files.read(reader, empty.id, "empty.txt")
  end

  test "file replacement compares object identities across Pod and Drive writers", ctx do
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
               nil,
               "report.pdf",
               "%PDF first",
               "application/pdf"
             )

    assert is_binary(first.file.object_id)
    assert {:ok, current} = Pages.fetch(page.id)
    assert current.object_id == first.file.object_id

    assert {:error, :manifest_changed} =
             Files.upload(
               Ankole.PrincipalsFixtures.actor_fixture(ctx.owner),
               page.id,
               "file",
               nil,
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
               first.file.object_id,
               "replacement.pdf",
               "%PDF second"
             )

    assert {:error, :not_found} =
             Files.read(Ankole.PrincipalsFixtures.actor_fixture(ctx.owner), page.id, "report.pdf")

    assert {:ok, %{files: [%{path: "replacement.pdf", object_id: replacement_id}]}} =
             Files.manifest(Ankole.PrincipalsFixtures.actor_fixture(ctx.owner), page.id)

    # A runtime write changes the same token, even if Pod metadata has not changed.
    assert {:ok, runtime} = Drive.write_node(actor_fixture(ctx.owner), page.id, "runtime bytes")

    assert {:error, :manifest_changed} =
             Files.upload(
               actor_fixture(ctx.owner),
               page.id,
               "file",
               replacement_id,
               "replacement.pdf",
               "stale browser"
             )

    assert {:ok, %{files: [%{object_id: current_id}]}} =
             Files.manifest(actor_fixture(ctx.owner), page.id)

    assert current_id == runtime.object_id

    assert {:ok, _} =
             Files.upload(
               actor_fixture(ctx.owner),
               page.id,
               "file",
               current_id,
               "replacement.pdf",
               "fresh browser"
             )
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
    assert is_binary(page.object_id)
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
               nil,
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
        Map.merge(html, %{path: "applet/index.html", source: "agent"}),
        Map.merge(js, %{path: "applet/app.js", source: "agent"})
      ])

    manifest = [
      %{path: "src/main.tsx", object_id: js.object_id, source_path: "applet/app.js"},
      %{path: "dist/index.html", object_id: html.object_id, source_path: "applet/index.html"},
      %{path: "dist/app.js", object_id: js.object_id, source_path: "applet/app.js"}
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
    assert {:error, :not_found} = Drive.fetch(ctx.agent, "unshared")

    {:ok, before_rejection} =
      Files.manifest(Ankole.PrincipalsFixtures.actor_fixture(ctx.owner), page.id)

    bad_manifest = [
      %{path: "src/main.tsx", object_id: js.object_id, source_path: "applet/app.js"},
      %{path: "dist/index.html", object_id: hidden.object_id, source_path: "unshared"}
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

    assert {:error, :manifest_changed} =
             Files.read(
               Ankole.PrincipalsFixtures.actor_fixture(ctx.reader),
               page.id,
               "dist/app.js",
               js.sha256
             )
  end

  test "trashing keeps page files readable and restoring preserves their bytes", ctx do
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

    assert {:ok, _, "persistent"} =
             Files.read(
               Ankole.PrincipalsFixtures.actor_fixture(ctx.owner),
               page.id,
               result.file.path
             )

    assert {:error, :not_found} =
             Files.upload(
               Ankole.PrincipalsFixtures.actor_fixture(ctx.owner),
               page.id,
               "asset",
               nil,
               "replacement.png",
               "blocked"
             )

    assert {:ok, _file} = Files.fetch_file(page.id, result.file.path)
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

    assert {:ok, %{revision: 0, file: file}} =
             Files.copy_from_message(
               Ankole.PrincipalsFixtures.actor_fixture(ctx.reader),
               page.id,
               nil,
               message.id,
               0
             )

    assert file.object_id == attachment["object_id"]

    assert {:ok, _, "committed report bytes"} =
             Files.read(Ankole.PrincipalsFixtures.actor_fixture(ctx.reader), page.id, file.path)

    refute Ankole.AuthZ.allowed?(ctx.reader, resource, "read")

    assert {:ok, saved} =
             Files.create_from_message(actor_fixture(ctx.reader), %{
               type: :file,
               saved_from_message_id: message.id,
               attachment_position: 0,
               private_owner_uid: ctx.reader
             })

    assert saved.saved_from_message_id == message.id
    assert saved.title == attachment["name"] <> " (1)"
    assert saved.object_id == attachment["object_id"]

    assert {:ok, _, "committed report bytes"} =
             Files.read(actor_fixture(ctx.reader), saved.id, saved.title)

    Ankole.FilesFixtures.drive_file_fixture(agent, "private/unshared.txt", "private notes")

    assert {:error, :not_found} =
             Files.copy_from_message(
               Ankole.PrincipalsFixtures.actor_fixture(ctx.reader),
               page.id,
               file.object_id,
               message.id,
               99
             )

    assert {:ok, %{revision: 0, files: [_]}} =
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
    purge_node(attachment["node_id"])
    object_id = attachment["object_id"]
    old = DateTime.add(DateTime.utc_now(:microsecond), -2, :day)
    objects = from object in Ankole.Files.Schemas.FileObject, where: object.id == ^object_id
    Repo.update_all(objects, set: [created_at: old])
    assert {:ok, 0} = Drive.collect_objects()
    assert {:ok, "committed report bytes"} = Drive.read_object(object_id)

    assert {:ok, %{revision: 0, file: first}} =
             Files.copy_from_message(
               Ankole.PrincipalsFixtures.actor_fixture(ctx.reader),
               page.id,
               nil,
               message.id,
               0
             )

    assert {:ok, _, "committed report bytes"} =
             Files.read(Ankole.PrincipalsFixtures.actor_fixture(ctx.reader), page.id, first.path)

    Ankole.FilesFixtures.drive_file_fixture(agent, attachment["path"], "changed after reply")
    assert {:ok, _, "changed after reply"} = Drive.read(agent, attachment["path"])

    assert {:ok, %{revision: 0, file: second}} =
             Files.copy_from_message(
               Ankole.PrincipalsFixtures.actor_fixture(ctx.reader),
               page.id,
               first.object_id,
               message.id,
               0
             )

    assert first.object_id == attachment["object_id"]
    assert second.sha256 == first.sha256

    assert {:ok, _, "committed report bytes"} =
             Files.read(Ankole.PrincipalsFixtures.actor_fixture(ctx.reader), page.id, second.path)

    assert {:ok, _} =
             Ankole.Conversations.delete(
               Ankole.PrincipalsFixtures.actor_fixture(ctx.reader),
               message.conversation_id
             )

    assert {:ok, 0} = Drive.collect_objects()
    assert {:ok, object} = Drive.fetch_object(object_id)
    {:ok, _} = Pages.delete(actor_fixture(ctx.reader), page.id)
    purge_node(page.id)
    assert {:ok, 1} = Drive.collect_objects()
    assert {:error, :not_found} = Drive.fetch_object(object_id)

    assert :ok =
             Ankole.Files.Jobs.DeleteObject.run(%Oban.Job{
               args: %{"storage_key" => object.storage_key}
             })

    assert {:error, %{"code" => "not_found"}} = Ankole.ObjectStore.read(object.storage_key)
  end

  test "an unreadable conversation cannot supply an attachment to a writable Page", ctx do
    {_agent, message, _attachment} = native_attachment(ctx.owner)

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

    assert {:error, :not_found} =
             Files.copy_from_message(
               Ankole.PrincipalsFixtures.actor_fixture(ctx.reader),
               page.id,
               nil,
               message.id,
               0
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
              Map.merge(blob, %{path: "publish/#{page.id}/#{path}", source: "pod"})
            ])

          %{path: path, object_id: blob.object_id, source_path: "publish/#{page.id}/#{path}"}
        end
      )

    {:ok, _} =
      Files.publish(Ankole.PrincipalsFixtures.actor_fixture(ctx.owner), page.id, 0, manifest)

    assert {:ok, _} = Files.fetch_file(page.id, "server/main.js")
    {:ok, _} = Pages.delete(Ankole.PrincipalsFixtures.actor_fixture(ctx.owner), page.id)
    purge_node(page.id)

    for path <- ["src/main.tsx", "dist/index.html", "server/main.js"] do
      assert {:error, :not_found} = Files.fetch_file(page.id, path)
    end

    refute Repo.get(Ankole.Pod.Page, page.id)
  end

  defp purge_node(id) do
    old = DateTime.add(DateTime.utc_now(:microsecond), -90, :day)
    query = from node in Ankole.Files.Schemas.Node, where: node.id == ^id
    Repo.update_all(query, set: [deleted_at: old, purge_started_at: old])
    assert :ok = Ankole.Files.Jobs.PurgeNode.run(%Oban.Job{args: %{"node_id" => id}})
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
