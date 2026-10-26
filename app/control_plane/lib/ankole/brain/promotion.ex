defmodule Ankole.Brain.Promotion do
  @moduledoc """
  Console-reviewed materialization of vocabulary promotion suggestions.

  Approval runs one transaction: register the new type or subtype, retype
  the existing objects (type rewrite plus slug-prefix migration with
  redirects), and let installed schema shadow the vocabulary term on the
  write path. Rejected suggestions keep their record, so the same term does
  not return. A generic action on `Ankole.Brain.Schemas.SchemaSuggestion`
  owns the transaction of each decision.
  """

  require Ash.Query

  alias Ankole.Brain.Objects
  alias Ankole.Brain.Schemas.Object
  alias Ankole.Brain.Schemas.SchemaSuggestion
  alias Ankole.Brain.Schemas.SchemaType
  alias Ankole.Brain.Schemas.SlugAlias
  alias Ankole.Ecto.UUIDv7
  alias Ankole.Repo

  @library_projection_type "agent-skills"
  @lazy_skill_prefix "lazyload-agent-skills/"

  @doc """
  Approves one pending suggestion and materializes it in the caller's
  transaction.
  """
  @spec approve_in_tx(Ecto.UUID.t(), Ankole.ActorRef.t(), map()) ::
          {:ok, map()} | {:error, term()}
  def approve_in_tx(suggestion_id, decided_by, attrs) do
    with :ok <- Repo.require_transaction(),
         {:ok, suggestion} <- fetch_pending(suggestion_id) do
      result =
        case suggestion.kind do
          :new_type -> materialize_type(suggestion, attrs)
          :new_subtype -> materialize_subtype(suggestion, attrs)
          :alias -> {:ok, %{status: :alias_noted}}
        end

      with {:ok, outcome} <- result,
           {:ok, _suggestion} <-
             Ankole.Ash.update(suggestion, :approve, %{decided_by: decided_by}) do
        {:ok, outcome}
      end
    end
  end

  @doc """
  Rejects one pending suggestion in the caller's transaction; the record
  stays so the term is not suggested again.
  """
  @spec reject_in_tx(Ecto.UUID.t(), Ankole.ActorRef.t()) ::
          {:ok, SchemaSuggestion.t()} | {:error, term()}
  def reject_in_tx(suggestion_id, decided_by) do
    with :ok <- Repo.require_transaction(),
         {:ok, suggestion} <- fetch_pending(suggestion_id) do
      Ankole.Ash.update(suggestion, :reject, %{decided_by: decided_by})
    end
  end

  # A promoted term becomes a first-class type with its own slug prefix.
  # Objects tagged with the term retype and migrate their slugs; redirects
  # keep old references resolvable.
  defp materialize_type(suggestion, attrs) do
    term = suggestion.term
    primitive = attrs[:primitive] || "concept"
    prefix = attrs[:slug_prefix] || pluralized_prefix(term)

    with :ok <- reject_reserved_type(term),
         :ok <- reject_reserved_prefix(prefix),
         {:ok, pack} <- Ankole.Ash.create(Ankole.Brain.Schemas.SchemaPack, :ensure_promoted, %{}),
         type = %{
           id: UUIDv7.autogenerate(),
           name: term,
           primitive: primitive,
           slug_prefix: prefix,
           subtypes: [],
           extractable: attrs[:extractable] == true,
           expert_routing: false,
           pack_name: pack.name,
           created_at: DateTime.utc_now(:microsecond)
         },
         {:ok, _type} <- Ankole.Ash.create(SchemaType, :register, type) do
      migrated = retype_tagged_objects(term, prefix)
      {:ok, %{status: :type_created, type: term, migrated: migrated}}
    end
  end

  defp materialize_subtype(suggestion, attrs) do
    target = attrs[:target_type] || suggestion.target_type || "note"

    with :ok <- reject_reserved_type(target) do
      case Ankole.Ash.read_one!(Ash.Query.filter(SchemaType, name == ^target)) do
        nil ->
          {:error, {:unknown_target_type, target}}

        %SchemaType{} = type ->
          with {:ok, _type} <-
                 Ankole.Ash.update(type, :add_subtypes, %{subtypes: [suggestion.term]}) do
            {:ok, %{status: :subtype_added, type: target, subtype: suggestion.term}}
          end
      end
    end
  end

  defp reject_reserved_type(type) when type in [@library_projection_type, "agent"],
    do: {:error, {:reserved_object_type, type}}

  defp reject_reserved_type(_type), do: :ok

  defp reject_reserved_prefix(@lazy_skill_prefix <> _rest = prefix),
    do: {:error, {:reserved_object_slug_prefix, prefix}}

  defp reject_reserved_prefix("agents/" <> _rest = prefix),
    do: {:error, {:reserved_object_slug_prefix, prefix}}

  defp reject_reserved_prefix(_prefix), do: :ok

  # The canonical page of a Principal keeps its type and slug.
  defp retype_tagged_objects(term, prefix) do
    objects =
      Object
      |> Ash.Query.filter(
        exists(tags, tag == ^term) and is_nil(deleted_at) and is_nil(managed_by_source_id) and
          type != "agent"
      )
      |> Ankole.Ash.read!()
      |> Enum.reject(&Objects.canonical_principal_page?(&1.slug))

    Enum.count(objects, fn object ->
      new_slug = prefix <> last_slug_segment(object.slug)

      cond do
        object.slug == new_slug ->
          retype_only(object, term)

        slug_taken?(new_slug) ->
          retype_only(object, term)

        true ->
          {:ok, _object} =
            Ankole.Ash.update(object, :retype, %{type: term, slug: new_slug})

          {:ok, _alias} =
            Ankole.Ash.create(SlugAlias, :add, %{
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

  defp slug_taken?(slug) do
    Object
    |> Ash.Query.filter(slug == ^slug)
    |> Ankole.Ash.exists?()
  end

  defp retype_only(object, term) do
    {:ok, _object} =
      Ankole.Ash.update(object, :retype, %{type: term})

    true
  end

  defp last_slug_segment(slug) do
    slug |> String.split("/") |> List.last()
  end

  defp pluralized_prefix(term), do: term <> "s/"

  defp fetch_pending(suggestion_id) do
    SchemaSuggestion
    |> Ash.Query.filter(id == ^suggestion_id)
    |> Ash.Query.lock(:for_update)
    |> Ankole.Ash.read_one!()
    |> case do
      %SchemaSuggestion{status: :pending} = suggestion -> {:ok, suggestion}
      %SchemaSuggestion{} -> {:error, :suggestion_not_pending}
      nil -> {:error, :not_found}
    end
  end
end
