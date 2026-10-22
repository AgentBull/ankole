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
  require Ash.Query

  alias Ankole.Brain.Schemas.Object
  alias Ankole.Brain.Schemas.SchemaSuggestion
  alias Ankole.Brain.Schemas.SchemaType
  alias Ankole.Brain.Schemas.SlugAlias
  alias Ankole.Brain.Schemas.Tag
  alias Ankole.Ecto.UUIDv7
  alias Ankole.Principals.Principal
  alias Ankole.Repo

  @library_projection_type "agent-skills"
  @lazy_skill_prefix "lazyload-agent-skills/"

  @doc "Lists promotion suggestions for the Console read model."
  @spec list_for_console(String.t(), keyword()) ::
          {:ok, [SchemaSuggestion.t()]} | {:error, term()}
  def list_for_console(status, opts) when is_binary(status) and is_list(opts) do
    limit = Keyword.fetch!(opts, :limit)

    SchemaSuggestion
    |> Ash.Query.filter(status == ^status)
    |> Ash.Query.sort(created_at: :desc)
    |> Ash.Query.limit(limit)
    |> Ankole.Ash.read()
  end

  @doc """
  Approves one pending suggestion and materializes it.
  """
  @spec approve(Ecto.UUID.t(), Ankole.ActorRef.t(), map()) :: {:ok, map()} | {:error, term()}
  def approve(suggestion_id, decided_by, attrs \\ %{}) do
    Repo.transact(fn repo ->
      with {:ok, suggestion} <- fetch_pending(repo, suggestion_id) do
        result =
          case suggestion.kind do
            :new_type -> materialize_type(repo, suggestion, attrs)
            :new_subtype -> materialize_subtype(repo, suggestion, attrs)
            :alias -> {:ok, %{status: :alias_noted}}
          end

        with {:ok, outcome} <- result,
             {:ok, _suggestion} <-
               Ankole.Ash.update(suggestion, :approve, %{decided_by: decided_by}) do
          {:ok, outcome}
        end
      end
    end)
  end

  @doc """
  Rejects one pending suggestion; the record stays so the term is not
  suggested again.
  """
  @spec reject(Ecto.UUID.t(), Ankole.ActorRef.t()) ::
          {:ok, SchemaSuggestion.t()} | {:error, term()}
  def reject(suggestion_id, decided_by) do
    Repo.transact(fn repo ->
      with {:ok, suggestion} <- fetch_pending(repo, suggestion_id) do
        Ankole.Ash.update(suggestion, :reject, %{decided_by: decided_by})
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
      migrated = retype_tagged_objects(repo, term, prefix)
      {:ok, %{status: :type_created, type: term, migrated: migrated}}
    end
  end

  defp materialize_subtype(_repo, suggestion, attrs) do
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

  defp retype_tagged_objects(repo, term, prefix) do
    objects =
      Object
      |> join(:inner, [object], tag in Tag,
        on: tag.tenant_id == object.tenant_id and tag.object_slug == object.slug
      )
      |> join(:left, [object, _tag], principal in Principal,
        on:
          principal.tenant_id == object.tenant_id and principal.type == :human and
            object.slug == fragment("'people/' || ?", principal.uid)
      )
      |> where([_object, tag, _principal], tag.tag == ^term)
      |> where([object, _tag, _principal], is_nil(object.deleted_at))
      |> where([object, _tag, _principal], is_nil(object.managed_by_source_id))
      |> where([object, _tag, principal], object.type != "agent" and is_nil(principal.uid))
      |> select([object, _tag, _principal], object)
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

  defp retype_only(_repo, object, term) do
    {:ok, _object} =
      Ankole.Ash.update(object, :retype, %{type: term})

    true
  end

  defp last_slug_segment(slug) do
    slug |> String.split("/") |> List.last()
  end

  defp pluralized_prefix(term), do: term <> "s/"

  defp fetch_pending(repo, suggestion_id) do
    SchemaSuggestion
    |> where([suggestion], suggestion.id == ^suggestion_id)
    |> lock("FOR UPDATE")
    |> repo.one()
    |> case do
      %SchemaSuggestion{status: :pending} = suggestion -> {:ok, suggestion}
      %SchemaSuggestion{} -> {:error, :suggestion_not_pending}
      nil -> {:error, :not_found}
    end
  end
end
