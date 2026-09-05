defmodule Ankole.Brain.PatternsTest do
  use Ankole.AIGatewayCase

  alias Ankole.AppConfigure
  alias Ankole.Brain.{Claims, Markdoc, Objects, Patterns, Recall, SchemaPacks}
  alias Ankole.Brain.Schemas.{Link, Object, ObjectVersion}

  setup context do
    allow_cache_database_access()
    AppConfigure.Cache.clear_for_test()
    on_exit(fn -> AppConfigure.Cache.clear_for_test() end)
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
    scope = if context[:private], do: "principal:" <> owner.uid, else: "world"

    slugs =
      for index <- 1..Map.get(context, :page_count, 4) do
        slug = "projects/pattern-#{index}"

        {:ok, _object} =
          Objects.create_object(
            %{slug: slug, type: "project", title: "Project #{index}"},
            :system
          )

        write_fact!(slug, "Project #{index} requires renewal approval.", scope, agent.uid)
        slug
      end

    %{state: state, slugs: slugs, scope: scope, owner: owner, outsider: outsider, agent: agent}
  end

  @tag :private
  test "updates the same topic and replaces evidence links within its audience", context do
    first = pattern(Enum.take(context.slugs, 3))
    respond(context.state, [first])
    assert %{status: :ok, pages: 1} = Patterns.run()
    assert [page] = pages()

    assert page.slug ==
             "analysis/patterns/" <>
               Ankole.Kernel.xxh3_128_hex(context.scope) <> "/renewal-approval"

    assert {:ok, [scope]} = Markdoc.scopes(page.body)
    assert scope == context.scope
    assert evidence(page.slug) == Enum.take(context.slugs, 3)

    second = pattern(Enum.drop(context.slugs, 1), "Renewal approval now follows a shared review.")
    respond(context.state, [second])
    assert %{status: :ok, pages: 1} = Patterns.run()
    assert [updated] = pages()
    assert updated.id == page.id
    assert updated.body =~ "shared review"
    assert evidence(page.slug) == Enum.drop(context.slugs, 1)
    assert Repo.aggregate(ObjectVersion, :count) == 1
    assert List.last(requests(context.state))["messages"] |> inspect() =~ page.slug

    assert {:ok, visible} = Recall.recall(context.owner.uid, %{query: "renewal approval"})
    assert Enum.any?(visible.chunks, &(&1.object_slug == page.slug))
    assert {:ok, hidden} = Recall.recall(context.outsider.uid, %{query: "renewal approval"})
    refute Enum.any?(hidden.chunks, &(&1.object_slug == page.slug))
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
        "world",
        context.agent.uid
      )
    end

    assert %{status: :ok, pages: 0, buckets: 0} = Patterns.run()
    assert requests(context.state) == []
  end

  test "rejects invalid batches without partial pages or links", context do
    valid = pattern(Enum.take(context.slugs, 3))

    for invalid <- [
          Map.put(valid, "topic_slug", "daily-2026-09-05"),
          Map.put(valid, "evidence_slugs", ["projects/missing" | Enum.take(context.slugs, 2)]),
          pattern(Enum.take(context.slugs, 2)),
          Map.put(valid, "body", "Unsupported synthesis without evidence links.")
        ] do
      respond(context.state, [valid, invalid])
      assert %{status: :failed, pages: 0, errors: [:invalid_pattern_output]} = Patterns.run()
      assert pages() == []
      assert Repo.aggregate(Link, :count) == 0
    end
  end

  @tag :private
  test "rejects audience escapes", context do
    valid = pattern(Enum.take(context.slugs, 3))
    invalid = Map.update!(valid, "body", &("{% /audience %}\n" <> &1))
    respond(context.state, [invalid])
    assert %{status: :failed, pages: 0} = Patterns.run()
    assert pages() == []
  end

  test "a write conflict rolls back the whole audience batch", context do
    conflict_slug =
      "analysis/patterns/" <> Ankole.Kernel.xxh3_128_hex(context.scope) <> "/existing-note"

    {:ok, note} =
      Objects.create_object(
        %{slug: conflict_slug, type: "note", title: "Existing note", body: "Keep this note."},
        :system
      )

    valid = pattern(Enum.take(context.slugs, 3))
    respond(context.state, [valid, Map.put(valid, "topic_slug", "existing-note")])
    assert %{status: :failed, pages: 0, errors: [:pattern_target_conflict]} = Patterns.run()
    assert [^note] = pages()
    assert Repo.aggregate(Link, :count) == 0
    assert Repo.aggregate(ObjectVersion, :count) == 0
  end

  @tag :private
  test "same topic in different audiences has separate pages and model inputs", context do
    for {slug, index} <- Enum.with_index(context.slugs) do
      write_fact!(slug, "Public renewal policy #{index}.", "world", context.agent.uid)
    end

    respond(context.state, [pattern(Enum.take(context.slugs, 3))])
    assert %{status: :ok, pages: 2, buckets: 2} = Patterns.run()
    assert length(pages()) == 2

    assert MapSet.new(pages(), &Markdoc.scopes(&1.body)) ==
             MapSet.new([{:ok, ["world"]}, {:ok, [context.scope]}])

    respond(context.state, [])
    assert %{status: :ok, pages: 0} = Patterns.run()

    for request <- Enum.take(requests(context.state), -2) do
      prompt = inspect(request["messages"])
      assert Enum.count(pages(), &String.contains?(prompt, &1.slug)) == 1
    end
  end

  defp pattern(slugs, text \\ "Renewal approval recurs across projects.") do
    %{
      "topic_slug" => "renewal-approval",
      "title" => "Renewal approval",
      "body" => text <> "\n\n" <> Enum.map_join(slugs, "\n", &"- [[#{&1}]]"),
      "evidence_slugs" => slugs
    }
  end

  defp respond(state, patterns),
    do: Agent.update(state, &%{&1 | output: %{"patterns" => patterns}})

  defp requests(state), do: Agent.get(state, & &1.requests)

  defp pages,
    do:
      Repo.all(
        from object in Object,
          where: like(object.slug, "analysis/patterns/%"),
          order_by: object.slug
      )

  defp evidence(slug),
    do:
      Repo.all(
        from link in Link,
          where:
            link.from_object_slug == ^slug and link.link_source == "dreaming" and
              link.link_type == "derived_from",
          order_by: link.to_object_slug,
          select: link.to_object_slug
      )

  defp write_fact!(slug, text, scope, writer) do
    assert {:ok, _result} =
             Claims.write_fact(
               %{
                 object_slug: slug,
                 claim: text,
                 kind: "fact",
                 holder: "world",
                 audience_scope: scope,
                 notability: "high",
                 confidence: 0.9,
                 valid_from: DateTime.utc_now(:microsecond),
                 provenance: "test"
               },
               writer
             )
  end
end
