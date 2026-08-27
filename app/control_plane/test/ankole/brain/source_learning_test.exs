defmodule Ankole.Brain.SourceLearningTest do
  # The commit transaction is the guarantee under test: a run whose extracted
  # items all fail write validation must roll back whole. A committed empty
  # replacement would expire the old facts and advance the fingerprint, so a
  # model-quality failure would read as `unchanged` forever.
  use Ankole.AIGatewayCase

  import Ecto.Query

  alias Ankole.AppConfigure
  alias Ankole.Brain.SchemaPacks
  alias Ankole.Brain.Schemas.Claim
  alias Ankole.Brain.Schemas.Source
  alias Ankole.Brain.SourceLearning
  alias Ankole.Repo

  setup do
    allow_cache_database_access()
    AppConfigure.Cache.clear_for_test()
    on_exit(fn -> AppConfigure.Cache.clear_for_test() end)

    {:ok, _result} = SchemaPacks.install_packs([])

    {:ok, items_holder} = Agent.start_link(fn -> [] end)

    base_url =
      start_upstream_server(fn
        %{path: "chat/completions", body: body} ->
          items = Agent.get(items_holder, & &1)

          {:json, 200,
           chat_completion_body(body["model"], Ankole.JSON.encode!(%{"items" => items}))}

        %{path: "embeddings", body: body} ->
          data =
            body["input"]
            |> List.wrap()
            |> Enum.with_index()
            |> Enum.map(fn {_text, index} ->
              %{"index" => index, "embedding" => List.duplicate(0.5, 8)}
            end)

          {:json, 200, %{"data" => data, "usage" => %{"prompt_tokens" => 1, "total_tokens" => 1}}}
      end)

    {:ok, _provider} =
      ProviderConfigs.create_provider(%{
        provider_id: "brain-source",
        provider_kind: "openrouter",
        base_url: base_url,
        credential_pool: %{"entries" => [%{"label" => "Default", "api_key" => "sk-test"}]}
      })

    {:ok, _value} =
      AppConfigure.put_global_by_key("brain.extraction_model", %{
        "provider_id" => "brain-source",
        "model" => "fake-extract"
      })

    {:ok, _value} =
      AppConfigure.put_global_by_key("brain.embedding_model", %{
        "provider_id" => "brain-source",
        "model" => "fake-embed",
        "dimensions" => 8
      })

    path =
      Path.join(System.tmp_dir!(), "source-learning-#{System.unique_integer([:positive])}.txt")

    on_exit(fn -> File.rm(path) end)

    {:ok, source} =
      SourceLearning.register_source(%{upstream_id: path, kind: "file", name: "Field Notes"})

    %{source: source, path: path, items_holder: items_holder}
  end

  test "an all-rejected extraction rolls back whole and the next run retries",
       %{source: source, path: path, items_holder: holder} do
    File.write!(path, "Cobalt shipment arrived on time.")
    set_items(holder, [valid_item("Cobalt shipment arrived on time")])

    assert {:ok, %{status: :learned, claims: 1, rejected: 0}} = SourceLearning.learn(source.id)

    first_revision = Repo.get!(Source, source.id).upstream_revision
    assert [%Claim{expired_at: nil} = original] = source_claims(source)

    # The changed content extracts only items the write side rejects.
    File.write!(path, "Cobalt shipment was cancelled.")

    set_items(holder, [
      %{"claim" => "Cobalt shipment was cancelled", "kind" => "not-a-kind", "confidence" => 0.75}
    ])

    assert {:error, {:all_items_rejected, [_reason | _rest]}} = SourceLearning.learn(source.id)

    # Rolled back whole: the old fact is still current and the fingerprint
    # did not advance, so the same revision stays learnable.
    assert Repo.get!(Source, source.id).upstream_revision == first_revision
    assert [%Claim{id: kept_id, expired_at: nil}] = source_claims(source)
    assert kept_id == original.id

    set_items(holder, [valid_item("Cobalt shipment was cancelled")])
    assert {:ok, %{status: :learned, claims: 1}} = SourceLearning.learn(source.id)

    claims = source_claims(source)
    assert Enum.any?(claims, &(&1.id == original.id and &1.expired_at != nil))
    assert Enum.any?(claims, &(is_nil(&1.expired_at) and &1.claim =~ "cancelled"))
  end

  defp set_items(holder, items), do: Agent.update(holder, fn _items -> items end)

  defp valid_item(text),
    do: %{"claim" => text, "kind" => "fact", "notability" => "medium", "confidence" => 0.75}

  defp source_claims(source) do
    session = "source:" <> source.id

    Claim
    |> where([claim], claim.provenance_session == ^session)
    |> Repo.all()
  end
end
