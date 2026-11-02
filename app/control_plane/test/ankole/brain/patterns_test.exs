defmodule Ankole.Brain.PatternsTest do
  use Ankole.AIGatewayCase

  alias Ankole.Brain.Patterns
  alias Ankole.Brain.SchemaPacks
  alias Ankole.Brain.Schemas.Link
  alias Ankole.Brain.Schemas.Page, as: Object

  setup context do
    {:ok, _result} = SchemaPacks.install_packs([])
    state = start_supervised!({Agent, fn -> %{output: %{"patterns" => []}, requests: []} end})

    base_url =
      start_upstream_server(fn %{path: "chat/completions", body: body} ->
        output =
          Agent.get_and_update(state, fn data ->
            {data.output, %{data | requests: data.requests ++ [body]}}
          end)

        {:json, 200, chat_completion_body(body["model"], Ankole.JSON.encode!(output))}
      end)

    {:ok, _provider} =
      ProviderConfigs.create_provider(%{
        provider_id: "brain-patterns",
        provider_kind: "openrouter",
        base_url: base_url,
        credential_pool: %{"entries" => [%{"label" => "Default", "api_key" => "sk-test"}]}
      })

    configure_brain_maintainer_profile!("heavy", "brain-patterns", "fake-dreaming")
    %{principal: owner} = human_fixture()
    %{principal: outsider} = human_fixture()
    %{principal: agent} = agent_fixture(%{owner_principal_uid: owner.uid})

    scope =
      if context[:private],
        do: Ankole.Brain.Scope.principal(owner.uid),
        else: Ankole.Brain.Scope.world()

    slugs =
      for index <- 1..Map.get(context, :page_count, 4) do
        slug = "projects/evidence-#{index}"

        {:ok, object} =
          Ankole.Brain.create_object(
            %{slug: slug, type: "project", title: "Project #{index}"},
            :system
          )

        write_fact!(object.id, "Project #{index} requires renewal approval.", scope, owner.uid)
        object.id
      end

    %{state: state, slugs: slugs, scope: scope, owner: owner, outsider: outsider, agent: agent}
  end

  @tag :private
  test "updates the same topic and replaces evidence links within its audience", context do
    first = pattern(Enum.take(context.slugs, 3))
    respond(context.state, [first])
    assert %{status: :ok, pages: 1} = Patterns.run()
    assert [page] = pages()

    assert page.parent_id == context.scope
    assert evidence(page.id) == Enum.take(context.slugs, 3) |> Enum.sort()

    second = pattern(Enum.drop(context.slugs, 1), "Renewal approval now follows a shared review.")
    respond(context.state, [second])
    assert %{status: :ok, pages: 1} = Patterns.run()
    assert [updated] = pages()
    assert updated.id == page.id
    assert updated.body =~ "shared review"
    assert evidence(page.id) == Enum.sort(Enum.drop(context.slugs, 1))
    snapshots = Repo.all(from s in Ankole.Pod.PageSnapshot, where: s.page_id == ^page.id)
    assert length(snapshots) == 2
    assert Enum.all?(snapshots, &(&1.author.uid == "ankole_brain"))

    assert {:ok, _} = Ankole.Pod.Pages.get(actor_fixture(context.owner), page.id)
    assert {:error, :forbidden} = Ankole.Pod.Pages.get(actor_fixture(context.outsider), page.id)
  end

  test "no useful pattern is a successful no-op", context do
    assert %{status: :ok, pages: 0, buckets: 1} = Patterns.run()
    assert pages() == []
    assert length(requests(context.state)) == 1
  end

  @tag page_count: 2
  test "many facts on fewer than three pages do not trigger a model call", context do
    for index <- 1..4 do
      write_fact!(
        hd(context.slugs),
        "Additional independent fact #{index}.",
        Ankole.Brain.Scope.world(),
        context.agent.uid
      )
    end

    assert %{status: :ok, pages: 0, buckets: 0} = Patterns.run()
    assert requests(context.state) == []
  end

  test "rejects invalid batches without partial pages or links", context do
    valid = pattern(Enum.take(context.slugs, 3))

    for invalid <- [
          Map.put(valid, "topic", "bad/topic"),
          Map.put(valid, "evidence_page_ids", [Ecto.UUID.generate() | Enum.take(context.slugs, 2)]),
          pattern(Enum.take(context.slugs, 2))
        ] do
      respond(context.state, [valid, invalid])
      assert %{status: :failed, pages: 0, errors: [:invalid_pattern_output]} = Patterns.run()
      assert pages() == []
      assert Repo.aggregate(Link, :count) == 0
    end
  end

  test "a write conflict rolls back the whole audience batch", context do
    {:ok, note} =
      Ankole.Repo.transact_top_level(fn ->
        {:ok, node} =
          Ankole.AIAgent.Library.Knowledge.ensure_child_in_tx(
            context.scope,
            "pattern-existing-note",
            :knowledge
          )

        Ankole.AIAgent.Library.Knowledge.put_markdown_in_tx(node, "Keep this note.")
      end)

    valid = pattern(Enum.take(context.slugs, 3))
    respond(context.state, [valid, Map.put(valid, "topic", "existing-note")])
    assert %{status: :failed, pages: 0, errors: [:pattern_target_conflict]} = Patterns.run()
    assert Enum.map(pages(), & &1.id) == [note.id]
    assert Repo.aggregate(Link, :count) == 0
  end

  @tag :private
  test "same topic in different audiences has separate pages and model inputs", context do
    for {slug, index} <- Enum.with_index(context.slugs) do
      write_fact!(
        slug,
        "Public renewal policy #{index}.",
        Ankole.Brain.Scope.world(),
        context.owner.uid
      )
    end

    respond(context.state, [pattern(Enum.take(context.slugs, 3))])
    assert %{status: :ok, pages: 2, buckets: 2} = Patterns.run()
    assert length(pages()) == 2

    assert MapSet.new(pages(), & &1.parent_id) ==
             MapSet.new([Ankole.Brain.Scope.world(), context.scope])

    respond(context.state, [])
    assert %{status: :ok, pages: 0} = Patterns.run()
  end

  defp pattern(slugs, text \\ "Renewal approval recurs across projects.") do
    %{
      "topic" => "renewal-approval",
      "title" => "Renewal approval",
      "body" => text <> "\n\n" <> Enum.map_join(slugs, "\n", &"- [[#{&1}]]"),
      "evidence_page_ids" => slugs
    }
  end

  defp respond(state, patterns),
    do: Agent.update(state, &%{&1 | output: %{"patterns" => patterns}})

  defp requests(state), do: Agent.get(state, & &1.requests)

  defp pages,
    do:
      Repo.all(
        from object in Object,
          where: like(object.slug, "%pattern-%"),
          order_by: object.slug
      )

  defp evidence(slug),
    do:
      Repo.all(
        from link in Link,
          where:
            link.from_page_id == ^slug and link.link_source == "dreaming" and
              link.link_type == "derived_from",
          order_by: link.to_page_id,
          select: link.to_page_id
      )

  defp write_fact!(slug, text, scope, writer) do
    assert {:ok, _result} =
             Ankole.Brain.write_fact(
               %{
                 subject_page_id: slug,
                 claim: text,
                 kind: "fact",
                 holder: "world",
                 source_node_id: scope,
                 notability: "high",
                 confidence: 0.9,
                 valid_from: DateTime.utc_now(:microsecond),
                 provenance: "test"
               },
               writer
             )
  end
end
