defmodule Ankole.Brain.LazySkillVisibility do
  @moduledoc """
  Resolves the current Agent's visible lazy Skill projection and applies it
  before Brain candidate selection. Non-Agent administrative queriers see the
  complete projection.
  """

  import Ecto.Query, warn: false

  alias Ankole.AIAgent.Library
  alias Ankole.Principals.Agent
  alias Ankole.Repo

  @object_type "agent-skills"
  @slug_prefix "lazyload-agent-skills/"
  @slug_pattern @slug_prefix <> "%"

  defstruct slugs: :all

  @type t :: %__MODULE__{slugs: :all | [String.t()]}

  @spec for_querier(String.t(), keyword()) :: {:ok, t()} | {:error, term()}
  def for_querier(querier_uid, opts \\ []) do
    repo = Keyword.get(opts, :repo, Repo)

    case repo.get(Agent, querier_uid) do
      nil ->
        {:ok, %__MODULE__{}}

      %Agent{} ->
        with {:ok, skills} <- Library.enabled_skills_for_agent(querier_uid, opts) do
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

  @spec filter_objects(Ecto.Queryable.t(), t()) :: Ecto.Query.t()
  def filter_objects(query, %__MODULE__{slugs: :all}), do: query

  def filter_objects(query, %__MODULE__{slugs: slugs}) do
    where(query, [object, ...], object.type != @object_type or object.slug in ^slugs)
  end

  @spec filter_chunks(Ecto.Queryable.t(), t()) :: Ecto.Query.t()
  def filter_chunks(query, %__MODULE__{slugs: :all}), do: query

  def filter_chunks(query, %__MODULE__{slugs: slugs}) do
    where(query, [_chunk, object, ...], object.type != @object_type or object.slug in ^slugs)
  end

  @spec filter_claims(Ecto.Queryable.t(), t()) :: Ecto.Query.t()
  def filter_claims(query, %__MODULE__{slugs: :all}), do: query

  def filter_claims(query, %__MODULE__{slugs: slugs}) do
    where(
      query,
      [claim, ...],
      is_nil(claim.object_slug) or not like(claim.object_slug, ^@slug_pattern) or
        claim.object_slug in ^slugs
    )
  end

  @spec filter_links(Ecto.Queryable.t(), t()) :: Ecto.Query.t()
  def filter_links(query, %__MODULE__{slugs: :all}), do: query

  def filter_links(query, %__MODULE__{slugs: slugs}) do
    where(
      query,
      [link, ...],
      (not like(link.from_object_slug, ^@slug_pattern) or link.from_object_slug in ^slugs) and
        (not like(link.to_object_slug, ^@slug_pattern) or link.to_object_slug in ^slugs)
    )
  end

  @spec filter_timelines(Ecto.Queryable.t(), t()) :: Ecto.Query.t()
  def filter_timelines(query, %__MODULE__{slugs: :all}), do: query

  def filter_timelines(query, %__MODULE__{slugs: slugs}) do
    where(
      query,
      [timeline, ...],
      not like(timeline.object_slug, ^@slug_pattern) or timeline.object_slug in ^slugs
    )
  end
end
