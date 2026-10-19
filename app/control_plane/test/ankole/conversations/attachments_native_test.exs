defmodule Ankole.Conversations.AttachmentsNativeTest do
  use Ankole.DataCase, async: false
  import Ankole.PrincipalsFixtures
  alias Ankole.Conversations.Attachments
  alias Ankole.Conversations.Attachments.Native
  alias Ankole.Conversations.Message
  alias Ankole.Files
  alias Ankole.Signals.Signal

  setup do
    human = human_fixture().principal
    agent = agent_fixture(%{owner_principal_uid: human.uid}).principal
    %{human: human, agent: agent}
  end

  test "an attachment-only Message retains bytes and identities without exposing queued files to the Agent",
       ctx do
    upload = upload!(ctx.human.uid, "brief.txt", "Original uploaded text")
    attrs = attrs(ctx.agent, [upload.receipt])
    assert {:ok, detail} = Ankole.ConversationsFixtures.create(ctx.human.uid, attrs)
    assert detail.conversation.title == "brief.txt"
    assert [%Message{text: nil, attachments: [attachment]}] = detail.messages
    assert is_integer(attachment["attachment_id"])
    assert attachment["path"] =~ "chats/#{attrs.conversation_id}/inbox/"
    assert {:ok, "Original uploaded text"} = Files.read_content(attachment["blob_ref"])
    assert {:error, :not_found} = Files.fetch(ctx.agent.uid, attachment["path"])
    signal = Repo.get_by!(Signal, message_id: attrs.message_id)
    assert signal.data["entry"] == %{"text" => nil, "attachments" => [attachment]}

    assert {:ok, retry} = Ankole.ConversationsFixtures.create(ctx.human.uid, attrs)
    assert retry.messages == detail.messages
    assert Repo.aggregate(Message, :count) == 1
    assert Repo.aggregate(Signal, :count) == 1
    assert attachment["path"] =~ "/inbox/#{attrs.message_id}/"

    # This is the existing consumption owner, called before a Worker receives the payload.
    assert :ok =
             Attachments.link_payload(
               ctx.agent.uid,
               Signal.envelope(signal),
               attrs.conversation_id
             )

    assert {:ok, _, "Original uploaded text"} = Files.read(ctx.agent.uid, attachment["path"])

    {:ok, edited} = Files.store("The Agent's later edits")

    {:ok, _} =
      Files.commit(ctx.agent.uid, [
        %{path: attachment["path"], sha256: edited.sha256, source: "agent"}
      ])

    next_id = Ecto.UUID.generate()

    assert {:ok, followup} =
             Ankole.ConversationsFixtures.post(ctx.human.uid, attrs.conversation_id, %{
               message_id: next_id,
               text: "Read the original file again",
               attachments: [upload.receipt]
             })

    next_attachment = hd(List.last(followup.messages).attachments)
    refute next_attachment["path"] == attachment["path"]
    next_signal = Repo.get_by!(Signal, message_id: next_id)

    assert :ok =
             Attachments.link_payload(
               ctx.agent.uid,
               Signal.envelope(next_signal),
               attrs.conversation_id
             )

    assert {:ok, _, "Original uploaded text"} = Files.read(ctx.agent.uid, next_attachment["path"])
    assert {:ok, _, "The Agent's later edits"} = Files.read(ctx.agent.uid, attachment["path"])

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
             Native.resolve(ctx.human.uid, [%{"blob_ref" => "known hash"}])

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

  test "collection cannot claim a committed attachment and a file already claimed is not accepted",
       ctx do
    upload = upload!(ctx.human.uid, "kept.txt", "Keep")
    attrs = attrs(ctx.agent, [upload.receipt])
    assert {:ok, detail} = Ankole.ConversationsFixtures.create(ctx.human.uid, attrs)
    attachment = hd(hd(detail.messages).attachments)
    digest = Base.decode16!(attachment["blob_ref"], case: :mixed)

    Repo.query!(
      "UPDATE files SET last_referenced_at = now() - interval '2 days' WHERE sha256 = $1",
      [digest]
    )

    assert {:ok, _} = Files.Jobs.CollectUnreferenced.mark_unreferenced()
    refute Repo.get!(Files.Schemas.Blob, digest).deleting

    abandoned = upload!(ctx.human.uid, "collected.txt", "Abandoned")
    {:ok, [stored]} = Native.resolve(ctx.human.uid, [abandoned.receipt])
    other_digest = Base.decode16!(stored["blob_ref"], case: :mixed)
    Repo.query!("UPDATE files SET deleting = true WHERE sha256 = $1", [other_digest])

    assert {:error, {:blob_missing, _}} =
             Ankole.ConversationsFixtures.post(ctx.human.uid, attrs.conversation_id, %{
               message_id: Ecto.UUID.generate(),
               text: "Too late",
               attachments: [abandoned.receipt]
             })

    assert Repo.aggregate(Message, :count) == 1
  end

  test "downloads use committed frozen bytes and current membership instead of the Agent's mutable path",
       ctx do
    upload = upload!(ctx.human.uid, "report.txt", "Original")
    attrs = attrs(ctx.agent, [upload.receipt])
    {:ok, detail} = Ankole.ConversationsFixtures.create(ctx.human.uid, attrs)
    attachment = hd(hd(detail.messages).attachments)

    :ok =
      Attachments.link_payload(
        ctx.agent.uid,
        Signal.envelope(Repo.get_by!(Signal, message_id: attrs.message_id)),
        attrs.conversation_id
      )

    {:ok, replacement} = Files.store("Changed Agent file")

    {:ok, _} =
      Files.commit(ctx.agent.uid, [
        %{path: attachment["path"], sha256: replacement.sha256, source: "agent"}
      ])

    local = Files.temp_path()
    on_exit(fn -> File.rm(local) end)

    assert {:ok, ^attachment} =
             Native.read_to_file(
               ctx.human.uid,
               attrs.conversation_id,
               attrs.message_id,
               attachment["path"],
               local
             )

    assert File.read!(local) == "Original"
    other = human_fixture().principal

    assert {:error, :not_found} =
             Native.read_to_file(
               other.uid,
               attrs.conversation_id,
               attrs.message_id,
               attachment["path"],
               local
             )

    assert {:error, :not_found} =
             Native.read_to_file(
               ctx.human.uid,
               attrs.conversation_id,
               Ecto.UUID.generate(),
               attachment["path"],
               local
             )
  end

  test "the real native input owner gives the model image bytes and a readable Worker drive path",
       ctx do
    agent = Ankole.SessionsCase.agent_fixture(%{owner_principal_uid: ctx.human.uid}).principal

    bytes = File.read!(Path.expand("../../fixtures/sessions/rgba.png", __DIR__))

    upload = upload!(ctx.human.uid, "pixel.png", bytes, "image/png")
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

    assert {:ok, _, ^bytes} = Files.read(agent.uid, attachment["path"])
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
    {:ok, upload} = Native.upload(uid, Ecto.UUID.generate(), name, {:file, local}, content_type)
    upload
  end
end
