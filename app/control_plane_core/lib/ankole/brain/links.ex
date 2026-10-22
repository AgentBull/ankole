defmodule Ankole.Brain.Links do
  @moduledoc """
  Relation edges, tags, and natural-language aliases of objects.

  Links widen relation-based recall candidates and never carry their own
  audience scope: the endpoint content keeps its own boundary. Aliases store
  one normalized form (NFKC, Unicode lowercase, folded whitespace) so lookup
  and volunteer matching agree on one text shape.
  """

  require Ash.Query

  alias Ankole.Brain.Objects
  alias Ankole.Brain.Markdoc
  alias Ankole.Brain.Schemas.Link
  alias Ankole.Brain.Schemas.ObjectAlias
  alias Ankole.Brain.Schemas.Tag
  alias Ankole.Repo

  @doc "Returns the object's tags in canonical order."
  def tags_for_object(slug) do
    Tag
    |> Ash.Query.filter(object_slug == ^slug)
    |> Ash.Query.sort(tag: :asc)
    |> Ankole.Ash.read!()
    |> Enum.map(& &1.tag)
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
    with :ok <- Repo.require_transaction(repo),
         {:ok, _removed} <-
           Tag
           |> Ash.Query.filter(object_slug == ^slug and tag not in ^tags)
           |> Ankole.Ash.destroy_where(:remove) do
      Enum.reduce_while(tags, :ok, fn tag, :ok ->
        case Ankole.Ash.create(Tag, :add, %{object_slug: slug, tag: tag}) do
          {:ok, _tag} -> {:cont, :ok}
          {:error, _error} = error -> {:halt, error}
        end
      end)
    end
  end

  @doc """
  Reconciles body-owned Markdown and alias edges without a model, in the
  caller's transaction. The `:reconcile_object_links` action of
  `Ankole.Brain.Schemas.Object` owns the transaction of a single reconcile.
  """
  def reconcile_object_links_in_tx(slug) do
    with :ok <- Repo.require_transaction(Repo),
         {:ok, object} <- Objects.lock_object_in_tx(Repo, slug),
         true <- is_nil(object.deleted_at) do
      wikilinks =
        Enum.map(Markdoc.wikilinks(object.body), &{&1, "", "markdown", nil, "qualified"})

      mentions =
        object.body
        |> match_aliases_in_text()
        |> Enum.reject(&(&1 == slug))
        |> Enum.map(&{&1, "mentions", "mentions", "plain", "unqualified"})

      with {:ok, keys} <- insert_body_links(slug, wikilinks ++ mentions),
           :ok <- remove_stale_body_links(slug, keys),
           {:ok, _} <- Ankole.Ash.update(object, :stamp_links, %{}) do
        {:ok, object}
      end
    else
      false -> {:error, :object_deleted}
      error -> error
    end
  end

  defp insert_body_links(slug, links) do
    Enum.reduce_while(links, {:ok, MapSet.new()}, fn {target, type, source, kind, resolution},
                                                     {:ok, keys} ->
      result =
        with {:ok, target} <- Objects.resolve_slug(target),
             {:ok, _} <-
               upsert_link(%{
                 from_object_slug: slug,
                 to_object_slug: target.slug,
                 link_type: type,
                 link_source: source,
                 link_kind: kind,
                 origin_object_slug: slug,
                 origin_field: "body",
                 resolution_type: resolution
               }) do
          {:ok, {target.slug, type, source}}
        end

      case result do
        {:ok, key} -> {:cont, {:ok, MapSet.put(keys, key)}}
        {:error, :not_found} -> {:cont, {:ok, keys}}
      end
    end)
  end

  defp remove_stale_body_links(slug, keys) do
    stale_ids =
      Link
      |> Ash.Query.filter(
        origin_object_slug == ^slug and origin_field == "body" and
          link_source in ["markdown", "mentions"]
      )
      |> Ankole.Ash.read!()
      |> Enum.reject(&MapSet.member?(keys, {&1.to_object_slug, &1.link_type, &1.link_source}))
      |> Enum.map(& &1.id)

    case Link
         |> Ash.Query.filter(id in ^stale_ids)
         |> Ankole.Ash.destroy_where(:remove) do
      {:ok, _removed} -> :ok
      {:error, _error} = error -> error
    end
  end

  @doc """
  Upserts one directed edge; the dedup key treats equal NULLs as equal, so
  one source form of one edge keeps one row.
  """
  @spec upsert_link(map()) :: {:ok, Link.t() | :duplicate} | {:error, term()}
  def upsert_link(attrs) when is_map(attrs) do
    with {:ok, from_object} <- Objects.resolve_slug(attrs[:from_object_slug]),
         {:ok, to_object} <- Objects.resolve_slug(attrs[:to_object_slug]) do
      row = %{
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

      insert_distinct(Link, row)
    end
  end

  @doc """
  Adds one natural-language alias candidate for one object idempotently.
  """
  @spec add_alias(String.t(), String.t()) ::
          {:ok, ObjectAlias.t() | :duplicate} | {:error, term()}
  def add_alias(object_slug, alias_text) when is_binary(alias_text) do
    normalized = normalize_alias(alias_text)

    with :ok <- if(normalized == "", do: {:error, :blank_alias}, else: :ok),
         {:ok, object} <- Objects.resolve_slug(object_slug) do
      row = %{
        alias_norm: normalized,
        object_slug: object.slug,
        created_at: DateTime.utc_now(:microsecond)
      }

      insert_distinct(ObjectAlias, row)
    end
  end

  defp insert_distinct(schema, attrs) do
    case Ankole.Ash.insert_if_absent(schema, :add, attrs) do
      {:ok, inserted, :created} -> {:ok, inserted}
      {:ok, _existing, :existing} -> {:ok, :duplicate}
      {:error, _error} = error -> error
    end
  end

  @doc """
  Returns the candidate objects of one alias, deterministically ordered.
  Real-world names collide; readers must handle ambiguity explicitly.
  """
  @spec lookup_alias(String.t()) :: [String.t()]
  def lookup_alias(alias_text) do
    normalized = normalize_alias(alias_text)

    ObjectAlias
    |> Ash.Query.filter(alias_norm == ^normalized)
    |> Ash.Query.sort(object_slug: :asc)
    |> Ankole.Ash.read!()
    |> Enum.map(& &1.object_slug)
  end

  @doc """
  Returns the object slugs whose normalized alias occurs inside one text.

  Matching runs in SQL so only hits leave the database; volunteer pointers
  call this on every Text Turn, and shipping the whole alias table to the
  application per call would not survive alias growth. The text normalizes
  with the same rule as stored aliases, so containment here and exact
  lookup agree on one text shape.
  """
  @spec match_aliases_in_text(String.t()) :: [String.t()]
  def match_aliases_in_text(text) when is_binary(text) do
    normalized = normalize_alias(text)

    if normalized == "" do
      []
    else
      ObjectAlias
      |> Ash.Query.filter(fragment("strpos(?, ?) > 0", ^normalized, alias_norm))
      |> Ash.Query.sort(object_slug: :asc)
      |> Ash.Query.distinct([:object_slug])
      |> Ash.Query.select([:object_slug])
      |> Ankole.Ash.read!()
      |> Enum.map(& &1.object_slug)
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
