defmodule Ankole.Pod.MentionsTest do
  use Ankole.DataCase, async: false

  Code.require_file(
    "../../../priv/repo/migrations/20261030050000_migrate_doc_embeds_to_mentions.exs",
    __DIR__
  )

  import Ankole.PrincipalsFixtures
  alias Ankole.Pod.{Documents, Pages}

  setup do
    owner =
      human_fixture(%{
        display_name: "Alice Owner",
        email: "alice.owner@example.com",
        job_title: "Product Lead"
      }).principal

    colleague =
      human_fixture(%{
        display_name: "Boris Builder",
        email: "boris.builder@example.com",
        job_title: "Staff Engineer"
      }).principal

    outsider =
      human_fixture(%{
        display_name: "Secret Member",
        email: "secret.member@example.com",
        job_title: "Security Lead"
      }).principal

    guest =
      human_fixture(%{
        membership: :guest,
        display_name: "Grace Guest",
        email: "grace.guest@partner.example",
        job_title: "External Reviewer"
      }).principal

    agent =
      agent_fixture(%{
        owner_principal_uid: owner.uid,
        uid: "research_bot",
        display_name: "Research Colleague",
        role: "Deep Research Specialist"
      }).principal

    %{
      owner: owner,
      colleague: colleague,
      outsider: outsider,
      guest: guest,
      agent: agent
    }
  end

  test "documents persist canonical <mention /> tags and resolve XML references without leaking restricted targets",
       ctx do
    owner_actor = actor_fixture(ctx.owner.uid)
    guest_actor = actor_fixture(ctx.guest.uid)

    {:ok, public_target} =
      Pages.create(owner_actor, %{
        title: "Q4 Architecture Roadmap",
        icon: "📐",
        xml: "<page><p>Core milestones and delivery plan.</p></page>"
      })

    {:ok, secret_target} =
      Pages.create(owner_actor, %{
        private_owner_uid: ctx.owner.uid,
        title: "Confidential M&A Plan",
        icon: "🔒",
        xml: "<page><p>Top secret valuation numbers.</p></page>"
      })

    {:ok, host_doc} = Pages.create(owner_actor, %{title: "Weekly Alignment"})

    {:ok, _} =
      Pages.update_sharing(owner_actor, public_target.id, %{
        upserts: [%{principal_uid: ctx.guest.uid, role: "view", target_scope: "self"}]
      })

    {:ok, _} =
      Pages.update_sharing(owner_actor, host_doc.id, %{
        upserts: [
          %{principal_uid: ctx.guest.uid, role: "view", target_scope: "self"},
          %{principal_uid: ctx.colleague.uid, role: "edit", target_scope: "self"}
        ]
      })

    xml =
      "<page><p>See <mention page=\"#{public_target.id}\" /> and <mention page=\"#{secret_target.id}\" /> owned by <mention principal=\"#{ctx.colleague.uid}\" /> and <mention principal=\"#{ctx.outsider.uid}\" />.</p></page>"

    assert {:ok, %{content: saved}} = Documents.write(owner_actor, host_doc.id, 0, xml)
    assert saved.content == xml

    owner_refs = Pages.resolve_xml_references(owner_actor, saved.content, host_doc.id)

    assert [
             %{id: pub_id, access: :ok, title: "Q4 Architecture Roadmap", icon: "📐"},
             %{id: sec_id, access: :ok, title: "Confidential M&A Plan", icon: "🔒"}
           ] = owner_refs.pages

    assert pub_id == public_target.id
    assert sec_id == secret_target.id

    guest_refs = Pages.resolve_xml_references(guest_actor, saved.content, host_doc.id)

    assert [
             %{
               id: ^pub_id,
               access: :ok,
               title: "Q4 Architecture Roadmap",
               excerpt: "Core milestones and delivery plan."
             },
             %{
               id: ^sec_id,
               access: :restricted,
               title: nil,
               icon: nil,
               type: nil,
               excerpt: nil,
               ancestors: nil
             }
           ] = guest_refs.pages

    # Guest sees colleague (who shares host_doc) and owner (host_doc contributor),
    # while unshared tenant member `outsider` resolves as `:restricted` with zero leakage.
    assert [
             %{principal_uid: colleague_uid, access: :ok, name: "Boris Builder"},
             %{principal_uid: outsider_uid, access: :restricted, name: nil, email: nil}
           ] = guest_refs.principals

    assert colleague_uid == ctx.colleague.uid
    assert outsider_uid == ctx.outsider.uid
  end

  test "guest candidate search isolates the tenant directory to shared collaborators", ctx do
    owner_actor = actor_fixture(ctx.owner.uid)
    guest_actor = actor_fixture(ctx.guest.uid)

    {:ok, shared_doc} = Pages.create(owner_actor, %{title: "Partner Kickoff"})
    {:ok, _unshared_doc} = Pages.create(owner_actor, %{title: "Internal Strategy"})

    {:ok, _} =
      Pages.update_sharing(owner_actor, shared_doc.id, %{
        upserts: [
          %{principal_uid: ctx.guest.uid, role: "view", target_scope: "self"},
          %{principal_uid: ctx.colleague.uid, role: "edit", target_scope: "self"}
        ]
      })

    assert {:ok, guest_candidates} =
             Pages.mention_candidates(guest_actor, %{
               query: "",
               category: :all,
               current_page_id: nil
             })

    assert Enum.map(guest_candidates.pages, & &1.id) == [shared_doc.id]

    visible_uids = MapSet.new(guest_candidates.principals, & &1.principal_uid)
    assert MapSet.member?(visible_uids, ctx.guest.uid)
    assert MapSet.member?(visible_uids, ctx.colleague.uid)
    refute MapSet.member?(visible_uids, ctx.outsider.uid)
    refute MapSet.member?(visible_uids, ctx.agent.uid)

    assert {:ok, secret_search} =
             Pages.mention_candidates(guest_actor, %{query: "Secret", category: :all})

    assert secret_search.total_all_matches == 0
    assert secret_search.pages == []
    assert secret_search.principals == []
  end

  test "all-category search caps first-screen results at 6 grouped items while category tabs return full lists",
       ctx do
    actor = actor_fixture(ctx.owner.uid)

    alpha_one =
      human_fixture(%{display_name: "Service Alpha Lead", email: "lead1@example.com"}).principal

    alpha_two =
      human_fixture(%{display_name: "Platform Alpha Eng", email: "lead2@example.com"}).principal

    alpha_three =
      human_fixture(%{display_name: "Core Alpha Staff", email: "lead3@example.com"}).principal

    alpha_four =
      human_fixture(%{display_name: "Infra Alpha Ops", email: "lead4@example.com"}).principal

    for idx <- 1..12 do
      {:ok, _} =
        Pages.create(actor, %{
          title: "Alpha Spec #{String.pad_leading(Integer.to_string(idx), 2, "0")}"
        })
    end

    assert {:ok, all_result} =
             Pages.mention_candidates(actor, %{
               query: "Alpha",
               category: :all,
               limit: 20
             })

    assert all_result.total_all_matches == 16

    assert Enum.map(all_result.ranking, & &1.kind) == [
             :page,
             :page,
             :page,
             :principal,
             :principal,
             :principal
           ]

    assert length(all_result.pages) == 3
    assert length(all_result.principals) == 3

    assert {:ok, page_tab} =
             Pages.mention_candidates(actor, %{
               query: "Alpha",
               category: :page,
               limit: 20
             })

    assert length(page_tab.pages) == 12
    assert page_tab.principals == []

    assert {:ok, principal_tab} =
             Pages.mention_candidates(actor, %{
               query: "Alpha",
               category: :principal,
               limit: 20
             })

    assert principal_tab.pages == []

    assert MapSet.new(principal_tab.principals, & &1.principal_uid) ==
             MapSet.new([alpha_one.uid, alpha_two.uid, alpha_three.uid, alpha_four.uid])
  end

  test "disabled principals are excluded from new candidates yet still resolve display_name in historical mentions",
       ctx do
    actor = actor_fixture(ctx.owner.uid)

    departed =
      human_fixture(%{
        display_name: "Departed Author",
        email: "departed@example.com"
      }).principal

    assert {:ok, _} = disable_principal_fixture(departed.uid)

    assert {:ok, candidates} =
             Pages.mention_candidates(actor, %{query: "Departed", category: :principal})

    refute Enum.any?(candidates.principals, &(&1.principal_uid == departed.uid))

    assert {:ok, resolved} =
             Pages.resolve_mentions(actor, %{principal_uids: [departed.uid]})

    assert [
             %{
               principal_uid: uid,
               access: :disabled,
               name: "Departed Author",
               kind: :human
             }
           ] = resolved.principals

    assert uid == departed.uid
  end

  test "trashed pages resolve as :trashed for authorized viewers and :restricted for unauthorized viewers, identical to missing IDs",
       ctx do
    owner_actor = actor_fixture(ctx.owner.uid)
    guest_actor = actor_fixture(ctx.guest.uid)

    {:ok, doc} = Pages.create(owner_actor, %{title: "Archived Proposal", icon: "🗂️"})
    {:ok, base_page} = Pages.create(owner_actor, %{type: :base, title: "Metrics Table"})
    {:ok, _} = Pages.delete(owner_actor, doc.id)

    missing_id = Ankole.Ecto.UUIDv7.autogenerate()

    assert {:ok, owner_resolved} =
             Pages.resolve_mentions(owner_actor, %{
               page_ids: [doc.id, base_page.id, missing_id]
             })

    assert [
             %{id: doc_id, access: :trashed, title: "Archived Proposal", icon: "🗂️"},
             %{id: base_id, access: :ok, type: :base, title: "Metrics Table"},
             %{id: ^missing_id, access: :restricted, title: nil, icon: nil, type: nil}
           ] = owner_resolved.pages

    assert doc_id == doc.id
    assert base_id == base_page.id

    assert {:ok, guest_resolved} =
             Pages.resolve_mentions(guest_actor, %{page_ids: [doc.id, missing_id]})

    [restricted_trashed, restricted_missing] = guest_resolved.pages
    assert Map.delete(restricted_trashed, :id) == Map.delete(restricted_missing, :id)
    assert restricted_trashed.access == :restricted
    assert restricted_trashed.title == nil
  end

  test "migrate_doc_embeds_xml rewrites only doc embeds to inline mention paragraphs while preserving comments, base embeds, and diff replay" do
    doc_id = Ankole.Ecto.UUIDv7.autogenerate()
    base_id = Ankole.Ecto.UUIDv7.autogenerate()
    comment_id = Ankole.Ecto.UUIDv7.autogenerate()

    source =
      ~s(<page><p>Intro <comment ids="#{comment_id}">annotated</comment></p><embed ref="#{doc_id}" /><embed ref="#{base_id}" view="{&quot;type&quot;:&quot;grid&quot;}" /><embed href="https://example.com/frame" title="Board" /><p>Outro</p></page>)

    other_doc_id = Ankole.Ecto.UUIDv7.autogenerate()

    assert {:ok, :unchanged} =
             Ankole.Repo.Migrations.MigrateDocEmbedsToMentions.migrate_doc_embeds_xml(
               source,
               MapSet.new([other_doc_id])
             )

    assert {:ok, migrated} =
             Ankole.Repo.Migrations.MigrateDocEmbedsToMentions.migrate_doc_embeds_xml(
               source,
               MapSet.new([doc_id])
             )

    assert migrated.xml =~ ~s(<p><mention page="#{doc_id}" /></p>)
    refute migrated.xml =~ ~s(<embed ref="#{doc_id}")
    assert migrated.xml =~ ~s(<embed ref="#{base_id}")
    assert migrated.xml =~ ~s(<embed href="https://example.com/frame" title="Board" />)
    assert migrated.xml =~ ~s(<comment ids="#{comment_id}">annotated</comment>)

    assert {:ok, changes} = Ankole.Kernel.page_diff(source, migrated.xml)
    assert changes != []
    assert {:ok, applied} = Ankole.Kernel.page_apply(source, changes)
    assert applied.xml == migrated.xml

    # Literal <embed /> examples inside CDATA code, math, and mermaid blocks stay untouched, while malformed XML returns {:error, _} instead of raising.
    cdata_source =
      ~s(<page><pre lang="xml"><![CDATA[<embed ref="#{doc_id}" />]]></pre><mermaid><![CDATA[graph TD;\nA["<embed ref='#{doc_id}' />"]]]></mermaid><embed ref="#{doc_id}" /></page>)

    assert {:ok, cdata_migrated} =
             Ankole.Repo.Migrations.MigrateDocEmbedsToMentions.migrate_doc_embeds_xml(
               cdata_source,
               MapSet.new([doc_id])
             )

    assert cdata_migrated.xml =~ ~s(<pre lang="xml">&lt;embed ref="#{doc_id}" /&gt;</pre>)
    refute cdata_migrated.xml =~ ~s(<embed ref="#{doc_id}")
    assert cdata_migrated.xml =~ ~s(<p><mention page="#{doc_id}" /></p>)

    only_cdata =
      ~s(<page><pre lang="xml"><![CDATA[<embed ref="#{doc_id}" />]]></pre></page>)

    assert {:ok, :unchanged} =
             Ankole.Repo.Migrations.MigrateDocEmbedsToMentions.migrate_doc_embeds_xml(
               only_cdata,
               MapSet.new([doc_id])
             )

    malformed = ~s(<page><p>Unclosed<embed ref="#{doc_id}" /></page>)

    assert {:error, _} =
             Ankole.Repo.Migrations.MigrateDocEmbedsToMentions.migrate_doc_embeds_xml(
               malformed,
               MapSet.new([doc_id])
             )
  end

  test "guests discover collaborators who share a child page via inherited ancestor container grants while PII stays redacted",
       ctx do
    owner_actor = actor_fixture(ctx.owner.uid)
    guest_actor = actor_fixture(ctx.guest.uid)

    {:ok, parent} = Pages.create(owner_actor, %{title: "Restricted Parent Folder"})

    {:ok, _} =
      Pages.set_sharing(owner_actor, parent.id, %{
        sharing_version: (Pages.sharing(owner_actor, parent.id) |> elem(1)).sharing_version,
        inherit_permissions: false,
        grants: [
          %{principal_uid: ctx.owner.uid, role: "manage", target_scope: "container"},
          %{principal_uid: ctx.colleague.uid, role: "edit", target_scope: "container"}
        ]
      })

    {:ok, child} =
      Pages.create(owner_actor, %{
        parent_id: parent.id,
        title: "Shared Subpage"
      })

    {:ok, _} =
      Pages.update_sharing(owner_actor, child.id, %{
        upserts: [%{principal_uid: ctx.guest.uid, role: "view", target_scope: "self"}]
      })

    assert {:error, :forbidden} = Pages.authorize(guest_actor, parent.id, "node_view")
    assert {:ok, _} = Pages.authorize(guest_actor, child.id, "node_view")

    assert {:ok, guest_subjects} = Pages.subjects(guest_actor)
    subject_uids = MapSet.new(guest_subjects, & &1.principal_uid)
    assert MapSet.member?(subject_uids, ctx.colleague.uid)
    refute MapSet.member?(subject_uids, ctx.outsider.uid)
    assert Enum.all?(guest_subjects, &is_nil(&1.subtitle))

    assert {:ok, candidates} =
             Pages.mention_candidates(guest_actor, %{query: "Boris", category: :principal})

    assert [%{principal_uid: colleague_uid, email: nil, job_title: nil}] = candidates.principals
    assert colleague_uid == ctx.colleague.uid

    assert {:ok, member_search} =
             Pages.mention_candidates(owner_actor, %{query: "@research_bot", category: :principal})

    assert [%{principal_uid: agent_uid}] = member_search.principals
    assert agent_uid == ctx.agent.uid

    assert {:ok, wildcard_search} =
             Pages.mention_candidates(owner_actor, %{query: "100%", category: :principal})

    assert wildcard_search.principals == []
  end

  test "batched trashed page mention resolution distinguishes multiple trashed targets and hides children of trashed ancestors",
       ctx do
    owner_actor = actor_fixture(ctx.owner.uid)
    guest_actor = actor_fixture(ctx.guest.uid)

    {:ok, shared_trashed_one} = Pages.create(owner_actor, %{title: "Shared Trashed One"})
    {:ok, shared_trashed_two} = Pages.create(owner_actor, %{title: "Shared Trashed Two"})
    {:ok, unshared_trashed} = Pages.create(owner_actor, %{title: "Unshared Trashed"})
    {:ok, trashed_folder} = Pages.create(owner_actor, %{title: "Trashed Folder"})

    {:ok, nested_child} =
      Pages.create(owner_actor, %{parent_id: trashed_folder.id, title: "Nested Under Trashed"})

    for id <- [shared_trashed_one.id, shared_trashed_two.id, trashed_folder.id] do
      {:ok, _} =
        Pages.update_sharing(owner_actor, id, %{
          upserts: [%{principal_uid: ctx.guest.uid, role: "view", target_scope: "container"}]
        })
    end

    {:ok, _} = Pages.delete(owner_actor, shared_trashed_one.id)
    {:ok, _} = Pages.delete(owner_actor, shared_trashed_two.id)
    {:ok, _} = Pages.delete(owner_actor, unshared_trashed.id)
    {:ok, _} = Pages.delete(owner_actor, trashed_folder.id)

    assert {:ok, resolved} =
             Pages.resolve_mentions(guest_actor, %{
               page_ids: [
                 shared_trashed_one.id,
                 shared_trashed_two.id,
                 unshared_trashed.id,
                 nested_child.id
               ]
             })

    assert [
             %{id: id_one, access: :trashed, title: "Shared Trashed One"},
             %{id: id_two, access: :trashed, title: "Shared Trashed Two"},
             %{id: id_three, access: :restricted, title: nil},
             %{id: id_four, access: :restricted, title: nil}
           ] = resolved.pages

    assert id_one == shared_trashed_one.id
    assert id_two == shared_trashed_two.id
    assert id_three == unshared_trashed.id
    assert id_four == nested_child.id
  end
end
