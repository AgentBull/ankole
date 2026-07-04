defmodule Ankole.AIGateway.MessageSchemaTest do
  use Ankole.DataCase, async: true

  alias Ankole.AIGateway.Schemas.Message

  describe "type/content contract" do
    test "message rows cannot contain compaction items" do
      changeset =
        Message.changeset(%Message{}, %{
          agent_uid: "agent-x",
          conversation_id: Ecto.UUID.generate(),
          role: "assistant",
          type: "message",
          status: "complete",
          content: [%{"type" => "compaction", "summary" => "compressed"}],
          metadata: %{}
        })

      refute changeset.valid?
      assert "must not include a compaction item" in errors_on(changeset).content
    end

    test "compaction rows require exactly one compaction item and a covered prefix boundary" do
      invalid =
        Message.changeset(%Message{}, %{
          agent_uid: "agent-x",
          conversation_id: Ecto.UUID.generate(),
          role: "assistant",
          type: "compaction",
          status: "complete",
          content: [%{"type" => "text", "text" => "compressed"}],
          metadata: %{}
        })

      refute invalid.valid?
      assert "must include exactly one compaction item" in errors_on(invalid).content
      assert "can't be blank" in errors_on(invalid).previous_message_id
      assert "can't be blank" in errors_on(invalid).covers_until_message_id

      duplicate =
        Message.changeset(%Message{}, %{
          agent_uid: "agent-x",
          conversation_id: Ecto.UUID.generate(),
          role: "assistant",
          type: "compaction",
          status: "complete",
          previous_message_id: Ecto.UUID.generate(),
          content: [
            %{"type" => "compaction", "summary" => "one"},
            %{"type" => "compaction", "summary" => "two"}
          ],
          covers_until_message_id: Ecto.UUID.generate(),
          metadata: %{}
        })

      refute duplicate.valid?
      assert "must include exactly one compaction item" in errors_on(duplicate).content

      valid =
        Message.changeset(%Message{}, %{
          agent_uid: "agent-x",
          conversation_id: Ecto.UUID.generate(),
          role: "assistant",
          type: "compaction",
          status: "complete",
          previous_message_id: Ecto.UUID.generate(),
          content: [%{"type" => "compaction", "summary" => "compressed"}],
          covers_until_message_id: Ecto.UUID.generate(),
          metadata: %{}
        })

      assert valid.valid?
    end
  end
end
