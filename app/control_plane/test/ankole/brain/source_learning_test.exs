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
  alias Ankole.Brain.Schemas.Page, as: Object
  alias Ankole.Brain.Schemas.Source
  alias Ankole.Brain.SourceLearning
  alias Ankole.Repo
  alias Ankole.AgentWorkers.WorkerRoute

  setup do
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

  test "a private report stays independent while its company facts follow report permissions",
       ctx do
    %{principal: reader} = Ankole.PrincipalsFixtures.human_fixture()
    %{principal: outsider} = Ankole.PrincipalsFixtures.human_fixture()

    {:ok, company} =
      Ankole.Brain.create_object(
        %{
          slug: "companies/jizhi",
          title: "激智科技",
          type: "company",
          body: "团队维护的公司主页。"
        },
        :system
      )

    {:ok, :granted} =
      Repo.transact(fn ->
        for principal <- [reader, outsider] do
          :ok =
            Ankole.Pod.Access.put_role(
              %{principal_uid: principal.uid},
              "drive:**:#{company.id}:node",
              "view"
            )
        end

        {:ok, :granted}
      end)

    {:ok, report_source} =
      SourceLearning.register_source(%{
        upstream_id: ctx.path <> ".report",
        kind: "file",
        name: "激智科技调研报告",
        default_source_node_id: Ankole.Brain.Scope.principal(reader.uid)
      })

    on_exit(fn -> File.rm(report_source.upstream_id) end)
    content = "激智科技调研报告\n\n激智科技计划新增两条产线。\n\n完整调研记录，包含访谈与计算过程。"
    File.write!(report_source.upstream_id, content)

    set_items(ctx.items_holder, [
      valid_item("激智科技计划新增两条产线") |> Map.put("subject_page_id", company.id)
    ])

    assert {:ok, %{subject_page_id: report_id, claims: 1}} =
             SourceLearning.learn(report_source.id)

    assert report_id != company.id
    assert_receive {:source_extraction_prompt, prompt}
    assert prompt =~ company.id
    assert {:ok, report} = Objects.get_by_slug(report_id)
    assert String.trim(report.body) == content
    assert report.title == "激智科技调研报告"
    assert [fact] = source_claims(report_source)
    assert {fact.subject_page_id, fact.source_node_id} == {company.id, report_id}
    assert {:ok, unchanged} = Objects.get_by_slug(company.id)
    assert {unchanged.body, unchanged.revision} == {company.body, company.revision}

    reader_context = %{querier_uid: reader.uid, disclosure: Ankole.Brain.Access.open_disclosure()}

    outsider_context = %{
      querier_uid: outsider.uid,
      disclosure: Ankole.Brain.Access.open_disclosure()
    }

    assert {:ok, %{claims: [at_company]}} =
             Ankole.Brain.Knowledge.panel(reader_context, company.id)

    assert {:ok, %{claims: [at_report]}} = Ankole.Brain.Knowledge.panel(reader_context, report_id)
    assert at_company.id == fact.id and at_report.id == fact.id
    assert {:ok, %{claims: []}} = Ankole.Brain.Knowledge.panel(outsider_context, company.id)
    refute match?({:ok, _}, Ankole.Brain.Knowledge.panel(outsider_context, report_id))

    {:ok, %{claim: manual}} =
      Ankole.Brain.Claims.write_fact(
        %{
          claim: "激智科技公司主页的独立事实",
          kind: "fact",
          holder: "world",
          confidence: 0.75,
          notability: "medium",
          source_node_id: company.id,
          subject_page_id: company.id,
          provenance: "team",
          valid_from: DateTime.utc_now(:microsecond)
        },
        :system,
        embed: false
      )

    File.write!(report_source.upstream_id, String.replace(content, "两条", "三条"))

    set_items(ctx.items_holder, [
      valid_item("激智科技计划新增三条产线") |> Map.put("subject_page_id", company.id)
    ])

    assert {:ok, %{claims: 1, claims_expired: 1}} = SourceLearning.learn(report_source.id)
    assert Repo.reload!(fact).expired_at
    refute Repo.reload!(manual).expired_at
    assert {:ok, %{claims: [current]}} = Ankole.Brain.Knowledge.panel(reader_context, report_id)
    assert current.claim =~ "三条"
    assert {:ok, %{claims: [public]}} = Ankole.Brain.Knowledge.panel(outsider_context, company.id)
    assert public.id == manual.id
  end

  test "a saved report creates a missing company without moving or copying the report", ctx do
    {:ok, report} =
      Ankole.Brain.create_object(
        %{
          slug: "documents/cerebras-research",
          title: "Cerebras",
          type: "document",
          subtype: "report",
          body: "Cerebras 公司设计晶圆级处理器。研究员尚未验证新产品交付情况。"
        },
        :system
      )

    {:ok, node_before} = Ankole.Pod.Pages.Tree.fetch(report.id)

    set_items(ctx.items_holder, [
      %{
        "type" => "object",
        "slug" => "Cerebras",
        "object_type" => "company",
        "title" => "Cerebras",
        "body" => report.body
      },
      valid_item("Cerebras 公司设计晶圆级处理器") |> Map.put("subject_page_id", "Cerebras"),
      valid_item("研究员尚未验证新产品交付情况") |> Map.put("subject_page_id", nil)
    ])

    assert {:ok, %{claims: 2, rejected: 0}} =
             SourceLearning.learn_page(report.id, report.revision)

    assert {:ok, company} = Objects.get_by_slug("companies/Cerebras")
    assert company.body == ""
    assert {:ok, report_after} = Objects.get_by_slug(report.id)

    assert {report_after.title, report_after.body, report_after.revision} ==
             {report.title, report.body, report.revision}

    assert {:ok, node_after} = Ankole.Pod.Pages.Tree.fetch(report.id)

    assert {node_after.parent_id, node_after.acl_anchor_id} ==
             {node_before.parent_id, node_before.acl_anchor_id}

    claims = Repo.all(from c in Claim, where: c.source_node_id == ^report.id)
    assert Enum.any?(claims, &(&1.subject_page_id == company.id))
    assert Enum.any?(claims, &is_nil(&1.subject_page_id))
  end

  for entity_type <- [nil, "custom-business-kind"] do
    @entity_type entity_type
    test "a business page extracts facts with entity_type #{inspect(entity_type)}", %{
      items_holder: holder
    } do
      {:ok, page} =
        Ankole.Brain.create_object(
          %{
            slug: "companies/plain-page",
            title: "Factory",
            type: @entity_type,
            body: "The factory has four production lines."
          },
          :system
        )

      assert page.type == (@entity_type || "knowledge")
      set_items(holder, [valid_item("The factory has four production lines")])
      assert {:ok, %{claims: 1}} = SourceLearning.learn_page(page.id, page.revision)

      assert [%{source_node_id: source, subject_page_id: subject}] =
               Repo.all(from(c in Claim, where: c.source_node_id == ^page.id))

      assert source == page.id
      assert subject == page.id
      assert_receive {:source_extraction_prompt, prompt}
      assert prompt =~ "four production lines"
    end
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

  test "source extraction and page jobs share a revision while manual edits replace automatic facts",
       ctx do
    File.write!(ctx.path, "Cobalt shipment arrived on time.")
    set_items(ctx.items_holder, [valid_item("Cobalt shipment arrived on time")])
    assert {:ok, %{subject_page_id: id}} = SourceLearning.learn(ctx.source.id)
    assert_receive {:source_extraction_prompt, _}
    {:ok, page} = Objects.get_by_slug(id)
    assert {:error, :stale_run} = SourceLearning.learn_page(id, page.revision)
    refute_receive {:source_extraction_prompt, _}
    assert [%{expired_at: nil}] = Repo.all(from(c in Claim, where: c.source_node_id == ^id))

    assert {:ok, %{claim: manual}} =
             Ankole.Brain.Claims.write_fact(
               %{
                 subject_page_id: id,
                 source_node_id: id,
                 claim: "The operator will inspect the shipment",
                 kind: "commitment",
                 holder: "world",
                 confidence: 0.75,
                 notability: "medium",
                 valid_from: DateTime.utc_now(:microsecond),
                 provenance: "manual operator note"
               },
               :system,
               embed: false
             )

    {:ok, changed} =
      Ankole.Brain.update_object(
        id,
        %{body: "Cobalt shipment was cancelled.", base_revision: page.revision},
        :system
      )

    set_items(ctx.items_holder, [valid_item("Cobalt shipment was cancelled")])

    assert {:ok, %{claims: 1, claims_expired: 1}} =
             SourceLearning.learn_page(id, changed.revision)

    assert Repo.get!(Claim, manual.id).expired_at == nil
    current = Repo.all(from(c in Claim, where: c.source_node_id == ^id and is_nil(c.expired_at)))
    assert length(current) == 2
    assert Enum.any?(current, &(&1.claim == "Cobalt shipment was cancelled"))
    assert {:error, :stale_run} = SourceLearning.learn_page(id, changed.revision)
    assert_receive {:source_extraction_prompt, _}

    assert {:ok, emptied} =
             Ankole.Brain.update_object(id, %{body: "", base_revision: changed.revision}, :system)

    assert [%{id: manual_id}] =
             Repo.all(from(c in Claim, where: c.source_node_id == ^id and is_nil(c.expired_at)))

    assert manual_id == manual.id
    assert {:error, :stale_run} = SourceLearning.learn_page(id, emptied.revision)
    refute_receive {:source_extraction_prompt, _}
  end

  test "source editors can maintain the imported page through ordinary Pod writes", ctx do
    %{principal: human} = Ankole.PrincipalsFixtures.human_fixture()
    path = ctx.path <> ".private"
    File.write!(path, "The factory has four production lines.")
    on_exit(fn -> File.rm(path) end)

    {:ok, source} =
      SourceLearning.register_source(%{
        upstream_id: path,
        kind: "file",
        name: "Factory",
        default_source_node_id: Ankole.Brain.Scope.principal(human.uid)
      })

    set_items(ctx.items_holder, [valid_item("The factory has four production lines")])
    assert {:ok, %{subject_page_id: id}} = SourceLearning.learn(source.id)
    {:ok, page} = Ankole.Pod.Pages.fetch(id)
    {:ok, parsed} = Ankole.Kernel.knowledge_parse("The factory has five production lines.")

    assert {:ok, %{page: edited}} =
             Ankole.Pod.Knowledge.write(
               Ankole.PrincipalsFixtures.actor_fixture(human),
               id,
               page.revision,
               parsed.xml,
               page.metadata
             )

    assert edited.revision == page.revision + 1
  end

  test "a queued page extraction observes Brain being disabled" do
    {:ok, page} =
      Ankole.Brain.create_object(
        %{slug: "notes/paused", title: "Paused", body: "Waiting for extraction."},
        :system
      )

    {:ok, _} = AppConfigure.put_global_by_key("brain.enabled", false)
    assert {:error, :brain_disabled} = SourceLearning.learn_page(page.id, page.revision)
    refute_receive {:source_extraction_prompt, _}
  end

  test "a Pod with only primary extracts Source facts as its system Principal", context do
    assert Repo.aggregate(Ankole.Principals.Agent, :count) == 0
    assert {:ok, _} = ModelProfiles.put_default_model_profile(:tenant, "light", nil)
    system_uid = configure_brain_maintainer_profile!("primary", "brain-source", "primary-extract")
    File.write!(context.path, "Cobalt shipment arrived on time.")
    set_items(context.items_holder, [valid_item("Cobalt shipment arrived on time")])

    assert {:ok, %{status: :learned, claims: 1}} = SourceLearning.learn(context.source.id)

    assert [%{author: %Ankole.ActorRef{uid: "ankole_brain"}}] = source_claims(context.source)

    assert [%{subject_uid: ^system_uid, origin: :brain, model: "brain-source/primary-extract"}] =
             Repo.all(Ankole.AIGateway.Schemas.UsageRecord)
  end

  test "source content is a normal Pod page with upstream identity", %{
    source: source,
    path: path,
    items_holder: holder
  } do
    File.write!(path, "Source-owned body.")
    set_items(holder, [])
    assert {:ok, %{status: :learned, subject_page_id: id}} = SourceLearning.learn(source.id)
    assert {:ok, page} = Objects.get_by_slug(id)
    assert page.managed_by_source_id == source.id

    assert {:ok, updated} =
             Ankole.Brain.update_object(
               id,
               %{body: "Reviewed body", base_revision: page.revision},
               :system
             )

    assert updated.body == "Reviewed body"
  end

  test "a non-object extraction item preserves the current page, facts, and revision", %{
    source: source,
    path: path,
    items_holder: holder
  } do
    File.write!(path, "Cobalt shipment arrived on time.")
    set_items(holder, [valid_item("Cobalt shipment arrived on time")])
    assert {:ok, %{subject_page_id: slug}} = SourceLearning.learn(source.id)
    original = Repo.get!(Object, slug)
    original_facts = source_claims(source)
    revision = Repo.get!(Source, source.id).upstream_revision

    File.write!(path, "Cobalt shipment was cancelled.")

    for invalid <- [42, "bad item", [], false, nil] do
      set_items(holder, [valid_item("Cobalt shipment was cancelled"), invalid])

      assert {:error, {:extraction_failed, :invalid_extraction_response}} =
               SourceLearning.learn(source.id)

      Ankole.DataCase.assert_persisted_equal(Repo.get!(Object, slug), original)
      assert source_claims(source) == original_facts
      assert Repo.get!(Source, source.id).upstream_revision == revision
    end
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

  test "a URL Source uses the Pod web_fetch profile and system execution identity", %{
    items_holder: holder
  } do
    test_pid = self()
    url = "https://127.0.0.1/provider-source"

    base_url =
      start_upstream_server(fn request ->
        send(test_pid, {:web_fetch_provider_request, request})

        content =
          if String.ends_with?(request.body["url"], "/shell"),
            do: "Please enable JavaScript to view this page.",
            else: "Provider-rendered source body"

        {:json, 200,
         %{
           "data" => %{
             "url" => request.body["url"],
             "title" => "Provider Source",
             "content" => content
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

    assert {:ok, false} = AppConfigure.put_tenant_by_key("security.ssrf_filter", false)
    {:ok, true} = AppConfigure.put_global_by_key("security.ssrf_filter", true)

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

    # A script shell has nothing to learn and stays learnable.
    {:ok, shell} =
      SourceLearning.register_source(%{
        upstream_id: "https://127.0.0.1/shell",
        kind: "url",
        name: "Script Shell Source"
      })

    assert {:error, {:source_fetch_unusable, "script_shell"}} = SourceLearning.learn(shell.id)
    refute Repo.get_by(Object, title: "Script Shell Source")
  end

  test "a URL Source without a web_fetch profile fails without asking a Worker" do
    %{principal: agent} = agent_fixture()
    route = "brain-web-fetch-#{System.unique_integer([:positive])}"
    :ok = put_ready_worker!(agent.uid, route)
    :ok = WorkerRoute.register_local_worker(route, self())
    on_exit(fn -> WorkerRoute.unregister_local_worker(route) end)

    {:ok, source} =
      SourceLearning.register_source(%{
        upstream_id: "https://example.com/unconfigured-source",
        kind: "url",
        name: "Unconfigured URL Source"
      })

    assert {:error, :web_fetch_model_not_configured} = SourceLearning.learn(source.id)
    refute_receive {:actor_lane, _envelope}
  end

  test "a disabled Agent does not prevent Pod URL fetching" do
    test_pid = self()
    url = "https://example.com/disabled-agent-source"
    %{principal: agent} = agent_fixture()

    base_url =
      start_upstream_server(fn request ->
        send(test_pid, {:disabled_agent_provider_request, request})

        {:json, 200,
         %{
           "data" => %{
             "url" => request.body["url"],
             "title" => "Independent URL Source",
             "content" => "Available after Agent disablement"
           }
         }}
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

    {:ok, source} =
      SourceLearning.register_source(%{
        upstream_id: url,
        kind: "url",
        name: "Independent URL Source"
      })

    assert {:ok, %{status: :disabled}} =
             Ankole.PrincipalsFixtures.disable_principal_fixture(agent.uid)

    assert {:ok, %{status: :learned, claims: 0}} = SourceLearning.learn(source.id)
    assert_receive {:disabled_agent_provider_request, _request}
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
    learning = Task.async(Repo.bind_tenant(fn -> SourceLearning.learn(source.id) end))

    assert_receive {:archive_fence_reached, upstream_request}, 5_000
    assert {:ok, _archived} = Ankole.Brain.archive_source(source.id)
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
    old_learning = Task.async(Repo.bind_tenant(fn -> SourceLearning.learn(source.id) end))
    assert_receive {:revision_fence_reached, upstream_request}, 5_000

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

  defp valid_item(text),
    do: %{"claim" => text, "kind" => "fact", "notability" => "medium", "confidence" => 0.75}

  defp source_claims(source) do
    session = "source:" <> source.id

    Claim
    |> where([claim], claim.provenance_session == ^session)
    |> Repo.all()
  end
end
