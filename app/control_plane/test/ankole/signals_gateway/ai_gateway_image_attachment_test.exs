defmodule Ankole.SignalsGateway.AIGatewayImageAttachmentTest do
  use Ankole.DataCase, async: false

  import Ankole.PrincipalsFixtures
  import Ankole.AIGatewayCase, only: [start_response_run: 1]

  alias Ankole.AIGateway.Conversations

  alias Ankole.AIGateway.Artifacts
  alias Ankole.AIGateway.StatefulResponses
  alias Ankole.Ecto.UUIDv7
  alias Ankole.SignalsGateway.AIGatewayLink
  alias Ankole.WorkerFilesFake
  alias Ankole.SignalsGateway.ActorRuntime.Schemas.AgentComputerWorker
  alias Ankole.SignalsGateway.ActorRuntime.WorkerRoute
  alias Ankole.SignalsGateway.ActorRuntime.TurnRef
  alias Ankole.Repo

  @png Base.decode64!(
         "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="
       )

  setup do
    route = "image-attachment-test-#{System.unique_integer([:positive])}"
    worker_id = "worker-#{route}"
    insert_ready_worker!(worker_id, route)
    stored = WorkerFilesFake.start!(route)

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
      start_response_run(%{
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
      start_response_run(%{
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
      start_response_run(%{
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
    WorkerRoute.unregister_local_worker(route)

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

  defp writes(stored), do: WorkerFilesFake.writes(stored)

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
end
