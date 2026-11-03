defmodule Ankole.Brain.VocabularyTest do
  use Ankole.DataCase, async: true
  import Ankole.BrainFixtures

  import Ankole.PrincipalsFixtures

  alias Ankole.Brain.SchemaPacks
  alias Ankole.Brain.Vocabulary

  test "reads the shipped vocabulary and matches exact and near terms" do
    terms = Vocabulary.terms()
    assert "ticket" in terms

    assert ["ticket"] = Vocabulary.closest_terms("Ticket")
    assert "ticket" in Vocabulary.closest_terms("tickets")
    assert Vocabulary.closest_terms("zzzzqqqq") == []
  end

  test "knowledge metadata accepts domain-specific entity types" do
    {:ok, _result} = SchemaPacks.install_packs([])
    %{principal: human} = human_fixture()

    assert {:ok, page} =
             page_fixture_result(
               %{slug: "notes/support", type: "ticket", title: "Support", body: ""},
               human.uid
             )

    assert page.meta["entity_type"] == "ticket"
  end
end
