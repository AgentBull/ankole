defmodule Ankole.Brain.CalibrationTest do
  use Ankole.AIGatewayCase

  alias Ankole.Brain.Calibration
  alias Ankole.Brain.Claims
  alias Ankole.Brain.Objects
  alias Ankole.Brain.SchemaPacks
  alias Ankole.Brain.Schemas.Claim
  alias Ankole.Brain.Schemas.SchemaCalibrationDomain
  alias Ankole.Brain.Schemas.TakeDomainAssignment
  alias Ankole.Repo

  setup do
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

      # Every fixture Take is expired, and a verdict on an expired Take resolves
      # it. The default verdict keeps the Take in the queue so the regrade
      # paths below stay reachable; a test that wants a resolution plans one.
      answer =
        Map.get_lazy(plan, :text, fn ->
          Ankole.JSON.encode!(Map.get(plan, :output, grade_output([])))
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
      Ankole.Brain.create_object(
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

  test "public predictions exclude private evidence from the model request", context do
    write_take!(context.member, %{object_slug: context.object.slug}, "Public prediction")
    write_fact!(context, "Public evidence")

    write_fact!(context, "Private acquisition detail",
      audience_scope: "principal:#{context.member.uid}"
    )

    assert %{attempted: 1, graded: 1} = Calibration.grade_takes()
    assert_receive {:calibration_prompt, prompt}
    assert prompt =~ "Public evidence"
    refute prompt =~ "Private acquisition detail"
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

    assert {:ok, _object} = Ankole.Brain.soft_delete_object(context.object.slug)
    plan_verdict!(context, "correct")
    assert %{status: :ok, candidates: 1, graded: 1} = Calibration.grade_takes()

    assert_receive {:calibration_prompt, prompt}
    assert prompt =~ channel_text
    refute prompt =~ object_text
    assert Repo.get!(Claim, object_take.id).graded_at == nil
    assert Repo.get!(Claim, channel_take.id).graded_quality == "correct"
  end

  test "a verdict on an expired Take resolves it without a manual resolve", context do
    take = write_take!(context.member, %{object_slug: context.object.slug}, "Expired prediction")
    write_fact!(context, "The outcome is known")

    plan_verdict!(context, "incorrect")
    assert %{status: :ok, candidates: 1, attempted: 1, graded: 1} = Calibration.grade_takes()
    assert_receive {:calibration_prompt, prompt}, 1_000
    assert prompt =~ "The outcome is known"

    resolved = Repo.get!(Claim, take.id)
    assert resolved.graded_quality == "incorrect"
    assert resolved.graded_by == grader_actor()
    assert %DateTime{} = resolved.resolved_at
    assert resolved.resolved_quality == "incorrect"
    assert resolved.resolved_outcome == false
    assert resolved.resolved_by == grader_actor()
    assert resolved.resolution_provenance == "dreaming grade"
    refute resolved.active

    # The Take has left the candidate set and entered the holder scorecard.
    assert %{status: :ok, candidates: 0, attempted: 0, graded: 0} = Calibration.grade_takes()
    refute_receive {:calibration_prompt, _prompt}, 0
    assert %{status: :ok, holders: 1, updated: 1} = Calibration.calibration_profile()
    assert {:ok, holder} = Objects.get_by_slug("people/#{context.member.uid}")
    assert holder.body =~ "Resolved takes: 1; Brier score: 0.36."

    assert {:error, :already_resolved} =
             Ankole.Errors.reason(
               Ankole.Brain.resolve_take(
                 take.id,
                 %{resolved_quality: "correct", resolved_outcome: true},
                 context.member.uid
               )
             )
  end

  test "a Pod with only primary runs Dreaming and attributes calibration to its system Principal",
       context do
    assert Repo.aggregate(Ankole.Principals.Agent, :count) == 0
    assert {:ok, _} = ModelProfiles.put_default_model_profile(:tenant, "heavy", nil)

    system_uid =
      configure_brain_maintainer_profile!("primary", "brain-calibration", "primary-calibration")

    assert {:ok, true} = Ankole.AppConfigure.put_global_by_key("brain.enabled", true)
    take = write_take!(context.member, %{object_slug: context.object.slug}, "Expired prediction")
    write_fact!(context, "The outcome is known")
    plan_verdict!(context, "incorrect")

    assert {:ok, report} = Ankole.Brain.Dreaming.run()
    assert report.grade_takes == %{status: :ok, candidates: 1, attempted: 1, graded: 1}
    refute Enum.any?(report, fn {_phase, result} -> result.status == :failed end)
    assert_receive {:calibration_request, %{"model" => "primary-calibration"}}
    assert Repo.get!(Claim, take.id).resolved_by == grader_actor()

    assert [%{subject_uid: ^system_uid, origin: :brain}] =
             Repo.all(Ankole.AIGateway.Schemas.UsageRecord)
  end

  test "a partial verdict resolves an expired Take without an outcome", context do
    take = write_take!(context.member, %{object_slug: context.object.slug}, "Partial prediction")

    plan_verdict!(context, "partial")
    assert %{graded: 1} = Calibration.grade_takes()
    assert_receive {:calibration_prompt, _prompt}, 1_000

    resolved = Repo.get!(Claim, take.id)
    assert resolved.resolved_quality == "partial"
    assert resolved.resolved_outcome == nil
    assert resolved.resolved_by == grader_actor()
    assert %{candidates: 0} = Calibration.grade_takes()
    assert %{status: :ok, holders: 0, updated: 0} = Calibration.calibration_profile()
  end

  test "an unresolvable verdict keeps an expired Take in the queue", context do
    take = write_take!(context.member, %{object_slug: context.object.slug}, "Open prediction")

    assert %{graded: 1} = Calibration.grade_takes()
    assert_receive {:calibration_prompt, _prompt}, 1_000

    graded = Repo.get!(Claim, take.id)
    assert graded.graded_quality == "unresolvable"
    assert graded.resolved_at == nil
    assert graded.active

    write_fact!(context, "Later evidence arrives")
    plan_verdict!(context, "correct")
    assert %{candidates: 1, attempted: 1, graded: 1} = Calibration.grade_takes()
    assert_receive {:calibration_prompt, _prompt}, 1_000
    assert Repo.get!(Claim, take.id).resolved_outcome == true
  end

  test "a stale Take without a due date keeps only its grade", context do
    take =
      write_take!(context.member, %{object_slug: context.object.slug}, "Open-ended prediction",
        until_date: nil
      )

    assert %{candidates: 0} = Calibration.grade_takes()

    take
    |> AshPostgres.DataLayer.to_ecto()
    |> Ecto.Changeset.change(created_at: ~U[2020-01-01 00:00:00.000000Z])
    |> Repo.update!()

    plan_verdict!(context, "correct")
    assert %{candidates: 1, attempted: 1, graded: 1} = Calibration.grade_takes()
    assert_receive {:calibration_prompt, _prompt}, 1_000

    graded = Repo.get!(Claim, take.id)
    assert graded.graded_quality == "correct"
    assert graded.resolved_at == nil
    assert graded.active
    assert %{candidates: 1, attempted: 0, graded: 0} = Calibration.grade_takes()
  end

  test "write_take rejects a due date that is not one calendar date", context do
    for invalid <- ["end of Q3", "2026-02-30", "2026/09/30", 20_260_930] do
      assert {:error, :invalid_until_date} =
               Claims.write_take(
                 take_attrs(context.member, %{object_slug: context.object.slug}, "Prediction",
                   until_date: invalid
                 ),
                 context.member.uid,
                 embed: false
               )
    end

    assert {:ok, take} =
             Claims.write_take(
               take_attrs(context.member, %{object_slug: context.object.slug}, "Prediction",
                 until_date: ~D[2027-01-31]
               ),
               context.member.uid,
               embed: false
             )

    assert take.until_date == ~D[2027-01-31]
  end

  test "successful input hashes persist and unchanged grades skip the model", context do
    take = write_take!(context.member, %{object_slug: context.object.slug}, "Legacy prediction")

    {:ok, _} =
      Repo.transact(fn _ ->
        Ankole.Ash.update(take, :record_grade, %{
          graded_quality: "partial",
          graded_confidence: 0.5,
          graded_by: grader_actor(),
          graded_at: ~U[2020-01-01 00:00:00.000000Z]
        })
      end)

    assert %{status: :ok, attempted: 1, graded: 1} = Calibration.grade_takes()
    assert_receive {:calibration_prompt, _prompt}, 1_000
    assert_receive {:calibration_request, body}, 1_000
    assert body["reasoning"]["effort"] == "high"

    graded = Repo.get!(Claim, take.id)
    assert graded.graded_input_hash =~ ~r/^[0-9a-f]{32}$/
    assert graded.graded_quality == "unresolvable"

    assert %{status: :ok, candidates: 1, attempted: 0, graded: 0} = Calibration.grade_takes()
    Ankole.DataCase.assert_persisted_equal(Repo.get!(Claim, take.id), graded)
    refute_receive {:calibration_prompt, _prompt}, 0

    [entry] = context.provider.credential_pool["entries"]

    assert {:ok, _provider} =
             ProviderConfigs.update_credential(context.provider.provider_id, entry["id"], %{
               "api_key" => "sk-rotated"
             })

    assert %{attempted: 0, graded: 0} = Calibration.grade_takes()
    Ankole.DataCase.assert_persisted_equal(Repo.get!(Claim, take.id), graded)
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
             Ankole.Brain.supersede_claim(
               fact.id,
               %{claim: "Delivery is delayed"},
               context.member.uid
             )

    assert %{attempted: 1, graded: 1} = Calibration.grade_takes()
    assert_receive {:calibration_prompt, corrected_prompt}, 1_000
    assert corrected_prompt =~ corrected.claim
    refute corrected_prompt =~ fact.claim

    assert {:ok, _expired} = Ankole.Brain.expire_fact(corrected.id)
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
    |> AshPostgres.DataLayer.to_ecto()
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
    Ankole.DataCase.assert_persisted_equal(Repo.get!(Claim, take.id), previous)

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
                         Ankole.Brain.resolve_take(
                           take.id,
                           %{resolved_quality: "incorrect", resolved_outcome: false},
                           context.member.uid
                         )

              :deactivate ->
                assert {:ok, _take} = Ankole.Brain.deactivate_take(take.id)

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

    # Ash binds LIMIT as a parameter, so the order clause names each query.
    claim_queries = Enum.filter(queries, &String.contains?(&1, ~s(FROM "brain_claims")))
    candidate_queries = Enum.filter(claim_queries, &(&1 =~ ~r/ORDER BY b0\."id" LIMIT/))

    evidence_queries =
      Enum.filter(claim_queries, &(&1 =~ ~r/ORDER BY b0\."valid_from" DESC, b0\."id" DESC LIMIT/))

    assert length(evidence_queries) == 51
    assert length(candidate_queries) == 2
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
             Ankole.Brain.resolve_take(
               object_take.id,
               %{resolved_quality: "correct", resolved_outcome: true},
               context.member.uid
             )

    assert {:ok, _resolved} =
             Ankole.Brain.resolve_take(
               channel_take.id,
               %{resolved_quality: "correct", resolved_outcome: true},
               context.member.uid
             )

    assert {:ok, _object} = Ankole.Brain.soft_delete_object(context.object.slug)
    assert %{status: :ok, holders: 1, updated: 1} = Calibration.calibration_profile()

    assert {:ok, holder} = Objects.get_by_slug("people/#{context.member.uid}")
    assert holder.body =~ "Resolved takes: 1; Brier score: 0.16."
    refute holder.body =~ "Resolved takes: 2"
  end

  defp write_take!(member, parent, claim, overrides \\ []) do
    {:ok, take} =
      Claims.write_take(take_attrs(member, parent, claim, overrides), member.uid, embed: false)

    take
  end

  defp take_attrs(member, parent, claim, overrides) do
    %{
      claim: claim,
      kind: "prediction",
      holder: "people/#{member.uid}",
      audience_scope: "world",
      weight: 0.6,
      until_date: "2020-01-01",
      provenance: "test"
    }
    |> Map.merge(parent)
    |> Map.merge(Map.new(overrides))
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
      Ankole.Brain.write_fact(attrs, context.member.uid, %{options: [embed: false, dedup: false]})

    fact
  end

  defp put_grade_profile!(provider_id, model, options) do
    assert {:ok, _profile} =
             ModelProfiles.put_default_model_profile(:tenant, "heavy", %{
               provider_id: provider_id,
               model: model,
               provider_options: options
             })
  end

  defp grader_actor do
    {:ok, system} = Ankole.Principals.system_principal("ankole_brain")
    to_string(Ankole.ActorRef.from_principal(%{tenant_id: Repo.tenant_id!(), uid: system.uid}))
  end

  defp grade_output(domains, quality \\ "unresolvable"),
    do: %{"quality" => quality, "confidence" => 0.9, "domains" => domains}

  # Plans the verdict of the next model call.
  defp plan_verdict!(context, quality),
    do: Agent.update(context.upstream, fn _plan -> %{output: grade_output([], quality)} end)

  defp insert_channel! do
    now = DateTime.utc_now(:microsecond)

    Ankole.ExternalConversationsFixtures.create_external_conversation!(%{
      id: Ecto.UUID.generate(),
      provider_conversation_id: "test:calibration-#{System.unique_integer([:positive])}",
      title: "Conversation",
      last_activity_at: now,
      external_kind: :im_dm,
      reply_mode: :entry,
      metadata: %{},
      raw_payload: %{},
      first_seen_at: now,
      last_seen_at: now
    })
  end
end
