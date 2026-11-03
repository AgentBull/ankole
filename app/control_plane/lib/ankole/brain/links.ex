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
  alias Ankole.Brain.Schemas.Link
  alias Ankole.Brain.Schemas.ObjectAlias
  alias Ankole.Brain.Schemas.Tag
  alias Ankole.Repo

  @doc "Returns the object's tags in canonical order."
  def tags_for_object(slug) do
    Tag
    |> Ash.Query.filter(subject_page_id == ^slug)
    |> Ash.Query.sort(tag: :asc)
    |> Ankole.Ash.read!()
    |> Enum.map(& &1.tag)
  end

  @doc false
  def replace_tags_in_tx(slug, tags) do
    with :ok <- Repo.require_transaction(),
         {:ok, _removed} <-
           Tag
           |> Ash.Query.filter(subject_page_id == ^slug and tag not in ^tags)
           |> Ankole.Ash.destroy_where(:remove) do
      Enum.reduce_while(tags, :ok, fn tag, :ok ->
        case Ankole.Ash.create(Tag, :add, %{subject_page_id: slug, tag: tag}) do
          {:ok, _tag} -> {:cont, :ok}
          {:error, _error} = error -> {:halt, error}
        end
      end)
    end
  end

  @doc "Synchronizes typed page references from XML and business metadata."
  def reconcile_object_links_in_tx(reference) do
    with {:ok, page} <- Objects.get_by_slug(reference),
         :ok <- reconcile_metadata_in_tx(page) do
      targets =
        (Regex.scan(~r/<mention\b[^>]*\bpage="([^"]+)"/, page.xml || "", capture: :all_but_first)
         |> List.flatten()) ++ metadata_references(page.meta)

      {:ok, _} =
        Link
        |> Ash.Query.filter(origin_page_id == ^page.id and link_source == "page")
        |> Ankole.Ash.destroy_where(:remove)

      Enum.reduce_while(Enum.uniq(targets), {:ok, page}, fn target, result ->
        case Objects.get_by_slug(target) do
          {:ok, target} ->
            case Ankole.Ash.create(Link, :add, %{
                   from_page_id: page.id,
                   to_page_id: target.id,
                   origin_page_id: page.id,
                   link_source: "page",
                   link_type: "references",
                   origin_field: "content"
                 }) do
              {:ok, _} -> {:cont, result}
              error -> {:halt, error}
            end

          {:error, :not_found} ->
            {:cont, result}
        end
      end)
    end
  end

  defp reconcile_metadata_in_tx(page) do
    with tags = metadata_names(Map.get(page.meta, "tags", [])),
         aliases = metadata_names(Map.get(page.meta, "aliases", [])),
         :ok <- replace_tags_in_tx(page.id, tags),
         normalized = Enum.map(aliases, &normalize_alias/1),
         {:ok, _} <-
           ObjectAlias
           |> Ash.Query.filter(subject_page_id == ^page.id and alias_norm not in ^normalized)
           |> Ankole.Ash.destroy_where(:remove) do
      Enum.reduce_while(normalized, :ok, fn name, :ok ->
        case Ankole.Ash.create(ObjectAlias, :add, %{subject_page_id: page.id, alias_norm: name}) do
          {:ok, _} -> {:cont, :ok}
          error -> {:halt, error}
        end
      end)
    end
  end

  defp metadata_names(value) when is_binary(value), do: metadata_names([value])

  defp metadata_names(values) when is_list(values),
    do:
      values
      |> Enum.filter(&is_binary/1)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.uniq()

  defp metadata_names(_), do: []

  defp metadata_references(%{"page_id" => id} = map) when is_binary(id),
    do: [id | metadata_references(Map.delete(map, "page_id"))]

  defp metadata_references(%{"subject" => id} = map) when is_binary(id),
    do: [id | metadata_references(Map.delete(map, "subject"))]

  defp metadata_references(map) when is_map(map),
    do: map |> Map.values() |> Enum.flat_map(&metadata_references/1)

  defp metadata_references(list) when is_list(list),
    do: Enum.flat_map(list, &metadata_references/1)

  defp metadata_references(_), do: []

  def upsert_link(attrs) when is_map(attrs) do
    with {:ok, from_object} <- Objects.resolve_slug(attrs[:from_page_id]),
         {:ok, to_object} <- Objects.resolve_slug(attrs[:to_page_id]) do
      row = %{
        from_page_id: from_object.id,
        to_page_id: to_object.id,
        link_type: attrs[:link_type] || "",
        context: attrs[:context] || "",
        link_source: attrs[:link_source],
        link_kind: attrs[:link_kind],
        origin_page_id: attrs[:origin_page_id],
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
  def add_alias(subject_page_id, alias_text),
    do: Repo.transact_top_level(fn -> add_alias_in_tx(subject_page_id, alias_text) end)

  def add_alias_in_tx(subject_page_id, alias_text) when is_binary(alias_text) do
    normalized = normalize_alias(alias_text)

    with :ok <- if(normalized == "", do: {:error, :blank_alias}, else: :ok),
         {:ok, page} <- Objects.lock_object_in_tx(subject_page_id) do
      names = metadata_names(Map.get(page.meta, "aliases", []))

      if normalized in Enum.map(names, &normalize_alias/1) do
        {:ok, :duplicate}
      else
        with {:ok, _} <-
               Objects.update_object_in_tx(
                 page.id,
                 %{meta: Map.put(page.meta, "aliases", names ++ [alias_text])},
                 :system
               ),
             do:
               {:ok,
                Ankole.Ash.read_one!(
                  Ash.Query.filter(
                    ObjectAlias,
                    subject_page_id == ^page.id and alias_norm == ^normalized
                  )
                )}
      end
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
    |> Ash.Query.sort(subject_page_id: :asc)
    |> Ankole.Ash.read!()
    |> Enum.map(& &1.subject_page_id)
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
      |> Ash.Query.sort(subject_page_id: :asc)
      |> Ash.Query.distinct([:subject_page_id])
      |> Ash.Query.select([:subject_page_id])
      |> Ankole.Ash.read!()
      |> Enum.map(& &1.subject_page_id)
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
