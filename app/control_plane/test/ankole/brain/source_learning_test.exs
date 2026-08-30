defmodule Ankole.Brain.SourceLearningTest do
  # The commit transaction is the guarantee under test: a run whose extracted
  # items all fail write validation must roll back whole. A committed empty
  # replacement would expire the old facts and advance the fingerprint, so a
  # model-quality failure would read as `unchanged` forever.
  use Ankole.AIGatewayCase

  import Ecto.Query

  alias Ankole.AppConfigure
  alias Ankole.Brain.Objects
  alias Ankole.Brain.SchemaPacks
  alias Ankole.Brain.Schemas.Claim
  alias Ankole.Brain.Schemas.Object
  alias Ankole.Brain.Schemas.Source
  alias Ankole.Brain.SourceLearning
  alias Ankole.Brain.Sources
  alias Ankole.Repo

  setup do
    allow_cache_database_access()
    AppConfigure.Cache.clear_for_test()
    on_exit(fn -> AppConfigure.Cache.clear_for_test() end)

    {:ok, _result} = SchemaPacks.install_packs([])

    test_pid = self()
    {:ok, items_holder} = Agent.start_link(fn -> %{"items" => []} end)

    base_url =
      start_upstream_server(fn
        %{path: "chat/completions", body: body} ->
          prompt = body["messages"] |> List.first() |> Map.fetch!("content")
          send(test_pid, {:source_extraction_prompt, prompt})
          output = Agent.get(items_holder, & &1)

          {:json, 200, chat_completion_body(body["model"], Ankole.JSON.encode!(output))}

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

  test "an invalid extraction response leaves the source revision retryable",
       %{source: source, path: path, items_holder: holder} do
    File.write!(path, "Cobalt shipment arrived on time.")
    set_output(holder, %{"unexpected" => []})

    assert {:error, {:extraction_failed, :invalid_extraction_response}} =
             SourceLearning.learn(source.id)

    assert Repo.get!(Source, source.id).upstream_revision == nil
    assert source_claims(source) == []

    set_items(holder, [valid_item("Cobalt shipment arrived on time")])
    assert {:ok, %{status: :learned, claims: 1}} = SourceLearning.learn(source.id)
  end

  test "the Source owns its media body and instance write paths cannot take it over",
       %{source: source, path: path, items_holder: holder} do
    File.write!(path, "Source-owned body.")
    set_items(holder, [])

    assert {:ok, %{status: :learned, object_slug: slug}} = SourceLearning.learn(source.id)

    assert %Object{managed_by_source_id: owner, content_hash: content_hash} =
             Repo.get_by!(Object, slug: slug)

    assert owner == source.id

    assert Objects.editability(Repo.get_by!(Object, slug: slug)) == %{
             editable: false,
             edit_block_reason: "source_managed"
           }

    assert {:error, {:source_managed, ^slug, _details}} =
             Objects.update_object(
               slug,
               %{body: "instance edit", expected_content_hash: content_hash},
               :system
             )

    assert {:error, :not_library_managed} = Objects.fork_library_page(slug)
  end

  test "extraction reaches content beyond the former 96,000-character boundary",
       %{source: source, path: path, items_holder: holder} do
    tail_marker = "TAIL_WINDOW_MUST_BE_EXTRACTED"
    File.write!(path, String.duplicate("a", 96_000) <> tail_marker)
    set_items(holder, [])

    assert {:ok, %{status: :learned, windows: 9, claims: 0}} =
             SourceLearning.learn(source.id)

    prompts =
      for _index <- 1..9 do
        assert_receive {:source_extraction_prompt, prompt}
        prompt
      end

    assert Enum.any?(prompts, &String.contains?(&1, tail_marker))
  end

  test "an archive during extraction fences every late write", %{source: source, path: path} do
    test_pid = self()

    configure_extraction_provider!("brain-source-archive-fence", fn body ->
      send(test_pid, {:archive_fence_reached, self()})

      receive do
        :release_archive_fence -> :ok
      end

      chat_completion_body(
        body["model"],
        Ankole.JSON.encode!(%{"items" => [valid_item("Late archived claim")]})
      )
    end)

    File.write!(path, "ARCHIVE_FENCE_CONTENT")
    learning = Task.async(fn -> SourceLearning.learn(source.id) end)

    assert_receive {:archive_fence_reached, upstream_request}
    assert {:ok, _archived} = Sources.archive(source.id)
    send(upstream_request, :release_archive_fence)

    assert Task.await(learning, 5_000) == {:error, :source_archived}
    assert Repo.get!(Source, source.id).upstream_revision == nil
    assert source_claims(source) == []
    refute Repo.exists?(Object |> where([object], object.title == "Field Notes"))
  end

  test "a late older extraction cannot replace a committed newer revision", %{
    source: source,
    path: path
  } do
    test_pid = self()

    configure_extraction_provider!("brain-source-revision-fence", fn body ->
      prompt = body["messages"] |> List.first() |> Map.fetch!("content")

      claim =
        if String.contains?(prompt, "REVISION_OLD") do
          send(test_pid, {:revision_fence_reached, self()})

          receive do
            :release_revision_fence -> :ok
          end

          "Claim from the old revision"
        else
          "Claim from the new revision"
        end

      chat_completion_body(
        body["model"],
        Ankole.JSON.encode!(%{"items" => [valid_item(claim)]})
      )
    end)

    File.write!(path, "REVISION_OLD")
    old_learning = Task.async(fn -> SourceLearning.learn(source.id) end)
    assert_receive {:revision_fence_reached, upstream_request}

    File.write!(path, "REVISION_NEW")
    assert {:ok, %{status: :learned, claims: 1}} = SourceLearning.learn(source.id)

    send(upstream_request, :release_revision_fence)
    assert Task.await(old_learning, 5_000) == {:error, :stale_run}

    assert [current] = source_claims(source)
    assert current.expired_at == nil
    assert current.claim == "Claim from the new revision"

    assert %Object{body: body} = Repo.get_by(Object, title: "Field Notes")
    assert body =~ "REVISION_NEW"
    refute body =~ "REVISION_OLD"
  end

  defp configure_extraction_provider!(provider_id, handler) do
    base_url =
      start_upstream_server(fn %{path: "chat/completions", body: body} ->
        {:json, 200, handler.(body)}
      end)

    {:ok, _provider} =
      ProviderConfigs.create_provider(%{
        provider_id: provider_id,
        provider_kind: "openrouter",
        base_url: base_url,
        credential_pool: %{"entries" => [%{"label" => "Default", "api_key" => "sk-test"}]}
      })

    {:ok, _value} =
      AppConfigure.put_global_by_key("brain.extraction_model", %{
        "provider_id" => provider_id,
        "model" => "fake-extract"
      })

    :ok
  end

  defp set_items(holder, items), do: set_output(holder, %{"items" => items})
  defp set_output(holder, output), do: Agent.update(holder, fn _output -> output end)

  defp valid_item(text),
    do: %{"claim" => text, "kind" => "fact", "notability" => "medium", "confidence" => 0.75}

  defp source_claims(source) do
    session = "source:" <> source.id

    Claim
    |> where([claim], claim.provenance_session == ^session)
    |> Repo.all()
  end
end
