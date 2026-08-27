defmodule Ankole.Brain.Promotion do
  @moduledoc """
  Console-reviewed materialization of vocabulary promotion suggestions.

  Approval runs one transaction: register the new type or subtype, retype
  the existing objects (type rewrite plus slug-prefix migration with
  redirects), and let installed schema shadow the vocabulary term on the
  write path. Rejected suggestions keep their record, so the same term does
  not return.
  """

  import Ecto.Query, warn: false

  alias Ankole.Brain.Schemas.Object
  alias Ankole.Brain.Schemas.SchemaSuggestion
  alias Ankole.Brain.Schemas.SchemaType
  alias Ankole.Brain.Schemas.SlugAlias
  alias Ankole.Brain.Schemas.Tag
  alias Ankole.Ecto.UUIDv7
  alias Ankole.Repo

  @promoted_pack "promoted"

  @doc """
  Approves one pending suggestion and materializes it.
  """
  @spec approve(Ecto.UUID.t(), String.t(), map()) :: {:ok, map()} | {:error, term()}
  def approve(suggestion_id, decided_by, attrs \\ %{}) do
    Repo.transact(fn repo ->
      with {:ok, suggestion} <- fetch_pending(repo, suggestion_id) do
        result =
          case suggestion.kind do
            "new_type" -> materialize_type(repo, suggestion, attrs)
            "new_subtype" -> materialize_subtype(repo, suggestion, attrs)
            "alias" -> {:ok, %{status: :alias_noted}}
          end

        with {:ok, outcome} <- result,
             {:ok, _suggestion} <- decide(repo, suggestion, "approved", decided_by) do
          {:ok, outcome}
        end
      end
    end)
  end

  @doc """
  Rejects one pending suggestion; the record stays so the term is not
  suggested again.
  """
  @spec reject(Ecto.UUID.t(), String.t()) :: {:ok, SchemaSuggestion.t()} | {:error, term()}
  def reject(suggestion_id, decided_by) do
    Repo.transact(fn repo ->
      with {:ok, suggestion} <- fetch_pending(repo, suggestion_id) do
        decide(repo, suggestion, "rejected", decided_by)
      end
    end)
  end

  # A promoted term becomes a first-class type with its own slug prefix.
  # Objects tagged with the term retype and migrate their slugs; redirects
  # keep old references resolvable.
  defp materialize_type(repo, suggestion, attrs) do
    term = suggestion.term
    primitive = attrs[:primitive] || "concept"
    prefix = attrs[:slug_prefix] || pluralized_prefix(term)

    type = %SchemaType{
      id: UUIDv7.autogenerate(),
      name: term,
      primitive: primitive,
      slug_prefix: prefix,
      subtypes: [],
      extractable: attrs[:extractable] == true,
      expert_routing: false,
      pack_name: ensure_promoted_pack(repo),
      created_at: DateTime.utc_now(:microsecond)
    }

    with {:ok, _type} <- repo.insert(type) do
      migrated = retype_tagged_objects(repo, term, prefix)
      {:ok, %{status: :type_created, type: term, migrated: migrated}}
    end
  end

  defp materialize_subtype(repo, suggestion, attrs) do
    target = attrs[:target_type] || suggestion.target_type || "note"

    case repo.get_by(SchemaType, name: target) do
      nil ->
        {:error, {:unknown_target_type, target}}

      %SchemaType{} = type ->
        subtypes = Enum.uniq(type.subtypes ++ [suggestion.term])

        with {:ok, _type} <- repo.update(Ecto.Changeset.change(type, subtypes: subtypes)) do
          {:ok, %{status: :subtype_added, type: target, subtype: suggestion.term}}
        end
    end
  end

  defp retype_tagged_objects(repo, term, prefix) do
    objects =
      Object
      |> join(:inner, [object], tag in Tag, on: tag.object_slug == object.slug)
      |> where([_object, tag], tag.tag == ^term)
      |> where([object, _tag], is_nil(object.deleted_at))
      |> select([object, _tag], object)
      |> distinct(true)
      |> repo.all()

    Enum.count(objects, fn object ->
      new_slug = prefix <> last_slug_segment(object.slug)

      cond do
        object.slug == new_slug ->
          retype_only(repo, object, term)

        repo.exists?(Object |> where([o], o.slug == ^new_slug)) ->
          retype_only(repo, object, term)

        true ->
          {:ok, _object} =
            repo.update(
              Ecto.Changeset.change(object,
                type: term,
                slug: new_slug,
                updated_at: DateTime.utc_now(:microsecond)
              )
            )

          {:ok, _alias} =
            repo.insert(%SlugAlias{
              id: UUIDv7.autogenerate(),
              alias_slug: object.slug,
              canonical_slug: new_slug,
              notes: "vocabulary promotion of #{term}",
              created_at: DateTime.utc_now(:microsecond)
            })

          true
      end
    end)
  end

  defp retype_only(repo, object, term) do
    {:ok, _object} =
      repo.update(
        Ecto.Changeset.change(object, type: term, updated_at: DateTime.utc_now(:microsecond))
      )

    true
  end

  defp last_slug_segment(slug) do
    slug |> String.split("/") |> List.last()
  end

  defp pluralized_prefix(term), do: term <> "s/"

  # Promotions register under one synthetic pack record so the type table's
  # pack ownership stays total.
  defp ensure_promoted_pack(repo) do
    case repo.get_by(Ankole.Brain.Schemas.SchemaPack, name: @promoted_pack) do
      %Ankole.Brain.Schemas.SchemaPack{name: name} ->
        name

      nil ->
        repo.insert!(%Ankole.Brain.Schemas.SchemaPack{
          id: UUIDv7.autogenerate(),
          name: @promoted_pack,
          version: "0",
          content_hash: "promoted",
          manifest: %{"name" => @promoted_pack, "promoted" => true},
          installed_at: DateTime.utc_now(:microsecond)
        })

        @promoted_pack
    end
  end

  defp fetch_pending(repo, suggestion_id) do
    SchemaSuggestion
    |> where([suggestion], suggestion.id == ^suggestion_id)
    |> lock("FOR UPDATE")
    |> repo.one()
    |> case do
      %SchemaSuggestion{status: "pending"} = suggestion -> {:ok, suggestion}
      %SchemaSuggestion{} -> {:error, :suggestion_not_pending}
      nil -> {:error, :not_found}
    end
  end

  defp decide(repo, suggestion, status, decided_by) do
    suggestion
    |> Ecto.Changeset.change(
      status: status,
      decided_by: decided_by,
      decided_at: DateTime.utc_now(:microsecond)
    )
    |> repo.update()
  end
end
