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
  alias Ankole.Kernel.RuntimeFabric
  alias Ankole.Principals
  alias Ankole.Repo
  alias Ankole.RuntimeFabric.V1, as: FabricProto
  alias Ankole.SignalsGateway.ActorRuntime.Schemas.AgentComputerWorker
  alias Ankole.SignalsGateway.ActorRuntime.Transport.Broker

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

    maintainer_uid =
      configure_brain_maintainer_profile!("light", "brain-source", "fake-extract")

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

    %{source: source, path: path, items_holder: items_holder, maintainer_uid: maintainer_uid}
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

  test "a URL Source uses the maintainer Agent web_fetch profile and execution policy", %{
    items_holder: holder,
    maintainer_uid: maintainer_uid
  } do
    test_pid = self()
    url = "https://127.0.0.1/provider-source"

    base_url =
      start_upstream_server(fn request ->
        send(test_pid, {:web_fetch_provider_request, request})

        {:json, 200,
         %{
           "data" => %{
             "url" => request.body["url"],
             "title" => "Provider Source",
             "content" => "Provider-rendered source body"
           }
         }}
      end)

    {:ok, _provider} =
      ProviderConfigs.create_provider(%{
        provider_id: "brain-source-web-fetch",
        provider_kind: "jina_reader",
        base_url: base_url,
        credential_pool: %{
          "entries" => [%{"label" => "Default", "api_key" => "jina-test"}]
        }
      })

    configure_brain_maintainer_profile!("web_fetch", "brain-source-web-fetch", "default")
    {:ok, true} = AppConfigure.put_global_by_key("security.ssrf_filter", true)

    {:ok, false} =
      AppConfigure.put_for_agent_by_key(maintainer_uid, "security.ssrf_filter", false)

    set_items(holder, [])

    {:ok, source} =
      SourceLearning.register_source(%{
        upstream_id: url,
        kind: "url",
        name: "Provider URL Source"
      })

    assert {:ok, %{status: :learned, claims: 0}} = SourceLearning.learn(source.id)

    assert_receive {:web_fetch_provider_request, request}
    assert request.body["url"] == url
    assert request.headers["authorization"] == "Bearer jina-test"
    assert %Object{body: body} = Repo.get_by!(Object, title: "Provider URL Source")
    assert body =~ "Provider-rendered source body"
  end

  test "a URL Source without a web_fetch profile uses the Worker's ankole-browser",
       %{items_holder: holder} do
    url = "https://example.com/local-source"
    route = "brain-web-fetch-#{System.unique_integer([:positive])}"
    now = DateTime.utc_now(:microsecond)

    Repo.insert!(%AgentComputerWorker{
      worker_id: "brain-web-fetch-worker-#{System.unique_integer([:positive])}",
      incarnation_id: Ecto.UUID.generate(),
      status: "ready",
      version: "test",
      capacity: %{},
      load: %{},
      transport_route: route,
      last_worker_heartbeat_at: now,
      started_at: now,
      metadata: %{"runtime" => "test"}
    })

    :ok = Broker.register_local_worker(route, self())
    on_exit(fn -> Broker.unregister_local_worker(route) end)
    set_items(holder, [])

    {:ok, source} =
      SourceLearning.register_source(%{
        upstream_id: url,
        kind: "url",
        name: "Local Browser URL Source"
      })

    learning = Task.async(fn -> SourceLearning.learn(source.id) end)

    assert_receive {:actor_lane,
                    %FabricProto.Envelope{
                      body: {:rpc_request, %FabricProto.RPCRequest{} = request}
                    }},
                   1_000

    assert request.method == "web_fetch.rendered"

    assert {:ok,
            %FabricProto.RenderedWebFetchRequest{
              urls: [^url],
              ssrf_filter: false,
              idle_ttl_ms: 1_800_000
            }} = FabricProto.RenderedWebFetchRequest.decode(request.payload)

    response_payload =
      encode_proto(%FabricProto.RenderedWebFetchResponse{
        body_json:
          Ankole.JSON.encode!(%{
            "success" => true,
            "results" => [
              %{"url" => url, "title" => "Local Source", "text" => "Locally rendered body"}
            ]
          })
      })

    send(
      Broker,
      {:runtime_fabric_router_received, route,
       RuntimeFabric.encode_envelope(%FabricProto.Envelope{
         message_id: "brain-web-fetch-response",
         correlation_id: request.request_id,
         lane: :LANE_RPC,
         durability: :CONTROL_EPHEMERAL,
         body:
           {:rpc_response,
            %FabricProto.RPCResponse{
              request_id: request.request_id,
              payload: response_payload
            }}
       })}
    )

    assert {:ok, %{status: :learned, claims: 0}} = Task.await(learning, 5_000)
    assert %Object{body: body} = Repo.get_by!(Object, title: "Local Browser URL Source")
    assert body =~ "Locally rendered body"
  end

  test "a disabled maintainer Agent prevents provider and local URL fetching", %{
    maintainer_uid: maintainer_uid
  } do
    test_pid = self()
    url = "https://example.com/disabled-maintainer-source"
    route = "brain-disabled-web-fetch-#{System.unique_integer([:positive])}"
    now = DateTime.utc_now(:microsecond)

    base_url =
      start_upstream_server(fn request ->
        send(test_pid, {:disabled_maintainer_provider_request, request})
        {:json, 500, %{"error" => "must not be called"}}
      end)

    {:ok, _provider} =
      ProviderConfigs.create_provider(%{
        provider_id: "brain-disabled-web-fetch",
        provider_kind: "jina_reader",
        base_url: base_url,
        credential_pool: %{
          "entries" => [%{"label" => "Default", "api_key" => "jina-test"}]
        }
      })

    configure_brain_maintainer_profile!("web_fetch", "brain-disabled-web-fetch", "default")

    Repo.insert!(%AgentComputerWorker{
      worker_id: "brain-disabled-web-fetch-worker-#{System.unique_integer([:positive])}",
      incarnation_id: Ecto.UUID.generate(),
      status: "ready",
      version: "test",
      capacity: %{},
      load: %{},
      transport_route: route,
      last_worker_heartbeat_at: now,
      started_at: now,
      metadata: %{"runtime" => "test"}
    })

    :ok = Broker.register_local_worker(route, self())
    on_exit(fn -> Broker.unregister_local_worker(route) end)

    {:ok, source} =
      SourceLearning.register_source(%{
        upstream_id: url,
        kind: "url",
        name: "Disabled Maintainer URL Source"
      })

    assert {:ok, %{status: :disabled}} = Principals.disable_principal(maintainer_uid)
    assert {:error, :brain_maintainer_agent_disabled} = SourceLearning.learn(source.id)
    refute_receive {:disabled_maintainer_provider_request, _request}
    refute_receive {:actor_lane, _envelope}
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

    configure_brain_maintainer_profile!("light", provider_id, "fake-extract")

    :ok
  end

  defp set_items(holder, items), do: set_output(holder, %{"items" => items})
  defp set_output(holder, output), do: Agent.update(holder, fn _output -> output end)

  defp encode_proto(message) do
    {iodata, _size} = message.__struct__.encode!(message)
    IO.iodata_to_binary(iodata)
  end

  defp valid_item(text),
    do: %{"claim" => text, "kind" => "fact", "notability" => "medium", "confidence" => 0.75}

  defp source_claims(source) do
    session = "source:" <> source.id

    Claim
    |> where([claim], claim.provenance_session == ^session)
    |> Repo.all()
  end
end
