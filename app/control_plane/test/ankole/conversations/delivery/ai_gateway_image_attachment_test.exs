defmodule Ankole.Conversations.Delivery.AIGatewayImageAttachmentTest do
  alias Ankole.AIGateway.ResponseCommit
  use Ankole.DataCase, async: false

  import Ankole.PrincipalsFixtures
  import Ankole.SignalsFixtures, only: [external_session_signal_fixture: 1]
  import Ankole.AIGatewayCase, only: [start_response_run: 1]

  alias Ankole.AIGateway.Conversations

  alias Ankole.AIGateway.Artifacts
  alias Ankole.Ecto.UUIDv7
  alias Ankole.Files
  alias Ankole.Sessions.ModelHistory
  alias Ankole.Sessions.RunRef

  @png Base.decode64!(
         "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="
       )

  test "stores hosted images in the drive as canonical attachments and retries the same paths" do
    %{principal: agent} = agent_fixture()
    signal = external_session_signal_fixture(agent.uid)
    signal_id = signal.id
    conversation_id = signal.conversation_id
    session_id = signal.session_id

    {:ok, conversation} =
      Conversations.ensure_conversation(agent.uid, session_id,
        metadata: %{
          "origin" => %{"conversation_id" => conversation_id, "channel_kind" => "im_group"}
        }
      )

    prior_image_id = image_id()

    assert {:ok, _artifact} =
             Artifacts.persist_generated_image(
               agent.uid,
               prior_image_id,
               Base.encode64(@png),
               "image/png"
             )

    {:ok, response} =
      start_response_run(%{
        subject_uid: agent.uid,
        conversation_id: conversation.id,
        metadata: %{"request_metadata" => %{"signal_id" => signal_id}},
        request_items: [image_item(prior_image_id)]
      })

    images = [
      {image_id(), "image/png", @png, "png"},
      {image_id(), "image/jpeg", <<255, 216, 255, 0>>, "jpg"},
      {image_id(), "image/webp", <<"RIFF", 0, 0, 0, 0, "WEBP">>, "webp"},
      {image_id(), "image/gif", <<"GIF89a">>, "gif"}
    ]

    for {id, mime_type, payload, _extension} <- images do
      assert {:ok, _artifact} =
               Artifacts.persist_generated_image(
                 agent.uid,
                 id,
                 Base.encode64(payload),
                 mime_type,
                 message_id: response.id
               )
    end

    assert {:ok, response} =
             ResponseCommit.commit_complete(
               response,
               Enum.map(images, &image_item(elem(&1, 0)))
             )

    turn_ref = turn_ref(agent.uid, session_id, signal_id)

    assert {:ok, completion} =
             ModelHistory.load_turn_completion(turn_ref, "resp_#{response.id}")

    expected_attachments =
      Enum.map(images, fn {id, mime_type, payload, extension} ->
        filename = "#{id}.#{extension}"
        blob_ref = Base.encode16(:crypto.hash(:sha256, payload), case: :lower)

        %{
          "path" =>
            "chats/#{conversation_id}/generated/#{String.slice(blob_ref, 0, 16)}/#{filename}",
          "blob_ref" => blob_ref,
          "name" => filename,
          "mime_type" => mime_type,
          "size" => byte_size(payload)
        }
      end)

    assert completion.final_text == nil
    assert completion.attachments == expected_attachments
    refute Enum.any?(completion.attachments, &String.contains?(&1["name"], prior_image_id))

    for {%{"path" => path, "mime_type" => mime_type}, {_id, _mime, payload, _ext}} <-
          Enum.zip(expected_attachments, images) do
      assert {:ok,
              %{source: "generated", content_type: ^mime_type, conversation_id: ^conversation_id},
              ^payload} =
               Files.read(agent.uid, path)
    end

    assert {:ok, retried} =
             ModelHistory.load_turn_completion(turn_ref, "resp_#{response.id}")

    assert retried.attachments == expected_attachments
    assert {:ok, %{files: files}} = Files.list(agent.uid, "chats/#{conversation_id}/generated")
    assert length(files) == length(images)
  end

  test "rejects an image artifact owned by another subject without writing a file" do
    %{principal: agent} = agent_fixture()
    %{principal: other_agent} = agent_fixture()
    signal_id = Ecto.UUID.generate()
    session_id = "cross-subject-hosted-image"
    {:ok, conversation} = Conversations.ensure_conversation(agent.uid, session_id)
    id = image_id()

    assert {:ok, _artifact} =
             Artifacts.persist_generated_image(
               other_agent.uid,
               id,
               Base.encode64(@png),
               "image/png"
             )

    {:ok, response} =
      start_response_run(%{
        subject_uid: agent.uid,
        conversation_id: conversation.id,
        metadata: %{"request_metadata" => %{"signal_id" => signal_id}}
      })

    assert {:ok, response} = ResponseCommit.commit_complete(response, [image_item(id)])

    assert {:error, {:generated_image_artifact_unavailable, ^id, %{code: "not_found"}}} =
             ModelHistory.load_turn_completion(
               turn_ref(agent.uid, session_id, signal_id),
               "resp_#{response.id}"
             )

    assert {:ok, %{files: []}} = Files.list(agent.uid, "generated")
  end

  test "propagates a drive store failure before turn completion" do
    %{principal: agent} = agent_fixture()
    signal_id = Ecto.UUID.generate()
    session_id = "hosted-image-store-failure"
    {:ok, conversation} = Conversations.ensure_conversation(agent.uid, session_id)

    {:ok, response} =
      start_response_run(%{
        subject_uid: agent.uid,
        conversation_id: conversation.id,
        metadata: %{"request_metadata" => %{"signal_id" => signal_id}}
      })

    id = image_id()
    # Bytes after IEND make the content new, so the store has to write it.
    bytes = @png <> :crypto.strong_rand_bytes(16)

    assert {:ok, _artifact} =
             Artifacts.persist_generated_image(
               agent.uid,
               id,
               Base.encode64(bytes),
               "image/png",
               message_id: response.id
             )

    assert {:ok, response} = ResponseCommit.commit_complete(response, [image_item(id)])

    root = Application.fetch_env!(:ankole, Ankole.ObjectStore)[:spec].root
    for dir <- [root, Path.join(root, ".tmp")], do: File.chmod!(dir, 0o500)
    on_exit(fn -> for dir <- [root, Path.join(root, ".tmp")], do: File.chmod(dir, 0o755) end)

    assert {:error, {:generated_image_materialization_failed, ^id, _reason}} =
             ModelHistory.load_turn_completion(
               turn_ref(agent.uid, session_id, signal_id),
               "resp_#{response.id}"
             )

    assert {:ok, %{files: []}} = Files.list(agent.uid, "generated")
  end

  defp image_id, do: "ig_#{UUIDv7.autogenerate()}"

  defp image_item(id) do
    %{
      "id" => id,
      "type" => "image_generation_call",
      "status" => "completed",
      "result" => nil
    }
  end

  defp turn_ref(agent_uid, session_id, signal_id) do
    %RunRef{
      agent_uid: agent_uid,
      session_id: session_id,
      signal_id: signal_id
    }
  end
end
