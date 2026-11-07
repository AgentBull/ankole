defmodule Ankole.Pod.PageFullTextSearchTest do
  use Ankole.DataCase, async: false

  import Ankole.PrincipalsFixtures

  alias Ankole.AuthZ

  alias Ankole.Pod.{
    Bases,
    Documents,
    FileCache,
    FileExtraction,
    Files,
    Knowledge,
    PageDailyActivity,
    Pages,
    PageSearchDocument
  }

  alias Ankole.Pod.Jobs.SyncFileCache
  alias Ankole.Repo

  setup do
    owner = human_fixture().principal
    peer = human_fixture().principal

    {:ok, _} =
      AuthZ.create_permission_grant(%{
        principal_uid: owner.uid,
        resource_pattern: "tenant_console:**",
        action: "update"
      })

    %{
      owner: owner,
      peer: peer,
      actor: actor_fixture(owner),
      peer_actor: actor_fixture(peer)
    }
  end

  test "recalls across title, metadata, rich blocks, quoted phrases, prefixes, and CJK/code tokens",
       ctx do
    {:ok, doc} =
      Pages.create(ctx.actor, %{
        title: "Nebula Service Playbook",
        xml: """
        <page>
          <h2>Incident Escalation</h2>
          <p>Run <code>Repo.query!</code> diagnostics when 延迟 spikes during handoff.</p>
          <bookmark src="https://runbooks.example.com/nebula-pager" title="PagerDuty Matrix" description="On-call rotation for Nebula" />
          <media kind="image" src="https://cdn.example.com/arch.png" title="Topology diagram" description="Multi-region failover flow" />
        </page>
        """
      })

    {:ok, distractor} =
      Pages.create(ctx.actor, %{
        title: "Unrelated Playbook",
        xml: "<page><p>Run diagnostics during normal deploy windows.</p></page>"
      })

    # Rich block attributes (<bookmark> and <media>) are indexed and searchable
    assert {:ok, %{pages: [found_bm], matches: [bm_match]}} =
             Pages.search(ctx.actor, "PagerDuty rotation")

    assert found_bm.id == doc.id
    assert :body in bm_match.match_fields
    assert Enum.any?(bm_match.snippet.segments, & &1.hit)

    assert {:ok, %{pages: [found_media]}} = Pages.search(ctx.actor, "failover topology")
    assert found_media.id == doc.id

    # Quoted phrase requires exact phrase adjacency
    assert {:ok, %{pages: [found_phrase]}} = Pages.search(ctx.actor, ~s("Incident Escalation"))
    assert found_phrase.id == doc.id
    assert {:ok, %{pages: []}} = Pages.search(ctx.actor, ~s("Escalation Incident"))

    # Prefix expansion on the last token ("escalat" -> "Escalation")
    assert {:ok, %{pages: [found_prefix], matches: [sec_match]}} =
             Pages.search(ctx.actor, "Nebula escalat")

    assert found_prefix.id == doc.id

    assert %{kind: :doc_section, heading: "Incident Escalation", level: 2} =
             sec_match.primary_target

    # Short CJK + code symbol identifier ("Repo.query!")
    assert {:ok, %{pages: [found_code]}} = Pages.search(ctx.actor, "Repo.query! 延迟")
    assert found_code.id == doc.id
    refute found_code.id == distractor.id

    # title_only restricts recall to title
    assert {:ok, %{pages: []}} =
             Pages.search(ctx.actor, "PagerDuty", %{title_only: true})

    assert {:ok, %{pages: [title_hit]}} =
             Pages.search(ctx.actor, "Nebula", %{title_only: true})

    assert title_hit.id == doc.id
  end

  test "indexes Base tables, views, and fields and resolves base_table deep-link targets", ctx do
    {:ok, base_page} = Pages.create(ctx.actor, %{type: :base, title: "Revenue Operations"})
    {:ok, %{tables: [first_table | _]}} = Bases.list_tables(ctx.actor, base_page.id)

    {:ok, renamed_table} =
      Bases.rename_table(ctx.actor, first_table.id, "Enterprise Deals")

    {:ok, field} =
      Bases.create_field(ctx.actor, renamed_table.id, %{
        "name" => "ARR Forecast",
        "type" => "number"
      })

    {:ok, view} =
      Bases.create_view(ctx.actor, renamed_table.id, %{
        "name" => " EMEA Pipeline ",
        "type" => "grid"
      })

    # Match view name -> jumps directly to table + view
    assert {:ok, %{pages: [found], matches: [match]}} =
             Pages.search(ctx.actor, "EMEA Pipeline")

    assert found.id == base_page.id
    table_id = renamed_table.id
    view_id = view.id

    assert %{kind: :base_table, table_id: ^table_id, view_id: ^view_id} =
             match.primary_target

    # Match field name -> jumps to owning table
    assert {:ok, %{pages: [^found], matches: [field_match]}} =
             Pages.search(ctx.actor, "ARR Forecast")

    assert %{kind: :base_table, table_id: ^table_id, label: "ARR Forecast"} =
             field_match.primary_target

    # Deleting the field removes it from the projection immediately
    {:ok, _} = Bases.delete_field(ctx.actor, field.id, field.version)
    assert {:ok, %{pages: []}} = Pages.search(ctx.actor, "ARR Forecast")
  end

  test "combines lexical tiers with personal recency, workspace activity, filters, and domains",
       ctx do
    category = Ankole.BrainFixtures.category_fixture(ctx.owner.uid)

    {:ok, brain_note} =
      Pages.create(ctx.actor, %{
        type: :knowledge,
        parent_id: category.id,
        title: "Quantum Architecture",
        xml: "<page><p>Shared lattice specification</p></page>"
      })

    {:ok, _} =
      Knowledge.write(
        ctx.actor,
        brain_note.id,
        brain_note.revision,
        "<page><p>Shared lattice specification</p></page>",
        Map.put(brain_note.metadata, "owner_team", "CryoCore")
      )

    {:ok, private_parent} =
      Pages.create(ctx.actor, %{
        private_owner_uid: ctx.owner.uid,
        title: "Engineering Folder",
        xml: "<page><p>Parent overview</p></page>"
      })

    {:ok, child_a} =
      Pages.create(ctx.actor, %{
        parent_id: private_parent.id,
        title: "Draft A",
        xml: "<page><p>Shared lattice note alpha</p></page>"
      })

    {:ok, child_b} =
      Pages.create(ctx.actor, %{
        parent_id: private_parent.id,
        title: "Draft B",
        xml: "<page><p>Shared lattice note beta</p></page>"
      })

    # Normalize timestamps so Draft A and Draft B start tied on lexical + updated_at
    same_time = ~U[2026-10-01 12:00:00.000000Z]

    Repo.update_all(
      from(p in Ankole.Pod.Page, where: p.id in ^[child_a.id, child_b.id]),
      set: [updated_at: same_time]
    )

    # Boost Draft A via favorite + workspace daily activity
    {:ok, _} = Pages.state(ctx.actor, child_a.id, %{favorite: true})

    Ankole.Ash.create!(PageDailyActivity, :put, %{
      page_id: child_a.id,
      day: Date.utc_today(),
      views: 25,
      edits: 5
    })

    # Default domain (:pages) excludes Brain; domain: :all includes Brain + Knowledge metadata
    assert {:ok, %{pages: pages_only}} = Pages.search(ctx.actor, "lattice")
    refute Enum.any?(pages_only, &(&1.id == brain_note.id))
    assert Enum.map(pages_only, & &1.id) == [child_a.id, child_b.id]

    assert {:ok, %{pages: [all_brain], matches: [brain_meta_match]}} =
             Pages.search(ctx.actor, "CryoCore", %{domain: :all})

    assert all_brain.id == brain_note.id
    assert :meta in brain_meta_match.match_fields
    assert Enum.any?(brain_meta_match.snippet.segments, & &1.hit)

    # Multi-word non-adjacent title hit via BM25 identifies :title without falsely claiming :body
    assert {:ok, %{pages: [quantum_hit], matches: [quantum_match]}} =
             Pages.search(ctx.actor, "Quantum Architecture", %{domain: :all})

    assert quantum_hit.id == brain_note.id
    assert quantum_match.match_fields == [:title]

    {:ok, multi_title_doc} =
      Pages.create(ctx.actor, %{
        title: "Quarterly Revenue Roadmap",
        xml: "<page><p>General planning notes without the searched words.</p></page>"
      })

    assert {:ok, %{pages: [bm25_title_page], matches: [bm25_title_match]}} =
             Pages.search(ctx.actor, "Quarterly Roadmap")

    assert bm25_title_page.id == multi_title_doc.id
    assert bm25_title_match.match_fields == [:title]

    # Filters: ancestor_id, scope, types, created_by, sort
    assert {:ok, %{pages: subtree_hits}} =
             Pages.search(ctx.actor, "lattice", %{
               domain: :all,
               ancestor_id: private_parent.id,
               scope: :private,
               types: "doc",
               created_by: ctx.owner.uid
             })

    assert Enum.map(subtree_hits, & &1.id) == [child_a.id, child_b.id]

    # Respect hide_visits for visited_at, while personal edited_at still boosts edited pages
    {:ok, _} = Pages.state(ctx.actor, child_b.id, %{visited: true, hide_visits: true})
    assert {:ok, %{pages: still_a_first}} = Pages.search(ctx.actor, "lattice")
    assert hd(still_a_first).id == child_a.id

    {:ok, child_c} =
      Pages.create(ctx.actor, %{
        parent_id: private_parent.id,
        title: "Draft C",
        xml: "<page><p>Shared lattice note gamma</p></page>"
      })

    Repo.update_all(
      from(p in Ankole.Pod.Page, where: p.id == ^child_c.id),
      set: [updated_at: same_time]
    )

    {:ok, saved_state} =
      Repo.transact_top_level(fn ->
        Pages.save_state_in_tx(ctx.owner.uid, child_b.id, %{edited_at: DateTime.utc_now()})
      end)

    assert saved_state.hide_visits == true
    assert %DateTime{} = saved_state.edited_at

    assert {:ok, %{pages: ranked_after_edit}} = Pages.search(ctx.actor, "lattice")

    assert Enum.find_index(ranked_after_edit, &(&1.id == child_b.id)) <
             Enum.find_index(ranked_after_edit, &(&1.id == child_c.id))
  end

  test "extracts inline text/CSV and async DOCX/PPTX/PDF files with deep-link coordinates and CAS safety",
       ctx do
    # 1. Synchronous Markdown file upload
    md_body = "# Architecture\nIntro\n## Caching Layer\nRedis cluster eviction policy\n"

    {:ok, md_page} =
      Files.create_from_upload(
        ctx.actor,
        %{private_owner_uid: ctx.owner.uid},
        "design.md",
        md_body,
        "text/markdown"
      )

    assert {:ok, %{pages: [md_found], matches: [md_match]}} =
             Pages.search(ctx.actor, "eviction policy")

    assert md_found.id == md_page.id

    assert %{
             kind: :md_section,
             heading: "Caching Layer",
             level: 2,
             start_line: 4
           } = md_match.primary_target

    # 2. Synchronous CSV file upload
    csv_body = "sku,region,owner\nSKU-100,APAC,Alice\nSKU-200,EMEA,Bob\n"

    {:ok, csv_page} =
      Files.create_from_upload(
        ctx.actor,
        %{private_owner_uid: ctx.owner.uid},
        "inventory.csv",
        csv_body,
        "text/csv"
      )

    assert {:ok, %{pages: [csv_found], matches: [csv_match]}} =
             Pages.search(ctx.actor, "SKU-200")

    assert csv_found.id == csv_page.id
    assert %{kind: :csv_rows, start_row: 2, end_row: 2} = csv_match.primary_target

    # 3. Asynchronous PPTX extraction with slide page_number coordinate
    pptx_bytes = build_minimal_pptx(["Title Slide", " Helios Launch Milestone "])

    {:ok, pptx_page} =
      Files.create_from_upload(
        ctx.actor,
        %{private_owner_uid: ctx.owner.uid},
        "roadmap.pptx",
        pptx_bytes,
        "application/vnd.openxmlformats-officedocument.presentationml.presentation"
      )

    assert :ok =
             SyncFileCache.perform(%Oban.Job{
               args: %{
                 "tenant_id" => Repo.tenant_id!(),
                 "page_id" => pptx_page.id,
                 "object_id" => pptx_page.object_id
               }
             })

    assert {:ok, %{pages: [pptx_found], matches: [pptx_match]}} =
             Pages.search(ctx.actor, "Helios Launch")

    assert pptx_found.id == pptx_page.id
    assert %{kind: :page_number, page: 2} = pptx_match.primary_target

    # Referencing the same immutable object_id from a second file page reuses the existing cache synchronously in-tx
    {:ok, shared_pptx} =
      Pages.create(ctx.actor, %{
        type: :file,
        title: "roadmap-shared.pptx",
        private_owner_uid: ctx.owner.uid
      })

    assert {:ok, _} =
             Repo.transact_top_level(fn ->
               Ankole.Pod.Files.Content.commit_in_tx(
                 ctx.actor,
                 shared_pptx.id,
                 pptx_page.object_id,
                 %{
                   content_type:
                     "application/vnd.openxmlformats-officedocument.presentationml.presentation"
                 }
               )
             end)

    assert {:ok, %{pages: both_pptx}} = Pages.search(ctx.actor, "Helios Launch")
    assert MapSet.new(both_pptx, & &1.id) == MapSet.new([pptx_page.id, shared_pptx.id])

    # 4. CAS race safety: a stale SyncFileCache job for an older object_id never overwrites a newer upload
    stale_object_id = pptx_page.object_id
    newer_pptx = build_minimal_pptx(["Replaced Deck", "Zephyr Architecture"])

    {:ok, updated_pptx} =
      Files.upload(
        ctx.actor,
        pptx_page.id,
        "file",
        stale_object_id,
        "roadmap.pptx",
        newer_pptx,
        "application/vnd.openxmlformats-officedocument.presentationml.presentation"
      )

    assert :ok =
             SyncFileCache.perform(%Oban.Job{
               args: %{
                 "tenant_id" => Repo.tenant_id!(),
                 "page_id" => pptx_page.id,
                 "object_id" => updated_pptx.file.object_id
               }
             })

    # Replaying the stale job is a no-op
    assert :ok =
             SyncFileCache.perform(%Oban.Job{
               args: %{
                 "tenant_id" => Repo.tenant_id!(),
                 "page_id" => pptx_page.id,
                 "object_id" => stale_object_id
               }
             })

    assert {:ok, %{pages: [zephyr_found]}} = Pages.search(ctx.actor, "Zephyr Architecture")
    assert zephyr_found.id == pptx_page.id
    assert {:ok, %{pages: remaining_helios}} = Pages.search(ctx.actor, "Helios Launch")
    assert Enum.map(remaining_helios, & &1.id) == [shared_pptx.id]

    # 5. Corrupt PDF records :failed and reconcile_tenant_batch does not re-loop it
    {:ok, bad_pdf} =
      Files.create_from_upload(
        ctx.actor,
        %{private_owner_uid: ctx.owner.uid},
        "broken.pdf",
        "%PDF-not-valid-xref",
        "application/pdf"
      )

    assert :ok =
             SyncFileCache.perform(%Oban.Job{
               args: %{
                 "tenant_id" => Repo.tenant_id!(),
                 "page_id" => bad_pdf.id,
                 "object_id" => bad_pdf.object_id
               }
             })

    assert %FileCache{extract_status: :failed, format: "pdf"} =
             Repo.get_by!(FileCache, page_id: bad_pdf.id)

    Oban.drain_queue(queue: :default)
    assert :ok = FileExtraction.reconcile_tenant_batch()

    enqueued_for_bad =
      Repo.all(
        from j in Oban.Job,
          where:
            fragment("?->>'page_id' = ?", j.args, ^bad_pdf.id) and
              j.state in ["available", "scheduled", "retryable", "executing"]
      )

    assert enqueued_for_bad == []

    # Document update clears removed body text from projection
    {:ok, doc} =
      Pages.create(ctx.actor, %{title: "Mutable Doc", xml: "<page><p>AlphaToken</p></page>"})

    assert {:ok, %{pages: [_]}} = Pages.search(ctx.actor, "AlphaToken")
    {:ok, _} = Documents.write(ctx.actor, doc.id, doc.revision, "<page><p>BetaToken</p></page>")
    assert {:ok, %{pages: []}} = Pages.search(ctx.actor, "AlphaToken")
    assert {:ok, %{pages: [_]}} = Pages.search(ctx.actor, "BetaToken")
    assert Repo.get_by!(PageSearchDocument, page_id: doc.id).body_text == "BetaToken"
  end

  test "coalesces incremental recent searches per principal, caps at 20, and supports delete/clear",
       ctx do
    # 1-char queries are ignored
    assert {:ok, nil} = Pages.record_recent_search(ctx.actor, "a", 3)
    assert {:ok, []} = Pages.list_recent_searches(ctx.actor)

    # Incremental typing within 30s coalesces into a single entry
    assert {:ok, first} = Pages.record_recent_search(ctx.actor, "qu", 10)
    assert {:ok, second} = Pages.record_recent_search(ctx.actor, "quar", 6)
    assert {:ok, third} = Pages.record_recent_search(ctx.actor, "quarterly", 2)
    assert first.id == second.id
    assert second.id == third.id

    assert {:ok, [only]} = Pages.list_recent_searches(ctx.actor)
    assert only.query == "quarterly"
    assert only.result_count == 2

    # Peer principal cannot see or clear owner's recent searches
    assert {:ok, []} = Pages.list_recent_searches(ctx.peer_actor)
    assert {:ok, %{cleared: true}} = Pages.clear_recent_searches(ctx.peer_actor)
    assert {:ok, [_]} = Pages.list_recent_searches(ctx.actor)

    # Distinct queries cap at 20
    for idx <- 1..25 do
      {:ok, _} = Pages.record_recent_search(ctx.actor, "distinct-topic-#{idx}", idx)
    end

    assert {:ok, capped} = Pages.list_recent_searches(ctx.actor, 20)
    assert length(capped) == 20
    assert hd(capped).query == "distinct-topic-25"

    assert {:ok, %{deleted: true}} = Pages.delete_recent_search(ctx.actor, hd(capped).id)
    assert {:ok, after_delete} = Pages.list_recent_searches(ctx.actor, 20)
    assert length(after_delete) == 19

    assert {:ok, %{cleared: true}} = Pages.clear_recent_searches(ctx.actor)
    assert {:ok, []} = Pages.list_recent_searches(ctx.actor, 20)
  end

  test "SearchIndexes.ensure_current verifies and self-heals page_search_documents_bm25_idx" do
    assert {:ok, actions} = Ankole.SearchIndexes.ensure_current()

    assert Enum.any?(
             actions,
             &(&1.index == "page_search_documents_bm25_idx" and &1.action in [:current, :created])
           )
  end

  test "PageSearchDocument :put normalizes NFKC compatibility and halfwidth forms to match runtime queries",
       ctx do
    examples = [{"ＣＡＴＬＯＧ", "catlog"}, {"oﬃceworks", "officeworks"}, {"ｶﾞﾗｽ", "ガラス"}]

    for {legacy_text, query} <- examples do
      {:ok, page} =
        Pages.create(ctx.actor, %{
          title: legacy_text,
          xml: "<page><p>Unrelated body</p></page>"
        })

      {:ok, _} =
        Repo.transact_top_level(fn ->
          Ankole.Ash.create(PageSearchDocument, :put, %{
            page_id: page.id,
            title: legacy_text,
            meta_text: "",
            body_text: "Unrelated body",
            updated_at: page.updated_at
          })
        end)

      assert {:ok, %{pages: hits}} = Pages.search(ctx.actor, query, %{title_only: true})
      assert Enum.any?(hits, &(&1.id == page.id))
    end
  end

  test "document targets preserve inline heading markup, rich-block hits, and return nil without headings",
       ctx do
    {:ok, rich_doc} =
      Pages.create(ctx.actor, %{
        title: "Inline Heading Doc",
        xml: """
        <page>
          <h2>Cust<strong>om</strong> <code>Section</code></h2>
          <bookmark href="https://example.com/runbook" title="Bookmarktargetneedle" description="Ops link" />
        </page>
        """
      })

    assert {:ok, %{pages: [%{id: id}], matches: [match]}} =
             Pages.search(ctx.actor, "Bookmarktargetneedle")

    assert id == rich_doc.id
    assert %{kind: :doc_section, heading: "Custom Section", level: 2} = match.primary_target

    {:ok, plain_doc} =
      Pages.create(ctx.actor, %{
        title: "Headingless Doc",
        xml: "<page><p>Headinglessneedle lives in body without any h1-h6</p></page>"
      })

    assert {:ok, %{pages: [%{id: plain_id}], matches: [plain_match]}} =
             Pages.search(ctx.actor, "Headinglessneedle")

    assert plain_id == plain_doc.id
    assert plain_match.primary_target == nil
  end

  test "ODS body matches resolve exact sheet targets even when earlier sheets mention the sheet name",
       ctx do
    xml = """
    <office:document-content xmlns:office="urn:oasis:names:tc:opendocument:xmlns:office:1.0"
                             xmlns:table="urn:oasis:names:tc:opendocument:xmlns:table:1.0"
                             xmlns:text="urn:oasis:names:tc:opendocument:xmlns:text:1.0">
      <office:body>
        <office:spreadsheet>
          <table:table table:name="First">
            <table:table-row>
              <table:table-cell><text:p>See Second for details</text:p></table:table-cell>
            </table:table-row>
          </table:table>
          <table:table table:name="Second">
            <table:table-row>
              <table:table-cell><text:p>Odsaccurateneedle</text:p></table:table-cell>
            </table:table-row>
          </table:table>
        </office:spreadsheet>
      </office:body>
    </office:document-content>
    """

    {:ok, {_name, bytes}} = :zip.create(~c"sheets.ods", [{~c"content.xml", xml}], [:memory])

    {:ok, page} =
      Files.create_from_upload(
        ctx.actor,
        %{private_owner_uid: ctx.owner.uid},
        "sheets.ods",
        bytes,
        "application/vnd.oasis.opendocument.spreadsheet"
      )

    assert :ok =
             SyncFileCache.perform(%Oban.Job{
               args: %{
                 "tenant_id" => Repo.tenant_id!(),
                 "page_id" => page.id,
                 "object_id" => page.object_id
               }
             })

    assert {:ok, %{pages: [%{id: id}], matches: [match]}} =
             Pages.search(ctx.actor, "Odsaccurateneedle")

    assert id == page.id
    assert %{kind: :spreadsheet_cell, sheet_name: "Second"} = match.primary_target
  end

  test "reconcile_tenant_batch rebuilds missing file projections from immutable objects and advances scan cursor",
       ctx do
    require Ash.Query
    tenant_id = Repo.tenant_id!()
    FileExtraction.ScanCursor.clear(tenant_id)

    {:ok, file_page} =
      Files.create_from_upload(
        ctx.actor,
        %{private_owner_uid: ctx.owner.uid},
        "rebuild.txt",
        "Immutableobjectneedle",
        "text/plain"
      )

    {:ok, _} =
      Repo.transact_top_level(fn ->
        PageSearchDocument
        |> Ash.Query.filter(page_id == ^file_page.id)
        |> Ankole.Ash.destroy_where(:purge)
      end)

    # Create uncached binary files so bounded scan_budget must advance across runs.
    for idx <- 1..3 do
      {:ok, _bin} =
        Files.create_from_upload(
          ctx.actor,
          %{private_owner_uid: ctx.owner.uid},
          "archive-#{idx}.bin",
          <<0, 1, 2, idx>>,
          "application/octet-stream"
        )
    end

    assert :ok = FileExtraction.reconcile_tenant_batch(scan_budget: 2, work_budget: 2)
    assert FileExtraction.ScanCursor.get(tenant_id) != nil
    assert :ok = FileExtraction.reconcile_tenant_batch(scan_budget: 10, work_budget: 5)

    for job <- all_enqueued(worker: SyncFileCache) do
      assert :ok = SyncFileCache.perform(job)
    end

    assert {:ok, %{pages: hits}} = Pages.search(ctx.actor, "Immutableobjectneedle")
    assert Enum.any?(hits, &(&1.id == file_page.id))
  end

  test "SyncFileCache CAS discards stale format extraction when a file is renamed mid-flight",
       ctx do
    {:ok, page} =
      Files.create_from_upload(
        ctx.actor,
        %{private_owner_uid: ctx.owner.uid},
        "metrics.csv",
        "sku,qty\nCasraceneedle,5\n",
        "text/plain"
      )

    {:ok, stale_extract} =
      Ankole.Kernel.file_extract_text("sku,qty\nCasraceneedle,5\n", "metrics.csv", "text/plain")

    # Rename .csv -> .txt while the earlier CSV extraction was in flight.
    {:ok, renamed} = Pages.Tree.rename(ctx.actor, page.id, "metrics.txt")

    assert String.ends_with?(renamed.name, ".txt")

    # Ensure the current .txt cache is persisted, then replay the stale :csv CAS commit.
    assert :ok =
             SyncFileCache.perform(%Oban.Job{
               args: %{
                 "tenant_id" => Repo.tenant_id!(),
                 "page_id" => page.id,
                 "object_id" => page.object_id
               }
             })

    assert :ok =
             SyncFileCache.commit_extraction(
               page.id,
               page.object_id,
               :text,
               "csv",
               Ankole.Kernel.file_extractor_version(),
               stale_extract
             )

    assert {:ok, %{pages: [%{id: id}], matches: [match]}} =
             Pages.search(ctx.actor, "Casraceneedle")

    assert id == page.id
    assert %{kind: :lines, start_line: 2, end_line: 2} = match.primary_target
  end

  defp build_minimal_pptx(slides) do
    slide_rels =
      slides
      |> Enum.with_index(1)
      |> Enum.map_join("", fn {_text, idx} ->
        ~s(<Relationship Id="rId#{idx}" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/slide" Target="slides/slide#{idx}.xml"/>)
      end)

    sld_ids =
      slides
      |> Enum.with_index(1)
      |> Enum.map_join("", fn {_text, idx} ->
        ~s(<p:sldId id="#{255 + idx}" r:id="rId#{idx}"/>)
      end)

    presentation_xml = """
    <?xml version="1.0" encoding="UTF-8"?>
    <p:presentation xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main"
                    xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"
                    xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main">
      <p:sldIdLst>#{sld_ids}</p:sldIdLst>
    </p:presentation>
    """

    rels_xml = """
    <?xml version="1.0" encoding="UTF-8"?>
    <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
      #{slide_rels}
    </Relationships>
    """

    slide_entries =
      slides
      |> Enum.with_index(1)
      |> Enum.map(fn {text, idx} ->
        xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <p:sld xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main"
               xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main">
          <p:cSld><p:spTree><p:sp><p:txBody><a:p><a:r><a:t>#{text}</a:t></a:r></a:p></p:txBody></p:sp></p:spTree></p:cSld>
        </p:sld>
        """

        {~c"ppt/slides/slide#{idx}.xml", xml}
      end)

    entries =
      [
        {~c"ppt/presentation.xml", presentation_xml},
        {~c"ppt/_rels/presentation.xml.rels", rels_xml}
      ] ++ slide_entries

    {:ok, {_name, bytes}} = :zip.create(~c"deck.pptx", entries, [:memory])
    bytes
  end
end
