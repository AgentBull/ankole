defmodule Ankole.Brain.SynthesisTest do
  use Ankole.DataCase, async: true

  import Ankole.PrincipalsFixtures

  alias Ankole.Brain.Links
  alias Ankole.Brain.Objects
  alias Ankole.Brain.SchemaPacks
  alias Ankole.Brain.Schemas.Timeline
  alias Ankole.Brain.Synthesis
  alias Ankole.Brain.Timelines
  alias Ankole.Ecto.UUIDv7

  setup do
    {:ok, _result} = SchemaPacks.install_packs([])

    %{principal: querier} = human_fixture()
    %{principal: other} = human_fixture()

    {:ok, object} =
      Objects.create_object(
        %{slug: "projects/delta-window", type: "project", title: "Delta Window"},
        querier.uid
      )

    %{querier: querier, other: other, object: object}
  end

  describe "delta/3 timeline knowledge boundary" do
    test "unreachable rows cannot crowd reachable rows out of the limit", context do
      {:ok, _reachable} =
        Timelines.write_timeline(
          %{
            object_slug: context.object.slug,
            date: ~D[2026-01-01],
            summary: "Reachable kickoff happened",
            provenance: "test",
            audience_scope: "world"
          },
          context.querier.uid
        )

      # More unreachable rows than the whole query limit, all with newer
      # dates: a post-load filter would spend the limit on them and drop the
      # reachable row; the SQL prefilter must not.
      now = DateTime.utc_now(:microsecond)

      unreachable_rows =
        Enum.map(1..51, fn index ->
          %{
            id: UUIDv7.autogenerate(),
            object_slug: context.object.slug,
            author_uid: nil,
            date: Date.add(~D[2026-08-01], rem(index, 20)),
            provenance: "test",
            summary: "Private event #{index}",
            detail: "",
            audience_scope: "principal:" <> context.other.uid,
            created_at: now
          }
        end)

      Repo.insert_all(Timeline, unreachable_rows)

      since = DateTime.add(now, -60, :second)
      assert {:ok, delta} = Synthesis.delta(context.querier.uid, %{since: since})

      summaries = Enum.map(delta.timeline_events, & &1.summary)
      assert "Reachable kickoff happened" in summaries
      refute Enum.any?(summaries, &String.starts_with?(&1, "Private event"))
    end
  end

  describe "delta/3 entity resolution" do
    test "an entity that does not resolve is an explicit error", context do
      assert {:error, {:entity_not_found, "no-such-entity"}} =
               Synthesis.delta(context.querier.uid, %{entity: "no-such-entity"})
    end

    test "an ambiguous entity name returns candidates", context do
      {:ok, _one} =
        Objects.create_object(
          %{slug: "companies/acme-east", type: "company", title: "Acme East"},
          context.querier.uid
        )

      {:ok, _two} =
        Objects.create_object(
          %{slug: "companies/acme-west", type: "company", title: "Acme West"},
          context.querier.uid
        )

      {:ok, _alias} = Links.add_alias("companies/acme-east", "Acme Group")
      {:ok, _alias} = Links.add_alias("companies/acme-west", "Acme Group")

      assert {:error, {:ambiguous_entity, candidates}} =
               Synthesis.delta(context.querier.uid, %{entity: "Acme Group"})

      assert Enum.map(candidates, & &1.slug) == ["companies/acme-east", "companies/acme-west"]
    end
  end
end
