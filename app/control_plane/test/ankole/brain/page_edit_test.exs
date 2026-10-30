defmodule Ankole.Brain.PageEditTest do
  use Ankole.DataCase, async: true

  import Ankole.PrincipalsFixtures

  alias Ankole.ActorRef
  alias Ankole.AuthZ
  alias Ankole.Brain.Recall
  alias Ankole.Brain.SchemaPacks
  alias Ankole.Brain.Schemas.Link
  alias Ankole.Brain.Schemas.Object
  alias Ankole.Brain.Schemas.ObjectVersion
  alias Ankole.Brain.Schemas.Source
  alias Ankole.Brain.Tools
  alias Ankole.Brain.Tools.Context
  alias Ankole.Repo

  setup do
    {:ok, _result} = SchemaPacks.install_packs([])

    %{principal: owner} = human_fixture()
    %{principal: alice} = human_fixture()
    %{principal: bob} = human_fixture()
    %{principal: agent} = agent_fixture(%{owner_principal_uid: owner.uid})

    {:ok, alpha_group} =
      AuthZ.create_principal_group(%{
        name: "alpha-curation-#{System.unique_integer([:positive])}",
        display_name: "Alpha Curation",
        domain: :operator,
        kind: :static
      })

    {:ok, beta_group} =
      AuthZ.create_principal_group(%{
        name: "beta-curation-#{System.unique_integer([:positive])}",
        display_name: "Beta Curation",
        domain: :operator,
        kind: :static
      })

    {:ok, _} = AuthZ.add_principal_to_group(alice.uid, alpha_group.id)
    {:ok, _} = AuthZ.add_principal_to_group(agent.uid, alpha_group.id)
    {:ok, _} = AuthZ.add_principal_to_group(bob.uid, beta_group.id)

    alice_dm_context = %Context{
      querier_uid: agent.uid,
      disclosure: %{mode: :strict, asker_uid: alice.uid, present_uids: [alice.uid]},
      default_write_scope: {:ok, "principal:" <> alice.uid},
      participant_uids: [alice.uid]
    }

    bob_dm_context = %Context{
      querier_uid: agent.uid,
      disclosure: %{mode: :strict, asker_uid: bob.uid, present_uids: [bob.uid]},
      default_write_scope: {:ok, "principal:" <> bob.uid},
      participant_uids: [bob.uid]
    }

    %{
      owner: owner,
      alice: alice,
      bob: bob,
      agent: agent,
      alpha_group: alpha_group,
      beta_group: beta_group,
      alice_context: alice_dm_context,
      bob_context: bob_dm_context
    }
  end

  describe "put_page creation and CAS replacement" do
    test "creates a scoped page by default, wires aliases, tags, and wikilinks, and supports world pages",
         context do
      {:ok, partner} =
        Ankole.Brain.create_object(
          %{slug: "companies/harbor-logistics", type: "company", title: "Harbor Logistics"},
          context.agent.uid
        )

      assert {:ok, created} =
               Tools.execute(
                 "put_page",
                 %{
                   "slug" => "projects/cold-chain-pilot",
                   "title" => "Cold Chain Pilot",
                   "type" => "project",
                   "content" => "Pilot rollout with [[#{partner.slug}]].",
                   "aliases" => ["CC Pilot"],
                   "tags" => ["logistics", "q4"]
                 },
                 context.alice_context
               )

      assert created["status"] == "created"
      assert created["slug"] == "projects/cold-chain-pilot"
      assert is_binary(created["revision"])

      stored = Repo.get_by!(Object, slug: "projects/cold-chain-pilot")
      assert stored.body =~ ~s({% audience scope="principal:#{context.alice.uid}" %})
      assert stored.body =~ "Pilot rollout with [[#{partner.slug}]]."

      # Alice reaches the new page via recall; Bob does not.
      assert {:ok, alice_recall} = Recall.recall(context.alice.uid, %{query: "Pilot rollout"})
      assert Enum.any?(alice_recall.chunks, &(&1.object_slug == "projects/cold-chain-pilot"))

      assert {:ok, bob_recall} = Recall.recall(context.bob.uid, %{query: "Pilot rollout"})
      refute Enum.any?(bob_recall.chunks, &(&1.object_slug == "projects/cold-chain-pilot"))

      # Outgoing wikilink, alias, and tags are persisted.
      assert Link
             |> where(
               [l],
               l.from_object_slug == "projects/cold-chain-pilot" and
                 l.to_object_slug == ^partner.slug
             )
             |> Repo.exists?()

      assert {:ok, %{"entity" => %{"slug" => "projects/cold-chain-pilot"}}} =
               Tools.execute("entity", %{"name" => "CC Pilot"}, context.alice_context)

      assert {:ok, %{"page" => page}} =
               Tools.execute(
                 "get_page",
                 %{"reference" => "projects/cold-chain-pilot", "include_content" => true},
                 context.alice_context
               )

      assert Enum.sort(page["tags"]) == ["logistics", "q4"]
      assert page["revision"] == created["revision"]
      assert page["content"] =~ "Pilot rollout"

      # Creating again without expected_revision refuses cleanly.
      assert {:error, {:slug_taken, "projects/cold-chain-pilot"}} =
               Tools.execute(
                 "put_page",
                 %{
                   "slug" => "projects/cold-chain-pilot",
                   "title" => "Duplicate",
                   "type" => "project",
                   "content" => "Overwrite attempt"
                 },
                 context.alice_context
               )

      # Explicit world scope leaves untagged prose unwrapped.
      assert {:ok, world_created} =
               Tools.execute(
                 "put_page",
                 %{
                   "slug" => "concepts/open-glossary",
                   "title" => "Open Glossary",
                   "type" => "concept",
                   "scope" => "world",
                   "content" => "Shared glossary definition."
                 },
                 context.alice_context
               )

      assert world_created["status"] == "created"

      assert Repo.get_by!(Object, slug: "concepts/open-glossary").body ==
               "Shared glossary definition."
    end

    test "replaces an existing page under expected_revision, preserves calibration fences, and guards hidden segments",
         context do
      body_with_calibration = """
      Initial public overview.

      <!-- brain:calibration:start -->
      Graded score: 0.91
      <!-- brain:calibration:end -->
      """

      {:ok, page} =
        Ankole.Brain.create_object(
          %{
            slug: "companies/solstice-energy",
            type: "company",
            title: "Solstice Energy",
            body: body_with_calibration
          },
          context.agent.uid
        )

      # Stale expected_revision fails with current_revision.
      assert {:error, {:revision_conflict, %{current_revision: current_rev}}} =
               Tools.execute(
                 "put_page",
                 %{
                   "slug" => page.slug,
                   "content" => "Updated overview.",
                   "scope" => "world",
                   "expected_revision" => "stale-hash"
                 },
                 context.alice_context
               )

      assert current_rev == page.content_hash

      # Empty content without allow_empty fails.
      assert {:error, :empty_content_not_allowed} =
               Tools.execute(
                 "put_page",
                 %{
                   "slug" => page.slug,
                   "content" => "   ",
                   "scope" => "world",
                   "expected_revision" => page.content_hash
                 },
                 context.alice_context
               )

      # Valid CAS replacement snapshots ObjectVersion and preserves calibration fence.
      assert {:ok, updated} =
               Tools.execute(
                 "put_page",
                 %{
                   "slug" => page.slug,
                   "title" => "Solstice Energy Holdings",
                   "content" => "Updated public overview.",
                   "scope" => "world",
                   "expected_revision" => page.content_hash
                 },
                 context.alice_context
               )

      assert updated["status"] == "updated"
      assert updated["revision"] != page.content_hash

      stored = Repo.get_by!(Object, slug: page.slug)
      assert stored.title == "Solstice Energy Holdings"
      assert stored.body =~ "Updated public overview."
      assert stored.body =~ "Graded score: 0.91"

      [version | _] =
        ObjectVersion
        |> where([v], v.object_id == ^stored.id)
        |> order_by([v], desc: v.snapshot_at)
        |> Repo.all()

      assert version.author == ActorRef.from_principal(context.agent)
      assert version.body =~ "Initial public overview."

      # Multi-audience page with hidden scope refuses put_page so hidden sections cannot be wiped.
      mixed_body = """
      Public note.

      {% audience scope="group:#{context.beta_group.name}" %}
      Beta team confidential note.
      {% /audience %}
      """

      {:ok, mixed_page} =
        Ankole.Brain.create_object(
          %{
            slug: "companies/mixed-scope",
            type: "company",
            title: "Mixed Scope",
            body: mixed_body
          },
          :system
        )

      assert {:error, :hidden_or_protected_segments_use_edit_page} =
               Tools.execute(
                 "put_page",
                 %{
                   "slug" => mixed_page.slug,
                   "content" => "Try wiping beta section.",
                   "scope" => "world",
                   "expected_revision" => mixed_page.content_hash
                 },
                 context.alice_context
               )
    end

    test "replacing a scoped page without an explicit scope preserves its scope and refuses untagged mixed-scope collapse",
         context do
      assert {:ok, created} =
               Tools.execute(
                 "put_page",
                 %{
                   "slug" => "notes/alice-private-dossier",
                   "title" => "Alice Private Dossier",
                   "type" => "note",
                   "content" => "Initial private note."
                 },
                 context.alice_context
               )

      assert {:ok, replaced} =
               Tools.execute(
                 "put_page",
                 %{
                   "slug" => "notes/alice-private-dossier",
                   "content" => "Rewritten private note without explicit scope.",
                   "expected_revision" => created["revision"]
                 },
                 context.alice_context
               )

      stored_private = Repo.get_by!(Object, slug: "notes/alice-private-dossier")
      assert stored_private.content_hash == replaced["revision"]
      assert stored_private.body =~ ~s({% audience scope="principal:#{context.alice.uid}" %})

      assert {:ok, bob_recall} =
               Recall.recall(context.bob.uid, %{query: "Rewritten private note"})

      refute Enum.any?(bob_recall.chunks, &(&1.object_slug == "notes/alice-private-dossier"))

      # A page mixing world and alpha_group (both readable and writable in Alice's context)
      # refuses untagged replacement when scope is omitted rather than collapsing to world.
      readable_mixed_body = """
      Public summary.

      {% audience scope="group:#{context.alpha_group.name}" %}
      Alpha team note.
      {% /audience %}
      """

      {:ok, readable_mixed} =
        Ankole.Brain.create_object(
          %{
            slug: "notes/readable-mixed-scope",
            type: "note",
            title: "Readable Mixed Scope",
            body: readable_mixed_body
          },
          context.agent.uid
        )

      alice_alpha_context = %{
        context.alice_context
        | disclosure: %{
            mode: :strict,
            asker_uid: context.alice.uid,
            present_uids: [context.alice.uid]
          }
      }

      assert {:error, {:mixed_scopes_require_explicit_tags_or_scope, _}} =
               Tools.execute(
                 "put_page",
                 %{
                   "slug" => readable_mixed.slug,
                   "content" => "Plain text missing audience tags.",
                   "expected_revision" => readable_mixed.content_hash
                 },
                 alice_alpha_context
               )
    end

    test "prevents code-fenced audience literals from bypassing default scope on create and replace, protects calibration context, and enforces body size and CRLF normalization",
         context do
      fenced_decoy = """
      Confidential architecture note with `{% audience scope="world" %}` inline literal.

      ```markdoc
      {% audience scope="world" %}
      sample block
      {% /audience %}
      ```
      """

      assert {:ok, created} =
               Tools.execute(
                 "put_page",
                 %{
                   "slug" => "notes/fenced-scope-decoy",
                   "title" => "Fenced Scope Decoy",
                   "type" => "note",
                   "content" => String.replace(fenced_decoy, "\n", "\r\n")
                 },
                 context.alice_context
               )

      stored = Repo.get_by!(Object, slug: "notes/fenced-scope-decoy")
      refute String.contains?(stored.body, "\r")
      assert {:ok, ["principal:" <> alice_uid]} = Ankole.Brain.Markdoc.scopes(stored.body)
      assert alice_uid == context.alice.uid

      assert {:ok, bob_recall} =
               Recall.recall(context.bob.uid, %{query: "Confidential architecture note"})

      refute Enum.any?(bob_recall.chunks, &(&1.object_slug == "notes/fenced-scope-decoy"))

      # Replacing without scope keeps private default wrapping even with code-fenced decoy or mixed blocks.
      mixed_replacement =
        "Untagged private summary with `{% audience scope=\"world\" %}`.\n\n" <>
          ~s({% audience scope="group:#{context.alpha_group.name}" %}\nAlpha detail.\n{% /audience %})

      assert {:ok, replaced} =
               Tools.execute(
                 "put_page",
                 %{
                   "slug" => "notes/fenced-scope-decoy",
                   "content" => mixed_replacement,
                   "expected_revision" => created["revision"]
                 },
                 context.alice_context
               )

      replaced_obj = Repo.get_by!(Object, slug: "notes/fenced-scope-decoy")

      assert {:ok, scopes} = Ankole.Brain.Markdoc.scopes(replaced_obj.body)

      assert Enum.sort(scopes) ==
               Enum.sort([
                 "principal:#{context.alice.uid}",
                 "group:#{context.alpha_group.name}"
               ])

      # Rejects bodies over 200,000 bytes on both create and replace.
      oversized = String.duplicate("a", 200_001)

      assert {:error, :body_too_large} =
               Tools.execute(
                 "put_page",
                 %{
                   "slug" => "notes/too-large",
                   "title" => "Too Large",
                   "type" => "note",
                   "content" => oversized
                 },
                 context.alice_context
               )

      assert {:error, :body_too_large} =
               Tools.execute(
                 "put_page",
                 %{
                   "slug" => "notes/fenced-scope-decoy",
                   "content" => oversized,
                   "expected_revision" => replaced["revision"]
                 },
                 context.alice_context
               )

      # Rejects wrapping a preserved world calibration section inside an audience tag or code fence.
      calibrated_body = """
      Public profile.

      <!-- brain:calibration:start -->
      Brier score: 0.25
      <!-- brain:calibration:end -->
      """

      {:ok, cal_page} =
        Ankole.Brain.create_object(
          %{
            slug: "notes/calibrated-put",
            type: "note",
            title: "Calibrated Put",
            body: calibrated_body
          },
          :system
        )

      assert {:error, {:edit_protected_span, :calibration_section}} =
               Tools.execute(
                 "put_page",
                 %{
                   "slug" => cal_page.slug,
                   "scope" => "world",
                   "expected_revision" => cal_page.content_hash,
                   "content" => """
                   {% audience scope="principal:#{context.alice.uid}" %}
                   <!-- brain:calibration:start -->
                   Brier score: 0.25
                   <!-- brain:calibration:end -->
                   {% /audience %}
                   """
                 },
                 context.alice_context
               )

      assert {:error, {:edit_protected_span, :calibration_section}} =
               Tools.execute(
                 "put_page",
                 %{
                   "slug" => cal_page.slug,
                   "scope" => "world",
                   "expected_revision" => cal_page.content_hash,
                   "content" => """
                   Public profile.

                   ```text
                   <!-- brain:calibration:start -->
                   Brier score: 0.25
                   <!-- brain:calibration:end -->
                   ```
                   """
                 },
                 context.alice_context
               )
    end
  end

  describe "edit_page surgical replacements and multi-audience isolation" do
    test "edits visible writable spans while preserving hidden audience sections and calibration fences byte-for-byte",
         context do
      {:ok, target_co} =
        Ankole.Brain.create_object(
          %{slug: "companies/northwind-grid", type: "company", title: "Northwind Grid"},
          :system
        )

      beta_block = """
      {% audience scope="group:#{context.beta_group.name}" %}
      Beta secret M&A valuation: 420M.
      {% /audience %}
      """

      calibration_block = """
      <!-- brain:calibration:start -->
      Brier score: 0.12
      <!-- brain:calibration:end -->
      """

      initial_body =
        String.trim("""
        Public header: Stage A.

        #{String.trim(beta_block)}

        Public footer: Pending partner review.

        #{String.trim(calibration_block)}
        """)

      {:ok, page} =
        Ankole.Brain.create_object(
          %{
            slug: "projects/aurora-grid",
            type: "project",
            title: "Aurora Grid",
            body: initial_body
          },
          :system
        )

      # Alice/Agent cannot see Beta's block via get_page(include_content: true).
      assert {:ok, %{"page" => visible_page}} =
               Tools.execute(
                 "get_page",
                 %{"reference" => page.slug, "include_content" => true},
                 context.alice_context
               )

      refute visible_page["content"] =~ "Beta secret M&A"
      assert visible_page["revision"] == page.content_hash

      # Attempting to match hidden text fails with edit_no_match.
      assert {:error, {:edit_no_match, %{edit_index: 0}}} =
               Tools.execute(
                 "edit_page",
                 %{
                   "slug" => page.slug,
                   "expected_revision" => visible_page["revision"],
                   "edits" => [%{"old_text" => "Beta secret M&A", "new_text" => "guessed"}]
                 },
                 context.alice_context
               )

      # Attempting to span across the hidden block boundary also fails with edit_no_match.
      assert {:error, {:edit_no_match, %{edit_index: 0}}} =
               Tools.execute(
                 "edit_page",
                 %{
                   "slug" => page.slug,
                   "expected_revision" => visible_page["revision"],
                   "edits" => [
                     %{
                       "old_text" =>
                         "Public header: Stage A.\n\nPublic footer: Pending partner review.",
                       "new_text" => "Collapsed across hidden block"
                     }
                   ]
                 },
                 context.alice_context
               )

      # Attempting to edit inside the protected calibration scorecard fails with edit_protected_span.
      assert {:error, {:edit_protected_span, %{edit_index: 0}}} =
               Tools.execute(
                 "edit_page",
                 %{
                   "slug" => page.slug,
                   "expected_revision" => visible_page["revision"],
                   "edits" => [
                     %{"old_text" => "Brier score: 0.12", "new_text" => "Brier score: 0.01"}
                   ]
                 },
                 context.alice_context
               )

      # Surgical edits on both public spans succeed, preserve Beta's hidden block and calibration
      # fence byte-for-byte, reconcile [[wikilinks]], and return a compact diff.
      assert {:ok, edit_result} =
               Tools.execute(
                 "edit_page",
                 %{
                   "slug" => page.slug,
                   "expected_revision" => visible_page["revision"],
                   "edits" => [
                     %{"old_text" => "Stage A", "new_text" => "Stage B"},
                     %{
                       "old_text" => "Pending partner review.",
                       "new_text" => "Approved with [[#{target_co.slug}]]."
                     }
                   ]
                 },
                 context.alice_context
               )

      assert edit_result["status"] == "updated"
      assert edit_result["revision"] != visible_page["revision"]
      assert edit_result["diff"] =~ "- Public header: Stage A."
      assert edit_result["diff"] =~ "+ Public header: Stage B."
      refute edit_result["diff"] =~ "Beta secret"

      stored = Repo.get_by!(Object, slug: page.slug)
      assert stored.body =~ "Public header: Stage B."
      assert stored.body =~ String.trim(beta_block)
      assert stored.body =~ "Public footer: Approved with [[#{target_co.slug}]]."
      assert stored.body =~ String.trim(calibration_block)

      assert Link
             |> where(
               [l],
               l.from_object_slug == ^page.slug and l.to_object_slug == ^target_co.slug
             )
             |> Repo.exists?()

      [version | _] =
        ObjectVersion
        |> where([v], v.object_id == ^stored.id)
        |> order_by([v], desc: v.snapshot_at)
        |> Repo.all()

      assert version.author == ActorRef.from_principal(context.agent)
      assert version.body == initial_body
    end

    test "refuses ambiguous matches, unauthorized audience scope injection, and fenced turns",
         context do
      {:ok, page} =
        Ankole.Brain.create_object(
          %{
            slug: "notes/curation-guards",
            type: "note",
            title: "Curation Guards",
            body: "Repeated phrase here.\n\nRepeated phrase here."
          },
          context.agent.uid
        )

      assert {:error, {:edit_ambiguous_match, %{edit_index: 0, match_count: 2}}} =
               Tools.execute(
                 "edit_page",
                 %{
                   "slug" => page.slug,
                   "expected_revision" => page.content_hash,
                   "edits" => [%{"old_text" => "Repeated phrase", "new_text" => "Unique phrase"}]
                 },
                 context.alice_context
               )

      # Injecting an audience tag for beta_group (which agent does not belong to) is refused.
      assert {:error, {:writer_not_in_scope_group, _}} =
               Tools.execute(
                 "edit_page",
                 %{
                   "slug" => page.slug,
                   "expected_revision" => page.content_hash,
                   "edits" => [
                     %{
                       "old_text" => "Repeated phrase here.\n\nRepeated phrase here.",
                       "new_text" =>
                         ~s({% audience scope="group:#{context.beta_group.name}" %}\nForged\n{% /audience %})
                     }
                   ]
                 },
                 context.alice_context
               )

      # Write fence blocks mutation before touching storage.
      fenced_context = %{
        context.alice_context
        | write_fence: fn -> {:error, :turn_superseded} end
      }

      assert {:error, :turn_superseded} =
               Tools.execute(
                 "edit_page",
                 %{
                   "slug" => page.slug,
                   "expected_revision" => page.content_hash,
                   "edits" => [
                     %{
                       "old_text" => "Repeated phrase here.\n\nRepeated phrase here.",
                       "new_text" => "Should not persist."
                     }
                   ]
                 },
                 fenced_context
               )

      assert Repo.get_by!(Object, slug: page.slug).content_hash == page.content_hash
    end

    test "blocks exfiltration of hidden audience blocks via unclosed code fences and rejects audience tag stripping",
         context do
      initial_body = """
      Public preface.

      {% audience scope="group:#{context.beta_group.name}" %}
      Beta confidential acquisition price: 900M.
      {% /audience %}

      {% audience scope="group:#{context.alpha_group.name}" %}
      Alpha rollout checklist.
      {% /audience %}
      """

      {:ok, page} =
        Ankole.Brain.create_object(
          %{
            slug: "projects/fence-exfil-guard",
            type: "project",
            title: "Fence Exfil Guard",
            body: initial_body
          },
          :system
        )

      # Opening an unclosed code fence in world would capture Beta's hidden block into world in CommonMark.
      assert {:error, :edit_corrupts_protected_boundaries} =
               Tools.execute(
                 "edit_page",
                 %{
                   "slug" => page.slug,
                   "expected_revision" => page.content_hash,
                   "edits" => [
                     %{
                       "old_text" => "Public preface.",
                       "new_text" => "Public preface.\n\n```text"
                     }
                   ]
                 },
                 context.alice_context
               )

      # Stripping {% audience %} tags around non-empty text is rejected instead of widening to world.
      assert {:error, {:edit_stripped_audience_scope, %{edit_index: 0}}} =
               Tools.execute(
                 "edit_page",
                 %{
                   "slug" => page.slug,
                   "expected_revision" => page.content_hash,
                   "edits" => [
                     %{
                       "old_text" =>
                         ~s({% audience scope="group:#{context.alpha_group.name}" %}\nAlpha rollout checklist.\n{% /audience %}),
                       "new_text" => "Alpha rollout checklist."
                     }
                   ]
                 },
                 context.alice_context
               )

      # Multi-step net no-op edit sequence is rejected without creating a spurious version.
      assert {:error, {:edit_invalid, :noop_edit}} =
               Tools.execute(
                 "edit_page",
                 %{
                   "slug" => page.slug,
                   "expected_revision" => page.content_hash,
                   "edits" => [
                     %{"old_text" => "Public preface.", "new_text" => "Temporary preface."},
                     %{"old_text" => "Temporary preface.", "new_text" => "Public preface."}
                   ]
                 },
                 context.alice_context
               )

      assert Repo.get_by!(Object, slug: page.slug).body == initial_body
    end

    test "supports editing scoped segments containing calibration fences, preserves line breaks around hidden blocks, and refuses library-managed pages",
         context do
      scoped_calibration_body =
        String.trim("""
        {% audience scope="group:#{context.alpha_group.name}" %}
        Alpha thesis v1.

        <!-- brain:calibration:start -->
        Alpha Brier: 0.14
        <!-- brain:calibration:end -->
        {% /audience %}
        {% audience scope="group:#{context.beta_group.name}" %}
        Beta private appendix.
        {% /audience %}
        {% audience scope="group:#{context.alpha_group.name}" %}
        Alpha conclusion v1.
        {% /audience %}
        """)

      {:ok, page} =
        Ankole.Brain.create_object(
          %{
            slug: "projects/scoped-calibration",
            type: "project",
            title: "Scoped Calibration",
            body: scoped_calibration_body
          },
          :system
        )

      assert {:ok, updated} =
               Tools.execute(
                 "edit_page",
                 %{
                   "slug" => page.slug,
                   "expected_revision" => page.content_hash,
                   "edits" => [
                     %{"old_text" => "Alpha thesis v1.", "new_text" => "Alpha thesis v2."},
                     %{
                       "old_text" =>
                         "\n{% audience scope=\"group:#{context.alpha_group.name}\" %}\nAlpha conclusion v1.\n{% /audience %}",
                       "new_text" =>
                         "{% audience scope=\"group:#{context.alpha_group.name}\" %}\nAlpha conclusion v2.\n{% /audience %}"
                     }
                   ]
                 },
                 context.alice_context
               )

      assert updated["status"] == "updated"
      stored = Repo.get_by!(Object, slug: page.slug)
      assert stored.body =~ "Alpha thesis v2."
      assert stored.body =~ "Alpha Brier: 0.14"
      assert stored.body =~ "Beta private appendix."
      assert stored.body =~ "Alpha conclusion v2."
      refute stored.body =~ "{% /audience %}{% audience"

      # Marking the page library-managed refuses both edit_page and put_page without writing versions.
      {:ok, source} =
        Ankole.Ash.create(Source, :register, %{
          upstream_id: "page-edit-managed-#{System.unique_integer([:positive])}",
          kind: "library",
          name: "Managed source",
          default_audience_scope: "world"
        })

      stored
      |> AshPostgres.DataLayer.to_ecto()
      |> Ecto.Changeset.change(managed_by_source_id: source.id)
      |> Repo.update!()

      version_count_before =
        ObjectVersion |> where([v], v.object_id == ^stored.id) |> Repo.aggregate(:count)

      assert {:error, {:library_managed, "projects/scoped-calibration", %{hint: _}}} =
               Tools.execute(
                 "edit_page",
                 %{
                   "slug" => page.slug,
                   "expected_revision" => updated["revision"],
                   "edits" => [
                     %{"old_text" => "Alpha thesis v2.", "new_text" => "Alpha thesis v3."}
                   ]
                 },
                 context.alice_context
               )

      assert {:error, {:library_managed, "projects/scoped-calibration", %{hint: _}}} =
               Tools.execute(
                 "put_page",
                 %{
                   "slug" => page.slug,
                   "content" => "Overwrite managed",
                   "expected_revision" => updated["revision"]
                 },
                 context.alice_context
               )

      assert ObjectVersion |> where([v], v.object_id == ^stored.id) |> Repo.aggregate(:count) ==
               version_count_before
    end

    test "blocks split audience tag stripping, inline-code tag decoys, empty unauthorized shells, split calibration injection, calibration wrapping, and deleted hidden group leaks",
         context do
      {:ok, ephemeral_group} =
        AuthZ.create_principal_group(%{
          name: "secret-ephemeral-#{System.unique_integer([:positive])}",
          display_name: "Secret Ephemeral",
          domain: :operator,
          kind: :static
        })

      initial_body =
        String.trim("""
        Public overview with code sample:

        ```markdoc
        {% audience scope="principal:example" %}
        demo
        {% /audience %}
        ```

        {% audience scope="group:#{ephemeral_group.name}" %}
        Ephemeral confidential note.
        {% /audience %}

        {% audience scope="group:#{context.alpha_group.name}" %}
        Alpha sensitive roadmap.
        {% /audience %}

        <!-- brain:calibration:start -->
        Brier score: 0.19
        <!-- brain:calibration:end -->
        """)

      {:ok, page} =
        Ankole.Brain.create_object(
          %{
            slug: "projects/edit-security-guards",
            type: "project",
            title: "Edit Security Guards",
            body: initial_body
          },
          :system
        )

      # 1. Two-edit split attack stripping opening and closing {% audience %} tags is rejected.
      assert {:error, {:edit_stripped_audience_scope, %{edit_index: 1}}} =
               Tools.execute(
                 "edit_page",
                 %{
                   "slug" => page.slug,
                   "expected_revision" => page.content_hash,
                   "edits" => [
                     %{
                       "old_text" =>
                         ~s({% audience scope="group:#{context.alpha_group.name}" %}\n),
                       "new_text" => ""
                     },
                     %{
                       "old_text" => "Alpha sensitive roadmap.\n{% /audience %}",
                       "new_text" => "Alpha sensitive roadmap."
                     }
                   ]
                 },
                 context.alice_context
               )

      # 2. Single-edit tag stripping with an inline `{% audience` code decoy is rejected.
      assert {:error, {:edit_stripped_audience_scope, %{edit_index: 0}}} =
               Tools.execute(
                 "edit_page",
                 %{
                   "slug" => page.slug,
                   "expected_revision" => page.content_hash,
                   "edits" => [
                     %{
                       "old_text" =>
                         ~s({% audience scope="group:#{context.alpha_group.name}" %}\nAlpha sensitive roadmap.\n{% /audience %}),
                       "new_text" => "Alpha sensitive roadmap with `{% audience` decoy."
                     }
                   ]
                 },
                 context.alice_context
               )

      # 3. Empty unauthorized {% audience %} shell is rejected by scope validation.
      assert {:error, {:writer_not_in_scope_group, _}} =
               Tools.execute(
                 "edit_page",
                 %{
                   "slug" => page.slug,
                   "expected_revision" => page.content_hash,
                   "edits" => [
                     %{
                       "old_text" => "Public overview with code sample:",
                       "new_text" =>
                         "Public overview:\n\n" <>
                           ~s({% audience scope="group:#{context.beta_group.name}" %}\n{% /audience %})
                     }
                   ]
                 },
                 context.alice_context
               )

      # 4. Two-edit split calibration fence marker injection is rejected.
      assert {:error, {:edit_protected_span, %{edit_index: 1}}} =
               Tools.execute(
                 "edit_page",
                 %{
                   "slug" => page.slug,
                   "expected_revision" => page.content_hash,
                   "edits" => [
                     %{
                       "old_text" => "Public overview with code sample:",
                       "new_text" => "Public overview <!-- brain:calibration:__SPLIT__"
                     },
                     %{
                       "old_text" => "__SPLIT__",
                       "new_text" => "start -->\nForged: 0.0\n<!-- brain:calibration:end"
                     }
                   ]
                 },
                 context.alice_context
               )

      # 5. Wrapping the preserved world calibration scorecard inside a code fence is rejected.
      {:ok, cal_only_page} =
        Ankole.Brain.create_object(
          %{
            slug: "notes/cal-wrap-guard",
            type: "note",
            title: "Cal Wrap Guard",
            body:
              "Header.\n\n<!-- brain:calibration:start -->\nScore: 0.31\n<!-- brain:calibration:end -->\n\nFooter."
          },
          :system
        )

      assert {:error, {:edit_protected_span, %{edit_index: 1}}} =
               Tools.execute(
                 "edit_page",
                 %{
                   "slug" => cal_only_page.slug,
                   "expected_revision" => cal_only_page.content_hash,
                   "edits" => [
                     %{"old_text" => "Header.", "new_text" => "Header.\n\n```text"},
                     %{"old_text" => "Footer.", "new_text" => "```\n\nFooter."}
                   ]
                 },
                 context.alice_context
               )

      assert {:error, {:edit_protected_span, %{edit_index: 1}}} =
               Tools.execute(
                 "edit_page",
                 %{
                   "slug" => cal_only_page.slug,
                   "expected_revision" => cal_only_page.content_hash,
                   "edits" => [
                     %{
                       "old_text" => "Header.",
                       "new_text" =>
                         "Header.\n\n" <>
                           ~s({% audience scope="principal:#{context.alice.uid}" %})
                     },
                     %{
                       "old_text" => "Footer.",
                       "new_text" => "{% /audience %}\n\nFooter."
                     }
                   ]
                 },
                 context.alice_context
               )

      # 6. Deleting the hidden group does not block world edits or leak the deleted group's name,
      #    editing a world code block containing {% audience %} succeeds, and CRLF normalizes.
      ephemeral_group
      |> AshPostgres.DataLayer.to_ecto()
      |> Repo.delete!()

      assert {:error, :not_found} = AuthZ.get_principal_group(ephemeral_group.name)

      assert {:ok, edit_ok} =
               Tools.execute(
                 "edit_page",
                 %{
                   "slug" => page.slug,
                   "expected_revision" => page.content_hash,
                   "edits" => [
                     %{
                       "old_text" =>
                         "Public overview with code sample:\r\n\r\n```markdoc\r\n{% audience scope=\"principal:example\" %}\r\ndemo\r\n{% /audience %}\r\n```",
                       "new_text" => "Updated public overview.\r\nSecond line."
                     }
                   ]
                 },
                 context.alice_context
               )

      assert edit_ok["status"] == "updated"
      updated_obj = Repo.get_by!(Object, slug: page.slug)
      refute String.contains?(updated_obj.body, "\r")
      assert updated_obj.body =~ "Updated public overview.\nSecond line."
      assert updated_obj.body =~ "Ephemeral confidential note."
      assert updated_obj.body =~ "Alpha sensitive roadmap."
    end
  end
end
