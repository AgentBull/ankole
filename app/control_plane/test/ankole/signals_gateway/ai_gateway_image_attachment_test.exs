defmodule Ankole.SignalsGateway.AIGatewayImageAttachmentTest do
  use Ankole.DataCase, async: false

  import Ankole.PrincipalsFixtures

  alias Ankole.AIGateway.Conversations

  alias Ankole.AIGateway.Artifacts
  alias Ankole.AIGateway.StatefulResponses
  alias Ankole.Ecto.UUIDv7
  alias Ankole.SignalsGateway.AIGatewayLink
  alias Ankole.SignalsGateway.ActorRuntime.FileTransferLane
  alias Ankole.SignalsGateway.ActorRuntime.Schemas.AgentComputerWorker
  alias Ankole.SignalsGateway.ActorRuntime.Transport.Broker
  alias Ankole.SignalsGateway.ActorRuntime.TurnRef
  alias Ankole.Repo

  @credit_window 4 * 1024 * 1024
  @png Base.decode64!(
         "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="
       )

  setup do
    route = "image-attachment-test-#{System.unique_integer([:positive])}"
    worker_id = "worker-#{route}"
    route_auth = %{route: route, worker_id: worker_id}
    stored = start_supervised!({Agent, fn -> %{transfers: %{}, writes: []} end})

    insert_ready_worker!(worker_id, route)

    :ok =
      Broker.register_local_worker(route, fn {:file_transfer_lane, frames} ->
        respond_to_write(route_auth, stored, frames)
      end)

    on_exit(fn -> Broker.unregister_local_worker(route) end)

    {:ok, route: route, stored: stored}
  end

  test "materializes hosted images as canonical attachments and retries the same paths", %{
    stored: stored
  } do
    %{principal: agent} = agent_fixture()
    actor_event_id = Ecto.UUID.generate()
    session_id = "hosted-image-attachment"
    {:ok, conversation} = Conversations.ensure_conversation(agent.uid, session_id)

    prior_image_id = image_id()

    assert {:ok, _artifact} =
             Artifacts.persist_generated_image(
               agent.uid,
               prior_image_id,
               Base.encode64(@png),
               "image/png"
             )

    {:ok, response} =
      StatefulResponses.start_response_run(%{
        subject_uid: agent.uid,
        conversation_id: conversation.id,
        metadata: %{"request_metadata" => %{"actor_event_id" => actor_event_id}},
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
             StatefulResponses.commit_complete(
               response,
               Enum.map(images, &image_item(elem(&1, 0)))
             )

    turn_ref = turn_ref(agent.uid, session_id, actor_event_id)

    assert {:ok, completion} =
             AIGatewayLink.load_turn_completion(turn_ref, "resp_#{response.id}")

    expected_attachments =
      Enum.map(images, fn {id, mime_type, payload, extension} ->
        filename = "#{id}.#{extension}"
        relative_path = "generated-images/#{filename}"

        %{
          "agent_computer_path" => "/agents/#{agent.uid}/user-files/#{relative_path}",
          "user_files_relative_path" => relative_path,
          "name" => filename,
          "mime_type" => mime_type,
          "size" => byte_size(payload)
        }
      end)

    assert completion.final_text == nil
    assert completion.attachments == expected_attachments
    refute Enum.any?(completion.attachments, &String.contains?(&1["name"], prior_image_id))
    assert writes(stored) == expected_writes(images, agent.uid)

    assert {:ok, retried} =
             AIGatewayLink.load_turn_completion(turn_ref, "resp_#{response.id}")

    assert retried.attachments == expected_attachments

    assert writes(stored) ==
             expected_writes(images, agent.uid) ++ expected_writes(images, agent.uid)
  end

  test "rejects an image artifact owned by another subject without writing a file", %{
    stored: stored
  } do
    %{principal: agent} = agent_fixture()
    %{principal: other_agent} = agent_fixture()
    actor_event_id = Ecto.UUID.generate()
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
      StatefulResponses.start_response_run(%{
        subject_uid: agent.uid,
        conversation_id: conversation.id,
        metadata: %{"request_metadata" => %{"actor_event_id" => actor_event_id}}
      })

    assert {:ok, response} = StatefulResponses.commit_complete(response, [image_item(id)])

    assert {:error, {:generated_image_artifact_unavailable, ^id, %{code: "not_found"}}} =
             AIGatewayLink.load_turn_completion(
               turn_ref(agent.uid, session_id, actor_event_id),
               "resp_#{response.id}"
             )

    assert writes(stored) == []
  end

  test "propagates WorkerFiles failures before turn completion", %{route: route, stored: stored} do
    %{principal: agent} = agent_fixture()
    actor_event_id = Ecto.UUID.generate()
    session_id = "hosted-image-worker-failure"
    {:ok, conversation} = Conversations.ensure_conversation(agent.uid, session_id)

    {:ok, response} =
      StatefulResponses.start_response_run(%{
        subject_uid: agent.uid,
        conversation_id: conversation.id,
        metadata: %{"request_metadata" => %{"actor_event_id" => actor_event_id}}
      })

    id = image_id()

    assert {:ok, _artifact} =
             Artifacts.persist_generated_image(
               agent.uid,
               id,
               Base.encode64(@png),
               "image/png",
               message_id: response.id
             )

    assert {:ok, response} = StatefulResponses.commit_complete(response, [image_item(id)])

    Repo.delete_all(AgentComputerWorker)
    Broker.unregister_local_worker(route)

    assert {:error, {:generated_image_materialization_failed, ^id, :no_worker_available}} =
             AIGatewayLink.load_turn_completion(
               turn_ref(agent.uid, session_id, actor_event_id),
               "resp_#{response.id}"
             )

    assert writes(stored) == []
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

  defp turn_ref(agent_uid, session_id, actor_event_id) do
    %TurnRef{
      agent_uid: agent_uid,
      session_id: session_id,
      activation_uid: Ecto.UUID.generate(),
      actor_epoch: 1,
      actor_event_id: actor_event_id,
      revision: 1
    }
  end

  defp expected_writes(images, agent_uid) do
    Enum.map(images, fn {id, _mime_type, payload, extension} ->
      %{
        path: "/user_files/#{agent_uid}/user-files/generated-images/#{id}.#{extension}",
        content: payload
      }
    end)
  end

  defp writes(stored), do: Agent.get(stored, &Enum.reverse(&1.writes))

  defp insert_ready_worker!(worker_id, route) do
    now = DateTime.utc_now(:microsecond)

    Repo.insert!(%AgentComputerWorker{
      worker_id: worker_id,
      incarnation_id: Ecto.UUID.generate(),
      status: "ready",
      version: "test",
      capacity: %{},
      load: %{},
      transport_route: route,
      last_worker_heartbeat_at: now,
      started_at: now,
      metadata: %{"runtime" => "test"}
    })
  end

  defp respond_to_write(route_auth, stored, [protocol, command, transfer_id | rest]) do
    case {command, rest} do
      {"WRITE_OPEN", [path, _original_size]} ->
        Agent.update(stored, fn state ->
          put_in(state, [:transfers, transfer_id], %{path: path, chunks: []})
        end)

        FileTransferLane.handle_worker_frame(route_auth, [
          protocol,
          "WRITE_READY",
          transfer_id,
          u64(@credit_window)
        ])

      {"DATA", [_sequence, _offset, _eof, chunk]} ->
        Agent.update(stored, fn state ->
          update_in(state, [:transfers, transfer_id, :chunks], &[chunk | &1])
        end)

        FileTransferLane.handle_worker_frame(route_auth, [
          protocol,
          "CREDIT",
          transfer_id,
          u64(byte_size(chunk))
        ])

      {"WRITE_COMMIT", []} ->
        %{path: path, chunks: chunks} = Agent.get(stored, & &1.transfers[transfer_id])
        content = zstd_decode_chunks!(chunks)

        Agent.update(stored, fn state ->
          %{
            state
            | transfers: Map.delete(state.transfers, transfer_id),
              writes: [%{path: path, content: content} | state.writes]
          }
        end)

        FileTransferLane.handle_worker_frame(route_auth, [
          protocol,
          "WRITE_COMMITTED",
          transfer_id,
          path,
          u64(byte_size(content)),
          ""
        ])
    end
  end

  defp zstd_decode_chunks!(chunks) do
    Enum.reduce(chunks, [], fn chunk, acc ->
      decoded = Ankole.Kernel.zstd_decompress_block(chunk, 2 * 1024 * 1024)
      true = is_binary(decoded)
      [decoded | acc]
    end)
    |> IO.iodata_to_binary()
  end

  defp u64(value), do: <<value::unsigned-big-integer-size(64)>>
end
