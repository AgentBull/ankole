defmodule Ankole.AIGateway.ArtifactsCleanupTest do
  use Ankole.DataCase, async: true

  import Ankole.PrincipalsFixtures
  import Ankole.AIGatewayCase, only: [start_response_run: 1]

  alias Ankole.AIGateway.Artifacts
  alias Ankole.AIGateway.Conversations
  alias Ankole.AIGateway.Schemas.Artifact
  alias Ankole.AIGateway.StatefulResponses
  alias Ankole.Ecto.UUIDv7
  alias Ankole.Repo

  @png_base64 "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="

  test "cleanup removes expired, orphaned, and failed-response images only" do
    agent = agent_fixture()
    now = DateTime.utc_now(:microsecond)

    future_id = persist_stateless!(agent.principal.uid)
    expired_id = persist_stateless!(agent.principal.uid)
    orphaned_id = persist_stateless!(agent.principal.uid)

    set_expiry!(expired_id, DateTime.add(now, -1, :second))
    set_expiry!(orphaned_id, nil)

    assert {:ok, conversation} =
             Conversations.ensure_conversation(agent.principal.uid, "artifact-cleanup")

    assert {:ok, complete_message} =
             start_response_run(%{
               subject_uid: agent.principal.uid,
               conversation_id: conversation.id,
               request_items: []
             })

    complete_id = persist_stateful!(agent.principal.uid, complete_message.id)
    assert {:ok, _message} = StatefulResponses.commit_complete(complete_message, [])

    assert {:ok, failed_message} =
             start_response_run(%{
               subject_uid: agent.principal.uid,
               conversation_id: conversation.id,
               request_items: []
             })

    failed_id = persist_stateful!(agent.principal.uid, failed_message.id)

    assert {:ok, _message} =
             StatefulResponses.commit_error(failed_message, [], %{"reason" => "provider_failed"})

    assert Artifacts.cleanup_expired_and_failed(now) == 3

    assert {:ok, _artifact} = Artifacts.get_generated_image(agent.principal.uid, future_id)
    assert {:ok, _artifact} = Artifacts.get_generated_image(agent.principal.uid, complete_id)

    assert {:error, %{status: 404}} =
             Artifacts.get_generated_image(agent.principal.uid, expired_id)

    assert {:error, %{status: 404}} =
             Artifacts.get_generated_image(agent.principal.uid, orphaned_id)

    assert {:error, %{status: 404}} =
             Artifacts.get_generated_image(agent.principal.uid, failed_id)
  end

  defp persist_stateless!(subject_uid) do
    id = "ig_#{UUIDv7.autogenerate()}"
    assert {:ok, _artifact} = Artifacts.persist_generated_image(subject_uid, id, @png_base64, nil)
    id
  end

  defp persist_stateful!(subject_uid, message_id) do
    id = "ig_#{UUIDv7.autogenerate()}"

    assert {:ok, _artifact} =
             Artifacts.persist_generated_image(subject_uid, id, @png_base64, nil,
               message_id: message_id
             )

    id
  end

  defp set_expiry!("ig_" <> id, expires_at) do
    {1, nil} =
      from(artifact in Artifact, where: artifact.id == ^id)
      |> Repo.update_all(set: [expires_at: expires_at])
  end
end
