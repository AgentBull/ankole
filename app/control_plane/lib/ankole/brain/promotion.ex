defmodule Ankole.Brain.Promotion do
  @moduledoc """
  Console-reviewed materialization of vocabulary promotion suggestions.

  Approval runs one transaction: register the new type or subtype, retype
  the existing knowledge pages through their metadata, and let installed schema shadow the vocabulary term on the
  write path. Rejected suggestions keep their record, so the same term does
  not return. A generic action on `Ankole.Brain.Schemas.SchemaSuggestion`
  owns the transaction of each decision.
  """

  require Ash.Query

  alias Ankole.Brain.Objects
  alias Ankole.Brain.Schemas.Page, as: Object
  alias Ankole.Brain.Schemas.SchemaSuggestion
  alias Ankole.Brain.Schemas.SchemaType
  alias Ankole.Ecto.UUIDv7
  alias Ankole.Repo

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
          :new_type -> materialize_type(suggestion, Map.put(attrs, :decided_by, decided_by))
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
  # Tagged pages adopt the type without moving their human-owned directories.
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
         {:ok, _type} <- Ankole.Ash.create(SchemaType, :register, type),
         :ok <- Ankole.Brain.Namespace.ensure_categories_in_tx() do
      migrated = retype_tagged_objects(term, attrs.decided_by)
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

  defp reject_reserved_type(type) when type in ["agent", "skill"],
    do: {:error, {:reserved_object_type, type}}

  defp reject_reserved_type(_type), do: :ok

  defp reject_reserved_prefix("agents/" <> _rest = prefix),
    do: {:error, {:reserved_object_slug_prefix, prefix}}

  defp reject_reserved_prefix(_prefix), do: :ok

  # Vocabulary classification changes page metadata; the human-owned location stays stable.
  defp retype_tagged_objects(term, decided_by) do
    ids =
      Ankole.Brain.Schemas.Tag
      |> Ash.Query.filter(tag == ^term)
      |> Ankole.Ash.read!()
      |> Enum.map(& &1.subject_page_id)

    Object
    |> Ash.Query.filter(
      id in ^ids and is_nil(deleted_at) and is_nil(managed_by_source_id) and
        type != "agent"
    )
    |> Ankole.Ash.read!()
    |> Enum.reject(&Objects.canonical_principal_page?(&1.id))
    |> Enum.count(fn page ->
      {:ok, _} = Objects.update_object_in_tx(page.id, %{type: term}, :system, author: decided_by)
      true
    end)
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
