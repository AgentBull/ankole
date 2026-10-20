defmodule Ankole.AIGateway.CompactionUsageTest do
  use Ankole.DataCase, async: true

  alias Ankole.AIGateway.CompactionArtifacts

  test "artifact insertion and replay preserve nested cached and reasoning counts" do
    %{principal: agent} = Ankole.PrincipalsFixtures.agent_fixture()

    usage = %{
      "input_tokens" => 20,
      "output_tokens" => 7,
      "total_tokens" => 27,
      "input_tokens_details" => %{"cached_tokens" => 11},
      "output_tokens_details" => %{"reasoning_tokens" => 4}
    }

    assert {:ok, artifact} =
             CompactionArtifacts.insert_artifact(%{
               subject_uid: agent.uid,
               summary_text: "Earlier work",
               usage: usage
             })

    assert artifact.content["usage"] == usage
    assert CompactionArtifacts.response_body(artifact)["usage"] == usage
  end
end
