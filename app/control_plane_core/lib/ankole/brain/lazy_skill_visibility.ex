defmodule Ankole.Brain.LazySkillVisibility do
  @moduledoc """
  Resolves the current Agent's visible lazy Skill projection and applies it
  before Brain candidate selection. Non-Agent administrative queriers see the
  complete projection.

  Each filter takes an Ash query. The Ecto form of the Claim, Chunk, and Link
  filters serves only the candidate queries of `Ankole.Brain.Recall` (M9
  retrieval).
  """

  import Ecto.Query, warn: false
  require Ash.Query

  alias Ankole.AIAgent.Library

  @object_type "agent-skills"
  @slug_prefix "lazyload-agent-skills/"
  @slug_pattern @slug_prefix <> "%"

  defstruct slugs: :all

  @type t :: %__MODULE__{slugs: :all | [String.t()]}

  @spec for_querier(String.t(), keyword()) :: {:ok, t()} | {:error, term()}
  def for_querier(querier_uid, opts \\ []) do
    case Ankole.Principals.get_agent(querier_uid) do
      {:error, _not_an_agent} ->
        {:ok, %__MODULE__{}}

      # The Turn's context resolution already synced the Skill rows, so every
      # Brain read of the same Turn reads them without another sync.
      {:ok, _agent} ->
        with {:ok, skills} <-
               Library.enabled_skills_for_agent(querier_uid, Keyword.put(opts, :sync, false)) do
          slugs =
            skills
            |> Enum.filter(&((&1["metadata"] || %{})["brain_recall_only"] == true))
            |> Enum.map(&(@slug_prefix <> &1["skill_name"]))

          {:ok, %__MODULE__{slugs: slugs}}
        end
    end
  end

  @spec visible?(t(), String.t()) :: boolean()
  def visible?(%__MODULE__{slugs: :all}, _slug), do: true

  def visible?(%__MODULE__{slugs: slugs}, @slug_prefix <> _rest = slug),
    do: slug in slugs

  def visible?(%__MODULE__{}, _slug), do: true

  @doc "Returns whether a recall record is lazy Skill discovery metadata."
  @spec skill_record?(map() | String.t()) :: boolean()
  def skill_record?(%{type: @object_type}), do: true
  def skill_record?(%{object_slug: slug}), do: skill_record?(slug)
  def skill_record?(@slug_prefix <> _rest), do: true
  def skill_record?(_record), do: false

  @spec filter_objects(Ash.Query.t(), t()) :: Ash.Query.t()
  def filter_objects(query, %__MODULE__{slugs: :all}), do: query

  def filter_objects(%Ash.Query{} = query, %__MODULE__{slugs: slugs}) do
    Ash.Query.filter(query, type != @object_type or slug in ^slugs)
  end

  @spec filter_chunks(query, t()) :: query when query: Ash.Query.t() | Ecto.Query.t()
  def filter_chunks(query, %__MODULE__{slugs: :all}), do: query

  def filter_chunks(%Ash.Query{} = query, %__MODULE__{slugs: slugs}) do
    Ash.Query.filter(query, object.type != @object_type or object.slug in ^slugs)
  end

  def filter_chunks(query, %__MODULE__{slugs: slugs}) do
    where(query, [_chunk, object, ...], object.type != @object_type or object.slug in ^slugs)
  end

  @spec filter_claims(query, t()) :: query when query: Ash.Query.t() | Ecto.Query.t()
  def filter_claims(query, %__MODULE__{slugs: :all}), do: query

  def filter_claims(%Ash.Query{} = query, %__MODULE__{slugs: slugs}) do
    Ash.Query.filter(
      query,
      is_nil(object_slug) or not string_starts_with(object_slug, @slug_prefix) or
        object_slug in ^slugs
    )
  end

  def filter_claims(query, %__MODULE__{slugs: slugs}) do
    where(
      query,
      [claim, ...],
      is_nil(claim.object_slug) or not like(claim.object_slug, ^@slug_pattern) or
        claim.object_slug in ^slugs
    )
  end

  @spec filter_links(query, t()) :: query when query: Ash.Query.t() | Ecto.Query.t()
  def filter_links(query, %__MODULE__{slugs: :all}), do: query

  def filter_links(%Ash.Query{} = query, %__MODULE__{slugs: slugs}) do
    Ash.Query.filter(
      query,
      (not string_starts_with(from_object_slug, @slug_prefix) or from_object_slug in ^slugs) and
        (not string_starts_with(to_object_slug, @slug_prefix) or to_object_slug in ^slugs)
    )
  end

  def filter_links(query, %__MODULE__{slugs: slugs}) do
    where(
      query,
      [link, ...],
      (not like(link.from_object_slug, ^@slug_pattern) or link.from_object_slug in ^slugs) and
        (not like(link.to_object_slug, ^@slug_pattern) or link.to_object_slug in ^slugs)
    )
  end

  @spec filter_timelines(Ash.Query.t(), t()) :: Ash.Query.t()
  def filter_timelines(query, %__MODULE__{slugs: :all}), do: query

  def filter_timelines(%Ash.Query{} = query, %__MODULE__{slugs: slugs}) do
    Ash.Query.filter(
      query,
      not string_starts_with(object_slug, @slug_prefix) or object_slug in ^slugs
    )
  end
end
