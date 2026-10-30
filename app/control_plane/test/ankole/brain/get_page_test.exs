defmodule Ankole.Brain.GetPageTest do
  use Ankole.DataCase, async: true

  import Ankole.PrincipalsFixtures

  alias Ankole.AuthZ
  alias Ankole.Brain.GetPage
  alias Ankole.Brain.Links
  alias Ankole.Brain.SchemaPacks

  setup do
    {:ok, _result} = SchemaPacks.install_packs([])
    %{principal: member} = human_fixture()
    %{principal: outsider} = human_fixture()

    {:ok, group} =
      AuthZ.create_principal_group(%{
        name: "page-team-#{System.unique_integer([:positive])}",
        display_name: "Page Team",
        domain: :operator,
        kind: :static
      })

    {:ok, _membership} = AuthZ.add_principal_to_group(member.uid, group.id)

    body = """
    Public introduction.

    {% audience scope="group:#{group.name}" %}
    Internal deal progress.
    {% /audience %}

    Public closing line.
    """

    {:ok, object} =
      Ankole.Brain.create_object(
        %{slug: "companies/minghu-ai", type: "company", title: "Minghu AI", body: body},
        member.uid
      )

    {:ok, _alias} = Links.add_alias("companies/minghu-ai", "明湖 AI")

    %{member: member, outsider: outsider, group: group, object: object}
  end

  test "different queriers receive different projections in original order", context do
    assert {:ok, member_page} = GetPage.get_page(context.member.uid, "companies/minghu-ai")
    assert String.contains?(member_page.rendered, "Public introduction.")
    assert String.contains?(member_page.rendered, "Internal deal progress.")
    assert String.contains?(member_page.rendered, "Public closing line.")

    intro = :binary.match(member_page.rendered, "Public introduction.") |> elem(0)
    internal = :binary.match(member_page.rendered, "Internal deal progress.") |> elem(0)
    closing = :binary.match(member_page.rendered, "Public closing line.") |> elem(0)
    assert intro < internal and internal < closing

    assert {:ok, outsider_page} = GetPage.get_page(context.outsider.uid, "companies/minghu-ai")
    assert String.contains?(outsider_page.rendered, "Public introduction.")
    refute String.contains?(outsider_page.rendered, "Internal deal progress.")
    assert String.contains?(outsider_page.rendered, "Public closing line.")

    # Page metadata stays visible to both.
    assert outsider_page.title == "Minghu AI"
    assert outsider_page.type == "company"
  end

  test "model and admin pages expose persisted tags while retaining page fields", context do
    assert {:ok, _} =
             Ankole.Repo.insert(%Ankole.Brain.Schemas.Tag{
               id: Ankole.Ecto.UUIDv7.autogenerate(),
               object_slug: context.object.slug,
               tag: "health",
               created_at: DateTime.utc_now(:microsecond)
             })

    assert {:ok, model} = GetPage.get_page(context.member.uid, context.object.slug)
    assert {:ok, admin} = GetPage.get_page_admin(context.object.slug)

    for page <- [model, admin] do
      assert page.tags == ["health"]

      for key <- [
            :slug,
            :type,
            :subtype,
            :title,
            :content_hash,
            :rendered,
            :facts,
            :takes,
            :timelines,
            :links
          ] do
        assert Map.has_key?(page, key)
      end
    end

    assert admin.body == context.object.body
    assert Map.has_key?(admin, :editable)
    refute Map.has_key?(model, :body)
  end

  test "ordinary text survives the page and context pack projections", context do
    text = "Dan prefers email; show hidden files."
    {:ok, %{claim: claim}} = write_group_fact(context.member, "world", text)

    assert {:ok, page} = GetPage.get_page(context.member.uid, context.object.slug)
    assert Enum.find(page.facts, &(&1.id == claim.id)).claim == text

    pack =
      Ankole.Brain.ContextPack.context_pack(context.member.uid, %{
        recent_text: "明湖 AI"
      })

    assert Enum.any?(pack.entities, fn entity ->
             Enum.any?(entity.facts, &(&1.claim == text))
           end)
  end

  test "resolution ladder covers alias, natural name, and exact title", context do
    Repo.insert!(%Ankole.Brain.Schemas.SlugAlias{
      id: Ankole.Ecto.UUIDv7.autogenerate(),
      alias_slug: "companies/minghu",
      canonical_slug: "companies/minghu-ai",
      created_at: DateTime.utc_now(:microsecond)
    })

    assert {:ok, by_alias} = GetPage.get_page(context.member.uid, "companies/minghu")
    assert by_alias.slug == "companies/minghu-ai"

    assert {:ok, by_name} = GetPage.get_page(context.member.uid, "明湖 AI")
    assert by_name.slug == "companies/minghu-ai"

    assert {:ok, by_title} = GetPage.get_page(context.member.uid, "Minghu AI")
    assert by_title.slug == "companies/minghu-ai"
    assert {:error, :not_found} = GetPage.get_page(context.member.uid, "Minghu")

    assert {:error, :not_found} =
             GetPage.get_page(context.member.uid, "totally unrelated xyz")
  end

  test "ambiguous natural names return candidates without guessing", context do
    {:ok, _other} =
      Ankole.Brain.create_object(
        %{slug: "people/minghu-founder", type: "person", title: "Minghu Founder"},
        context.member.uid
      )

    {:ok, _alias} = Links.add_alias("people/minghu-founder", "明湖 AI")

    assert {:ambiguous, candidates} = GetPage.get_page(context.member.uid, "明湖 AI")
    slugs = Enum.map(candidates, & &1.slug)
    assert "companies/minghu-ai" in slugs
    assert "people/minghu-founder" in slugs

    assert {:ok, _deleted} = Ankole.Brain.soft_delete_object("people/minghu-founder")
    assert {:ok, live} = GetPage.get_page(context.member.uid, "明湖 AI")
    assert live.slug == "companies/minghu-ai"
  end

  test "the admin page shows contradictions across every scope", context do
    scoped = "group:#{context.group.name}"

    {:ok, %{claim: a}} = write_group_fact(context.member, scoped, "Deal size is 10M")
    {:ok, %{claim: b}} = write_group_fact(context.member, scoped, "Deal size is 25M")

    assert :ok =
             Ankole.Brain.Dreaming.record_contradiction_verdict(
               a.id,
               b.id,
               "contradiction",
               0.9,
               %{
                 "axis" => "deal size",
                 "severity" => "high"
               }
             )

    assert {:ok, page} = GetPage.get_page_admin("companies/minghu-ai")
    assert [contradiction] = page.contradictions
    assert contradiction.verdict == "contradiction"
    assert contradiction.counterpart.id in [a.id, b.id]

    # The admin page also carries the group-scoped claims themselves.
    assert Enum.count(page.facts) == 2
  end

  test "contradiction reads have constant query cost and retain the newest twenty findings",
       context do
    {:ok, %{claim: own}} = write_group_fact(context.member, "world", "Baseline estimate")
    first = add_contradiction(context.member, own, "Estimate 0")
    assert {:ok, _} = GetPage.get_page_admin(context.object.slug)
    {small, small_queries} = page_with_query_count(context.object.slug)
    assert [finding] = small.contradictions
    assert finding.counterpart.id == first.id

    others =
      Enum.map(1..24, fn index ->
        add_contradiction(context.member, own, "Estimate #{index}")
      end)

    {large, large_queries} = page_with_query_count(context.object.slug)
    assert small_queries > 0
    assert large_queries == small_queries

    expected = others |> Enum.reverse() |> Enum.take(20) |> Enum.map(& &1.id)
    assert Enum.map(large.contradictions, & &1.counterpart.id) == expected
  end

  test "a batched contradiction counterpart still requires reader and disclosure access",
       context do
    {:ok, %{claim: own}} = write_group_fact(context.member, "world", "Public estimate")

    hidden =
      add_contradiction(context.member, own, "Private estimate", "group:#{context.group.name}")

    assert {:ok, member_page} = GetPage.get_page(context.member.uid, context.object.slug)
    assert [finding] = member_page.contradictions
    assert finding.counterpart.id == hidden.id

    assert {:ok, outsider_page} = GetPage.get_page(context.outsider.uid, context.object.slug)
    assert outsider_page.contradictions == []

    disclosure = %{
      mode: :strict,
      asker_uid: context.member.uid,
      present_uids: [context.member.uid, context.outsider.uid]
    }

    assert {:ok, shared_page} =
             GetPage.get_page(context.member.uid, context.object.slug, disclosure: disclosure)

    assert shared_page.contradictions == []
  end

  defp add_contradiction(member, own, text, scope \\ "world") do
    {:ok, %{claim: other}} = write_group_fact(member, scope, text)

    assert :ok =
             Ankole.Brain.Dreaming.record_contradiction_verdict(
               own.id,
               other.id,
               "contradiction",
               0.9,
               %{"axis" => "estimate", "severity" => "high"}
             )

    other
  end

  defp page_with_query_count(slug) do
    handler = {__MODULE__, self(), make_ref()}

    :ok =
      :telemetry.attach(
        handler,
        [:ankole, :repo, :query],
        fn _event, _measurements, _metadata, owner ->
          if self() == owner, do: send(owner, :page_query)
        end,
        self()
      )

    try do
      assert {:ok, page} = GetPage.get_page_admin(slug)
      {page, drain_query_count(0)}
    after
      :telemetry.detach(handler)
    end
  end

  defp drain_query_count(count) do
    receive do
      :page_query -> drain_query_count(count + 1)
    after
      0 -> count
    end
  end

  defp write_group_fact(member, scope, text) do
    Ankole.Brain.write_fact(
      %{
        object_slug: "companies/minghu-ai",
        claim: text,
        kind: "fact",
        holder: "world",
        audience_scope: scope,
        notability: "medium",
        confidence: 0.75,
        valid_from: DateTime.utc_now(:microsecond),
        provenance: "test"
      },
      member.uid
    )
  end

  test "strict disclosure prunes what present members cannot receive", context do
    strict = %{
      mode: :strict,
      asker_uid: context.member.uid,
      present_uids: [context.member.uid, context.outsider.uid]
    }

    assert {:ok, page} =
             GetPage.get_page(context.member.uid, "companies/minghu-ai", disclosure: strict)

    refute String.contains?(page.rendered, "Internal deal progress.")
    assert String.contains?(page.rendered, "Public introduction.")
  end

  test "an Agent reads body scopes carried by the current conversation readers", context do
    %{principal: agent} = agent_fixture(%{owner_principal_uid: context.member.uid})
    member_scope = "principal:#{context.member.uid}"

    {:ok, private_page} =
      Ankole.Brain.create_object(
        %{
          slug: "analysis/conversation-reader",
          type: "analysis",
          title: "Conversation Reader",
          body: """
          {% audience scope="#{member_scope}" %}
          Kestrel private synthesis body.
          {% /audience %}
          """
        },
        agent.uid
      )

    member_disclosure = %{
      mode: :strict,
      asker_uid: context.member.uid,
      present_uids: [context.member.uid]
    }

    assert {:ok, member_page} =
             GetPage.get_page(agent.uid, private_page.slug, disclosure: member_disclosure)

    assert member_page.rendered =~ "Kestrel private synthesis body."

    outsider_disclosure = %{
      mode: :strict,
      asker_uid: context.outsider.uid,
      present_uids: [context.outsider.uid]
    }

    assert {:ok, outsider_page} =
             GetPage.get_page(agent.uid, private_page.slug, disclosure: outsider_disclosure)

    refute outsider_page.rendered =~ "Kestrel private synthesis body."
  end

  test "get_page returns revision, fact context, and caller-pruned Markdoc content when requested",
       context do
    {:ok, %{claim: contextual_fact}} =
      Ankole.Brain.write_fact(
        %{
          object_slug: context.object.slug,
          claim: "Minghu AI signed a pilot contract",
          context: "Pilot covers three warehouses in Suzhou",
          kind: "fact",
          holder: "world",
          audience_scope: "world",
          notability: "medium",
          confidence: 0.85,
          valid_from: DateTime.utc_now(:microsecond),
          provenance: "test"
        },
        context.member.uid
      )

    assert {:ok, default_page} = GetPage.get_page(context.member.uid, context.object.slug)
    assert default_page.revision == context.object.content_hash
    refute Map.has_key?(default_page, :content)
    refute Map.has_key?(default_page, :body)

    assert Enum.find(default_page.facts, &(&1.id == contextual_fact.id)).context ==
             "Pilot covers three warehouses in Suzhou"

    assert {:ok, member_with_content} =
             GetPage.get_page(context.member.uid, context.object.slug, include_content: true)

    assert member_with_content.content =~ "Public introduction."
    assert member_with_content.content =~ ~s({% audience scope="group:#{context.group.name}" %})
    assert member_with_content.content =~ "Internal deal progress."
    refute Map.has_key?(member_with_content, :body)

    assert {:ok, outsider_with_content} =
             GetPage.get_page(context.outsider.uid, context.object.slug, include_content: true)

    assert outsider_with_content.content =~ "Public introduction."
    refute outsider_with_content.content =~ "Internal deal progress."
    refute outsider_with_content.content =~ "{% audience"
  end
end
