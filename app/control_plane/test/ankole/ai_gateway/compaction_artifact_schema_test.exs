defmodule Ankole.AIGateway.CompactionArtifactSchemaTest do
  use Ankole.DataCase, async: true

  alias Ankole.AIGateway.Schemas.CompactionArtifact

  describe "content version contract" do
    test "accepts the current artifact version" do
      assert artifact_changeset(2).valid?
    end

    test "rejects non-current artifact versions" do
      changeset = artifact_changeset(999)

      refute changeset.valid?
      assert "must use version 2" in errors_on(changeset).content
    end
  end

  defp artifact_changeset(version) do
    CompactionArtifact.changeset(%CompactionArtifact{}, %{
      subject_uid: "agent-x",
      content: %{
        "version" => version,
        "summary" => %{"text" => "summary"},
        "output" => []
      }
    })
  end
end
