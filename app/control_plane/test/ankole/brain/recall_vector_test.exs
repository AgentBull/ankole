defmodule Ankole.Brain.RecallVectorTest do
  # Runs the real ANN and exact-order SQL against PostgreSQL with a bound
  # query vector. The regression under test: an uncast bound parameter makes
  # `subvector(unknown, ...)` ambiguous (42725) and kills the vector arm.
  use Ankole.AIGatewayCase

  alias Ankole.AppConfigure
  alias Ankole.Brain.Claims
  alias Ankole.Brain.Objects
  alias Ankole.Brain.Recall
  alias Ankole.Brain.SchemaPacks

  @dimensions 8

  setup do
    allow_cache_database_access()
    AppConfigure.Cache.clear_for_test()
    on_exit(fn -> AppConfigure.Cache.clear_for_test() end)

    {:ok, _result} = SchemaPacks.install_packs([])

    base_url =
      start_upstream_server(fn %{path: "embeddings", body: body} ->
        data =
          body["input"]
          |> List.wrap()
          |> Enum.with_index()
          |> Enum.map(fn {text, index} ->
            %{"index" => index, "embedding" => fake_embedding(text)}
          end)

        {:json, 200, %{"data" => data, "usage" => %{"prompt_tokens" => 1, "total_tokens" => 1}}}
      end)

    {:ok, _provider} =
      ProviderConfigs.create_provider(%{
        provider_id: "brain-embed",
        provider_kind: "openrouter",
        base_url: base_url,
        credential_pool: %{"entries" => [%{"label" => "Default", "api_key" => "sk-test"}]}
      })

    {:ok, _value} =
      AppConfigure.put_global_by_key("brain.embedding_model", %{
        "provider_id" => "brain-embed",
        "model" => "fake-embed",
        "dimensions" => @dimensions
      })

    %{principal: member} = human_fixture()
    %{member: member}
  end

  test "vector arm retrieves and orders claims through the ANN query", %{member: member} do
    {:ok, object} =
      Objects.create_object(
        %{slug: "concepts/pigments", type: "concept", title: "Pigments", body: "Pigment notes."},
        member.uid
      )

    {:ok, %{claim: cobalt_fact}} = write_fact(object, member, "Cobalt shipment arrived on time")
    {:ok, %{claim: graphite_fact}} = write_fact(object, member, "Graphite order was cancelled")

    # No token overlap with either claim, so BM25 finds nothing; the fake
    # upstream maps "probe" and "cobalt" to the same direction, so only the
    # vector arm can surface cobalt_fact, and it must rank above graphite_fact.
    assert {:ok, result} = Recall.recall(member.uid, %{query: "warehouse probe zzz"})

    ids = Enum.map(result.claims, & &1.id)
    assert cobalt_fact.id in ids

    graphite_index = Enum.find_index(ids, &(&1 == graphite_fact.id))

    if graphite_index do
      assert Enum.find_index(ids, &(&1 == cobalt_fact.id)) < graphite_index
    end
  end

  defp write_fact(object, member, claim_text) do
    Claims.write_fact(
      %{
        object_slug: object.slug,
        claim: claim_text,
        kind: "fact",
        holder: "world",
        audience_scope: "world",
        notability: "medium",
        confidence: 0.9,
        valid_from: DateTime.utc_now(:microsecond),
        provenance: "test"
      },
      member.uid
    )
  end

  defp fake_embedding(text) do
    direction =
      if String.contains?(String.downcase(text), ["cobalt", "probe"]), do: 0, else: 1

    for index <- 0..(@dimensions - 1) do
      if index == direction, do: 1.0, else: 0.0
    end
  end
end
