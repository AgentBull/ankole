defmodule Ankole.Brain.SynthesisScopeTest do
  # `synthesize` writes a page whose body a model composed from recalled
  # evidence, so the audience of that page is the whole guarantee: an
  # untagged body reads as `world`, which every Principal reaches. The
  # provider upstream is faked; everything after it is the real write and
  # the real recall boundary.
  use Ankole.AIGatewayCase

  alias Ankole.Brain.Claims
  alias Ankole.Brain.Objects
  alias Ankole.Brain.Recall
  alias Ankole.Brain.SchemaPacks
  alias Ankole.Brain.Synthesis

  @analysis_body "Acme plans to cut the renewal to one seat."

  setup do
    {:ok, _result} = SchemaPacks.install_packs([])

    test_pid = self()

    base_url =
      start_upstream_server(fn %{path: "chat/completions", body: body} ->
        send(test_pid, {:synthesis_request, body})
        answer = Ankole.JSON.encode!(%{"title" => "Renewal risk", "body" => @analysis_body})
        {:json, 200, chat_completion_body(body["model"], answer)}
      end)

    {:ok, _provider} =
      ProviderConfigs.create_provider(%{
        provider_id: "brain-synthesis",
        provider_kind: "openrouter",
        base_url: base_url,
        credential_pool: %{"entries" => [%{"label" => "Default", "api_key" => "sk-test"}]}
      })

    configure_brain_maintainer_profile!("heavy", "brain-synthesis", "fake-dreaming")

    %{principal: owner} = human_fixture()
    %{principal: agent} = agent_fixture(%{owner_principal_uid: owner.uid})
    %{principal: alice} = human_fixture()
    %{principal: bob} = human_fixture()

    {:ok, _object} =
      Ankole.Brain.create_object(
        %{
          slug: "companies/acme",
          type: "company",
          title: "Acme",
          body: "Acme has zephyr lineage renewal evidence."
        },
        agent.uid
      )

    %{agent: agent, alice: alice, bob: bob}
  end

  test "a page deduced from one Principal's evidence stays that Principal's",
       %{agent: agent, alice: alice, bob: bob} do
    write_fact!(agent, "Acme asked to renew one seat instead of ten", "principal:" <> alice.uid)

    assert {:ok, page} = Synthesis.synthesize(agent.uid, "what is the renewal risk at Acme")
    assert page.audience_scope == "principal:" <> alice.uid

    assert page.slug in recalled_slugs(alice.uid, "renewal")
    refute page.slug in recalled_slugs(bob.uid, "renewal")

    # The stored body carries the tag, so every chunk of the page carries the
    # scope; the returned body stays the plain analysis for the caller.
    assert page.body == @analysis_body
    assert {:ok, stored} = Objects.get_by_slug(page.slug)
    assert stored.body =~ ~s({% audience scope="principal:#{alice.uid}" %})
  end

  test "evidence the page cannot carry leaves the deduction",
       %{agent: agent, alice: alice, bob: bob} do
    write_fact!(agent, "Acme asked to renew one seat instead of ten", "principal:" <> alice.uid)
    write_fact!(agent, "Acme renewal talks moved to next quarter", "principal:" <> alice.uid)
    write_fact!(agent, "Acme pays the renewal by bank transfer", "principal:" <> bob.uid)
    write_fact!(agent, "Acme is a customer since 2024", "world")

    assert {:ok, page} = Synthesis.synthesize(agent.uid, "what is the renewal risk at Acme")

    # Two audiences with no common narrower value: the one carrying the most
    # evidence takes the page and the other drops. Public evidence stays,
    # because it discloses nothing inside a narrower page.
    assert page.audience_scope == "principal:" <> alice.uid
    assert page.dropped_evidence == 1
  end

  test "a page deduced from public evidence stays public", %{agent: agent, bob: bob} do
    write_fact!(agent, "Acme published its renewal terms", "world")

    assert {:ok, page} = Synthesis.synthesize(agent.uid, "what is the renewal risk at Acme")
    assert page.audience_scope == "world"
    assert page.dropped_evidence == 0
    assert page.slug in recalled_slugs(bob.uid, "renewal")
  end

  test "the model receives fact validity and the separate prediction period", %{agent: agent} do
    fact = write_fact!(agent, "Acme published its renewal terms", "world")

    {:ok, take} =
      Claims.write_take(
        %{
          object_slug: "companies/acme",
          claim: "Acme will renew its contract",
          kind: "prediction",
          holder: "agents/" <> agent.uid,
          audience_scope: "world",
          weight: 0.65,
          since_date: "2027-02-01",
          until_date: "2027-03-31",
          provenance: "Account review on 2027-02-01"
        },
        agent.uid,
        embed: false
      )

    assert {:ok, _page} = Synthesis.synthesize(agent.uid, "Acme renewal")
    assert_receive {:synthesis_request, request}
    prompt = request["messages"] |> List.first() |> Map.fetch!("content")

    for value <- [
          fact.id,
          to_string(fact.valid_from),
          take.id,
          take.since_date,
          Date.to_iso8601(take.until_date),
          take.provenance
        ] do
      assert prompt =~ value
    end
  end

  test "synthesize passes claim context, decayed confidence, and scope-bounded open contradictions",
       %{agent: agent, alice: alice, bob: bob} do
    {:ok, %{claim: world_a}} =
      Ankole.Brain.write_fact(
        %{
          object_slug: "companies/acme",
          claim: "Acme renewal contract covers ten enterprise seats",
          context: "Signed under the EMEA enterprise addendum",
          kind: "fact",
          holder: "world",
          audience_scope: "world",
          notability: "high",
          confidence: 0.9,
          valid_from: DateTime.utc_now(:microsecond),
          provenance: "contract-a"
        },
        agent.uid
      )

    {:ok, %{claim: world_b}} =
      Ankole.Brain.write_fact(
        %{
          object_slug: "companies/acme",
          claim: "Acme renewal contract covers only two enterprise seats",
          kind: "fact",
          holder: "world",
          audience_scope: "world",
          notability: "high",
          confidence: 0.85,
          valid_from: DateTime.utc_now(:microsecond),
          provenance: "contract-b"
        },
        agent.uid
      )

    {:ok, %{claim: private_bob}} =
      Ankole.Brain.write_fact(
        %{
          object_slug: "companies/acme",
          claim: "Acme secret renewal discount for Bob",
          kind: "fact",
          holder: "world",
          audience_scope: "principal:" <> bob.uid,
          notability: "high",
          confidence: 0.9,
          valid_from: DateTime.utc_now(:microsecond),
          provenance: "bob-dm"
        },
        agent.uid
      )

    assert :ok =
             Ankole.Brain.Dreaming.record_contradiction_verdict(
               world_a.id,
               world_b.id,
               "contradiction",
               0.92,
               %{"axis" => "seat count", "severity" => "high"}
             )

    assert :ok =
             Ankole.Brain.Dreaming.record_contradiction_verdict(
               world_a.id,
               private_bob.id,
               "contradiction",
               0.95,
               %{"axis" => "secret discount", "severity" => "high"}
             )

    alice_disclosure = %{
      mode: :strict,
      asker_uid: alice.uid,
      present_uids: [alice.uid]
    }

    assert {:ok, page} =
             Synthesis.synthesize(agent.uid, "Acme renewal contract seats",
               disclosure: alice_disclosure
             )

    assert page.audience_scope == "world"
    assert page.open_contradictions == 1

    assert_receive {:synthesis_request, request}
    prompt = request["messages"] |> List.first() |> Map.fetch!("content")

    assert prompt =~ "Signed under the EMEA enterprise addendum"
    assert prompt =~ "effective_confidence 0.9"
    assert prompt =~ "Gaps & Open Questions"
    assert prompt =~ "axis seat count"
    refute prompt =~ "secret discount"
    refute prompt =~ "Acme secret renewal discount for Bob"
  end

  test "re-synthesis cannot replace an existing section outside the caller's disclosure",
       %{agent: agent, alice: alice} do
    write_fact!(agent, "Acme published its renewal terms", "world")
    question = "public Acme renewal summary"
    assert {:ok, page} = Synthesis.synthesize(agent.uid, question)

    body =
      "Public summary.\n\n{% audience scope=\"principal:#{agent.uid}\" %}\nPrivate note.\n{% /audience %}"

    assert {:ok, existing} = Objects.get_by_slug(page.slug)

    assert {:ok, original} =
             Ankole.Brain.update_object(
               page.slug,
               %{body: body, expected_content_hash: existing.content_hash},
               agent.uid
             )

    disclosure = %{mode: :strict, asker_uid: alice.uid, present_uids: [alice.uid]}

    assert {:error, :hidden_or_protected_segments_use_edit_page} =
             Synthesis.synthesize(agent.uid, question, disclosure: disclosure)

    assert {:ok, unchanged} = Objects.get_by_slug(page.slug)
    assert unchanged.body == original.body
    assert unchanged.content_hash == original.content_hash
  end

  test "same-day re-synthesis updates the live page, disambiguates soft-deleted slugs, and ignores expired contradiction counterparts",
       %{agent: agent} do
    {:ok, _partner} =
      Ankole.Brain.create_object(
        %{slug: "companies/partner-one", type: "company", title: "Partner One"},
        agent.uid
      )

    {:ok, %{claim: current_claim}} =
      Ankole.Brain.write_fact(
        %{
          object_slug: "companies/acme",
          claim: "Acme renewal stays active",
          kind: "fact",
          holder: "world",
          audience_scope: "world",
          notability: "high",
          confidence: 0.9,
          valid_from: DateTime.utc_now(:microsecond),
          provenance: "test"
        },
        agent.uid
      )

    {:ok, %{claim: expired_counterpart}} =
      Ankole.Brain.write_fact(
        %{
          object_slug: "companies/acme",
          claim: "Acme cancelled renewal in 2023",
          kind: "fact",
          holder: "world",
          audience_scope: "world",
          notability: "medium",
          confidence: 0.7,
          valid_from: DateTime.utc_now(:microsecond),
          provenance: "legacy"
        },
        agent.uid
      )

    assert :ok =
             Ankole.Brain.Dreaming.record_contradiction_verdict(
               current_claim.id,
               expired_counterpart.id,
               "contradiction",
               0.9,
               %{"axis" => "status", "severity" => "medium"}
             )

    # Expire the counterpart claim: open_contradictions must drop to 0.
    expired_counterpart
    |> AshPostgres.DataLayer.to_ecto()
    |> Ecto.Changeset.change(expired_at: DateTime.utc_now(:microsecond))
    |> Repo.update!()

    counter = :counters.new(1, [:atomics])

    dynamic_url =
      start_upstream_server(fn %{path: "chat/completions", body: body} ->
        n = :counters.get(counter, 1) + 1
        :counters.put(counter, 1, n)

        # Also emit a stray {% audience %} wrapper on pass 2 to verify tag stripping.
        text =
          if n == 1 do
            "Synthesis v1 citing [[companies/acme]]."
          else
            "{% audience scope=\"world\" %}\nSynthesis v#{n} citing [[companies/partner-one]].\n{% /audience %}"
          end

        answer = Ankole.JSON.encode!(%{"title" => "Renewal pass #{n}", "body" => text})
        {:json, 200, chat_completion_body(body["model"], answer)}
      end)

    {:ok, _provider} =
      ProviderConfigs.create_provider(%{
        provider_id: "brain-synthesis-dynamic",
        provider_kind: "openrouter",
        base_url: dynamic_url,
        credential_pool: %{"entries" => [%{"label" => "Default", "api_key" => "sk-test"}]}
      })

    configure_brain_maintainer_profile!("heavy", "brain-synthesis-dynamic", "fake-dreaming")

    assert {:ok, first} = Synthesis.synthesize(agent.uid, "Acme renewal status")
    assert first.open_contradictions == 0
    assert first.body == "Synthesis v1 citing [[companies/acme]]."

    # Re-synthesizing the same question on the same day updates the live analysis page.
    assert {:ok, second} = Synthesis.synthesize(agent.uid, "Acme renewal status")
    assert second.slug == first.slug
    assert second.title == "Renewal pass 2"
    assert second.body == "Synthesis v2 citing [[companies/partner-one]]."
    assert {:ok, stored_second} = Objects.get_by_slug(second.slug)
    assert stored_second.body == "Synthesis v2 citing [[companies/partner-one]]."

    # Soft-deleting the page and synthesizing again allocates a fresh disambiguated slug.
    assert {:ok, _} = Ankole.Brain.soft_delete_object(second.slug)
    assert {:ok, third} = Synthesis.synthesize(agent.uid, "Acme renewal status")
    assert third.slug != second.slug
    assert String.starts_with?(third.slug, second.slug <> "-")
  end

  defp write_fact!(agent, claim, audience_scope) do
    {:ok, %{claim: written}} =
      Ankole.Brain.write_fact(
        %{
          object_slug: "companies/acme",
          claim: claim,
          kind: "fact",
          holder: "world",
          audience_scope: audience_scope,
          notability: "medium",
          confidence: 0.9,
          valid_from: DateTime.utc_now(:microsecond),
          provenance: "test"
        },
        agent.uid
      )

    written
  end

  defp recalled_slugs(querier_uid, query) do
    {:ok, recall} = Recall.recall(querier_uid, %{query: query})
    Enum.map(recall.chunks, & &1.object_slug)
  end
end
