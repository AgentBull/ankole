defmodule Ankole.AIGateway.MessageSchemaTest do
  use Ankole.DataCase, async: true

  alias Ankole.AIGateway.Schemas.Message

  describe "type/content contract" do
    test "message rows cannot contain compaction items" do
      changeset =
        prepare(:start, %{
          subject_uid: "agent-x",
          conversation_id: Ecto.UUID.generate(),
          content: [%{"type" => "compaction", "summary" => "compressed"}],
          metadata: %{}
        })

      refute changeset.valid?
      assert "must not include compaction items or artifact refs" in errors_on(changeset).content
    end

    test "message rows cannot contain compaction artifact refs" do
      changeset =
        prepare(:start, %{
          subject_uid: "agent-x",
          conversation_id: Ecto.UUID.generate(),
          content: [%{"type" => "compaction_artifact", "id" => "cmp_#{Ecto.UUID.generate()}"}],
          metadata: %{}
        })

      refute changeset.valid?
      assert "must not include compaction items or artifact refs" in errors_on(changeset).content
    end

    test "checkpoint rows require exactly one compaction artifact ref" do
      invalid =
        prepare(:checkpoint, %{
          subject_uid: "agent-x",
          conversation_id: Ecto.UUID.generate(),
          content: [%{"type" => "text", "text" => "compressed"}],
          metadata: %{}
        })

      refute invalid.valid?
      assert "must include exactly one compaction artifact ref" in errors_on(invalid).content

      duplicate =
        prepare(:checkpoint, %{
          subject_uid: "agent-x",
          conversation_id: Ecto.UUID.generate(),
          previous_message_id: Ecto.UUID.generate(),
          content: [
            %{"type" => "compaction_artifact", "id" => "cmp_#{Ecto.UUID.generate()}"},
            %{"type" => "compaction_artifact", "id" => "cmp_#{Ecto.UUID.generate()}"}
          ],
          metadata: %{}
        })

      refute duplicate.valid?
      assert "must include exactly one compaction artifact ref" in errors_on(duplicate).content

      valid =
        prepare(:checkpoint, %{
          subject_uid: "agent-x",
          conversation_id: Ecto.UUID.generate(),
          previous_message_id: Ecto.UUID.generate(),
          content: [%{"type" => "compaction_artifact", "id" => "cmp_#{Ecto.UUID.generate()}"}],
          metadata: %{}
        })

      assert valid.valid?
    end

    test "compaction row type is invalid" do
      changeset =
        prepare(:start, %{
          subject_uid: "agent-x",
          conversation_id: Ecto.UUID.generate(),
          type: "compaction",
          content: [%{"type" => "compaction", "summary" => "compressed"}],
          metadata: %{}
        })

      refute changeset.valid?

      assert Enum.any?(
               changeset.errors,
               &match?(%Ash.Error.Invalid.NoSuchInput{input: :type}, &1)
             )
    end
  end

  defp prepare(action, attrs) do
    {:ok, changeset} =
      Repo.transact(fn -> {:ok, Ankole.Ash.for_create(Message, action, attrs)} end)

    changeset
  end
end
