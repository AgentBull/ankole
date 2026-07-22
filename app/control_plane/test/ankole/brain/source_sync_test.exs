defmodule Ankole.Brain.SourceSyncTest do
  use Ankole.DataCase, async: false

  import Ankole.PrincipalsFixtures

  alias Ankole.Brain.Knowledge
  alias Ankole.Brain.Jobs.EnqueueSourceSyncs
  alias Ankole.Brain.Jobs.SyncSource
  alias Ankole.Brain.Recall.Search
  alias Ankole.Brain.Scope
  alias Ankole.Brain.Schemas.Entry
  alias Ankole.Brain.Schemas.EntryBlock
  alias Ankole.Brain.Schemas.RetainedSource
  alias Ankole.Brain.SourceSync
  alias Ankole.Brain.Sources
  alias Ankole.Repo

  defmodule FakeConnector do
    @behaviour Ankole.Brain.SourceConnector

    @impl true
    def availability(%{locator: locator}), do: {:ok, state(locator).availability}

    @impl true
    def revision(%{locator: locator}), do: {:ok, state(locator).revision}

    @impl true
    def export(%{locator: locator}) do
      current = state(locator)

      {:ok,
       %{
         title: current.title,
         markdown: current.markdown,
         url: current.url
       }}
    end

    defp state(locator), do: Process.get({__MODULE__, locator})
  end

  defmodule BlockingConnector do
    @behaviour Ankole.Brain.SourceConnector

    def child_spec(owner) do
      %{id: __MODULE__, start: {__MODULE__, :start_link, [owner]}}
    end

    def start_link(owner), do: Agent.start_link(fn -> owner end, name: __MODULE__)

    @impl true
    def availability(reference), do: request(:availability, reference)

    @impl true
    def revision(reference), do: request(:revision, reference)

    @impl true
    def export(reference), do: request(:export, reference)

    defp request(operation, reference) do
      owner = Agent.get(__MODULE__, & &1)
      request_ref = make_ref()
      send(owner, {__MODULE__, self(), request_ref, operation, reference})

      receive do
        {^request_ref, response} -> response
      after
        5_000 -> {:error, :blocking_connector_timeout}
      end
    end
  end

  setup do
    %{principal: first_agent} = agent_fixture()
    %{principal: second_agent} = agent_fixture()
    %{principal: operator} = human_fixture()
    {:ok, first_scope} = Scope.for_store(first_agent.uid, "shared")
    {:ok, second_scope} = Scope.for_store(second_agent.uid, "shared")

    %{
      first_agent: first_agent,
      second_agent: second_agent,
      operator: operator,
      first_scope: first_scope,
      second_scope: second_scope,
      locator: "space/doc-1"
    }
  end

  test "a connector revision replaces one shared read-only mirror and withdrawal removes it",
       ctx do
    put_source(ctx.locator, %{
      availability: :available,
      revision: "1",
      title: "Operations manual",
      markdown:
        "# Current policy\n\nobsoleteunicorn is the active rule.\n\n## Recovery\n\nUse alpha.",
      url: "https://docs.example.test/doc-1"
    })

    assert {:ok, source} =
             SourceSync.register("fake_doc", ctx.locator,
               connector: FakeConnector,
               captured_by_uid: ctx.first_agent.uid
             )

    assert source.owner_uid == Scope.shared_owner_uid()
    assert source.store_key == "shared"
    assert source.capture_method == "fake_doc"
    assert source.connector_id == "fake_doc"
    assert source.revision == "1"

    first_mirror = mirror!(source.document_id)
    first_block_ids = mirror_block_ids(first_mirror.id)
    assert first_mirror.owner_uid == Scope.shared_owner_uid()
    assert first_mirror.properties["source_mirror"]
    assert first_mirror.properties["source_revision"] == "1"
    assert first_mirror.properties["source_url"] == "https://docs.example.test/doc-1"

    assert [_first, _second] =
             EntryBlock
             |> where([block], block.entry_id == ^first_mirror.id)
             |> order_by([block], asc: block.position)
             |> Repo.all()

    assert {:ok, opened_by_other_agent} =
             Knowledge.open(ctx.second_scope, first_mirror.id, block_limit: :all)

    assert opened_by_other_agent.entry.name == "Operations manual"

    assert {:error, :source_mirror_read_only} =
             Knowledge.apply_operations(
               ctx.second_scope,
               %{
                 operation: "set_summary",
                 entry_id: first_mirror.id,
                 expected_entry_lock_version: first_mirror.lock_version,
                 summary: "Local edit"
               },
               %{kind: :human, uid: ctx.second_agent.uid}
             )

    assert search_names(ctx.second_scope, "obsoleteunicorn") == ["Operations manual"]

    put_source(ctx.locator, %{
      availability: :available,
      revision: "1-metadata",
      title: "Operations manual",
      markdown:
        "# Current policy\n\nobsoleteunicorn is the active rule.\n\n## Recovery\n\nUse alpha.",
      url: "https://docs.example.test/doc-1?revision=metadata"
    })

    assert {:ok, %{status: :metadata_updated, revision: "1-metadata"}} =
             SourceSync.sync(source.id, connector: FakeConnector)

    metadata_only_mirror = mirror!(source.document_id)
    assert metadata_only_mirror.id == first_mirror.id
    assert mirror_block_ids(metadata_only_mirror.id) == first_block_ids
    assert metadata_only_mirror.properties["source_revision"] == "1-metadata"
    assert metadata_only_mirror.properties["source_url"] =~ "revision=metadata"

    put_source(ctx.locator, %{
      availability: :available,
      revision: "2",
      title: "Operations manual",
      markdown:
        "# Current policy\n\nreplacementphoenix is the active rule.\n\n## Recovery\n\nUse beta.",
      url: "https://docs.example.test/doc-1"
    })

    assert {:ok, %{status: :replaced, revision: "2"}} =
             SourceSync.sync(source.id, connector: FakeConnector)

    second_mirror = mirror!(source.document_id)
    refute second_mirror.id == first_mirror.id
    assert second_mirror.properties["source_revision"] == "2"
    assert {:error, :not_found} = Knowledge.open(ctx.first_scope, first_mirror.id)
    assert search_names(ctx.first_scope, "obsoleteunicorn") == []
    assert search_names(ctx.first_scope, "replacementphoenix") == ["Operations manual"]

    put_source(ctx.locator, %{
      availability: :deleted,
      revision: "2",
      title: "Operations manual",
      markdown: "not exported",
      url: nil
    })

    assert {:ok, %{status: :deleted}} = SourceSync.sync(source.id, connector: FakeConnector)
    assert Repo.get_by(Entry, id: second_mirror.id) == nil
    assert search_names(ctx.first_scope, "replacementphoenix") == []
    assert {:error, :not_found} = Sources.resolve(ctx.first_scope, source.document_id)
    assert Repo.get!(RetainedSource, source.id).sync_state == :deleted

    put_source(ctx.locator, %{
      availability: :available,
      revision: "3",
      title: "Operations manual",
      markdown: "# Current policy\n\nrestoredgriffin is active.",
      url: "https://docs.example.test/doc-1"
    })

    assert {:ok, %{status: :replaced, revision: "3"}} =
             SourceSync.sync(source.id, connector: FakeConnector)

    restored = mirror!(source.document_id)
    assert search_names(ctx.second_scope, "restoredgriffin") == ["Operations manual"]

    put_source(ctx.locator, %{
      availability: :access_lost,
      revision: "3",
      title: "Operations manual",
      markdown: "not exported",
      url: nil
    })

    assert {:ok, %{status: :access_lost}} =
             SourceSync.sync(source.id, connector: FakeConnector)

    refute Repo.get(Entry, restored.id)
    assert Repo.get!(RetainedSource, source.id).sync_state == :access_lost
  end

  test "manual pasted and URL text becomes knowledge while binary bytes remain a source", ctx do
    assert {:ok, %{resource_kind: :entry, entry_id: pasted_id}} =
             Sources.capture_material(
               ctx.first_scope,
               %{
                 kind: "paste",
                 title: "Pasted handbook",
                 content: "manualpastefact is immediately searchable."
               },
               ctx.operator.uid
             )

    assert {:ok, pasted} = Knowledge.open(ctx.second_scope, pasted_id, block_limit: :all)
    assert pasted.entry.owner_uid == Scope.shared_owner_uid()
    assert pasted.entry.type == "external_document"
    assert search_names(ctx.second_scope, "manualpastefact") == ["Pasted handbook"]
    assert Repo.aggregate(RetainedSource, :count) == 0

    text_fetch = fn owner_uid, url ->
      assert owner_uid == ctx.first_agent.uid
      assert url == "https://example.test/guide"

      {:ok,
       %{
         final_url: url,
         media_type: "text/markdown",
         content: "urlmanualfact is current."
       }}
    end

    assert {:ok, %{resource_kind: :entry, entry_id: url_entry_id}} =
             Sources.capture_material(
               ctx.first_scope,
               %{kind: "url", url: "https://example.test/guide", title: "URL guide"},
               ctx.operator.uid,
               fetch_fun: text_fetch
             )

    assert {:ok, _entry} = Knowledge.open(ctx.second_scope, url_entry_id)
    assert search_names(ctx.second_scope, "urlmanualfact") == ["URL guide"]
    assert Repo.aggregate(RetainedSource, :count) == 0

    binary_fetch = fn _owner_uid, url ->
      {:ok,
       %{
         final_url: url,
         media_type: "application/pdf",
         content: "%PDF-binary"
       }}
    end

    assert {:ok, %{resource_kind: :retained_source, source: binary}} =
             Sources.capture_material(
               ctx.first_scope,
               %{kind: "url", url: "https://example.test/manual.pdf"},
               ctx.operator.uid,
               fetch_fun: binary_fetch
             )

    assert binary.capture_method == "file"
    assert binary.owner_uid == Scope.shared_owner_uid()
    assert binary.learning_agent_uid == ctx.first_agent.uid
    assert {:ok, %{content: "%PDF-binary"}} = Sources.raw(ctx.second_scope, binary.document_id)
  end

  test "the periodic gate enqueues only connector sources whose configured interval elapsed",
       ctx do
    put_source(ctx.locator, %{
      availability: :available,
      revision: "1",
      title: "Scheduled manual",
      markdown: "scheduledsourcefact is current.",
      url: nil
    })

    assert {:ok, source} =
             SourceSync.register("fake_doc", ctx.locator, connector: FakeConnector)

    before_due = DateTime.add(source.last_synced_at, 14, :minute)
    due = DateTime.add(source.last_synced_at, 16, :minute)

    assert {:ok, 0} =
             perform_job(EnqueueSourceSyncs, %{"now" => DateTime.to_iso8601(before_due)})

    assert {:ok, 1} = perform_job(EnqueueSourceSyncs, %{"now" => DateTime.to_iso8601(due)})
    assert [%Oban.Job{args: %{"source_id" => source_id}}] = all_enqueued(worker: SyncSource)
    assert source_id == source.id
  end

  test "a stale export cannot replace a newer source revision", ctx do
    put_source(ctx.locator, %{
      availability: :available,
      revision: "1",
      title: "Operations manual",
      markdown: "initialsourcefact is current.",
      url: nil
    })

    assert {:ok, source} =
             SourceSync.register("fake_doc", ctx.locator, connector: FakeConnector)

    start_supervised!({BlockingConnector, self()})

    stale_sync =
      Task.async(fn -> SourceSync.sync(source.id, connector: BlockingConnector) end)

    reply_connector(:availability, {:ok, :available})
    reply_connector(:revision, {:ok, "2"})
    export_request = connector_request(:export)

    put_source(ctx.locator, %{
      availability: :available,
      revision: "3",
      title: "Operations manual",
      markdown: "newestsourcefact is current.",
      url: nil
    })

    assert {:ok, %{status: :replaced, revision: "3"}} =
             SourceSync.sync(source.id, connector: FakeConnector)

    reply_connector(export_request, {
      :ok,
      %{
        title: "Operations manual",
        markdown: "stalecandidatefact must not become current.",
        url: nil
      }
    })

    assert Task.await(stale_sync) == {:error, :source_sync_conflict}

    current = Repo.get!(RetainedSource, source.id)
    assert current.revision == "3"
    assert current.sync_state == :current
    assert mirror!(source.document_id).properties["source_revision"] == "3"
    assert search_names(ctx.first_scope, "newestsourcefact") == ["Operations manual"]
    assert search_names(ctx.first_scope, "stalecandidatefact") == []
  end

  test "a stale unchanged-revision check cannot restore a withdrawn source", ctx do
    put_source(ctx.locator, %{
      availability: :available,
      revision: "1",
      title: "Operations manual",
      markdown: "withdrawnsourcefact is current.",
      url: nil
    })

    assert {:ok, source} =
             SourceSync.register("fake_doc", ctx.locator, connector: FakeConnector)

    start_supervised!({BlockingConnector, self()})

    stale_sync =
      Task.async(fn -> SourceSync.sync(source.id, connector: BlockingConnector) end)

    reply_connector(:availability, {:ok, :available})
    revision_request = connector_request(:revision)

    put_source(ctx.locator, %{
      availability: :deleted,
      revision: "1",
      title: "Operations manual",
      markdown: "not exported",
      url: nil
    })

    assert {:ok, %{status: :deleted}} =
             SourceSync.sync(source.id, connector: FakeConnector)

    reply_connector(revision_request, {:ok, "1"})

    assert Task.await(stale_sync) == {:error, :source_sync_conflict}
    assert Repo.get!(RetainedSource, source.id).sync_state == :deleted

    refute Repo.exists?(
             from entry in Entry,
               where:
                 fragment(
                   "?->>'source_document_id' = ?",
                   entry.properties,
                   ^source.document_id
                 )
           )
  end

  defp put_source(locator, state), do: Process.put({FakeConnector, locator}, state)

  defp connector_request(operation) do
    assert_receive {BlockingConnector, caller, request_ref, ^operation, _reference}, 1_000
    {caller, request_ref}
  end

  defp reply_connector(operation, response) when is_atom(operation) do
    operation
    |> connector_request()
    |> reply_connector(response)
  end

  defp reply_connector({caller, request_ref}, response) do
    send(caller, {request_ref, response})
  end

  defp mirror!(document_id) do
    Repo.one!(
      from entry in Entry,
        where: fragment("?->>'source_document_id' = ?", entry.properties, ^document_id)
    )
  end

  defp mirror_block_ids(entry_id) do
    EntryBlock
    |> where([block], block.entry_id == ^entry_id)
    |> order_by([block], asc: block.position)
    |> select([block], block.id)
    |> Repo.all()
  end

  defp search_names(scope, query) do
    assert {:ok, result} =
             Search.search(scope, %{
               "query" => query,
               "layer" => "knowledge",
               "store" => "shared",
               "limit" => 10
             })

    Enum.map(result["results"], & &1["name"])
  end
end
