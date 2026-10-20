defmodule Ankole.Conversations.Delivery.AIGatewayImageAttachmentTest do
  alias Ankole.AIGateway.ResponseCommit
  use Ankole.DataCase, async: false

  import Ankole.PrincipalsFixtures

  import Ankole.SignalsFixtures,
    only: [external_session_signal_fixture: 1, external_session_signal_fixture: 2]

  import Ankole.AIGatewayCase, only: [start_response_run: 1]

  alias Ankole.AIGateway.Artifacts
  alias Ankole.Ecto.UUIDv7
  alias Ankole.Files
  alias Ankole.Sessions.Presentation
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
      Ankole.AIGatewayCase.ensure_conversation(agent.uid, session_id,
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

    image_items = Enum.map(images, &image_item(elem(&1, 0)))

    assert {:ok, response} =
             ResponseCommit.commit_complete(response, image_items ++ Enum.take(image_items, 2))

    turn_ref = turn_ref(agent.uid, session_id, signal_id)

    assert {:ok, completion} =
             prepare_and_commit(turn_ref, "resp_#{response.id}")

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
             prepare_and_commit(turn_ref, "resp_#{response.id}")

    assert retried.attachments == expected_attachments
    assert {:ok, %{files: files}} = Files.list(agent.uid, "chats/#{conversation_id}/generated")
    assert length(files) == length(images)
  end

  test "rejects an image artifact owned by another subject without writing a file" do
    %{principal: agent} = agent_fixture()
    %{principal: other_agent} = agent_fixture()
    signal_id = Ecto.UUID.generate()
    session_id = "cross-subject-hosted-image"
    {:ok, conversation} = Ankole.AIGatewayCase.ensure_conversation(agent.uid, session_id)
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

    assert {:error, %{"code" => "generated_image_materialization_failed", "retryable" => true}} =
             prepare_and_commit(
               turn_ref(agent.uid, session_id, signal_id),
               "resp_#{response.id}"
             )

    assert {:ok, %{files: []}} = Files.list(agent.uid, "generated")
  end

  test "propagates a drive store failure before turn completion" do
    %{principal: agent} = agent_fixture()
    signal_id = Ecto.UUID.generate()
    session_id = "hosted-image-store-failure"
    {:ok, conversation} = Ankole.AIGatewayCase.ensure_conversation(agent.uid, session_id)

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

    assert {:error, %{"code" => "generated_image_materialization_failed", "retryable" => true}} =
             prepare_and_commit(
               turn_ref(agent.uid, session_id, signal_id),
               "resp_#{response.id}"
             )

    assert {:ok, %{files: []}} = Files.list(agent.uid, "generated")
  end

  test "Run.finalize delivers hosted and provider IDs once from prepared bytes" do
    %{principal: agent} = Ankole.SessionsCase.agent_fixture()
    signal = external_session_signal_fixture(agent.uid, type: "conversation.message.addressed")
    key = %{agent_uid: agent.uid, session_id: signal.session_id}
    assert {:ok, run} = Ankole.Sessions.Admission.admit(key, signal)
    assert {:ok, {:preparing, run}} = Ankole.Sessions.Model.prepare(run)

    assert {:ok, response} =
             start_response_run(%{
               subject_uid: agent.uid,
               conversation_id: run.conversation.id,
               round_state: run,
               metadata: %{"request_metadata" => Ankole.Sessions.Run.metadata(run)}
             })

    ids = [image_id(), "provider-native-image-#{System.unique_integer([:positive])}"]

    artifacts =
      for id <- ids do
        assert {:ok, artifact} =
                 Artifacts.persist_generated_image(
                   agent.uid,
                   id,
                   Base.encode64(@png),
                   "image/png",
                   message_id: response.id
                 )

        artifact
      end

    assert {:ok, response} =
             ResponseCommit.commit_complete(response, Enum.map(ids, &image_item/1))

    run = %{run | model_response: response, anchor: response.id}
    assert {:ok, result} = Ankole.Sessions.Run.finalize(run)
    assert Repo.reload!(signal).completed_at
    attachments = Enum.flat_map(result.posted.intents, &(&1.payload["attachments"] || []))
    assert length(attachments) == 2

    assert Enum.map(attachments, & &1["name"]) ==
             Enum.map(artifacts, &(Artifacts.public_id(&1) <> ".png"))

    for attachment <- attachments do
      assert {:ok, _, @png} = Files.read(agent.uid, attachment["path"])
    end

    assert {:error, :run_closed} = Ankole.Sessions.Run.finalize(run)

    assert Repo.aggregate(Ankole.Conversations.Delivery.Intent, :count) ==
             length(result.posted.intents)
  end

  test "a changed provider alias rolls back references and the existing retry prepares its new bytes" do
    %{principal: agent} = Ankole.SessionsCase.agent_fixture()
    signal = external_session_signal_fixture(agent.uid, type: "conversation.message.addressed")
    key = %{agent_uid: agent.uid, session_id: signal.session_id}
    assert {:ok, run} = Ankole.Sessions.Admission.admit(key, signal)
    assert {:ok, {:preparing, run}} = Ankole.Sessions.Model.prepare(run)

    assert {:ok, response} =
             start_response_run(%{
               subject_uid: agent.uid,
               conversation_id: run.conversation.id,
               round_state: run,
               metadata: %{"request_metadata" => Ankole.Sessions.Run.metadata(run)}
             })

    id = "provider-alias-#{System.unique_integer([:positive])}"

    assert {:ok, _} =
             Artifacts.persist_generated_image(agent.uid, id, Base.encode64(@png), "image/png",
               message_id: response.id
             )

    assert {:ok, response} = ResponseCommit.commit_complete(response, [image_item(id)])
    run = %{run | model_response: response, anchor: response.id}
    parent = self()
    replacement = @png <> "replacement"
    hook = {__MODULE__, make_ref()}

    :telemetry.attach(
      hook,
      [:ankole, :repo, :query],
      fn _, _, metadata, _ ->
        if self() == parent and String.starts_with?(metadata.query, "INSERT INTO files ") do
          :telemetry.detach(hook)

          assert {:ok, _} =
                   Artifacts.persist_generated_image(
                     agent.uid,
                     id,
                     Base.encode64(replacement),
                     "image/png",
                     message_id: response.id
                   )
        end
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(hook) end)
    assert {:error, %{"retryable" => true} = error} = Ankole.Sessions.Run.finalize(run)
    refute Repo.reload!(signal).completed_at
    assert {:ok, %{files: []}} = Files.list(agent.uid)
    assert Repo.aggregate(Ankole.Conversations.Delivery.Intent, :count) == 0
    assert {:ok, deferred} = Ankole.Sessions.Run.defer_retry(run, error)

    assert {:ok, recovered} =
             Ankole.Sessions.Admission.admit(key, deferred, now: deferred.available_at)

    assert {:ok, {_, recovered}} = Ankole.Sessions.Run.restore(recovered)
    assert {:ok, result} = Ankole.Sessions.Run.finalize(recovered)
    [attachment] = Enum.flat_map(result.posted.intents, &(&1.payload["attachments"] || []))
    assert {:ok, _, ^replacement} = Files.read(agent.uid, attachment["path"])
    assert Repo.reload!(signal).completed_at
    assert Repo.aggregate(Ankole.AIGateway.Schemas.Message, :count) == 1
  end

  defp prepare_and_commit(run, response_id) do
    with {:ok, images} <- Presentation.prepare_generated_images(run, response_id) do
      Repo.transact(&Presentation.load_completion_in_tx(&1, run, response_id, images))
    end
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
