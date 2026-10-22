defmodule Ankole.AIGateway.ArtifactsCleanupTest do
  alias Ankole.AIGateway.ResponseCommit
  require Ash.Query
  use Ankole.DataCase, async: true

  import Ankole.PrincipalsFixtures
  import Ankole.AIGatewayCase, only: [start_response_run: 1]

  alias Ankole.AIGateway.Artifacts
  alias Ankole.AIGateway.Schemas.Artifact
  alias Ankole.Ecto.UUIDv7
  alias Ankole.Repo

  @png_base64 "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="

  test "resource writes derive the byte contract and reads select payload explicitly" do
    %{principal: agent} = agent_fixture()
    payload = Base.decode64!(@png_base64)

    attrs = %{
      subject_uid: agent.uid,
      filename: " preview.png ",
      purpose: "vision",
      mime_type: "image/png",
      payload: payload
    }

    assert {:ok, artifact} = Ankole.Ash.create(Artifact, :upload, attrs)
    assert artifact.kind == :uploaded_file
    assert artifact.filename == " preview.png "
    assert artifact.byte_size == byte_size(payload)
    assert artifact.sha256 == :crypto.hash(:sha256, payload)

    assert {:ok, %{payload: %Ash.NotLoaded{field: :payload, type: :attribute}}} =
             Artifacts.get_file(agent.uid, Artifacts.public_id(artifact))

    assert {:ok, %{payload: ^payload}} =
             Artifacts.get_file(agent.uid, Artifacts.public_id(artifact), payload?: true)

    for {field, value} <- [
          byte_size: 0,
          sha256: <<0::256>>,
          kind: :generated_image,
          message_id: Ecto.UUID.generate()
        ] do
      assert {:error, %Ash.Error.Invalid{errors: errors}} =
               Ankole.Ash.create(Artifact, :upload, Map.put(attrs, field, value))

      assert Enum.any?(errors, &match?(%Ash.Error.Invalid.NoSuchInput{input: ^field}, &1))
    end

    assert [stored] =
             Artifact |> Ash.Query.filter(subject_uid == ^agent.uid) |> Ankole.Ash.read!()

    assert stored.id == artifact.id
  end

  test "cleanup removes expired, orphaned, and failed-response images only" do
    agent = agent_fixture()
    now = DateTime.utc_now(:microsecond)

    future_id = persist_stateless!(agent.principal.uid)
    expired_id = persist_stateless!(agent.principal.uid)
    orphaned_id = persist_stateless!(agent.principal.uid)

    set_expiry!(expired_id, DateTime.add(now, -1, :second))
    set_expiry!(orphaned_id, nil)

    assert {:ok, conversation} =
             Ankole.AIGatewayCase.ensure_conversation(agent.principal.uid, "artifact-cleanup")

    assert {:ok, complete_message} =
             start_response_run(%{
               subject_uid: agent.principal.uid,
               conversation_id: conversation.id,
               request_items: []
             })

    complete_id = persist_stateful!(agent.principal.uid, complete_message.id)
    assert {:ok, _message} = ResponseCommit.commit_complete(complete_message, [])

    assert {:ok, failed_message} =
             start_response_run(%{
               subject_uid: agent.principal.uid,
               conversation_id: conversation.id,
               request_items: []
             })

    failed_id = persist_stateful!(agent.principal.uid, failed_message.id)

    assert {:ok, _message} =
             ResponseCommit.commit_error(failed_message, [], %{"reason" => "provider_failed"})

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
