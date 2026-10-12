defmodule Ankole.AIGateway.CompactionArtifactSchemaTest do
  use Ankole.DataCase, async: true

  alias Ankole.AIGateway.Schemas.CompactionArtifact

  describe "content version contract" do
    test "accepts a local version 2 artifact" do
      assert artifact_changeset(2).valid?
    end

    test "accepts a provider-native version 3 artifact" do
      changeset =
        CompactionArtifact.changeset(%CompactionArtifact{}, %{
          subject_uid: "agent-x",
          content: %{
            "version" => 3,
            "source" => "upstream",
            "binding" => %{
              "provider_row_id" => Ecto.UUID.generate(),
              "provider_updated_at" => "2026-08-13T12:00:00Z",
              "model" => "gpt-5.5"
            },
            "output" => [%{"type" => "compaction", "encrypted_content" => "opaque"}]
          }
        })

      assert changeset.valid?
    end

    for version <- [2, 3] do
      test "version #{version} validates optional context pack message items" do
        version = unquote(version)

        base =
          if version == 2,
            do: %{"version" => 2, "summary" => %{"text" => "summary"}, "output" => []},
            else: %{
              "version" => 3,
              "source" => "upstream",
              "binding" => %{
                "provider_row_id" => "p",
                "provider_updated_at" => "now",
                "model" => "m"
              },
              "output" => [%{"type" => "compaction", "encrypted_content" => "opaque"}]
            }

        pack = [
          %{
            "type" => "message",
            "role" => "user",
            "content" => [%{"type" => "input_text", "text" => "memory"}]
          }
        ]

        for value <- [[], pack] do
          assert CompactionArtifact.changeset(%CompactionArtifact{}, %{
                   subject_uid: "agent-x",
                   content: Map.put(base, "brain_context_pack", value)
                 }).valid?
        end

        for value <- [
              nil,
              %{},
              [%{"type" => "function_call"}],
              [%{"type" => "message", "role" => "assistant", "content" => []}]
            ] do
          refute CompactionArtifact.changeset(%CompactionArtifact{}, %{
                   subject_uid: "agent-x",
                   content: Map.put(base, "brain_context_pack", value)
                 }).valid?
        end
      end
    end

    test "rejects non-current artifact versions" do
      changeset = artifact_changeset(999)

      refute changeset.valid?
      assert "must use version 2 or 3" in errors_on(changeset).content
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
