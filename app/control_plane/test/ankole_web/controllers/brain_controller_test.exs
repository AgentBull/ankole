defmodule AnkoleWeb.BrainControllerTest do
  use AnkoleWeb.ConnCase, async: false

  alias Ankole.AppConfigure.Cache
  alias Ankole.AppConfigure.Registry
  alias Ankole.Brain.Schemas.Claim
  alias Ankole.Brain.Schemas.Object
  alias Ankole.Ecto.UUIDv7
  alias Ankole.Repo
  alias Ankole.Setup.Config, as: SetupConfig

  setup do
    allow_cache_database_access()
    Registry.clear_for_test()
    Cache.clear_for_test()

    {:ok, false} = SetupConfig.put_completed(false)
    :ok = SetupConfig.delete_bootstrap_activation_code()

    :ok
  end

  test "claim search filters before the list limit and treats wildcards literally", %{conn: conn} do
    {conn, principal_uid} = bearer_conn_with_principal(conn)
    now = DateTime.utc_now(:microsecond)

    object =
      Repo.insert!(%Object{
        id: UUIDv7.autogenerate(),
        slug: "notes/claim-search",
        type: "note",
        title: "Claim search",
        body: "",
        meta: %{},
        emotional_weight: 0.0,
        created_at: now,
        updated_at: now
      })

    row = fn claim, created_at ->
      %{
        id: UUIDv7.autogenerate(),
        author_uid: principal_uid,
        claim_type: "fact",
        object_slug: object.slug,
        claim: claim,
        kind: "fact",
        holder: "world",
        audience_scope: "world",
        notability: "medium",
        valid_from: now,
        confidence: 0.75,
        provenance: "controller test",
        created_at: created_at,
        updated_at: created_at
      }
    end

    target = row.("Rare claim beyond the first page", DateTime.add(now, -1, :day))

    fillers =
      for index <- 1..100 do
        row.("Common claim #{index}", DateTime.add(now, index, :microsecond))
      end

    percent_target = row.("Budget is 20% complete", DateTime.add(now, -2, :day))
    percent_decoy = row.("Budget is 201 complete", DateTime.add(now, -3, :day))
    underscore_target = row.("part_number", DateTime.add(now, -4, :day))
    underscore_decoy = row.("partXnumber", DateTime.add(now, -5, :day))
    backslash_target = row.("path\\segment", DateTime.add(now, -6, :day))
    backslash_decoy = row.("pathsegment", DateTime.add(now, -7, :day))

    {107, nil} =
      Repo.insert_all(Claim, [
        target,
        percent_target,
        percent_decoy,
        underscore_target,
        underscore_decoy,
        backslash_target,
        backslash_decoy
        | fillers
      ])

    assert %{"claims" => unfiltered} =
             conn
             |> get(~p"/api/v1/brain/claims")
             |> json_response(200)

    assert length(unfiltered) == 100
    refute Enum.any?(unfiltered, &(&1["id"] == target.id))

    assert %{"claims" => [%{"id" => target_id}]} =
             conn
             |> recycle_api()
             |> get(~p"/api/v1/brain/claims?q=RARE%20CLAIM")
             |> json_response(200)

    assert target_id == target.id

    assert %{"claims" => [%{"id" => percent_target_id}]} =
             conn
             |> recycle_api()
             |> get(~p"/api/v1/brain/claims?q=%25")
             |> json_response(200)

    assert percent_target_id == percent_target.id

    assert %{"claims" => [%{"id" => underscore_target_id}]} =
             conn
             |> recycle_api()
             |> get(~p"/api/v1/brain/claims?q=_")
             |> json_response(200)

    assert underscore_target_id == underscore_target.id

    assert %{"claims" => [%{"id" => backslash_target_id}]} =
             conn
             |> recycle_api()
             |> get(~p"/api/v1/brain/claims?q=%5C")
             |> json_response(200)

    assert backslash_target_id == backslash_target.id
  end
end
