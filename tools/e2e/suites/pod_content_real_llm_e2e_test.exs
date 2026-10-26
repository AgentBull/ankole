defmodule Ankole.E2E.PodContentRealLLMTest do
  @moduledoc "A real Human request produces durable Pod content through a model and Docker Worker."

  use ExUnit.Case, async: false
  use Oban.Testing, repo: Ankole.Repo

  import Ecto.Query
  import Ankole.E2E.PodContentStory

  alias Ankole.AuthZ.Actor
  alias Ankole.BackgroundAgentJobs.Schemas.Job
  alias Ankole.E2E.PodContentBrowser, as: Browser
  alias Ankole.E2E.PodContentEvidence, as: Evidence
  alias Ankole.E2E.PodContentStory, as: Story
  alias Ankole.Conversations
  alias Ankole.Conversations.Message
  alias Ankole.Pod.{Bases, BaseRecord, Formula, Page, PageContent, Pages}
  alias Ankole.Pod.Files, as: PageFiles
  alias Ankole.Repo
  alias Ankole.Signals.Signal

  @story_timeout 3_600_000

  setup_all do
    Ankole.E2E.Harness.start_committed_repo!()
  end

  setup do
    tenant = Ankole.DataCase.create_committed_tenant()
    Repo.put_tenant_id(tenant.id)
    {:ok, tenant: tenant}
  end

  @tag :real_llm
  @tag :pod_content_real_llm
  @tag :pod_content_browser_report
  @tag timeout: @story_timeout
  test "a Human receives an Agent-created report with a live sales table that outlives its Conversation",
       %{tenant: tenant} do
    {ctx, owner} = Story.start!(tenant)
    record_observer = Evidence.observe_record_writes!()
    reference = "POD#{System.unique_integer([:positive])}"
    title = "October sales review #{reference}"

    request =
      Browser.send_message!(ctx, owner,
        text: """
        Make a durable Pod report titled "#{title}" for our October sales review.

        Under that report, create a Base titled "Sales ledger #{reference}" with a
        table named "October sales". Its primary field holds the product name. Add
        number fields named Price and Quantity, and a read-only formula field named
        Total that calculates [Price] * [Quantity]. Enter these two sales:
        Oak: Price 120, Quantity 2. Pine: Price 75, Quantity 3.

        Write a brief report with the products, their totals and combined sales, and
        include a working reference to its child Base. Keep the report and data
        saved so we can continue to edit them together. Do not use web research.

        Also create a child Applet named "Sales workspace #{reference}" that works
        with this same table. It must display Oak and Pine and a live sum of Total
        in a status region whose accessible name is "Total sales".
        Add a button labeled "Add Cedar sale"
        that adds one Cedar record with Price 10 and Quantity 2 to the same table.
        Do not create Cedar now: I will click the button after you deliver the applet.
        The sum must update from 465 to 485 and the added sale must survive reload.
        Publish this working applet and show it directly inside the report.

        Send me the saved report as a clickable page link.
        Do the work now; you already have edit access to the space.
        """
      )

    conversation_id = request["conversation_id"]
    message_id = request["message_id"]
    refute request["page_id"]

    input = Repo.get_by!(Signal, message_id: message_id)
    assert input.human_uid == owner

    completion = complete_request!(ctx, input)

    report = Repo.get_by!(Page, title: title, type: :doc)
    ledger = Repo.get_by!(Page, parent_id: report.id, type: :base)
    applet = Repo.get_by!(Page, parent_id: report.id, type: :applet)
    assert report.revision > 0
    assert applet.revision > 0

    for page <- [report, ledger, applet] do
      assert page.saved_from_message_id == message_id,
             "#{page.type} #{page.id} lost its source Human message after Agent work"

      assert page.created_by.uid == ctx.agent.uid
      assert page.created_by.tenant_id == Repo.tenant_id!()
      assert {:ok, _} = Pages.authorize(ctx.owner_actor, page.id, "page_view")
      assert {:ok, _} = Pages.authorize(Actor.new(ctx.agent), page.id, "page_edit")
    end

    {:ok, %{tables: tables}} = Bases.list_tables(ctx.owner_actor, ledger.id)
    table = Enum.find(tables, &(&1.name == "October sales"))
    assert table, "Agent did not save the requested business table"
    definitions = Bases.fields(table.id)
    primary = Enum.find(definitions, & &1.is_primary)
    price = Enum.find(definitions, &(&1.name == "Price"))
    quantity = Enum.find(definitions, &(&1.name == "Quantity"))
    total = Enum.find(definitions, &(&1.name == "Total"))
    assert primary.type == :text
    assert price.type == :number
    assert quantity.type == :number
    assert total.type == :formula

    assert %{
             "kind" => "binary",
             "op" => "*",
             "left" => %{"kind" => "field", "id" => left},
             "right" => %{"kind" => "field", "id" => right}
           } = total.config["ast"]

    assert MapSet.new([left, right]) == MapSet.new([price.id, quantity.id])

    {:ok, expression, :number, parameters} = Formula.expression(total, definitions, [])

    for {unit_price, count, expected} <- [{17, 4, 68}, {12.5, 3, 37.5}] do
      assert %{rows: [[actual]]} =
               Repo.query!(
                 "SELECT (#{expression})::double precision FROM (SELECT $#{length(parameters) + 1}::jsonb AS data) r",
                 parameters ++ [%{price.id => unit_price, quantity.id => count}]
               )

      assert actual == expected
    end

    assert {:ok, %{records: records}} = Bases.query(ctx.owner_actor, table.id, %{})
    assert length(records) == 2

    assert Map.new(records, fn record ->
             data = record["data"]
             {data[primary.id], {data[price.id], data[quantity.id], data[total.id]}}
           end) == %{
             "Oak" => {120, 2, 240},
             "Pine" => {75, 3, 225}
           }

    assert {:ok, %{groups: [%{metrics: %{"sales" => 465}}]}} =
             Bases.aggregate(ctx.owner_actor, table.id, %{
               metrics: [%{operation: "sum", field_id: total.id, alias: "sales"}]
             })

    for record <- Repo.all(from r in BaseRecord, where: r.table_id == ^table.id),
        do: assert(record.created_by.uid == ctx.agent.uid)

    content = Repo.get!(PageContent, report.id)
    assert content.updated_by.uid == ctx.agent.uid
    assert_named_facts!(content.plain_text, [{"Oak", "\\b240\\b"}, {"Pine", "\\b225\\b"}])
    assert content.plain_text =~ "465"
    assert_base_reference(content.content, ledger.id)
    assert Regex.match?(~r/<embed\b[^>]*\bref="#{applet.id}"/, content.content)

    assert {:ok, manifest} = PageFiles.manifest(ctx.owner_actor, applet.id)
    paths = Enum.map(manifest.files, & &1.path)
    assert "src/main.tsx" in paths
    assert "dist/index.html" in paths
    assert "dist/app.js" in paths

    source =
      manifest.files
      |> Enum.filter(&String.starts_with?(&1.path, "src/"))
      |> Enum.map_join("\n", fn file ->
        {:ok, _, bytes} = PageFiles.read(ctx.owner_actor, applet.id, file.path)
        bytes
      end)

    assert source =~ "@ankole/applet-sdk"
    assert {:ok, _, artifact} = PageFiles.read(ctx.owner_actor, applet.id, "dist/app.js")
    refute artifact =~ "jsxDEV"

    detail =
      await_delivery(ctx.owner_actor, conversation_id, message_id, ctx.agent.uid, report.id)

    delivered? = delivered_after?(detail, message_id, ctx.agent.uid, report.id)

    delivery_evidence(ctx, Repo.reload!(completion), detail, delivered?)

    assert delivered?,
           """
           The final Conversation did not deliver a clickable saved report.
           completion=#{inspect(Map.take(Repo.reload!(completion), [:status, :completed_at, :dead_letter_at]))}
           messages=#{inspect(Enum.map(detail.messages, &Map.take(&1, [:author_type, :text, :links, :signal_id])), printable_limit: 12_000)}
           """

    assert {:ok, %{source_conversation: %{id: ^conversation_id, deleted: false}}} =
             Pages.get(ctx.owner_actor, report.id)

    refute Enum.any?(Evidence.record_writes(record_observer, table.id, :before_human), fn write ->
             write["data"][primary.id] == "Cedar"
           end),
           "The Agent wrote Cedar before the Human's first click, even if it later removed or renamed the record"

    Browser.report!(ctx, owner, conversation_id, report.id, applet.id, :add)
    assert {:ok, %{records: after_human}} = Bases.query(ctx.owner_actor, table.id, %{})
    assert length(after_human) == 3
    cedar = Enum.find(after_human, &(&1["data"][primary.id] == "Cedar"))
    assert cedar["data"][primary.id] == "Cedar"
    assert cedar["data"][price.id] == 10
    assert cedar["data"][quantity.id] == 2
    assert cedar["data"][total.id] == 20
    assert Repo.get_by!(BaseRecord, table_id: table.id, id: cedar["id"]).created_by.uid == owner

    cedar_writes =
      Enum.filter(Evidence.record_writes(record_observer, table.id, :after_human), fn write ->
        write["data"][primary.id] == "Cedar"
      end)

    assert [%{"operation" => "INSERT", "record_id" => cedar_id, "actor" => cedar_actor}] =
             cedar_writes

    assert cedar_id == cedar["id"]
    assert cedar_actor == "ankole:#{Repo.tenant_id!()}:principal/#{owner}"

    assert {:ok, %{groups: [%{metrics: %{"sales" => 485}}]}} =
             Bases.aggregate(ctx.owner_actor, table.id, %{
               metrics: [%{operation: "sum", field_id: total.id, alias: "sales"}]
             })

    followup_request =
      Browser.send_message!(ctx, owner,
        page_id: report.id,
        text: """
        更新此页面。我刚使用此页面中的 Applet 添加了 Cedar。
        请重新读取此页面引用的原有销售表，把此页面的现有销售总结更新为三种产品及其最新总额。
        保留原有多维表、Applet 和两个嵌入引用；不要创建替代页面或表，也不要再添加 Cedar。
        请完成实际修改，并给我更新后的可点击链接。
        """
      )

    followup_id = followup_request["message_id"]
    followup_conversation_id = followup_request["conversation_id"]
    assert followup_request["page_id"] == report.id
    refute followup_request["text"] =~ report.id

    assert {:ok, %{conversation: %{page_id: page_id}}} =
             Conversations.get(ctx.owner_actor, followup_conversation_id)

    assert page_id == report.id

    followup_input = Repo.get_by!(Signal, message_id: followup_id)
    followup = complete_request!(ctx, followup_input)

    followup_detail =
      await_delivery(
        ctx.owner_actor,
        followup_conversation_id,
        followup_id,
        ctx.agent.uid,
        report.id
      )

    followup_delivered? = delivered_after?(followup_detail, followup_id, ctx.agent.uid, report.id)
    delivery_evidence(ctx, followup, followup_detail, followup_delivered?)

    assert followup_delivered?,
           "The Conversation did not deliver the same saved report in a new Agent reply after the Human's update request"

    updated = Repo.get!(PageContent, report.id)

    assert_named_facts!(updated.plain_text, [
      {"Oak", "\\b240\\b"},
      {"Pine", "\\b225\\b"},
      {"Cedar", "\\b20\\b"}
    ])

    assert updated.plain_text =~ "485"
    assert updated.updated_by.uid == ctx.agent.uid
    followup_jobs = Repo.all(from j in Job, where: j.source_signal_id == ^followup_input.id)

    assert Enum.any?(followup_jobs, &String.contains?(&1.task, report.id)),
           "Page chat did not pass the stable current Page to its real Agent Job"

    assert Repo.get!(Page, report.id).revision > report.revision
    assert_base_reference(updated.content, ledger.id)
    assert Regex.match?(~r/<embed\b[^>]*\bref="#{applet.id}"/, updated.content)
    assert {:ok, %{records: ^after_human}} = Bases.query(ctx.owner_actor, table.id, %{})
    Browser.report!(ctx, owner, followup_conversation_id, report.id, applet.id, :read)

    assert {:ok, _} = Pages.remove_space_agent(ctx.owner_actor, ctx.agent.uid)
    assert {:error, :forbidden} = Pages.authorize(Actor.new(ctx.agent), report.id, "page_view")
    assert {:error, :forbidden} = Bases.query(Actor.new(ctx.agent), table.id, %{})
    assert {:ok, _} = Bases.query(ctx.owner_actor, table.id, %{})

    assert {:ok, ^conversation_id} = Conversations.delete(ctx.owner_actor, conversation_id)

    assert {:ok, %{source_conversation: %{deleted: true}, content: remaining}} =
             Pages.get(ctx.owner_actor, report.id)

    assert remaining.content == updated.content
    assert {:ok, %{records: remaining_records}} = Bases.query(ctx.owner_actor, table.id, %{})
    assert remaining_records == after_human
    refute Repo.exists?(from m in Message, where: m.conversation_id == ^conversation_id)

    IO.puts(
      "Pod real-model story verified: report=#{report.id} table=#{table.id} applet=#{applet.id} agent_rows=2 human_rows=1 sales=485 source=deleted agent_access=revoked"
    )
  end

  @tag :real_llm
  @tag :pod_content_real_llm
  @tag :pod_content_pure_spa
  @tag timeout: @story_timeout
  test "a Human uses a pure frontend applet and finds the Agent-moved original page in its new hierarchy",
       %{tenant: tenant} do
    {ctx, owner} = Story.start!(tenant)
    reference = "SPA#{System.unique_integer([:positive])}"
    shelf_title = "Project shelf #{reference}"
    note_title = "Pilot decision #{reference}"
    applet_title = "Focus counter #{reference}"
    marker = "Decision: publish the pilot on Friday."

    request =
      Browser.send_message!(ctx, owner,
        text: """
        Create a top-level document titled "#{shelf_title}" with a short project overview.
        Create a separate top-level document titled "#{note_title}" containing exactly:
        #{marker}

        Under "#{shelf_title}", build and publish a pure frontend React Applet titled
        "#{applet_title}". Its only state is an in-memory focus counter, initially zero.
        Show only the numeric count inside a status region named "Focus points".
        A button labeled "Add focus point" increases it by one, and "Reset" returns it to zero.
        Reloading starts a new session at zero. This applet needs no Base or server data.

        Send clickable links to both documents and the working Applet. Do the work now;
        you already have space edit access. Do not move either document yet.
        """
      )

    input = Repo.get_by!(Signal, message_id: request["message_id"])
    completion = complete_request!(ctx, input)
    shelf = Repo.get_by!(Page, title: shelf_title, type: :doc)
    note = Repo.get_by!(Page, title: note_title, type: :doc)
    applet = Repo.get_by!(Page, title: applet_title, type: :applet)
    original = Repo.get!(PageContent, note.id)
    assert is_nil(shelf.parent_id)
    assert is_nil(note.parent_id)
    assert applet.parent_id == shelf.id
    assert original.plain_text =~ marker
    assert original.updated_by.uid == ctx.agent.uid
    refute Repo.exists?(from p in Page, where: p.type == :base)

    for page <- [shelf, note, applet] do
      assert page.created_by.uid == ctx.agent.uid
      assert page.saved_from_message_id == request["message_id"]

      detail =
        await_delivery(
          ctx.owner_actor,
          request["conversation_id"],
          request["message_id"],
          ctx.agent.uid,
          page.id
        )

      assert delivered_after?(detail, request["message_id"], ctx.agent.uid, page.id)
    end

    assert {:ok, manifest} = PageFiles.manifest(ctx.owner_actor, applet.id)

    for path <- ["src/main.tsx", "dist/index.html", "dist/app.js"],
        do: assert(Enum.any?(manifest.files, &(&1.path == path)))

    assert {:ok, _, artifact} = PageFiles.read(ctx.owner_actor, applet.id, "dist/app.js")
    refute artifact =~ "jsxDEV"
    Browser.counter!(ctx, owner, request["conversation_id"], applet.id)

    assert {:ok, _} = Pages.authorize(Actor.new(ctx.agent), note.id, "page_edit")
    assert {:error, :forbidden} = Pages.authorize(Actor.new(ctx.agent), note.id, "page_manage")
    assert {:ok, %{agents: initial_agents}} = Pages.space(ctx.owner_actor)
    assert %{role: "edit"} = Enum.find(initial_agents, &(&1.principal_uid == ctx.agent.uid))

    IO.puts(
      "Pod move permission observed: source=#{note.id} page_edit=true page_manage=false space_role=edit"
    )

    assert {:ok, _} = Pages.authorize(Actor.new(ctx.agent), shelf.id, "page_edit")
    assert {:error, :forbidden} = Pages.authorize(Actor.new(ctx.agent), shelf.id, "page_manage")
    assert is_nil(Repo.get!(Page, note.id).parent_id)
    assert Repo.get!(PageContent, note.id).content == original.content

    move_request =
      Browser.send_message!(ctx, owner,
        conversation_id: request["conversation_id"],
        text: """
        Move the existing "#{note_title}" document inside "#{shelf_title}" as its child.
        Preserve its existing content and identity, and keep the published Applet where it is.
        Do not make a copy. Send me a clickable link to the moved original document.
        """
      )

    move_input = Repo.get_by!(Signal, message_id: move_request["message_id"])
    moved_completion = complete_request!(ctx, move_input, require_job: false)
    moved = Repo.get!(Page, note.id)
    assert moved.parent_id == shelf.id
    assert Repo.get!(PageContent, note.id).content == original.content
    assert {:ok, _} = Pages.authorize(Actor.new(ctx.agent), note.id, "page_edit")
    assert {:error, :forbidden} = Pages.authorize(Actor.new(ctx.agent), note.id, "page_manage")
    assert {:ok, %{agents: moved_agents}} = Pages.space(ctx.owner_actor)
    assert %{role: "edit"} = Enum.find(moved_agents, &(&1.principal_uid == ctx.agent.uid))
    assert Repo.aggregate(from(p in Page, where: p.type == :doc), :count) == 2
    assert Repo.aggregate(from(p in Page, where: p.type == :applet), :count) == 1
    assert Repo.get!(Page, applet.id).parent_id == shelf.id
    refute Repo.exists?(from p in Page, where: p.type == :base)

    detail =
      await_delivery(
        ctx.owner_actor,
        request["conversation_id"],
        move_request["message_id"],
        ctx.agent.uid,
        note.id
      )

    assert delivered_after?(detail, move_request["message_id"], ctx.agent.uid, note.id)
    delivery_evidence(ctx, moved_completion, detail, true)
    Browser.moved_page!(ctx, owner, shelf, moved, marker)

    IO.puts(
      "Pod pure-SPA and Agent move verified: applet=#{applet.id} moved_original=#{note.id} parent=#{shelf.id} initial_completion=#{completion.id} source_manage=false space_role=edit"
    )
  end

  @tag :real_llm
  @tag :pod_content_real_llm
  @tag :pod_content_research
  @tag timeout: @story_timeout
  test "the installed research Skill delivers an editable Page by default from an ordinary browser Chat",
       %{tenant: tenant} do
    {ctx, owner} = Story.start!(tenant)
    title = "Text contrast brief RESEARCH#{System.unique_integer([:positive])}"
    source = "https://www.w3.org/WAI/WCAG22/Understanding/contrast-minimum.html"

    request =
      Browser.send_message!(ctx, owner,
        text: """
        Use the installed create-deep-research Skill for this narrow evidence question.
        Our product designer needs to choose a readable text color. Investigate the minimum
        contrast ratio required for ordinary-size text by WCAG 2.2 Success Criterion 1.4.3,
        using this W3C source: #{source}
        Explain the ordinary-text threshold, how large text differs, and one practical example.
        Title the brief "#{title}" and aim for about 150 words with a source citation.
        This is research into the standard, not an implementation plan. Start now without
        clarification; the question, source, and scope are already settled.
        """
      )

    input = Repo.get_by!(Signal, message_id: request["message_id"])
    completion = complete_request!(ctx, input)
    jobs = Repo.all(from j in Job, where: j.agent_uid == ^ctx.agent.uid)

    assert Enum.any?(jobs, &(&1.workspace_template_id == "deep-research")),
           "The installed Deep Research workspace did not run"

    refute request["text"] =~ ~r/\bpage\b/i
    report = Repo.get_by!(Page, title: title, type: :doc)
    assert report.created_by.uid == ctx.agent.uid
    assert report.saved_from_message_id == request["message_id"]
    assert report.revision > 0
    content = Repo.get!(PageContent, report.id)
    assert content.updated_by.uid == ctx.agent.uid

    assert_named_facts!(content.plain_text, [
      {"ordinary|normal|regular|body|small|普通|常规|正文|小号", "4\\.5\\s*(?:[:∶：]|to|比)\\s*1"},
      {"large|大号|大字体", "(?<![\\d.])3(?:\\.0)?\\s*(?:[:∶：]|to|比)\\s*1"}
    ])

    assert content.content =~ source

    assert {:ok, %{source_conversation: %{id: conversation_id, deleted: false}}} =
             Pages.get(ctx.owner_actor, report.id)

    assert conversation_id == request["conversation_id"]

    detail =
      await_delivery(
        ctx.owner_actor,
        conversation_id,
        request["message_id"],
        ctx.agent.uid,
        report.id
      )

    assert delivered_after?(detail, request["message_id"], ctx.agent.uid, report.id)
    delivery_evidence(ctx, completion, detail, true)
    human_edit = Browser.document!(ctx, owner, conversation_id, report, ["4.5"])
    edited = Repo.get!(PageContent, report.id)
    assert edited.plain_text =~ human_edit["saved_marker"]
    assert edited.updated_by.uid == owner
    assert Repo.get!(Page, report.id).revision > report.revision

    IO.puts(
      "Pod research default-Page verified: page=#{report.id} source=#{source} no_requested_output_format=true"
    )
  end

  @tag :real_llm
  @tag :pod_content_real_llm
  @tag :pod_applet_backend
  @tag timeout: @story_timeout
  test "a Human reserves real shared stock through an Agent-built backend and edits its original Applet",
       %{tenant: tenant} do
    {ctx, owner} = Story.start!(tenant)
    observer = Evidence.observe_record_writes!()
    reference = "BACKEND#{System.unique_integer([:positive])}"
    title = "Sample operations #{reference}"

    request =
      Browser.send_message!(ctx, owner,
        text: """
        Build and deliver a small shared sample-reservation workspace now.
        Save a report titled "#{title}", with a child Base containing one
        Inventory table: product name and an Available number. Add just one product,
        Cedar sample kit, with 5 available samples.

        Create a child Applet, render it inside that report, and use our Pod components
        and design tokens. Keep the interface quiet, readable, and usable on mobile.
        It shows the saved quantity in a status labelled "Available samples".
        Include a number input labeled "Quantity" and a
        "Reserve samples" button. A reservation must call the Applet's own backend
        POST route; the backend reads and updates the same Inventory record through
        AnkoleRuntime. Check a positive whole quantity on the server and never allow
        stock below zero, including simultaneous requests. Use field versions and
        re-read after conflicts. Its GET route reads the saved inventory. Use the
        SDK route hooks; after reserving, refresh the route query.

        If there is not enough stock, show a helpful inline error, retain the entered
        quantity, and leave saved stock unchanged. Show truthful saving feedback,
        prevent duplicate submission while pending, and ensure success survives reload.
        Do not reserve any stock yourself: I will reserve 2 samples after delivery.
        Build, publish, and verify with applet call using only a read route.
        Deliver the saved report as a clickable Page link. You already have edit access.
        """
      )

    input = Repo.get_by!(Signal, message_id: request["message_id"])
    completion = complete_request!(ctx, input, require_job: false)
    report = Repo.get_by!(Page, title: title, type: :doc)
    database = Repo.get_by!(Page, parent_id: report.id, type: :base)
    applet = Repo.get_by!(Page, parent_id: report.id, type: :applet)
    {:ok, %{tables: [table]}} = Bases.list_tables(ctx.owner_actor, database.id)
    fields = Bases.fields(table.id)
    stock = Enum.find(fields, &(&1.name == "Available"))
    assert stock && stock.type == :number
    assert {:ok, %{records: [record]}} = Bases.query(ctx.owner_actor, table.id, %{})
    assert record["data"][stock.id] == 5

    assert Enum.all?(Evidence.record_writes(observer, table.id, :before_human), fn write ->
             write["data"][stock.id] in [nil, 5]
           end),
           "The Agent consumed stock before the Human's first reservation"

    assert {:ok, manifest} = PageFiles.manifest(ctx.owner_actor, applet.id)
    assert Enum.any?(manifest.files, &(&1.path == "server/main.js"))
    assert {:ok, _, server} = PageFiles.read(ctx.owner_actor, applet.id, "server/main.js")
    assert server =~ "AnkoleRuntime"

    assert Regex.match?(
             ~r/<embed\b[^>]*\bref="#{applet.id}"/,
             Repo.get!(PageContent, report.id).content
           )

    for page <- [report, database, applet] do
      assert page.saved_from_message_id == request["message_id"]
      assert page.created_by.uid == ctx.agent.uid
    end

    detail =
      await_delivery(
        ctx.owner_actor,
        request["conversation_id"],
        request["message_id"],
        ctx.agent.uid,
        report.id
      )

    assert delivered_after?(detail, request["message_id"], ctx.agent.uid, report.id)
    delivery_evidence(ctx, completion, detail, true)

    Browser.inventory!(ctx, owner, request["conversation_id"], report.id, applet.id, :reserve)

    assert {:ok, %{records: [reserved]}} = Bases.query(ctx.owner_actor, table.id, %{})
    assert reserved["id"] == record["id"]
    assert reserved["data"][stock.id] == 3
    assert Repo.get_by!(BaseRecord, table_id: table.id, id: record["id"]).updated_by.uid == owner
    human_writes = Evidence.record_writes(observer, table.id, :after_human)
    human_actor = "ankole:#{Repo.tenant_id!()}:principal/#{owner}"

    assert [%{"data" => human_data}] =
             Enum.filter(
               human_writes,
               &(&1["operation"] == "UPDATE" and &1["actor"] == human_actor)
             )

    assert human_data[stock.id] == 3
    published_revision = Repo.get!(Page, applet.id).revision

    followup =
      Browser.send_message!(ctx, owner,
        page_id: report.id,
        text: """
        Update this report's existing sample-reservation Applet in place. Add a quiet
        footer saying "Shared inventory". Keep the same Applet Page, Inventory table,
        backend behavior and existing record; the saved stock is now 3. Do not reserve,
        restock, reset, duplicate or replace the business data. Publish the updated
        original Applet and give me this report's clickable link.
        """
      )

    followup_input = Repo.get_by!(Signal, message_id: followup["message_id"])
    followup_completion = complete_request!(ctx, followup_input, require_job: false)
    assert Repo.get!(Page, applet.id).revision > published_revision
    assert Repo.aggregate(from(p in Page, where: p.type == :applet), :count) == 1
    assert {:ok, %{records: [retained]}} = Bases.query(ctx.owner_actor, table.id, %{})
    assert retained["id"] == record["id"]
    assert retained["data"][stock.id] == 3

    followup_detail =
      await_delivery(
        ctx.owner_actor,
        followup["conversation_id"],
        followup["message_id"],
        ctx.agent.uid,
        report.id
      )

    assert delivered_after?(followup_detail, followup["message_id"], ctx.agent.uid, report.id)
    delivery_evidence(ctx, followup_completion, followup_detail, true)
    Browser.inventory!(ctx, owner, followup["conversation_id"], report.id, applet.id, :read)

    IO.puts(
      "Pod backend Applet story verified: applet=#{applet.id} table=#{table.id} stock=3 human_writes=1 updated_original=true"
    )
  end

  defp assert_base_reference(xml, id) do
    assert Regex.match?(~r/<embed\b[^>]*\bref="#{id}"/, xml) or
             Regex.match?(~r/<a\b[^>]*\bhref="ankole:page\/#{id}"/, xml),
           "Report lost its reference to Base #{id}"
  end
end
