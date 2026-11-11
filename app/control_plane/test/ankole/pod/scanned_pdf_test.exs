defmodule Ankole.Pod.ScannedPdfTest do
  # A PDF page without a text layer is a scan. The tests upload real PDFs and
  # run the extraction jobs that Pod enqueues against an OCR upstream, so the
  # cache, the search text, and Brain's content version follow the production
  # path.
  use Ankole.AIGatewayCase

  import Ecto.Query
  import Ankole.PdfFixture
  import ExUnit.CaptureLog

  alias Ankole.Brain.Objects
  alias Ankole.Brain.Schemas.Chunk
  alias Ankole.AIGateway.Schemas.UsageRecord
  alias Ankole.Pod.{FileCache, FileExtraction, Files, Pages, PageSearchDocument}
  alias Ankole.Pod.Jobs.SyncFileCache
  alias Ankole.Repo

  setup do
    owner = human_fixture().principal
    actor = actor_fixture(owner)
    {:ok, folder} = Pages.create(actor, %{type: :doc, title: "Contracts"})
    %{owner: owner, actor: actor, folder: folder}
  end

  test "the OCR model reads the scanned pages, and their text joins the text the PDF has", ctx do
    configure_ocr(fn _request ->
      read_pages([{1, "# Purchase contract\n\nBuyer: Huadong Precision"}, {2, ""}])
    end)

    bytes = pdf(["Cover page with a text layer", "", ""])
    page = upload(ctx, "contract.pdf", bytes)
    assert %{failure: 0} = extract()

    # AIGateway numbers pages from 0, and only the pages without text are sent.
    assert_receive {:ocr_request, request}
    assert request["pages"] == [1, 2]

    assert request["document"]["document_url"] ==
             "data:application/pdf;base64," <> Base.encode64(bytes)

    assert %FileCache{extract_status: :ok, metadata: metadata} = cache(page)
    assert metadata["ocr_pages"] == [2]
    assert metadata["textless_pages"] == [3]

    assert body_text(page) ==
             "[Page 1]\nCover page with a text layer\n" <>
               "[Page 2]\n# Purchase contract\n\nBuyer: Huadong Precision\n"

    # Brain's content version counts the pages OCR read, and its chunks hold their text.
    assert {:ok, object} = Objects.get_by_slug(page.id)

    {:ok, stored} = Ankole.Files.fetch_object(page.object_id)

    assert object.content_hash ==
             "#{Base.encode16(stored.sha256, case: :lower)}:v#{Ankole.Kernel.file_extractor_version()}:ocr1"

    chunks = Repo.all(from c in Chunk, where: c.page_id == ^page.id, select: c.chunk_text)
    assert Enum.any?(chunks, &(&1 =~ "[Page 2]\n# Purchase contract"))

    # AIGateway records the two pages the Pod paid for.
    assert [usage] = Repo.all(UsageRecord)

    assert {usage.origin, usage.capability, usage.unit, usage.quantity} ==
             {:pod_files, :ocr, :page, 2}

    # The cache keeps what OCR read, the page without text included, so no later run pays again:
    # neither a second run of the upload's job nor an extraction of the outdated cache.
    assert cache(page).ocr == %{
             "pages" => %{"2" => "# Purchase contract\n\nBuyer: Huadong Precision", "3" => ""}
           }

    assert :ok = SyncFileCache.perform(job(page, %{"read_scans" => true}))

    # Another page that holds the same object takes these pages instead of paying for them.
    assert FileExtraction.known_ocr(ctx.folder.id, page.object_id) == cache(page).ocr
    outdate(page)
    assert :ok = FileExtraction.reconcile_tenant_batch()
    assert %{failure: 0} = extract()
    refute_received {:ocr_request, _request}
    assert cache(page).extractor_version == Ankole.Kernel.file_extractor_version()
    assert cache(page).metadata["ocr_pages"] == [2]
    assert body_text(page) =~ "[Page 2]\n# Purchase contract"
    assert [_usage] = Repo.all(UsageRecord)
  end

  test "committing the same bytes again keeps what OCR read and sends nothing", ctx do
    configure_ocr(fn _request -> read_pages([{1, "Scanned appendix"}]) end)
    bytes = pdf(["Cover page with a text layer", ""])
    page = upload(ctx, "report.pdf", bytes)
    assert %{failure: 0} = extract()
    assert_receive {:ocr_request, _request}
    read = cache(page)

    # An Agent's `drive put` and a sync client commit unchanged files again, and each commit is a new object.
    assert {:ok, _file} =
             Files.upload(
               ctx.actor,
               page.id,
               "file",
               page.object_id,
               "report.pdf",
               bytes,
               "application/pdf"
             )

    assert %{failure: 0} = extract()
    refute_received {:ocr_request, _request}
    again = cache(page)
    assert again.object_id != read.object_id
    assert {again.ocr, again.metadata} == {read.ocr, read.metadata}
    assert body_text(page) =~ "[Page 2]\nScanned appendix"
  end

  test "a scan uploaded before the OCR model is read once an administrator agrees to pay", ctx do
    page = upload(ctx, "scan.pdf", pdf(["", ""]))
    assert %{failure: 0} = extract()

    assert %FileCache{extract_status: :skipped, extract_error: "empty_text_layer"} =
             unread = cache(page)

    assert unread.metadata["textless_pages"] == [1, 2]
    refute Map.has_key?(unread.metadata, "ocr_pages")
    assert {:ok, %{content_hash: unread_version}} = Objects.get_by_slug(page.id)

    # Without an OCR model the reconciliation leaves the scan alone.
    assert :ok = FileExtraction.reconcile_tenant_batch()
    assert waiting_jobs(page) == []

    # An OCR model alone does not spend money on the scans that are already there,
    # not even when their cache is outdated and extracted again.
    configure_ocr(fn _request -> read_pages([{0, "Stamped receipt 2026-03-01"}, {1, ""}]) end)
    assert :ok = FileExtraction.reconcile_tenant_batch()
    assert waiting_jobs(page) == []
    outdate(page)
    assert :ok = FileExtraction.reconcile_tenant_batch()
    assert [_job] = waiting_jobs(page)
    assert %{failure: 0} = extract()
    refute_received {:ocr_request, _request}
    assert FileExtraction.unread_scans() == %{files: 1, pages: 2, counting: false}

    assert {:ok, true} = Ankole.AppConfigure.put_tenant_by_key("pod.ocr_existing_scans", true)
    assert :ok = FileExtraction.reconcile_tenant_batch()
    assert [_job] = waiting_jobs(page)
    assert %{failure: 0} = extract()

    assert %FileCache{extract_status: :ok, metadata: metadata} = cache(page)
    assert metadata["ocr_pages"] == [1]
    assert metadata["textless_pages"] == [2]
    assert body_text(page) == "[Page 1]\nStamped receipt 2026-03-01\n"
    assert {:ok, %{content_hash: read_version}} = Objects.get_by_slug(page.id)
    assert read_version == unread_version <> ":ocr1"
    assert FileExtraction.unread_scans() == %{files: 0, pages: 0, counting: false}

    # The finished run is on record, so the page OCR found empty is not sent again.
    assert :ok = FileExtraction.reconcile_tenant_batch()
    assert waiting_jobs(page) == []
  end

  test "a scan in a trashed folder is not counted or read until the folder is restored", ctx do
    page = upload(ctx, "scan.pdf", pdf(["", ""]))
    assert %{failure: 0} = extract()
    configure_ocr(fn _request -> read_pages([{0, "Stamped receipt 2026-03-01"}, {1, ""}]) end)
    assert {:ok, true} = Ankole.AppConfigure.put_tenant_by_key("pod.ocr_existing_scans", true)

    # Trashing the folder marks the folder alone: the file inside has no `deleted_at`.
    assert {:ok, _folder} = Pages.delete(ctx.actor, ctx.folder.id)
    assert {:ok, %{deleted_at: nil}} = Pages.fetch(page.id)

    assert FileExtraction.unread_scans() == %{files: 0, pages: 0, counting: false}
    assert :ok = FileExtraction.reconcile_tenant_batch()
    assert waiting_jobs(page) == []

    # A job that was already waiting when the folder went to the trash reads nothing.
    outdate(page)
    assert :ok = SyncFileCache.perform(job(page, %{"read_scans" => true}))
    refute_received {:ocr_request, _request}
    assert cache(page).extractor_version == Ankole.Kernel.file_extractor_version()

    assert {:ok, _folder} = Pages.restore(ctx.actor, ctx.folder.id)
    assert FileExtraction.unread_scans() == %{files: 1, pages: 2, counting: false}
    assert :ok = FileExtraction.reconcile_tenant_batch()
    assert %{failure: 0} = extract()
    assert_receive {:ocr_request, _request}
    assert body_text(page) == "[Page 1]\nStamped receipt 2026-03-01\n"
  end

  test "a failed OCR call keeps the text the PDF has and leaves the scan unread", ctx do
    configure_ocr(fn _request -> {:json, 400, %{"message" => "document is not readable"}} end)
    page = upload(ctx, "mixed.pdf", pdf(["Cover page with a text layer", ""]))

    assert capture_log(fn -> assert %{failure: 0} = extract() end) =~
             "OCR could not read the scanned pages"

    assert %FileCache{extract_status: :ok, metadata: metadata} = cache(page)
    assert metadata["textless_pages"] == [2]
    refute Map.has_key?(metadata, "ocr_pages")
    assert body_text(page) == "[Page 1]\nCover page with a text layer\n"

    assert cache(page).ocr == %{"pages" => %{}, "failures" => 1}

    # With the administrator's consent the scan is tried again, half an hour after the failure.
    assert {:ok, true} = Ankole.AppConfigure.put_tenant_by_key("pod.ocr_existing_scans", true)
    assert :ok = FileExtraction.reconcile_tenant_batch()
    assert waiting_jobs(page) == []
    put_cache(page, updated_at: DateTime.add(DateTime.utc_now(:microsecond), -31, :minute))
    assert :ok = FileExtraction.reconcile_tenant_batch()
    assert [_job] = waiting_jobs(page)
    capture_log(fn -> assert %{failure: 0} = extract() end)

    # After five failures in a row the scan is tried once a day, so it is read when the provider works again.
    put_cache(page,
      ocr: %{"pages" => %{}, "failures" => 5},
      updated_at: DateTime.add(DateTime.utc_now(:microsecond), -6, :hour)
    )

    assert :ok = FileExtraction.reconcile_tenant_batch()
    assert waiting_jobs(page) == []
    put_cache(page, updated_at: DateTime.add(DateTime.utc_now(:microsecond), -25, :hour))
    assert :ok = FileExtraction.reconcile_tenant_batch()
    assert [_job] = waiting_jobs(page)
  end

  test "a failed request keeps the pages read before it, and the next run sends only the rest",
       ctx do
    {:ok, requests} = Agent.start_link(fn -> 0 end)

    configure_ocr(fn %{"pages" => pages} ->
      if Agent.get_and_update(requests, &{&1, &1 + 1}) == 1,
        do: {:json, 400, %{"message" => "too many pages for now"}},
        else: read_pages(for index <- pages, do: {index, "Scan of page #{index + 1}"})
    end)

    page =
      upload(ctx, "long.pdf", pdf(["Cover page with a text layer" | List.duplicate("", 101)]))

    capture_log(fn -> assert %{failure: 0} = extract() end)

    # The first hundred pages are paid for and stay; page 102 is still unread.
    assert %FileCache{metadata: metadata, ocr: ocr} = cache(page)
    assert metadata["ocr_pages"] == Enum.to_list(2..101)
    assert metadata["textless_pages"] == [102]
    assert {map_size(ocr["pages"]), ocr["failures"]} == {100, 1}

    assert {:ok, true} = Ankole.AppConfigure.put_tenant_by_key("pod.ocr_existing_scans", true)
    put_cache(page, updated_at: DateTime.add(DateTime.utc_now(:microsecond), -31, :minute))
    assert :ok = FileExtraction.reconcile_tenant_batch()
    assert %{failure: 0} = extract()

    assert_receive {:ocr_request, %{"pages" => first}}
    assert_receive {:ocr_request, %{"pages" => [101]}}
    assert_receive {:ocr_request, %{"pages" => [101]}}
    refute_received {:ocr_request, _request}
    assert first == Enum.to_list(1..100)
    assert %FileCache{metadata: %{"textless_pages" => []}, ocr: ocr} = cache(page)
    assert {map_size(ocr["pages"]), ocr["failures"]} == {101, nil}
  end

  test "pages read by a run whose result could not be stored are kept and not bought again",
       ctx do
    page = upload(ctx, "mixed.pdf", pdf(["Cover page with a text layer", "", ""]))
    assert %{failure: 0} = extract()

    # The run read page 2 and then failed to store its extraction.
    assert :ok =
             FileExtraction.keep_ocr(page.id, page.object_id, %{
               "pages" => %{"2" => "Kept page two"}
             })

    assert cache(page).ocr == %{"pages" => %{"2" => "Kept page two"}, "failures" => 1}

    configure_ocr(fn %{"pages" => pages} ->
      read_pages(for index <- pages, do: {index, "Read page #{index + 1}"})
    end)

    assert {:ok, true} = Ankole.AppConfigure.put_tenant_by_key("pod.ocr_existing_scans", true)
    put_cache(page, updated_at: DateTime.add(DateTime.utc_now(:microsecond), -31, :minute))
    assert :ok = FileExtraction.reconcile_tenant_batch()
    assert %{failure: 0} = extract()

    # Only page 3 is sent, and the kept page joins the text without a second charge.
    assert_receive {:ocr_request, %{"pages" => [2]}}
    refute_received {:ocr_request, _request}

    assert body_text(page) ==
             "[Page 1]\nCover page with a text layer\n[Page 2]\nKept page two\n[Page 3]\nRead page 3\n"

    assert cache(page).ocr == %{"pages" => %{"2" => "Kept page two", "3" => "Read page 3"}}
  end

  test "two pages that hold the same file pay for its scans once", ctx do
    page = upload(ctx, "scan.pdf", pdf(["", ""]))
    assert %{failure: 0} = extract()

    {:ok, _copy} =
      Repo.transact_top_level(fn ->
        Ankole.Pod.Files.Content.create_private_file_in_tx(
          ctx.owner.uid,
          "copy.pdf",
          page.object_id,
          %{content_type: "application/pdf"}
        )
      end)

    assert [copy] =
             Repo.all(
               from c in FileCache,
                 where: c.object_id == ^page.object_id and c.page_id != ^page.id
             )

    configure_ocr(fn _request -> read_pages([{0, "Stamped receipt"}, {1, "Second page"}]) end)
    assert {:ok, true} = Ankole.AppConfigure.put_tenant_by_key("pod.ocr_existing_scans", true)

    # Jobs run side by side, so a pass sends one page of the object to OCR.
    assert :ok = FileExtraction.reconcile_tenant_batch()
    assert length(waiting_jobs(page) ++ waiting_jobs(%{id: copy.page_id})) == 1
    assert %{failure: 0} = extract()
    assert_receive {:ocr_request, %{"pages" => [0, 1]}}

    # The next pass reaches the other page, which takes what the first one read.
    assert :ok = FileExtraction.reconcile_tenant_batch()
    assert length(waiting_jobs(page) ++ waiting_jobs(%{id: copy.page_id})) == 1
    assert %{failure: 0} = extract()
    refute_received {:ocr_request, _request}

    read = %{"pages" => %{"1" => "Stamped receipt", "2" => "Second page"}}
    assert cache(page).ocr == read
    assert Repo.get_by!(FileCache, page_id: copy.page_id).ocr == read

    for page_id <- [page.id, copy.page_id] do
      assert Repo.get_by!(PageSearchDocument, page_id: page_id).body_text ==
               "[Page 1]\nStamped receipt\n[Page 2]\nSecond page\n"
    end
  end

  test "pages kept after a failed commit join the text without consent or another charge", ctx do
    page = upload(ctx, "mixed.pdf", pdf(["Cover page with a text layer", ""]))
    assert %{failure: 0} = extract()

    # A run read the only scan and could not store its extraction.
    assert :ok =
             FileExtraction.keep_ocr(page.id, page.object_id, %{
               "pages" => %{"2" => "Kept page two"}
             })

    # Nothing is left to read, yet the paid text is not in the file's text. Joining it costs nothing.
    assert FileExtraction.unread_scans() == %{files: 0, pages: 0, counting: false}
    assert :ok = FileExtraction.reconcile_tenant_batch()
    assert [_job] = waiting_jobs(page)
    assert %{failure: 0} = extract()

    assert body_text(page) == "[Page 1]\nCover page with a text layer\n[Page 2]\nKept page two\n"
    assert cache(page).metadata["ocr_pages"] == [2]
    assert :ok = FileExtraction.reconcile_tenant_batch()
    assert waiting_jobs(page) == []
  end

  test "a file whose search text is empty although its extraction succeeded is extracted again",
       ctx do
    page = upload(ctx, "report.pdf", pdf(["Cover page with a text layer"]))
    assert %{failure: 0} = extract()
    {:ok, stored} = Pages.fetch(page.id)

    # A rebuild of a page whose search document was missing leaves this state behind.
    {:ok, :ok} =
      Repo.transact_top_level(fn ->
        {:ok, Ankole.Pod.SearchProjection.upsert_in_tx(stored, body_text: "")}
      end)

    assert body_text(page) == ""
    assert :ok = SyncFileCache.perform(job(page, %{}))
    assert body_text(page) == "[Page 1]\nCover page with a text layer\n"
  end

  test "a result for bytes that were committed again is stored for the new object", ctx do
    bytes = pdf(["Cover page with a text layer", ""])
    page = upload(ctx, "report.pdf", bytes)
    assert %{failure: 0} = extract()
    cached = cache(page)

    # The same bytes arrive as a new object while a run for the old one is reading.
    assert {:ok, _file} =
             Files.upload(
               ctx.actor,
               page.id,
               "file",
               page.object_id,
               "report.pdf",
               bytes,
               "application/pdf"
             )

    assert cache(page).updated_at == cached.updated_at
    {:ok, current} = Pages.fetch(page.id)

    {:ok, result} =
      Ankole.Kernel.file_extract_text(bytes, "report.pdf", "application/pdf", [
        {2, "Read meanwhile"}
      ])

    ocr = %{"pages" => %{"2" => "Read meanwhile"}}

    assert :ok =
             SyncFileCache.commit_extraction(
               page.id,
               page.object_id,
               :document,
               "pdf",
               Ankole.Kernel.file_extractor_version(),
               result,
               ocr
             )

    # The old run's pages are on the row of the object that the page holds now.
    assert %FileCache{object_id: object_id, ocr: ^ocr} = cache(page)
    assert object_id == current.object_id
    assert body_text(page) =~ "[Page 2]\nRead meanwhile"
  end

  test "renaming a file whose cache is outdated keeps what OCR read", ctx do
    configure_ocr(fn _request -> read_pages([{1, "Scanned appendix"}]) end)
    page = upload(ctx, "report.pdf", pdf(["Cover page with a text layer", ""]))
    assert %{failure: 0} = extract()
    assert_receive {:ocr_request, _request}
    read = cache(page).ocr
    outdate(page)

    # The rename rebuilds the file from the same object, and the row with the paid text stays.
    assert {:ok, _renamed} =
             Pages.update(ctx.actor, page.id, %{
               title: "renamed.pdf",
               expected_title: "report.pdf"
             })

    assert cache(page).ocr == read
    assert %{failure: 0} = extract()

    refute_received {:ocr_request, _request}
    assert cache(page).extractor_version == Ankole.Kernel.file_extractor_version()
    assert cache(page).ocr == read
    assert body_text(page) =~ "[Page 2]\nScanned appendix"
  end

  test "a scan cached before the kernel listed its pages is listed without any charge", ctx do
    page = upload(ctx, "scan.pdf", pdf(["", ""]))
    assert %{failure: 0} = extract()
    put_cache(page, metadata: %{})
    configure_ocr(fn _request -> read_pages([{0, "never asked for"}]) end)
    # Until the scan is listed, Console is told that its numbers are incomplete.
    assert FileExtraction.unread_scans() == %{files: 0, pages: 0, counting: true}

    assert :ok = FileExtraction.reconcile_tenant_batch()
    assert [_job] = waiting_jobs(page)
    assert %{failure: 0} = extract()

    refute_received {:ocr_request, _request}
    assert cache(page).metadata["textless_pages"] == [1, 2]
    assert FileExtraction.unread_scans() == %{files: 1, pages: 2, counting: false}
  end

  test "a PDF with more than 100 scanned pages is read in batches that keep their page numbers",
       ctx do
    configure_ocr(fn %{"pages" => pages} ->
      read_pages(for index <- pages, do: {index, "Scan of page #{index + 1}"})
    end)

    page =
      upload(ctx, "long.pdf", pdf(["Cover page with a text layer" | List.duplicate("", 101)]))

    assert %{failure: 0} = extract()

    # Pages 2 to 102 are scans. AIGateway takes 100 pages a request and counts them from 0.
    assert_receive {:ocr_request, %{"pages" => first}}
    assert_receive {:ocr_request, %{"pages" => second}}
    assert {first, second} == {Enum.to_list(1..100), [101]}

    assert %FileCache{metadata: metadata} = cache(page)
    assert metadata["ocr_pages"] == Enum.to_list(2..102)
    assert metadata["textless_pages"] == []

    text = body_text(page)

    assert String.starts_with?(
             text,
             "[Page 1]\nCover page with a text layer\n[Page 2]\nScan of page 2\n"
           )

    assert text =~ "[Page 101]\nScan of page 101\n[Page 102]\nScan of page 102\n"
  end

  test "text for a page that was not requested is not used, and the page is not sent again",
       ctx do
    # The scan is page 2, which AIGateway calls page 1. This model answers for page 2 of its own count.
    configure_ocr(fn _request -> read_pages([{2, "Text of some other page"}]) end)
    page = upload(ctx, "shifted.pdf", pdf(["Cover page with a text layer", ""]))

    assert capture_log(fn -> assert %{failure: 0} = extract() end) =~
             "OCR returned pages outside the request"

    assert %FileCache{extract_status: :ok, metadata: metadata, ocr: ocr} = cache(page)
    assert {metadata["textless_pages"], metadata["ocr_pages"]} == {[2], []}
    assert body_text(page) == "[Page 1]\nCover page with a text layer\n"

    # Asking again would pay again for the same answer, so the page counts as read without text.
    assert ocr == %{"pages" => %{"2" => ""}}
    assert {:ok, true} = Ankole.AppConfigure.put_tenant_by_key("pod.ocr_existing_scans", true)
    assert :ok = FileExtraction.reconcile_tenant_batch()
    assert waiting_jobs(page) == []
  end

  test "a scan before the point where a long PDF fills the text limit is still read", ctx do
    configure_ocr(fn _request -> read_pages([{0, "Scan before the long page"}]) end)
    long = String.duplicate("lorem ipsum dolor sit amet ", 24_000)
    page = upload(ctx, "long-text.pdf", pdf(["", long, ""]))
    assert %{failure: 0} = extract()

    # The text ends inside page 2. Page 1 comes before that point, so its OCR text fits,
    # and page 3 comes after it, so it is neither listed nor sent.
    assert_receive {:ocr_request, %{"pages" => [0]}}
    refute_received {:ocr_request, _request}

    assert %FileCache{metadata: metadata, ocr: ocr} = cache(page)
    assert metadata["truncated"]
    assert {metadata["ocr_pages"], metadata["textless_pages"]} == {[1], []}
    assert ocr == %{"pages" => %{"1" => "Scan before the long page"}}

    text = body_text(page)
    assert String.starts_with?(text, "[Page 1]\nScan before the long page\n[Page 2]\nlorem ipsum")
    assert byte_size(text) <= 512 * 1024

    # Nothing is left to read, so a consent does not keep sending the file.
    assert {:ok, true} = Ankole.AppConfigure.put_tenant_by_key("pod.ocr_existing_scans", true)
    assert :ok = FileExtraction.reconcile_tenant_batch()
    assert waiting_jobs(page) == []
  end

  defp configure_ocr(respond) do
    test_pid = self()

    base_url =
      start_upstream_server(fn %{path: "v1/ocr", body: body} ->
        send(test_pid, {:ocr_request, body})
        respond.(body)
      end)

    {:ok, _provider} =
      ProviderConfigs.create_provider(%{
        provider_id: "mistral-main",
        provider_kind: "mistral",
        base_url: base_url <> "/v1",
        credential_pool: %{"entries" => [%{"label" => "Default", "api_key" => "sk-mistral"}]}
      })

    {:ok, _profile} =
      ModelProfiles.put_default_model_profile(:tenant, "ocr", %{
        provider_id: "mistral-main",
        model: "mistral-ocr-latest"
      })
  end

  defp read_pages(pages) do
    {:json, 200,
     %{
       "pages" =>
         for({index, markdown} <- pages, do: %{"index" => index, "markdown" => markdown}),
       "model" => "mistral-ocr-2503-completion",
       "usage_info" => %{"pages_processed" => length(pages)}
     }}
  end

  defp upload(ctx, name, bytes) do
    {:ok, page} =
      Files.create_from_upload(
        ctx.actor,
        %{parent_id: ctx.folder.id},
        name,
        bytes,
        "application/pdf"
      )

    page
  end

  # Runs the extraction jobs that an upload or a reconciliation enqueued.
  defp extract, do: Oban.drain_queue(queue: :default)

  defp cache(page), do: Repo.get_by!(FileCache, page_id: page.id)

  defp job(page, extra) do
    %Oban.Job{
      attempt: 1,
      args:
        Map.merge(
          %{
            "tenant_id" => Repo.tenant_id!(),
            "page_id" => page.id,
            "object_id" => page.object_id
          },
          extra
        )
    }
  end

  # Rewrites the file's cache row with `changes`, as an earlier release or the passing of time would have left it.
  defp put_cache(page, changes) do
    attrs =
      page
      |> cache()
      |> Map.take(
        ~w(page_id subtype format object_id extractor_version extract_status extract_error metadata ocr updated_at)a
      )
      |> Map.merge(Map.new(changes))

    {:ok, _cache} =
      Repo.transact_top_level(fn -> Ankole.Ash.create(FileCache, :put, attrs) end)
  end

  defp outdate(page), do: put_cache(page, extractor_version: 1)
  defp body_text(page), do: Repo.get_by!(PageSearchDocument, page_id: page.id).body_text

  defp waiting_jobs(page) do
    Repo.all(
      from j in Oban.Job,
        where:
          j.worker == "Ankole.Pod.Jobs.SyncFileCache" and j.state == "available" and
            fragment("?->>'page_id' = ?", j.args, ^page.id)
    )
  end
end
