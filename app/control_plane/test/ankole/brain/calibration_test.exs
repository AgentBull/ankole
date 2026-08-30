defmodule Ankole.Brain.CalibrationTest do
  use Ankole.AIGatewayCase

  alias Ankole.AppConfigure
  alias Ankole.Brain.Calibration
  alias Ankole.Brain.Claims
  alias Ankole.Brain.Objects
  alias Ankole.Brain.SchemaPacks
  alias Ankole.Brain.Schemas.Claim
  alias Ankole.Repo

  setup do
    allow_cache_database_access()
    AppConfigure.Cache.clear_for_test()
    on_exit(fn -> AppConfigure.Cache.clear_for_test() end)

    {:ok, _result} = SchemaPacks.install_packs([])

    test_pid = self()

    base_url =
      start_upstream_server(fn %{path: "chat/completions", body: body} ->
        prompt = body["messages"] |> List.first() |> Map.fetch!("content")
        send(test_pid, {:calibration_prompt, prompt})

        answer =
          Ankole.JSON.encode!(%{
            "quality" => "correct",
            "confidence" => 0.9,
            "domains" => []
          })

        {:json, 200, chat_completion_body(body["model"], answer)}
      end)

    {:ok, _provider} =
      ProviderConfigs.create_provider(%{
        provider_id: "brain-calibration",
        provider_kind: "openrouter",
        base_url: base_url,
        credential_pool: %{"entries" => [%{"label" => "Default", "api_key" => "sk-test"}]}
      })

    {:ok, _value} =
      AppConfigure.put_global_by_key("brain.dreaming_model", %{
        "provider_id" => "brain-calibration",
        "model" => "fake-calibration"
      })

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

    %{member: member, object: object, channel: insert_channel!()}
  end

  test "grade_takes skips deleted Object parents and grades channel parents", context do
    object_text = "The deleted object prediction must not reach the model"
    channel_text = "The channel prediction remains eligible for grading"

    object_take = write_take!(context.member, %{object_slug: context.object.slug}, object_text)

    channel_take =
      write_take!(
        context.member,
        %{signal_gateway_channel_id: context.channel.id},
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
        %{signal_gateway_channel_id: context.channel.id},
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

  defp insert_channel! do
    now = DateTime.utc_now(:microsecond)

    Repo.insert!(
      Ankole.SignalsGateway.Channel.changeset(%Ankole.SignalsGateway.Channel{}, %{
        id: "test:calibration-#{System.unique_integer([:positive])}",
        kind: :im_dm,
        reply_mode: :entry,
        metadata: %{},
        raw_payload: %{},
        first_seen_at: now,
        last_seen_at: now
      })
    )
  end
end
