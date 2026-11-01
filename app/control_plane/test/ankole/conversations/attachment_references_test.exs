defmodule Ankole.Conversations.AttachmentReferencesTest do
  use Ankole.DataCase, async: false

  import Ankole.PrincipalsFixtures
  import Ankole.FilesFixtures
  import Ankole.SignalsFixtures

  alias Ankole.Conversations.{Delivery, DeliveryAttachment}
  alias Ankole.Conversations.Delivery.Intent
  alias Ankole.Files

  test "an unfinished delivery pins its object after the source node is removed" do
    %{principal: agent} = agent_fixture()
    binding_fixture(agent.uid, "bot", :ignore)
    attachment = sent_attachment_fixture(agent.uid, "report.txt", "Original bytes", "text/plain")

    assert {:ok, intent} =
             commit_delivery(%{
               agent_uid: agent.uid,
               binding_name: "bot",
               outbound_key: "frozen-object",
               operation: :post,
               payload: %{"attachments" => [attachment]}
             })

    stored =
      Repo.get_by!(Intent,
        agent_uid: agent.uid,
        binding_name: "bot",
        outbound_key: "frozen-object"
      )

    refute Map.has_key?(stored.payload, "attachments")

    reference =
      Repo.get_by!(DeliveryAttachment,
        agent_uid: agent.uid,
        binding_name: "bot",
        outbound_key: "frozen-object",
        position: 0
      )

    assert reference.object_id == attachment["object_id"]
    refute Map.has_key?(reference.metadata, "object_id")
    refute Map.has_key?(reference.metadata, "node_id")

    assert {:ok, _} = Files.delete(agent.uid, attachment["path"])

    assert {:ok, "Original bytes"} =
             Delivery.attachment_content(hd(intent.payload["attachments"]))

    Repo.delete_all(
      from node in Ankole.Files.Schemas.Node, where: node.id == ^attachment["node_id"]
    )

    assert {:error,
            %Postgrex.Error{
              postgres: %{
                code: :restrict_violation,
                constraint: "delivery_attachments_object_fkey"
              }
            }} =
             Repo.query(
               "DELETE FROM file_objects WHERE tenant_id = $1 AND id = $2",
               [Ecto.UUID.dump!(Repo.tenant_id!()), Ecto.UUID.dump!(attachment["object_id"])],
               mode: :savepoint
             )

    assert {:ok, failed} = Repo.transact(fn -> Ankole.Ash.update(intent, :fail, %{}) end)

    assert {:ok, "Original bytes"} =
             Delivery.attachment_content(hd(failed.payload["attachments"]))

    assert Repo.get_by!(DeliveryAttachment,
             agent_uid: agent.uid,
             binding_name: "bot",
             outbound_key: "frozen-object",
             position: 0
           ).object_id == attachment["object_id"]
  end

  test "terminal deliveries release byte references while preserving their audit descriptors" do
    %{principal: agent} = agent_fixture()
    binding_fixture(agent.uid, "bot", :ignore)
    attachment = sent_attachment_fixture(agent.uid, "report.txt", "Original bytes", "text/plain")

    for {key, action} <- [{"sent", :succeed}, {"expired", :expire}] do
      assert {:ok, intent} =
               commit_delivery(%{
                 agent_uid: agent.uid,
                 binding_name: "bot",
                 outbound_key: key,
                 operation: :post,
                 payload: %{"attachments" => [attachment]}
               })

      assert {:ok, _} = Repo.transact(fn -> Ankole.Ash.update(intent, action, %{}) end)

      row =
        Repo.get_by!(DeliveryAttachment,
          agent_uid: agent.uid,
          binding_name: "bot",
          outbound_key: key,
          position: 0
        )

      assert row.object_id == nil
      assert row.node_id == nil
      assert row.metadata["name"] == "report.txt"

      [loaded] =
        Ankole.Conversations.list_intents!(
          query: [filter: [agent_uid: agent.uid, binding_name: "bot", outbound_key: key]]
        )

      assert [%{"name" => "report.txt"} = descriptor] = loaded.payload["attachments"]
      refute Map.has_key?(descriptor, "object_id")
    end
  end
end
