defmodule Ankole.Conversations.AttachmentsNativeTest do
  use Ankole.DataCase, async: false
  import Ankole.PrincipalsFixtures
  alias Ankole.Conversations.Attachments.Native
  alias Ankole.Conversations.Message
  alias Ankole.Files
  alias Ankole.Signals.Signal

  setup do
    human = human_fixture().principal
    agent = agent_fixture(%{owner_principal_uid: human.uid}).principal
    Ankole.ConversationsFixtures.grant_chat(human.uid, agent.uid)
    %{human: human, agent: agent}
  end

  test "an anchor-page reader downloads frozen attachments without joining the conversation",
       ctx do
    actor = actor_fixture(ctx.human)
    reader = human_fixture().principal |> actor_fixture()
    {:ok, page} = Ankole.Pod.Pages.create(actor, %{title: "Shared attachment"})

    {:ok, _} =
      Ankole.Pod.PagesFixtures.set_sharing(ctx.human.uid, page.id, %{
        inherit_permissions: false,
        grants: [%{principal_uid: reader.principal.uid, role: "view"}]
      })

    upload = upload!(ctx.human.uid, "report.txt", "Shared bytes")

    attrs =
      Map.merge(attrs(ctx.agent, [upload.receipt]), %{
        page_id: page.id,
        access_scope: "anchor_page"
      })

    assert {:ok, detail} = Ankole.ConversationsFixtures.create(ctx.human.uid, attrs)

    refute Repo.get_by(Ankole.Conversations.Participant,
             conversation_id: attrs.conversation_id,
             principal_uid: reader.principal.uid
           )

    assert {:ok, attachment} =
             Ankole.Conversations.Attachments.resolve(
               reader,
               attrs.conversation_id,
               attrs.message_id,
               0
             )

    assert attachment == hd(hd(detail.messages).attachments)

    {:ok, _} =
      Ankole.Pod.PagesFixtures.set_sharing(ctx.human.uid, page.id, %{
        inherit_permissions: false,
        grants: []
      })

    assert {:error, :not_found} =
             Ankole.Conversations.Attachments.resolve(
               reader,
               attrs.conversation_id,
               attrs.message_id,
               0
             )
  end

  test "an attachment-only Message commits shared-root files and frozen object references", ctx do
    upload = upload!(ctx.human.uid, "brief.txt", "Original uploaded text")
    attrs = attrs(ctx.agent, [upload.receipt])
    assert {:ok, detail} = Ankole.ConversationsFixtures.create(ctx.human.uid, attrs)
    assert detail.conversation.title == "brief.txt"
    assert [%Message{text: nil, attachments: [attachment]}] = detail.messages
    assert is_integer(attachment["attachment_id"])
    assert {:ok, conversation_id} = Files.node_conversation_id(attachment["node_id"])
    assert conversation_id == attrs.conversation_id
    assert {:ok, "Original uploaded text"} = Files.read_object(attachment["object_id"])
    assert {:ok, file} = Files.authorize_node(ctx.agent.uid, attachment["node_id"], "node_view")
    assert file.id == attachment["node_id"]
    signal = Repo.get_by!(Signal, message_id: attrs.message_id)
    assert signal.data["entry"] == %{"text" => nil, "attachments" => [attachment]}

    assert {:ok, retry} = Ankole.ConversationsFixtures.create(ctx.human.uid, attrs)
    assert retry.messages == detail.messages
    assert Repo.aggregate(Message, :count) == 1
    assert Repo.aggregate(Signal, :count) == 1
    assert Repo.aggregate(Ankole.Conversations.MessageAttachment, :count) == 1

    assert Repo.get_by!(Ankole.Conversations.MessageAttachment, message_id: attrs.message_id).object_id ==
             attachment["object_id"]

    assert {:error, :conversation_conflict} =
             Ankole.ConversationsFixtures.create(ctx.human.uid, %{
               attrs
               | attachments: [],
                 text: "Changed content"
             })
  end

  test "a receipt cannot attach another Human's or tenant's global bytes", ctx do
    upload = upload!(ctx.human.uid, "private.txt", "Private bytes")
    other = human_fixture().principal
    assert {:error, :invalid_attachment} = Native.resolve(other.uid, [upload.receipt])
    tenant_id = Repo.tenant_id!()
    other_tenant = create_tenant()
    Repo.put_tenant_id(other_tenant.id)
    assert {:error, :invalid_attachment} = Native.resolve(ctx.human.uid, [upload.receipt])
    Repo.put_tenant_id(tenant_id)

    assert {:error, :invalid_attachment} =
             Native.resolve(ctx.human.uid, [upload.receipt <> "tampered"])

    assert {:error, :invalid_attachment} =
             Native.resolve(ctx.human.uid, [%{"object_id" => "unverified object"}])

    assert Repo.aggregate(Message, :count) == 0
  end

  test "expired unsent uploads are rejected but exact accepted retries remain idempotent", ctx do
    upload = upload!(ctx.human.uid, "retry.txt", "Retained")

    {:ok, payload} =
      Phoenix.Token.verify(AnkoleWeb.Endpoint, "native-conversation-attachment", upload.receipt,
        max_age: :infinity
      )

    expired =
      Phoenix.Token.sign(AnkoleWeb.Endpoint, "native-conversation-attachment", payload,
        signed_at: System.system_time(:second) - 86_401
      )

    assert {:error, :attachment_expired} = Native.resolve(ctx.human.uid, [expired])
    attrs = attrs(ctx.agent, [upload.receipt])
    assert {:ok, detail} = Ankole.ConversationsFixtures.create(ctx.human.uid, attrs)

    assert {:ok, retried} =
             Ankole.ConversationsFixtures.create(ctx.human.uid, %{attrs | attachments: [expired]})

    assert retried.messages == detail.messages

    assert {:error, :attachment_expired} =
             Ankole.ConversationsFixtures.post(ctx.human.uid, attrs.conversation_id, %{
               message_id: Ecto.UUID.generate(),
               text: "new",
               attachments: [expired]
             })
  end

  test "the database prevents collection of a Message attachment object", ctx do
    upload = upload!(ctx.human.uid, "kept.txt", "Keep")
    attrs = attrs(ctx.agent, [upload.receipt])
    assert {:ok, detail} = Ankole.ConversationsFixtures.create(ctx.human.uid, attrs)
    attachment = hd(hd(detail.messages).attachments)

    Repo.delete_all(
      from node in Ankole.Files.Schemas.Node, where: node.id == ^attachment["node_id"]
    )

    assert {:error,
            %Postgrex.Error{
              postgres: %{
                code: :restrict_violation,
                constraint: "message_attachments_object_fkey"
              }
            }} =
             Repo.query(
               "DELETE FROM file_objects WHERE tenant_id = $1 AND id = $2",
               [Ecto.UUID.dump!(Repo.tenant_id!()), Ecto.UUID.dump!(attachment["object_id"])],
               mode: :savepoint
             )

    assert {:ok, "Keep"} = Files.read_object(attachment["object_id"])
  end

  test "downloads use committed frozen bytes and current membership instead of the Agent's mutable path",
       ctx do
    upload = upload!(ctx.human.uid, "report.txt", "Original")
    attrs = attrs(ctx.agent, [upload.receipt])
    {:ok, detail} = Ankole.ConversationsFixtures.create(ctx.human.uid, attrs)
    attachment = hd(hd(detail.messages).attachments)

    {:ok, _} =
      Ankole.AuthZ.create_permission_grant(%{
        principal_uid: ctx.agent.uid,
        resource_pattern: "drive:**:#{attachment["node_id"]}:node",
        target_node_id: attachment["node_id"],
        target_scope: "self",
        action: "node_edit"
      })

    {:ok, _} = Files.write_node(ctx.agent.uid, attachment["node_id"], "Changed Agent file")

    local = Files.temp_path()
    on_exit(fn -> File.rm(local) end)

    assert {:ok, ^attachment} =
             Ankole.Conversations.read_attachment_to_file(
               Ankole.PrincipalsFixtures.actor_fixture(ctx.human.uid),
               attrs.conversation_id,
               attrs.message_id,
               0,
               local
             )

    assert File.read!(local) == "Original"
    other = human_fixture().principal

    assert {:error, :not_found} =
             Ankole.Conversations.read_attachment_to_file(
               Ankole.PrincipalsFixtures.actor_fixture(other.uid),
               attrs.conversation_id,
               attrs.message_id,
               0,
               local
             )

    assert {:error, :not_found} =
             Ankole.Conversations.read_attachment_to_file(
               Ankole.PrincipalsFixtures.actor_fixture(ctx.human.uid),
               attrs.conversation_id,
               Ecto.UUID.generate(),
               0,
               local
             )
  end

  test "the real native input owner gives the model image bytes and a frozen attachment command",
       ctx do
    agent = Ankole.SessionsCase.agent_fixture(%{owner_principal_uid: ctx.human.uid}).principal

    bytes = File.read!(Path.expand("../../fixtures/sessions/rgba.png", __DIR__))

    upload = upload!(ctx.human.uid, "pixel.png", bytes, "image/png")
    Ankole.ConversationsFixtures.grant_chat(ctx.human.uid, agent.uid)
    attrs = attrs(agent, [upload.receipt])
    {:ok, detail} = Ankole.ConversationsFixtures.create(ctx.human.uid, attrs)
    attachment = hd(hd(detail.messages).attachments)
    event = Repo.get_by!(Signal, message_id: attrs.message_id)
    key = %{agent_uid: agent.uid, session_id: event.session_id}
    {:ok, run} = Ankole.Sessions.Admission.admit(key, event)
    {:ok, {:preparing, run}} = Ankole.Sessions.Model.prepare(run)
    messages = Ankole.Sessions.Prompt.Input.messages(run, event)
    content = messages |> List.last() |> Map.fetch!("content")

    assert [%{"image_url" => "data:image/webp;base64," <> encoded}] =
             Enum.filter(content, &(&1["type"] == "input_image"))

    assert <<"RIFF", _size::little-32, "WEBP", _::binary>> = Base.decode64!(encoded)

    assert Enum.any?(
             content,
             &(&1["type"] == "input_text" and String.contains?(&1["text"], attachment["path"]))
           )

    command = "ankole-pod chat attachment get #{attrs.conversation_id} #{attrs.message_id} 0 --to"

    assert Enum.any?(
             content,
             &(&1["type"] == "input_text" and String.contains?(&1["text"], command))
           )

    assert {:ok, ^bytes} = Files.read_object(attachment["object_id"])
  end

  defp attrs(agent, receipts),
    do: %{
      conversation_id: Ecto.UUID.generate(),
      message_id: Ecto.UUID.generate(),
      agent_uid: agent.uid,
      text: "",
      attachments: receipts,
      delivery_mode: "queue"
    }

  defp upload!(uid, name, bytes, content_type \\ "text/plain") do
    local = Files.temp_path()
    File.write!(local, bytes)
    on_exit(fn -> File.rm(local) end)

    {:ok, upload} =
      Native.upload(
        Ankole.PrincipalsFixtures.actor_fixture(uid),
        Ecto.UUID.generate(),
        name,
        {:file, local},
        content_type
      )

    upload
  end
end
