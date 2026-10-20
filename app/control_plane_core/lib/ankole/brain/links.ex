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
  alias Ankole.Brain.Markdoc
  alias Ankole.Brain.Schemas.Link
  alias Ankole.Brain.Schemas.ObjectAlias
  alias Ankole.Brain.Schemas.Tag
  alias Ankole.Ecto.UUIDv7
  alias Ankole.Repo

  @doc "Returns the object's tags in canonical order."
  def tags_for_object(slug, opts \\ []) do
    repo = Keyword.get(opts, :repo, Repo)

    Tag
    |> where([tag], tag.object_slug == ^slug)
    |> order_by([tag], asc: tag.tag)
    |> select([tag], tag.tag)
    |> repo.all()
    |> Enum.sort()
  end

  @doc false
  def normalize_tags(tags) when is_list(tags) do
    if Enum.all?(tags, &(is_binary(&1) and String.trim(&1) != "")),
      do: {:ok, tags |> Enum.map(&String.trim/1) |> Enum.uniq() |> Enum.sort()},
      else: {:error, {:invalid, "tags"}}
  end

  def normalize_tags(_tags), do: {:error, {:invalid, "tags"}}

  @doc false
  def replace_tags_in_tx(repo, slug, tags) do
    with :ok <- Repo.require_transaction(repo) do
      Tag
      |> where([tag], tag.object_slug == ^slug and tag.tag not in ^tags)
      |> repo.delete_all()

      now = DateTime.utc_now(:microsecond)

      rows =
        Enum.map(tags, fn tag ->
          %{
            id: UUIDv7.autogenerate(),
            tenant_id: Repo.tenant_id!(),
            object_slug: slug,
            tag: tag,
            created_at: now
          }
        end)

      repo.insert_all(Tag, rows, on_conflict: :nothing)
      :ok
    end
  end

  @doc "Reconciles body-owned Markdown and alias edges without a model."
  def reconcile_object_links(slug, opts \\ []) do
    repo = Keyword.get(opts, :repo, Repo)

    repo.transact(fn repo ->
      with {:ok, object} <- Objects.lock_object_in_tx(repo, slug),
           true <- is_nil(object.deleted_at) do
        wikilinks =
          Enum.map(Markdoc.wikilinks(object.body), &{&1, "", "markdown", nil, "qualified"})

        mentions =
          object.body
          |> match_aliases_in_text(repo: repo)
          |> Enum.reject(&(&1 == slug))
          |> Enum.map(&{&1, "mentions", "mentions", "plain", "unqualified"})

        with {:ok, keys} <- insert_body_links(repo, slug, wikilinks ++ mentions),
             :ok <- remove_stale_body_links(repo, slug, keys),
             {:ok, _} <-
               repo.update(Ecto.Changeset.change(object, links_extracted_at: object.updated_at)) do
          {:ok, object}
        end
      else
        false -> {:error, :object_deleted}
        error -> error
      end
    end)
  end

  defp insert_body_links(repo, slug, links) do
    Enum.reduce_while(links, {:ok, MapSet.new()}, fn {target, type, source, kind, resolution},
                                                     {:ok, keys} ->
      result =
        with {:ok, target} <- Objects.resolve_slug(target, repo: repo),
             {:ok, _} <-
               upsert_link(
                 %{
                   from_object_slug: slug,
                   to_object_slug: target.slug,
                   link_type: type,
                   link_source: source,
                   link_kind: kind,
                   origin_object_slug: slug,
                   origin_field: "body",
                   resolution_type: resolution
                 },
                 repo: repo
               ) do
          {:ok, {target.slug, type, source}}
        end

      case result do
        {:ok, key} -> {:cont, {:ok, MapSet.put(keys, key)}}
        {:error, :not_found} -> {:cont, {:ok, keys}}
      end
    end)
  end

  defp remove_stale_body_links(repo, slug, keys) do
    stale_ids =
      Link
      |> where(
        [link],
        link.origin_object_slug == ^slug and link.origin_field == "body" and
          link.link_source in ["markdown", "mentions"]
      )
      |> repo.all()
      |> Enum.reject(&MapSet.member?(keys, {&1.to_object_slug, &1.link_type, &1.link_source}))
      |> Enum.map(& &1.id)

    Link |> where([link], link.id in ^stale_ids) |> repo.delete_all()
    :ok
  end

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
    attrs = row |> Map.take(schema.__schema__(:fields)) |> Map.put(:tenant_id, Repo.tenant_id!())

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
