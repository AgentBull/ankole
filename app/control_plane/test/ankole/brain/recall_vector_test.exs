defmodule Ankole.Brain.RecallVectorTest do
  # Runs the real ANN and exact-order SQL against PostgreSQL with a bound
  # query vector. The regression under test: an uncast bound parameter makes
  # `subvector(unknown, ...)` ambiguous (42725) and kills the vector arm.
  use Ankole.AIGatewayCase

  alias Ankole.AppConfigure
  alias Ankole.Brain.Claims
  alias Ankole.Brain.Embeddings
  alias Ankole.Brain.Objects
  alias Ankole.Brain.Recall
  alias Ankole.Brain.SchemaPacks
  alias Ankole.Brain.Schemas.Claim
  alias Ankole.Brain.SelfHealing
  alias Ankole.Kernel, as: NativeKernel
  alias Ankole.Repo

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

  test "vector arm ignores rows from another embedding signature", %{member: member} do
    {:ok, object} =
      Objects.create_object(
        %{slug: "concepts/model-switch", type: "concept", title: "Model Switch"},
        member.uid
      )

    {:ok, %{claim: stale_fact}} =
      write_fact(object, member, "Cobalt shipment arrived on time")

    {:ok, _value} =
      AppConfigure.put_global_by_key("brain.embedding_model", %{
        "provider_id" => "brain-embed",
        "model" => "fake-embed-v2",
        "dimensions" => @dimensions
      })

    # The upstream returns the same vector for both model names. Only the
    # signature filter can keep this stale row out of the pure-vector result.
    assert {:ok, result} = Recall.recall(member.uid, %{query: "warehouse probe zzz"})
    refute stale_fact.id in Enum.map(result.claims, & &1.id)
  end

  test "embedding signature follows the provider snapshot resolved by AIGateway" do
    handler_id = {__MODULE__, make_ref()}
    marker = {__MODULE__, make_ref()}
    target = self()
    event = Repo.config()[:telemetry_prefix] ++ [:query]

    :ok =
      :telemetry.attach(
        handler_id,
        event,
        fn _event, _measurements, metadata, {target, marker} ->
          if self() == target and is_binary(metadata.query) and
               String.contains?(metadata.query, ~s(FROM "ai_gateway_providers")) and
               is_nil(Process.get(marker)) do
            Process.put(marker, true)

            {:ok, _provider} =
              ProviderConfigs.update_provider("brain-embed", %{
                provider_kind: "openai_compatible",
                connection_options: %{}
              })
          end
        end,
        {target, marker}
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    assert {:ok, {[_vector], signature}} = Embeddings.embed_texts(["Cobalt snapshot probe"])
    assert Process.get(marker)
    assert signature == NativeKernel.xxh3_128_hex("openrouter|fake-embed|#{@dimensions}")
  end

  test "self-healing skips deleted Object claims and keeps channel claims", %{member: member} do
    {:ok, object} =
      Objects.create_object(
        %{slug: "concepts/deleted-embedding", type: "concept", title: "Deleted Embedding"},
        member.uid
      )

    {:ok, %{claim: object_claim}} =
      write_fact(object, member, "Cobalt object memory must stay forgotten")

    channel = insert_channel!()

    {:ok, %{claim: channel_claim}} =
      Claims.write_fact(
        %{
          signal_gateway_channel_id: channel.id,
          claim: "Cobalt channel memory remains live",
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

    old_signature = object_claim.embedding_signature
    assert channel_claim.embedding_signature == old_signature

    {:ok, _value} =
      AppConfigure.put_global_by_key("brain.embedding_model", %{
        "provider_id" => "brain-embed",
        "model" => "fake-embed-v2",
        "dimensions" => @dimensions
      })

    assert {:ok, _object} = Objects.soft_delete(object.slug)
    assert %{claims: 1} = SelfHealing.embed_pending()

    current_signature = NativeKernel.xxh3_128_hex("openrouter|fake-embed-v2|#{@dimensions}")
    assert Repo.get!(Claim, channel_claim.id).embedding_signature == current_signature
    assert Repo.get!(Claim, object_claim.id).embedding_signature == old_signature
  end

  test "evidence found by both routes outranks a fresher single-route claim", %{member: member} do
    {:ok, object} =
      Objects.create_object(
        %{slug: "concepts/orders", type: "concept", title: "Orders", body: "Order notes."},
        member.uid
      )

    # BM25 and the vector arm both rank this first, but at half confidence.
    {:ok, %{claim: both_routes}} =
      write_fact(object, member, "Cobalt shipment arrived on time", 0.5)

    # Only the vector arm finds this, at full confidence.
    {:ok, %{claim: vector_only}} =
      write_fact(object, member, "Graphite order was cancelled", 0.9)

    assert {:ok, result} = Recall.recall(member.uid, %{query: "cobalt probe zzz"})

    ids = Enum.map(result.claims, & &1.id)
    both_index = Enum.find_index(ids, &(&1 == both_routes.id))
    vector_index = Enum.find_index(ids, &(&1 == vector_only.id))

    assert both_index
    assert vector_index

    # The kernel's fused score is additive, about twice a single-route score
    # for a double hit, so half the confidence does not flip the order. A
    # score rebuilt from the final rank would flatten that margin and put the
    # full-confidence single-route claim first.
    assert both_index < vector_index
  end

  defp write_fact(object, member, claim_text, confidence \\ 0.9) do
    Claims.write_fact(
      %{
        object_slug: object.slug,
        claim: claim_text,
        kind: "fact",
        holder: "world",
        audience_scope: "world",
        notability: "medium",
        confidence: confidence,
        valid_from: DateTime.utc_now(:microsecond),
        provenance: "test"
      },
      member.uid
    )
  end

  defp insert_channel! do
    now = DateTime.utc_now(:microsecond)

    Repo.insert!(
      Ankole.SignalsGateway.Channel.changeset(%Ankole.SignalsGateway.Channel{}, %{
        id: "test:embedding-#{System.unique_integer([:positive])}",
        kind: :im_dm,
        reply_mode: :entry,
        metadata: %{},
        raw_payload: %{},
        first_seen_at: now,
        last_seen_at: now
      })
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
