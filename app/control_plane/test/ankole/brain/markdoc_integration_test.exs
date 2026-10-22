defmodule Ankole.Brain.MarkdocIntegrationTest do
  use Ankole.DataCase, async: true

  import Ankole.PrincipalsFixtures

  alias Ankole.Brain.GetPage
  alias Ankole.Brain.SchemaPacks
  alias Ankole.Brain.Schemas.Chunk
  alias Ankole.Brain.Schemas.Object
  alias Ankole.Brain.Schemas.ObjectVersion

  setup do
    {:ok, _result} = SchemaPacks.install_packs([])
    %{principal: owner} = human_fixture()
    %{principal: outsider} = human_fixture()
    %{owner: owner, outsider: outsider}
  end

  test "the fenced close-tag exploit fails closed across every body path", context do
    body = leaking_body(context.owner.uid)

    assert {:error, :unclosed_audience_tag} =
             Ankole.Errors.reason(
               Ankole.Brain.create_object(
                 %{slug: "notes/rejected-markdoc", type: "note", title: "Rejected", body: body},
                 context.owner.uid
               )
             )

    refute Repo.get_by(Object, slug: "notes/rejected-markdoc")

    assert {:ok, editable} =
             Ankole.Brain.create_object(
               %{slug: "notes/editable-markdoc", type: "note", title: "Editable", body: "v1"},
               context.owner.uid
             )

    assert {:error, :unclosed_audience_tag} =
             Ankole.Errors.reason(
               Ankole.Brain.update_object(
                 editable.slug,
                 %{body: body, expected_content_hash: editable.content_hash},
                 context.owner.uid
               )
             )

    assert Repo.get_by!(Object, slug: editable.slug).body == "v1"

    assert Repo.aggregate(
             from(version in ObjectVersion, where: version.object_id == ^editable.id),
             :count
           ) == 0

    corrupt =
      %Object{}
      |> AshPostgres.DataLayer.to_ecto()
      |> Ecto.Changeset.change(%{
        id: Ankole.Ecto.UUIDv7.autogenerate(),
        created_at: DateTime.utc_now(:microsecond),
        updated_at: DateTime.utc_now(:microsecond),
        slug: "notes/corrupt-markdoc",
        type: "note",
        title: "Corrupt",
        body: body,
        meta: %{},
        content_hash: "corrupt-markdoc-fixture"
      })
      |> Repo.insert!()

    assert {:error, :unclosed_audience_tag} =
             Ankole.Errors.reason(Ankole.Brain.reconcile_chunks(corrupt))

    assert Repo.aggregate(from(chunk in Chunk, where: chunk.object_id == ^corrupt.id), :count) ==
             0

    assert {:ok, page} = GetPage.get_page(context.outsider.uid, corrupt.slug)
    refute page.rendered =~ "tail that must stay private"
    refute page.rendered =~ "private"
  end

  defp leaking_body(owner_uid) do
    """
    {% audience scope="principal:#{owner_uid}" %}
    private
    ~~~markdoc
    {% /audience %}
    ~~~
    tail that must stay private
    """
  end
end
