defmodule Ankole.Brain.FilePagesTest do
  # File pages enter Brain through the extraction cache that Pod writes. The
  # tests upload real files, so chunks, facts, and timelines follow the same
  # transactions as in production.
  use Ankole.AIGatewayCase

  import Ecto.Query

  alias Ankole.Brain.{Chunks, Config, Dreaming, GetPage, Objects, SourceLearning, Timelines}
  alias Ankole.Brain.Schemas.{Chunk, Claim, Timeline}
  alias Ankole.Pod.{FileCache, Files, Pages, Spreadsheets}
  alias Ankole.Pod.Jobs.SyncFileCache
  alias Ankole.Repo

  @csv "sku,region,owner\nSKU-100,APAC,Alice\nSKU-200,EMEA,Bob\n"

  setup do
    {:ok, _result} = Ankole.Brain.SchemaPacks.install_packs([])

    test_pid = self()
    {:ok, output} = Agent.start_link(fn -> %{"items" => []} end)

    base_url =
      start_upstream_server(fn %{path: "chat/completions", body: body} ->
        send(test_pid, {:prompt, body["messages"] |> List.first() |> Map.fetch!("content")})
        reply = Ankole.JSON.encode!(Agent.get(output, & &1))
        {:json, 200, chat_completion_body(body["model"], reply)}
      end)

    {:ok, _provider} =
      ProviderConfigs.create_provider(%{
        provider_id: "brain-files",
        provider_kind: "openrouter",
        base_url: base_url,
        credential_pool: %{"entries" => [%{"label" => "Default", "api_key" => "sk-test"}]}
      })

    configure_brain_maintainer_profile!("light", "brain-files", "fake-extract")
    configure_brain_maintainer_profile!("heavy", "brain-files", "fake-dream")

    owner = human_fixture().principal
    actor = actor_fixture(owner)
    {:ok, folder} = Pages.create(actor, %{type: :doc, metadata: %{"extract_facts" => true}})

    %{owner: owner, actor: actor, folder: folder, output: output}
  end

  test "a public file is chunked with its table header, and a private file is not", ctx do
    page = upload(ctx, "inventory.csv", @csv, "text/csv")

    assert [%{content_kind: :body, source_node_id: source, chunk_text: text}] = chunks(page.id)
    assert source == page.id
    assert text == "R1\tsku\tregion\towner\nR2\tSKU-100\tAPAC\tAlice\nR3\tSKU-200\tEMEA\tBob"

    {:ok, private} =
      Files.create_from_upload(
        ctx.actor,
        %{private_owner_uid: ctx.owner.uid},
        "inventory.csv",
        @csv,
        "text/csv"
      )

    assert chunks(private.id) == []
    assert learn_jobs(private.id) == []
  end

  test "a replaced file learns its new version and rejects the late result of the old one",
       ctx do
    page = upload(ctx, "notes.md", "The factory has three lines.", "text/markdown")
    {:ok, first} = Objects.get_by_slug(page.id)

    assert first.content_hash == file_version(page)

    {:ok, _replaced} =
      Files.upload(
        ctx.actor,
        page.id,
        "file",
        page.object_id,
        "notes.md",
        "The factory has four lines.",
        "text/markdown"
      )

    {:ok, second} = Objects.get_by_slug(page.id)

    # Replacing a file names a new object and leaves the page revision alone.
    assert second.revision == first.revision
    assert second.content_hash != first.content_hash
    assert [%{chunk_text: "The factory has four lines."}] = chunks(page.id)

    assert MapSet.new(learn_jobs(page.id), & &1.args["content_version"]) ==
             MapSet.new([first.content_hash, second.content_hash])

    extraction = %{
      items: [%{"claim" => "The factory has four lines", "kind" => "fact"}],
      windows: 1
    }

    assert {:error, :stale_run} =
             Repo.transact_top_level(fn ->
               SourceLearning.commit_page_run_in_tx(page.id, first.content_hash, extraction)
             end)

    assert {:ok, %{claims: 1}} =
             Repo.transact_top_level(fn ->
               SourceLearning.commit_page_run_in_tx(page.id, second.content_hash, extraction)
             end)

    assert {:error, :stale_run} = SourceLearning.learn_page(page.id, second.content_hash)
  end

  test "committing the same bytes again keeps the content version, and Brain learns nothing new",
       ctx do
    page = upload(ctx, "notes.md", "The factory has three lines.", "text/markdown")
    {:ok, first} = Objects.get_by_slug(page.id)

    assert {:ok, %{claims: 1}} =
             Repo.transact_top_level(fn ->
               SourceLearning.commit_page_run_in_tx(page.id, first.content_hash, %{
                 items: [%{"claim" => "The factory has three lines", "kind" => "fact"}],
                 windows: 1
               })
             end)

    learned = learn_jobs(page.id)

    # An Agent's `drive put` and a sync client commit unchanged files again, each time as a new object.
    {:ok, _file} =
      Files.upload(
        ctx.actor,
        page.id,
        "file",
        page.object_id,
        "notes.md",
        "The factory has three lines.",
        "text/markdown"
      )

    {:ok, again} = Objects.get_by_slug(page.id)
    {:ok, recommitted} = Pages.fetch(page.id)
    assert recommitted.object_id != page.object_id
    assert again.content_hash == first.content_hash
    assert learn_jobs(page.id) == learned
    assert [%{chunk_text: "The factory has three lines."}] = chunks(page.id)

    # Different bytes are a new version, and Brain learns it.
    {:ok, _file} =
      Files.upload(
        ctx.actor,
        page.id,
        "file",
        recommitted.object_id,
        "notes.md",
        "The factory has four lines.",
        "text/markdown"
      )

    {:ok, changed} = Objects.get_by_slug(page.id)
    assert changed.content_hash != first.content_hash
    assert length(learn_jobs(page.id)) == length(learned) + 1
  end

  test "a table file learns one summary, indexed after body chunks that keep their vectors",
       ctx do
    page = upload(ctx, "inventory.csv", @csv, "text/csv")
    {:ok, object} = Objects.get_by_slug(page.id)
    [body] = chunks(page.id)
    assert {:ok, :updated} = Chunks.record_embedding(body, {:error, "offline", "sig-1"})

    Agent.update(ctx.output, fn _ ->
      %{
        "summary" => "Inventory owners by region.",
        "items" => [%{"claim" => "The inventory lists stock owners", "kind" => "fact"}]
      }
    end)

    assert {:ok, %{claims: 1}} = SourceLearning.learn_page(page.id, object.content_hash)
    assert_receive {:prompt, prompt}
    assert prompt =~ "[Table] 3 rows extracted\nR1\tsku\tregion\towner\n"
    assert prompt =~ "The leading rows are a sample"

    assert [kept, summary] = chunks(page.id)

    assert {kept.id, kept.chunk_text, kept.embedding_signature} ==
             {body.id, body.chunk_text, "sig-1"}

    assert summary.chunk_text == "[Summary]\nInventory owners by region."

    assert {:ok, %{content: "Inventory owners by region.", file: file}} =
             GetPage.get_page(ctx.owner.uid, page.id, level: :l1)

    assert %{"format" => "csv", "row_count" => 2, "truncated" => false} = file
    assert file["guidance"] =~ "original file"

    # The summary describes one content version and leaves with it.
    {:ok, _replaced} =
      Files.upload(
        ctx.actor,
        page.id,
        "file",
        page.object_id,
        "inventory.csv",
        "a,b\n1,2\n",
        "text/csv"
      )

    assert [%{chunk_text: "R1\ta\tb\nR2\t1\t2"}] = chunks(page.id)
  end

  test "a file replaced by an unsupported format loses its chunks, facts, and timelines", ctx do
    page = upload(ctx, "notes.md", "The plant opened on 2024-03-01.", "text/markdown")
    {:ok, object} = Objects.get_by_slug(page.id)

    {:ok, _} =
      Repo.transact_top_level(fn ->
        with {:ok, _} <-
               SourceLearning.commit_page_run_in_tx(page.id, object.content_hash, %{
                 items: [%{"claim" => "The plant opened in March 2024", "kind" => "fact"}],
                 windows: 1
               }) do
          Timelines.write_timeline_in_tx(
            %{
              subject_page_id: page.id,
              source_node_id: page.id,
              date: ~D[2024-03-01],
              summary: "Plant opened",
              provenance: "page:#{page.id}:#{object.content_hash}"
            },
            :system,
            author: Config.execution_author!()
          )
        end
      end)

    assert Enum.map(chunks(page.id), & &1.content_kind) == [:body, :timeline]

    {:ok, _replaced} =
      Files.upload(
        ctx.actor,
        page.id,
        "file",
        page.object_id,
        "notes.zip",
        <<80, 75, 3, 4, 0, 0>>,
        "application/zip"
      )

    assert chunks(page.id) == []
    refute Repo.exists?(from t in Timeline, where: t.source_node_id == ^page.id)

    refute Repo.exists?(
             from c in Claim, where: c.source_node_id == ^page.id and is_nil(c.expired_at)
           )
  end

  test "Dreaming extracts a learned file's timelines once per content version", ctx do
    page = upload(ctx, "notes.md", "The plant opened on 2024-03-01.", "text/markdown")
    {:ok, object} = Objects.get_by_slug(page.id)

    # A file enters timeline extraction after source learning has covered it.
    assert %{status: :ok} = Dreaming.phase_extract_timelines()
    refute Enum.any?(prompts(), &(&1 =~ "The plant opened"))

    {:ok, _} =
      Repo.transact_top_level(fn ->
        SourceLearning.commit_page_run_in_tx(page.id, object.content_hash, %{
          items: [],
          windows: 1
        })
      end)

    Agent.update(ctx.output, fn _ ->
      %{"items" => [%{"date" => "2024-03-01", "summary" => "Plant opened"}]}
    end)

    assert %{status: :ok, timelines: 1} = Dreaming.phase_extract_timelines()
    assert Enum.any?(prompts(), &(&1 =~ "The plant opened on 2024-03-01."))

    assert [%{date: ~D[2024-03-01], provenance: provenance}] =
             Repo.all(from t in Timeline, where: t.source_node_id == ^page.id)

    assert provenance == "page:#{page.id}:#{object.content_hash}"

    assert %{status: :ok, timelines: 0} = Dreaming.phase_extract_timelines()
    assert prompts() == []
  end

  test "a Word document is chunked and learned per section", ctx do
    styles = """
    <w:styles xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
      <w:style w:type="paragraph" w:styleId="1"><w:name w:val="heading 1"/></w:style>
    </w:styles>
    """

    document = """
    <w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:body>
      <w:p><w:pPr><w:pStyle w:val="1"/></w:pPr><w:r><w:t>合同条款</w:t></w:r></w:p>
      <w:p><w:r><w:t>甲方应按期付款。</w:t></w:r></w:p>
      <w:p><w:pPr><w:outlineLvl w:val="1"/></w:pPr><w:r><w:t>违约责任</w:t></w:r></w:p>
      <w:p><w:r><w:t>逾期支付违约金。</w:t></w:r></w:p>
    </w:body></w:document>
    """

    {:ok, {_name, bytes}} =
      :zip.create(
        ~c"contract.docx",
        [{~c"word/styles.xml", styles}, {~c"word/document.xml", document}],
        [:memory]
      )

    page =
      upload(
        ctx,
        "contract.docx",
        bytes,
        "application/vnd.openxmlformats-officedocument.wordprocessingml.document"
      )

    # Office documents are extracted by the background job.
    assert chunks(page.id) == []

    assert :ok =
             SyncFileCache.perform(%Oban.Job{
               args: %{
                 "tenant_id" => Repo.tenant_id!(),
                 "page_id" => page.id,
                 "object_id" => page.object_id
               }
             })

    assert Enum.map(chunks(page.id), & &1.chunk_text) == [
             "[Section: 合同条款]\n甲方应按期付款。",
             "[Section: 合同条款 > 违约责任]\n逾期支付违约金。"
           ]

    {:ok, object} = Objects.get_by_slug(page.id)

    Agent.update(ctx.output, fn _ ->
      %{"items" => [%{"claim" => "逾期付款需支付违约金", "kind" => "fact"}]}
    end)

    assert {:ok, %{claims: 1}} = SourceLearning.learn_page(page.id, object.content_hash)
    assert_receive {:prompt, prompt}
    assert prompt =~ "[Section: 合同条款 > 违约责任]\n逾期支付违约金。"
  end

  test "a file outside a learning folder opts in from its own page", ctx do
    {:ok, folder} = Pages.create(ctx.actor, %{type: :doc})

    {:ok, page} =
      Files.create_from_upload(
        ctx.actor,
        %{parent_id: folder.id},
        "notes.md",
        "The factory has three lines.",
        "text/markdown"
      )

    assert {:ok, %{fact_learning: %{enabled: false, inherited: false}}} =
             Pages.get(ctx.actor, page.id)

    # The file is searchable either way; learning waits for the opt-in.
    assert [%{chunk_text: "The factory has three lines."}] = chunks(page.id)
    assert learn_jobs(page.id) == []

    assert {:ok, _} = Pages.update(ctx.actor, page.id, %{extract_facts: true})

    assert {:ok, %{fact_learning: %{enabled: true, inherited: false}}} =
             Pages.get(ctx.actor, page.id)

    {:ok, object} = Objects.get_by_slug(page.id)
    assert [%{args: %{"content_version" => version}}] = learn_jobs(page.id)
    assert version == object.content_hash
  end

  test "file windows open with the marker of their page", _ctx do
    assert SourceLearning.file_windows("[Page 1]\nIntro\n[Page 2]\nTerms\n") ==
             ["[Page 1]\nIntro\n\n[Page 2]\nTerms\n"]
  end

  test "reading a file returns its extracted text up to a limit near the extraction cap", ctx do
    assert {:ok, %{level: "L2", content: "The factory has three lines.", file: small}} =
             read(ctx, "notes.md", "The factory has three lines.")

    assert %{"format" => "md", "content_truncated" => false} = small

    # Two bytes per token keeps the file inline while passing the token limit.
    text = Enum.map_join(1..130_000, " ", &<<rem(&1 * 7, 26) + ?a>>)
    assert Ankole.Brain.Chunker.estimate_tokens(text) > 100_000

    assert {:ok, %{content: content, file: %{"content_truncated" => true}}} =
             read(ctx, "long.txt", text)

    assert String.starts_with?(text, content)
    assert byte_size(content) < byte_size(text)
  end

  test "a spreadsheet's cache carries the extractor version that self-healing compares", ctx do
    {:ok, page} = Spreadsheets.create_blank(ctx.actor, %{parent_id: ctx.folder.id})
    version = Ankole.Kernel.file_extractor_version()

    assert %FileCache{subtype: :spreadsheet, extractor_version: ^version} =
             Repo.get_by!(FileCache, page_id: page.id)

    assert {:ok, %{content_hash: hash}} = Objects.get_by_slug(page.id)
    assert hash == file_version(page)
  end

  # A file's content version: the digest of its bytes and the extractor version.
  defp file_version(page) do
    {:ok, current} = Pages.fetch(page.id)
    {:ok, object} = Ankole.Files.fetch_object(current.object_id)
    "#{Base.encode16(object.sha256, case: :lower)}:v#{Ankole.Kernel.file_extractor_version()}"
  end

  defp upload(ctx, name, content, content_type) do
    {:ok, page} =
      Files.create_from_upload(
        ctx.actor,
        %{parent_id: ctx.folder.id},
        name,
        content,
        content_type
      )

    page
  end

  defp read(ctx, name, content) do
    {:ok, page} =
      Files.create_from_upload(
        ctx.actor,
        %{private_owner_uid: ctx.owner.uid},
        name,
        content,
        "text/plain"
      )

    GetPage.get_page(ctx.owner.uid, page.id, level: :l2)
  end

  defp prompts do
    receive do
      {:prompt, prompt} -> [prompt | prompts()]
    after
      0 -> []
    end
  end

  defp chunks(page_id),
    do: Repo.all(from c in Chunk, where: c.page_id == ^page_id, order_by: c.chunk_index)

  defp learn_jobs(page_id) do
    Repo.all(
      from j in Oban.Job,
        where:
          j.worker == "Ankole.Brain.Jobs.LearnSource" and
            fragment("?->>'page_id' = ?", j.args, ^page_id)
    )
  end
end
