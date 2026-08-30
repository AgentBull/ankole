defmodule Ankole.Brain.GetPageTest do
  use Ankole.DataCase, async: true

  import Ankole.PrincipalsFixtures

  alias Ankole.AuthZ
  alias Ankole.Brain.GetPage
  alias Ankole.Brain.Links
  alias Ankole.Brain.Objects
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
      Objects.create_object(
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

  test "resolution ladder covers alias, natural name, and fuzzy title", context do
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

    assert {:ok, by_title} = GetPage.get_page(context.member.uid, "Minghu")
    assert by_title.slug == "companies/minghu-ai"

    assert {:error, :not_found} =
             GetPage.get_page(context.member.uid, "totally unrelated xyz")
  end

  test "ambiguous natural names return candidates without guessing", context do
    {:ok, _other} =
      Objects.create_object(
        %{slug: "people/minghu-founder", type: "person", title: "Minghu Founder"},
        context.member.uid
      )

    {:ok, _alias} = Links.add_alias("people/minghu-founder", "明湖 AI")

    assert {:ambiguous, candidates} = GetPage.get_page(context.member.uid, "明湖 AI")
    slugs = Enum.map(candidates, & &1.slug)
    assert "companies/minghu-ai" in slugs
    assert "people/minghu-founder" in slugs

    assert {:ok, _deleted} = Objects.soft_delete("people/minghu-founder")
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

  defp write_group_fact(member, scope, text) do
    Ankole.Brain.Claims.write_fact(
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
      Objects.create_object(
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
end
