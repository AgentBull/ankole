defmodule Ankole.Brain.ToolsTest do
  use Ankole.DataCase, async: true
  import Ankole.PrincipalsFixtures
  import Ankole.BrainFixtures
  alias Ankole.Brain.{Tools, Claims}
  alias Ankole.Brain.Schemas.Claim

  setup do
    %{principal: human} = human_fixture()

    {:ok, page} =
      page_fixture_result(
        %{
          slug: "concepts/wire",
          title: "Wire Format",
          body: "Wire format evidence.",
          meta: %{"aliases" => ["Wire Format"]}
        },
        human.uid
      )

    context = %Tools.Context{
      querier_uid: human.uid,
      disclosure: Ankole.Brain.Access.open_disclosure(),
      default_write_scope: {:ok, page.id},
      holder_default: "world"
    }

    %{human: human, page: page, context: context}
  end

  test "catalog contains atomic knowledge operations", ctx do
    assert Tools.operations() == ~w(remember recall entity whoknows synthesize delta write_object)

    for spec <- Tools.function_specs(Tools.operations()) do
      assert spec["parameters"]["type"] == "object"
      assert is_binary(spec["description"])
    end

    for removed <- ~w(get_page put_page edit_page learn_source) do
      assert {:error, {:unknown_operation, ^removed}} = Tools.execute(removed, %{}, ctx.context)
    end
  end

  test "remember accepts no entity and uses the current source", ctx do
    assert {:ok, result} =
             Tools.execute(
               "remember",
               %{"claim" => "The wire format uses dated facts", "provenance" => "Meeting note"},
               ctx.context
             )

    claim = Repo.get!(Claim, result["claim_id"])
    assert result["status"] == "inserted"
    assert {:ok, ^result} = Ankole.Ash.Types.JSONMap.cast_input(result, [])
    assert claim.subject_page_id == nil
    assert claim.source_node_id == ctx.page.id
    assert {:ok, recall} = Tools.execute("recall", %{"query" => "wire format"}, ctx.context)
    assert Enum.any?(recall["claims"], &(&1["id"] == claim.id))
    assert is_binary(Ankole.JSON.encode!(recall))
  end

  test "explicit sources use the request visibility intersection", ctx do
    %{principal: other} = human_fixture()
    source = source_node("principal:" <> other.uid)

    assert {:error, :forbidden} =
             Tools.execute(
               "remember",
               %{
                 "claim" => "Private assertion",
                 "provenance" => "note",
                 "source_node_id" => source
               },
               ctx.context
             )
  end

  test "entity and context pack resolve metadata aliases", ctx do
    assert {:ok, _} =
             Claims.write_fact(
               %{
                 subject_page_id: ctx.page.id,
                 source_node_id: ctx.page.id,
                 claim: "Wire format serializes dated facts",
                 kind: "fact",
                 holder: "world",
                 confidence: 0.75,
                 notability: "medium",
                 valid_from: DateTime.utc_now(:microsecond),
                 provenance: "spec"
               },
               ctx.human.uid
             )

    assert {:ok, %{"entity" => entity}} =
             Tools.execute("entity", %{"name" => "Wire Format"}, ctx.context)

    assert entity["id"] == ctx.page.id
    assert is_binary(Ankole.JSON.encode!(entity))
    assert {:ok, ^entity} = Ankole.Ash.Types.JSONMap.cast_input(entity, [])

    assert {:ok, delta} = Tools.execute("delta", %{"entity" => "Wire Format"}, ctx.context)
    assert {:ok, ^delta} = Ankole.Ash.Types.JSONMap.cast_input(delta, [])

    pack = Tools.context_pack(ctx.context, %{recent_text: "Wire Format"})
    assert Enum.any?(pack.entities, &(&1.id == ctx.page.id))
  end
end
