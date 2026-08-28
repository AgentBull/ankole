defmodule Ankole.Brain.VocabularyTest do
  use Ankole.DataCase, async: true

  import Ankole.PrincipalsFixtures

  alias Ankole.Brain.Objects
  alias Ankole.Brain.SchemaPacks
  alias Ankole.Brain.Vocabulary

  test "reads the shipped vocabulary and matches exact and near terms" do
    terms = Vocabulary.terms()
    assert "ticket" in terms

    assert ["ticket"] = Vocabulary.closest_terms("Ticket")
    assert "ticket" in Vocabulary.closest_terms("tickets")
    assert Vocabulary.closest_terms("zzzzqqqq") == []
  end

  test "a type rejection carries the closest vocabulary terms" do
    {:ok, _result} = SchemaPacks.install_packs([])
    %{principal: human} = human_fixture()

    assert {:error, {:unknown_object_type, "tickets", details}} =
             Objects.create_object(
               %{slug: "notes/some-note", type: "tickets", title: "Note", body: ""},
               human.uid
             )

    assert "note" in details.installed_types
    assert "ticket" in details.vocabulary_terms
  end
end
