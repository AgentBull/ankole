defmodule Ankole.Brain.CalibrationTest do
  use Ankole.AIGatewayCase

  alias Ankole.AppConfigure
  alias Ankole.Brain.Calibration
  alias Ankole.Brain.Claims
  alias Ankole.Brain.Objects
  alias Ankole.Brain.SchemaPacks
  alias Ankole.Brain.Schemas.Claim
  alias Ankole.Brain.Schemas.SchemaCalibrationDomain
  alias Ankole.Brain.Schemas.TakeDomainAssignment
  alias Ankole.Repo

  setup do
    allow_cache_database_access()
    AppConfigure.Cache.clear_for_test()
    on_exit(fn -> AppConfigure.Cache.clear_for_test() end)

    {:ok, _result} = SchemaPacks.install_packs([])

    test_pid = self()
    tenant_id = Repo.tenant_id!()
    upstream = start_supervised!({Agent, fn -> %{} end})

    handler = fn %{path: "chat/completions", body: body} ->
      plan = Agent.get_and_update(upstream, &{&1, %{}})
      if before_reply = plan[:before_reply], do: Repo.with_tenant(tenant_id, before_reply)

      prompt = body["messages"] |> List.first() |> Map.fetch!("content")
      send(test_pid, {:calibration_prompt, prompt})
      send(test_pid, {:calibration_request, body})

      answer =
        Map.get_lazy(plan, :text, fn ->
          Ankole.JSON.encode!(
            Map.get(plan, :output, %{
              "quality" => "correct",
              "confidence" => 0.9,
              "domains" => []
            })
          )
        end)

      {:json, 200, chat_completion_body(body["model"], answer)}
    end

    base_url = start_upstream_server(handler)

    {:ok, provider} =
      ProviderConfigs.create_provider(%{
        provider_id: "brain-calibration",
        provider_kind: "openrouter",
        base_url: base_url,
        credential_pool: %{"entries" => [%{"label" => "Default", "api_key" => "sk-test"}]}
      })

    configure_brain_maintainer_profile!("heavy", "brain-calibration", "fake-calibration")

    %{principal: member} = human_fixture()

    {:ok, object} =
      Objects.create_object(
        %{
          slug: "concepts/deleted-calibration",
          type: "concept",
          title: "Deleted Calibration"
        },
        member.uid
      )

    %{
      member: member,
      object: object,
      channel: insert_channel!(),
      provider: provider,
      upstream: upstream,
      handler: handler
    }
  end

  test "grade_takes skips deleted Object parents and grades channel parents", context do
    object_text = "The deleted object prediction must not reach the model"
    channel_text = "The channel prediction remains eligible for grading"

    object_take = write_take!(context.member, %{object_slug: context.object.slug}, object_text)

    channel_take =
      write_take!(
        context.member,
        %{conversation_id: context.channel.id},
        channel_text
      )

    assert {:ok, _object} = Objects.soft_delete(context.object.slug)
    assert %{status: :ok, candidates: 1, graded: 1} = Calibration.grade_takes()

    assert_receive {:calibration_prompt, prompt}
    assert prompt =~ channel_text
    refute prompt =~ object_text
    assert Repo.get!(Claim, object_take.id).graded_at == nil
    assert Repo.get!(Claim, channel_take.id).graded_quality == "correct"
  end

  test "successful input hashes persist and unchanged grades skip the model", context do
    take = write_take!(context.member, %{object_slug: context.object.slug}, "Legacy prediction")

    take
    |> Ecto.Changeset.change(
      graded_quality: "partial",
      graded_confidence: 0.5,
      graded_at: ~U[2020-01-01 00:00:00.000000Z]
    )
    |> Repo.update!()

    assert %{status: :ok, attempted: 1, graded: 1} = Calibration.grade_takes()
    assert_receive {:calibration_prompt, _prompt}, 1_000
    assert_receive {:calibration_request, body}, 1_000
    assert body["reasoning"]["effort"] == "high"

    graded = Repo.get!(Claim, take.id)
    assert graded.graded_input_hash =~ ~r/^[0-9a-f]{32}$/
    assert graded.graded_quality == "correct"

    assert %{status: :ok, candidates: 1, attempted: 0, graded: 0} = Calibration.grade_takes()
    assert Repo.get!(Claim, take.id) == graded
    refute_receive {:calibration_prompt, _prompt}, 0

    [entry] = context.provider.credential_pool["entries"]

    assert {:ok, _provider} =
             ProviderConfigs.update_credential(context.provider.provider_id, entry["id"], %{
               "api_key" => "sk-rotated"
             })

    assert %{attempted: 0, graded: 0} = Calibration.grade_takes()
    assert Repo.get!(Claim, take.id) == graded
    refute_receive {:calibration_prompt, _prompt}, 0
  end

  test "new, corrected, expired, and deleted selected evidence trigger grading", context do
    take = write_take!(context.member, %{object_slug: context.object.slug}, "Delivery prediction")
    assert %{graded: 1} = Calibration.grade_takes()
    assert_receive {:calibration_prompt, empty_prompt}, 1_000
    initial_hash = Repo.get!(Claim, take.id).graded_input_hash

    fact = write_fact!(context, "Delivery is on time")
    assert %{attempted: 1, graded: 1} = Calibration.grade_takes()
    assert_receive {:calibration_prompt, added_prompt}, 1_000
    assert added_prompt =~ fact.claim
    refute empty_prompt =~ fact.claim
    refute Repo.get!(Claim, take.id).graded_input_hash == initial_hash

    assert {:ok, corrected} =
             Claims.supersede_claim(fact.id, %{claim: "Delivery is delayed"}, context.member.uid)

    assert %{attempted: 1, graded: 1} = Calibration.grade_takes()
    assert_receive {:calibration_prompt, corrected_prompt}, 1_000
    assert corrected_prompt =~ corrected.claim
    refute corrected_prompt =~ fact.claim

    assert {:ok, _expired} = Claims.expire_fact(corrected.id)
    assert %{attempted: 1, graded: 1} = Calibration.grade_takes()
    assert_receive {:calibration_prompt, expired_prompt}, 1_000
    refute expired_prompt =~ corrected.claim

    deleted = write_fact!(context, "Temporary delivery evidence")
    assert %{graded: 1} = Calibration.grade_takes()
    assert_receive {:calibration_prompt, before_delete}, 1_000
    assert before_delete =~ deleted.claim
    Repo.delete!(deleted)

    assert %{attempted: 1, graded: 1} = Calibration.grade_takes()
    assert_receive {:calibration_prompt, after_delete}, 1_000
    refute after_delete =~ deleted.claim
    assert %{attempted: 0, graded: 0} = Calibration.grade_takes()
    refute_receive {:calibration_prompt, _prompt}, 0
  end

  test "only the ten selected facts affect the grading input", context do
    write_take!(context.member, %{object_slug: context.object.slug}, "Latest evidence prediction")

    facts =
      for index <- 1..11 do
        write_fact!(context, "Evidence item #{index}",
          valid_from: DateTime.add(~U[2020-01-01 00:00:00.000000Z], index, :second)
        )
      end

    assert %{graded: 1} = Calibration.grade_takes()
    assert_receive {:calibration_prompt, prompt}, 1_000
    refute prompt =~ "Evidence item 1\n"
    assert prompt =~ "Evidence item 11\n"

    facts
    |> List.first()
    |> Ecto.Changeset.change(claim: "Old evidence outside the prompt changed")
    |> Repo.update!()

    assert %{attempted: 0, graded: 0} = Calibration.grade_takes()
    refute_receive {:calibration_prompt, _prompt}, 0
  end

  test "same profile changes model, provider options, and route invalidate grades", context do
    write_take!(context.member, %{object_slug: context.object.slug}, "Model selection prediction")
    assert %{graded: 1} = Calibration.grade_takes()
    assert_receive {:calibration_prompt, _prompt}, 1_000
    assert_receive {:calibration_request, first_request}, 1_000
    assert first_request["model"] == "fake-calibration"

    put_grade_profile!(context.provider.provider_id, "replacement-calibration", %{})
    assert %{attempted: 1, graded: 1} = Calibration.grade_takes()
    assert_receive {:calibration_prompt, _prompt}, 1_000
    assert_receive {:calibration_request, changed_model}, 1_000
    assert changed_model["model"] == "replacement-calibration"

    put_grade_profile!(context.provider.provider_id, "replacement-calibration", %{
      "reasoningEffort" => "low"
    })

    assert %{attempted: 1, graded: 1} = Calibration.grade_takes()
    assert_receive {:calibration_prompt, _prompt}, 1_000
    assert_receive {:calibration_request, changed_options}, 1_000
    assert changed_options["reasoning"]["effort"] == "low"

    assert {:ok, _provider} =
             ProviderConfigs.update_provider(context.provider.provider_id, %{
               base_url: start_upstream_server(context.handler)
             })

    assert %{attempted: 1, graded: 1} = Calibration.grade_takes()
    assert_receive {:calibration_prompt, _prompt}, 1_000
    assert %{attempted: 0, graded: 0} = Calibration.grade_takes()
    refute_receive {:calibration_prompt, _prompt}, 0
  end

  test "domain changes regrade and assignments remain idempotent", context do
    take = write_take!(context.member, %{object_slug: context.object.slug}, "Legal prediction")
    assert %{graded: 1} = Calibration.grade_takes()
    assert_receive {:calibration_prompt, original_prompt}, 1_000
    assert original_prompt =~ "Installed calibration domains: none installed"

    assert {:ok, _result} = SchemaPacks.install_packs(["legal"])
    Agent.update(context.upstream, fn _plan -> %{output: grade_output(["matter_outcome"])} end)
    assert %{attempted: 1, graded: 1} = Calibration.grade_takes()
    assert_receive {:calibration_prompt, added_prompt}, 1_000
    assert added_prompt =~ "matter_outcome"

    assert [%TakeDomainAssignment{take_claim_id: id, domain: "matter_outcome", pack: "legal"}] =
             Repo.all(TakeDomainAssignment)

    assert id == take.id
    assert %{attempted: 0, graded: 0} = Calibration.grade_takes()
    refute_receive {:calibration_prompt, _prompt}, 0

    domain = Repo.get_by!(SchemaCalibrationDomain, name: "matter_outcome")
    Repo.delete!(domain)
    assert %{attempted: 1, graded: 1} = Calibration.grade_takes()
    assert_receive {:calibration_prompt, removed_prompt}, 1_000
    refute removed_prompt =~ "matter_outcome"
    assert Repo.aggregate(TakeDomainAssignment, :count) == 1
  end

  test "invalid model output is not a cache hit and retries with unchanged input", context do
    take = write_take!(context.member, %{object_slug: context.object.slug}, "Retry prediction")
    Agent.update(context.upstream, fn _plan -> %{text: "Unable to return a grade"} end)

    assert %{attempted: 1, graded: 0} = Calibration.grade_takes()
    assert_receive {:calibration_prompt, _prompt}, 1_000
    assert Repo.get!(Claim, take.id).graded_input_hash == nil
    assert Repo.get!(Claim, take.id).graded_at == nil

    assert %{attempted: 1, graded: 1} = Calibration.grade_takes()
    assert_receive {:calibration_prompt, _prompt}, 1_000
    previous = Repo.get!(Claim, take.id)
    write_fact!(context, "Retry with new evidence")
    Agent.update(context.upstream, fn _plan -> %{text: "Still unable to return a grade"} end)

    assert %{attempted: 1, graded: 0} = Calibration.grade_takes()
    assert_receive {:calibration_prompt, _prompt}, 1_000
    assert Repo.get!(Claim, take.id) == previous

    assert %{attempted: 1, graded: 1} = Calibration.grade_takes()
    assert_receive {:calibration_prompt, _prompt}, 1_000
    refute Repo.get!(Claim, take.id).graded_input_hash == previous.graded_input_hash
    assert %{attempted: 0, graded: 0} = Calibration.grade_takes()
    refute_receive {:calibration_prompt, _prompt}, 0
  end

  test "evidence changed during the model call is graded in the next round", context do
    take =
      write_take!(context.member, %{object_slug: context.object.slug}, "In-flight prediction")

    Agent.update(context.upstream, fn _plan ->
      %{before_reply: fn -> write_fact!(context, "New evidence during grading") end}
    end)

    assert %{attempted: 1, graded: 0} = Calibration.grade_takes()
    assert_receive {:calibration_prompt, original_prompt}, 1_000
    refute original_prompt =~ "New evidence during grading"
    assert Repo.get!(Claim, take.id).graded_input_hash == nil

    assert %{attempted: 1, graded: 1} = Calibration.grade_takes()
    assert_receive {:calibration_prompt, new_prompt}, 1_000
    assert new_prompt =~ "New evidence during grading"
    assert %{attempted: 0, graded: 0} = Calibration.grade_takes()
    refute_receive {:calibration_prompt, _prompt}, 0
  end

  test "model changed during the call cannot commit the old model grade", context do
    take = write_take!(context.member, %{object_slug: context.object.slug}, "Model in flight")

    Agent.update(context.upstream, fn _plan ->
      %{
        before_reply: fn ->
          put_grade_profile!(context.provider.provider_id, "new-in-flight-model", %{})
        end
      }
    end)

    assert %{attempted: 1, graded: 0} = Calibration.grade_takes()
    assert_receive {:calibration_request, first_request}, 1_000
    assert first_request["model"] == "fake-calibration"
    assert Repo.get!(Claim, take.id).graded_input_hash == nil

    assert %{attempted: 1, graded: 1} = Calibration.grade_takes()
    assert_receive {:calibration_request, fresh_request}, 1_000
    assert fresh_request["model"] == "new-in-flight-model"
    assert %{attempted: 0, graded: 0} = Calibration.grade_takes()
    refute_receive {:calibration_request, _request}, 0
  end

  for change <- [:resolve, :deactivate, :delete] do
    @change change
    test "a Take #{@change}d during the model call is not overwritten", context do
      take = write_take!(context.member, %{object_slug: context.object.slug}, "Human state wins")

      Agent.update(context.upstream, fn _plan ->
        %{
          before_reply: fn ->
            case @change do
              :resolve ->
                assert {:ok, _take} =
                         Claims.resolve_take(
                           take.id,
                           %{resolved_quality: "incorrect", resolved_outcome: false},
                           context.member.uid
                         )

              :deactivate ->
                assert {:ok, _take} = Claims.deactivate_take(take.id)

              :delete ->
                Repo.delete!(take)
            end
          end
        }
      end)

      assert %{attempted: 1, graded: 0} = Calibration.grade_takes()
      assert_receive {:calibration_prompt, _prompt}, 1_000

      assert_changed_take_state(@change, Repo.get(Claim, take.id))

      assert %{candidates: 0, attempted: 0, graded: 0} = Calibration.grade_takes()
      refute_receive {:calibration_prompt, _prompt}, 0
    end
  end

  test "fifty cached Takes do not consume the later model attempt budget", context do
    write_fact!(context, "The shared grading evidence remains current")

    takes =
      for index <- 1..51 do
        write_take!(
          context.member,
          %{object_slug: context.object.slug},
          "Prediction #{index}"
        )
      end

    {cold_us, cold_report} = :timer.tc(&Calibration.grade_takes/0)
    assert %{candidates: 50, attempted: 50, graded: 50} = cold_report
    for _index <- 1..50, do: assert_receive({:calibration_prompt, _prompt}, 1_000)

    assert %{candidates: 51, attempted: 1, graded: 1} = Calibration.grade_takes()
    assert_receive {:calibration_prompt, last_prompt}, 1_000
    assert last_prompt =~ Enum.max_by(takes, & &1.id).claim
    handler_id = {__MODULE__, make_ref()}
    target = self()

    :ok =
      :telemetry.attach(
        handler_id,
        Repo.config()[:telemetry_prefix] ++ [:query],
        fn _event, _measurements, metadata, target ->
          if self() == target, do: send(target, {handler_id, metadata.query})
        end,
        target
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)
    {cached_us, cached_report} = :timer.tc(&Calibration.grade_takes/0)
    :ok = :telemetry.detach(handler_id)
    queries = collect_queries(handler_id)

    assert %{candidates: 51, attempted: 0, graded: 0} = cached_report
    assert Enum.count(queries, &String.contains?(&1, ~s(FROM "ai_gateway_providers"))) == 1

    assert Enum.count(queries, &String.contains?(&1, ~s(FROM "brain_schema_calibration_domains"))) ==
             1

    candidate_queries = Enum.filter(queries, &String.contains?(&1, "LIMIT 50"))
    evidence_queries = Enum.filter(queries, &String.contains?(&1, "LIMIT 10"))
    assert length(evidence_queries) == 51
    assert length(candidate_queries) == 2
    assert Enum.all?(candidate_queries, &String.contains?(&1, "LIMIT 50"))
    refute_receive {:calibration_prompt, _prompt}, 0

    IO.puts(
      "Q19_PHASE_COMPARISON " <>
        Ankole.JSON.encode!(%{
          cold_candidates: 50,
          cold_model_calls: 50,
          cold_microseconds: cold_us,
          cached_candidates: 51,
          cached_model_calls: 0,
          cached_microseconds: cached_us,
          cached_provider_reads: 1,
          cached_domain_reads: 1,
          cached_candidate_batches: 2,
          cached_evidence_reads: 51
        })
    )

    write_take!(
      context.member,
      %{object_slug: context.object.slug},
      "A later changed input after fifty-one cached Takes"
    )

    assert %{candidates: 52, attempted: 1, graded: 1} = Calibration.grade_takes()
    assert_receive {:calibration_prompt, new_prompt}, 1_000
    assert new_prompt =~ "later changed input"
    refute_receive {:calibration_prompt, _prompt}, 0
  end

  test "calibration_profile excludes deleted Object parents and keeps channel parents", context do
    object_take =
      write_take!(
        context.member,
        %{object_slug: context.object.slug},
        "The deleted object prediction was resolved"
      )

    channel_take =
      write_take!(
        context.member,
        %{conversation_id: context.channel.id},
        "The channel prediction was resolved"
      )

    assert {:ok, _resolved} =
             Claims.resolve_take(
               object_take.id,
               %{resolved_quality: "correct", resolved_outcome: true},
               context.member.uid
             )

    assert {:ok, _resolved} =
             Claims.resolve_take(
               channel_take.id,
               %{resolved_quality: "correct", resolved_outcome: true},
               context.member.uid
             )

    assert {:ok, _object} = Objects.soft_delete(context.object.slug)
    assert %{status: :ok, holders: 1, updated: 1} = Calibration.calibration_profile()

    assert {:ok, holder} = Objects.get_by_slug("people/#{context.member.uid}")
    assert holder.body =~ "Resolved takes: 1; Brier score: 0.16."
    refute holder.body =~ "Resolved takes: 2"
  end

  defp write_take!(member, parent, claim) do
    attrs =
      Map.merge(
        %{
          claim: claim,
          kind: "prediction",
          holder: "people/#{member.uid}",
          audience_scope: "world",
          weight: 0.6,
          until_date: "2020-01-01",
          provenance: "test"
        },
        parent
      )

    {:ok, take} = Claims.write_take(attrs, member.uid, embed: false)
    take
  end

  defp assert_changed_take_state(:delete, current), do: assert(is_nil(current))

  defp assert_changed_take_state(change, current) do
    assert current.graded_input_hash == nil
    assert current.graded_at == nil
    refute current.active
    if change == :resolve, do: assert(current.resolved_quality == "incorrect")
  end

  defp collect_queries(handler_id, queries \\ []) do
    receive do
      {^handler_id, query} -> collect_queries(handler_id, [query | queries])
    after
      0 -> Enum.reverse(queries)
    end
  end

  defp write_fact!(context, claim, overrides \\ []) do
    attrs =
      %{
        object_slug: context.object.slug,
        claim: claim,
        kind: "fact",
        holder: "people/#{context.member.uid}",
        audience_scope: "world",
        notability: "medium",
        confidence: 0.8,
        context: "Delivery schedule",
        valid_from: DateTime.utc_now(:microsecond),
        provenance: "test evidence"
      }
      |> Map.merge(Map.new(overrides))

    {:ok, %{claim: fact}} =
      Claims.write_fact(attrs, context.member.uid, embed: false, dedup: false)

    fact
  end

  defp put_grade_profile!(provider_id, model, options) do
    {:ok, maintainer} = AppConfigure.get_by_key("brain.maintainer_agent_uid")

    assert {:ok, _profile} =
             ModelProfiles.put_model_profile(maintainer, "heavy", %{
               provider_id: provider_id,
               model: model,
               provider_options: options
             })
  end

  defp grade_output(domains),
    do: %{"quality" => "correct", "confidence" => 0.9, "domains" => domains}

  defp insert_channel! do
    now = DateTime.utc_now(:microsecond)

    Repo.insert!(
      Ankole.Conversations.Conversation.changeset(%Ankole.Conversations.Conversation{}, %{
        id: Ecto.UUID.generate(),
        provider_conversation_id: "test:calibration-#{System.unique_integer([:positive])}",
        title: "Conversation",
        last_activity_at: now,
        kind: :external,
        external_kind: :im_dm,
        reply_mode: :entry,
        metadata: %{},
        raw_payload: %{},
        first_seen_at: now,
        last_seen_at: now
      })
    )
  end
end
