defmodule Ankole.Brain.Links do
  @moduledoc """
  Relation edges, tags, and natural-language aliases of objects.

  Links widen relation-based recall candidates and never carry their own
  audience scope: the endpoint content keeps its own boundary. Aliases store
  one normalized form (NFKC, Unicode lowercase, folded whitespace) so lookup
  and volunteer matching agree on one text shape.
  """

  import Ecto.Query, warn: false

  alias Ankole.Brain.Objects
  alias Ankole.Brain.Schemas.Link
  alias Ankole.Brain.Schemas.ObjectAlias
  alias Ankole.Brain.Schemas.Tag
  alias Ankole.Ecto.UUIDv7
  alias Ankole.Repo

  @doc """
  Upserts one directed edge; the dedup key treats equal NULLs as equal, so
  one source form of one edge keeps one row.
  """
  @spec upsert_link(map(), keyword()) :: {:ok, Link.t() | :duplicate} | {:error, term()}
  def upsert_link(attrs, opts \\ []) when is_map(attrs) do
    repo = Keyword.get(opts, :repo, Repo)

    with {:ok, from_object} <- Objects.resolve_slug(attrs[:from_object_slug], repo: repo),
         {:ok, to_object} <- Objects.resolve_slug(attrs[:to_object_slug], repo: repo) do
      row = %Link{
        id: UUIDv7.autogenerate(),
        from_object_slug: from_object.slug,
        to_object_slug: to_object.slug,
        link_type: attrs[:link_type] || "",
        context: attrs[:context] || "",
        link_source: attrs[:link_source],
        link_kind: attrs[:link_kind],
        origin_object_slug: attrs[:origin_object_slug],
        origin_field: attrs[:origin_field],
        resolution_type: attrs[:resolution_type],
        created_at: DateTime.utc_now(:microsecond)
      }

      insert_distinct(repo, row)
    end
  end

  @doc """
  Adds one tag to one object idempotently.
  """
  @spec add_tag(String.t(), String.t(), keyword()) ::
          {:ok, Tag.t() | :duplicate} | {:error, term()}
  def add_tag(object_slug, tag, opts \\ []) when is_binary(tag) do
    repo = Keyword.get(opts, :repo, Repo)
    tag = String.trim(tag)

    with :ok <- if(tag == "", do: {:error, :blank_tag}, else: :ok),
         {:ok, object} <- Objects.resolve_slug(object_slug, repo: repo) do
      row = %Tag{
        id: UUIDv7.autogenerate(),
        object_slug: object.slug,
        tag: tag,
        created_at: DateTime.utc_now(:microsecond)
      }

      insert_distinct(repo, row)
    end
  end

  @doc """
  Adds one natural-language alias candidate for one object idempotently.
  """
  @spec add_alias(String.t(), String.t(), keyword()) ::
          {:ok, ObjectAlias.t() | :duplicate} | {:error, term()}
  def add_alias(object_slug, alias_text, opts \\ []) when is_binary(alias_text) do
    repo = Keyword.get(opts, :repo, Repo)
    normalized = normalize_alias(alias_text)

    with :ok <- if(normalized == "", do: {:error, :blank_alias}, else: :ok),
         {:ok, object} <- Objects.resolve_slug(object_slug, repo: repo) do
      row = %ObjectAlias{
        id: UUIDv7.autogenerate(),
        alias_norm: normalized,
        object_slug: object.slug,
        created_at: DateTime.utc_now(:microsecond)
      }

      insert_distinct(repo, row)
    end
  end

  defp insert_distinct(repo, %schema{} = row) do
    attrs = Map.take(row, schema.__schema__(:fields))

    case repo.insert_all(schema, [attrs], on_conflict: :nothing, returning: true) do
      {0, []} -> {:ok, :duplicate}
      {1, [inserted]} -> {:ok, inserted}
    end
  end

  @doc """
  Returns the candidate objects of one alias, deterministically ordered.
  Real-world names collide; readers must handle ambiguity explicitly.
  """
  @spec lookup_alias(String.t(), keyword()) :: [String.t()]
  def lookup_alias(alias_text, opts \\ []) do
    repo = Keyword.get(opts, :repo, Repo)
    normalized = normalize_alias(alias_text)

    ObjectAlias
    |> where([alias], alias.alias_norm == ^normalized)
    |> order_by([alias], asc: alias.object_slug)
    |> select([alias], alias.object_slug)
    |> repo.all()
  end

  @doc """
  Returns the object slugs whose normalized alias occurs inside one text.

  Matching runs in SQL so only hits leave the database; volunteer pointers
  call this on every Text Turn, and shipping the whole alias table to the
  application per call would not survive alias growth. The text normalizes
  with the same rule as stored aliases, so containment here and exact
  lookup agree on one text shape.
  """
  @spec match_aliases_in_text(String.t(), keyword()) :: [String.t()]
  def match_aliases_in_text(text, opts \\ []) when is_binary(text) do
    repo = Keyword.get(opts, :repo, Repo)
    normalized = normalize_alias(text)

    if normalized == "" do
      []
    else
      ObjectAlias
      |> where([alias], fragment("strpos(?, ?) > 0", ^normalized, alias.alias_norm))
      |> select([alias], alias.object_slug)
      |> distinct(true)
      |> order_by([alias], asc: alias.object_slug)
      |> repo.all()
    end
  end

  @doc """
  Normalizes an alias: NFKC, Unicode lowercase, folded whitespace.
  """
  @spec normalize_alias(String.t()) :: String.t()
  def normalize_alias(text) when is_binary(text) do
    text
    |> String.normalize(:nfkc)
    |> String.downcase()
    |> String.replace(~r/\s+/u, " ")
    |> String.trim()
  end
end
