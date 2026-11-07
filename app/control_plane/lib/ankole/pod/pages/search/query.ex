defmodule Ankole.Pod.Pages.Search.Query do
  @moduledoc """
  Parses user search text and normalizes scope, subtree, type, author, recency,
  and ordering filters for `Ankole.Pod.Pages.Search`.
  """

  require Ash.Query

  alias Ankole.AuthZ.Actor
  alias Ankole.Pod.{Access, Page, SearchProjection}

  @default_limit 30
  @max_limit 100
  @max_query_chars 256
  @max_phrases 4
  @max_tokens 16
  @valid_types ~w(doc knowledge base applet file)
  @embeddable_types ~w(base file applet)
  @valid_sorts ~w(best updated_desc updated_asc created_desc created_asc)
  @valid_scopes ~w(all private space shared conversation)
  @valid_domains ~w(pages brain all)
  @valid_actions %{
    :node_view => :node_view,
    "node_view" => :node_view,
    :node_edit => :node_edit,
    "node_edit" => :node_edit
  }

  @type parsed_query :: %{
          raw: String.t(),
          phrases: [String.t()],
          tokens: [String.t()],
          prefix_token: String.t() | nil,
          terms: [String.t()]
        }

  @doc "Parses normalized user search text into bounded phrases, tokens, and optional prefix token."
  @spec parse_query(String.t()) :: parsed_query()
  def parse_query(raw_query) when is_binary(raw_query) do
    clean =
      raw_query
      |> SearchProjection.sanitize()
      |> String.trim()
      |> String.slice(0, @max_query_chars)

    if clean == "" do
      %{raw: "", phrases: [], tokens: [], prefix_token: nil, terms: []}
    else
      phrases =
        Regex.scan(~r/"([^"]+)"/u, clean, capture: :all_but_first)
        |> List.flatten()
        |> Enum.map(&String.trim/1)
        |> Enum.reject(&(&1 == ""))
        |> Enum.uniq()
        |> Enum.take(@max_phrases)

      tokens =
        clean
        |> then(&Regex.replace(~r/"[^"]*"/u, &1, " "))
        |> String.replace("\"", " ")
        |> String.split()
        |> Enum.uniq()
        |> Enum.take(@max_tokens)

      terms = phrases ++ tokens

      if terms == [] do
        %{raw: "", phrases: [], tokens: [], prefix_token: nil, terms: []}
      else
        prefix_token =
          case List.last(tokens) do
            last when is_binary(last) ->
              if String.length(last) in 2..64 and Regex.match?(~r/^[[:alnum:]]+$/u, last),
                do: String.downcase(last),
                else: nil

            _ ->
              nil
          end

        %{
          raw: clean,
          phrases: phrases,
          tokens: tokens,
          prefix_token: prefix_token,
          terms: terms
        }
      end
    end
  end

  @doc "Validates and normalizes search filter options for a tenant."
  @spec normalize_filters(Actor.t(), map(), term(), term(), String.t()) ::
          {:ok, map()} | {:error, :invalid_request}
  def normalize_filters(actor, opts, reachable, context, tenant_id) do
    with {:ok, required_action} <-
           parse_required_action(Ankole.Attrs.get(opts, :required_action, :node_view)),
         {:ok, domain} <- parse_domain(Ankole.Attrs.get(opts, :domain, :pages)),
         {:ok, types} <-
           parse_types(
             Ankole.Attrs.get(opts, :types),
             Ankole.Attrs.get(opts, :embeddable, false) in [true, "true"]
           ),
         {:ok, sort} <- parse_sort(Ankole.Attrs.get(opts, :sort, :best)),
         {:ok, created_by} <- parse_created_by(Ankole.Attrs.get(opts, :created_by), tenant_id),
         {:ok, updated_after} <- parse_updated_after(Ankole.Attrs.get(opts, :updated_after)),
         {:ok, excluded_subtree} <-
           parse_excluded_subtree(Ankole.Attrs.get(opts, :exclude_subtree_of)),
         {:ok, ancestor_ids} <- parse_ancestor_ids(Ankole.Attrs.get(opts, :ancestor_id)),
         {:ok, scope_ids} <-
           parse_scope_ids(Ankole.Attrs.get(opts, :scope), actor, reachable, context) do
      limit = parse_limit(Ankole.Attrs.get(opts, :limit, @default_limit))
      title_only = Ankole.Attrs.get(opts, :title_only, false) in [true, "true"]
      brain_ids = if domain == "all", do: [], else: brain_node_ids()
      hidden_brain_sources = hidden_brain_source_ids()
      excluded_ids = Enum.uniq(excluded_subtree ++ hidden_brain_sources)
      {has_subset, subset_ids} = intersect_optional_id_sets(scope_ids, ancestor_ids)

      {:ok,
       %{
         tenant_id: tenant_id,
         required_action: required_action,
         domain: domain,
         brain_ids: brain_ids,
         excluded_ids: excluded_ids,
         has_subset: has_subset,
         subset_ids: subset_ids,
         types: types,
         created_by: created_by,
         updated_after: updated_after,
         title_only: title_only,
         sort: sort,
         limit: limit
       }}
    end
  end

  defp parse_limit(n) when is_integer(n), do: max(1, min(n, @max_limit))

  defp parse_limit(s) when is_binary(s) do
    case Integer.parse(s) do
      {n, ""} -> max(1, min(n, @max_limit))
      _ -> @default_limit
    end
  end

  defp parse_limit(_), do: @default_limit

  defp parse_required_action(action) do
    case Map.fetch(@valid_actions, action) do
      {:ok, atom} -> {:ok, atom}
      :error -> {:error, :invalid_request}
    end
  end

  defp parse_domain(nil), do: {:ok, "pages"}

  defp parse_domain(domain) do
    str = to_string(domain)
    if str in @valid_domains, do: {:ok, str}, else: {:error, :invalid_request}
  end

  defp parse_types(raw_types, embeddable?) do
    with {:ok, list} <- normalize_type_items(raw_types) do
      cond do
        not embeddable? -> {:ok, list}
        is_nil(list) -> {:ok, @embeddable_types}
        true -> {:ok, Enum.filter(list, &(&1 in @embeddable_types))}
      end
    end
  end

  defp normalize_type_items(raw_types) when raw_types in [nil, "", []], do: {:ok, nil}

  defp normalize_type_items(raw_types) when is_binary(raw_types) do
    raw_types
    |> String.split(",", trim: true)
    |> validate_type_list()
  end

  defp normalize_type_items(raw_types) when is_list(raw_types) do
    raw_types
    |> Enum.map(&to_string/1)
    |> validate_type_list()
  end

  defp normalize_type_items(_), do: {:error, :invalid_request}

  defp validate_type_list(items) do
    cleaned =
      items
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.uniq()

    cond do
      cleaned == [] -> {:ok, nil}
      Enum.all?(cleaned, &(&1 in @valid_types)) -> {:ok, cleaned}
      true -> {:error, :invalid_request}
    end
  end

  defp parse_sort(nil), do: {:ok, "best"}

  defp parse_sort(sort) do
    str = to_string(sort)
    if str in @valid_sorts, do: {:ok, str}, else: {:error, :invalid_request}
  end

  defp parse_created_by(nil, _tenant_id), do: {:ok, nil}
  defp parse_created_by("", _tenant_id), do: {:ok, nil}

  defp parse_created_by("ankole:" <> _ = ref_str, _tenant_id) do
    case Ankole.ActorRef.cast(ref_str) do
      {:ok, ref} -> {:ok, to_string(ref)}
      :error -> {:error, :invalid_request}
    end
  end

  defp parse_created_by(uid, tenant_id) when is_binary(uid) do
    case Ankole.ActorRef.cast(%Ankole.ActorRef{tenant_id: tenant_id, uid: String.trim(uid)}) do
      {:ok, ref} -> {:ok, to_string(ref)}
      :error -> {:error, :invalid_request}
    end
  end

  defp parse_created_by(_, _tenant_id), do: {:error, :invalid_request}

  defp parse_updated_after(nil), do: {:ok, nil}
  defp parse_updated_after(""), do: {:ok, nil}
  defp parse_updated_after(%DateTime{} = dt), do: {:ok, dt}

  defp parse_updated_after(%Date{} = d) do
    {:ok, DateTime.new!(d, ~T[00:00:00.000000], "Etc/UTC")}
  end

  defp parse_updated_after(value) when is_binary(value) do
    trimmed = String.trim(value)

    case DateTime.from_iso8601(trimmed) do
      {:ok, dt, _offset} ->
        {:ok, dt}

      _ ->
        case Date.from_iso8601(trimmed) do
          {:ok, d} -> {:ok, DateTime.new!(d, ~T[00:00:00.000000], "Etc/UTC")}
          _ -> {:error, :invalid_request}
        end
    end
  end

  defp parse_updated_after(_), do: {:error, :invalid_request}

  defp parse_excluded_subtree(nil), do: {:ok, []}
  defp parse_excluded_subtree(""), do: {:ok, []}

  defp parse_excluded_subtree(source_id) when is_binary(source_id) do
    case Ecto.UUID.cast(source_id) do
      {:ok, uuid} -> {:ok, Ankole.Pod.descendant_node_ids(uuid)}
      :error -> {:error, :invalid_request}
    end
  end

  defp parse_excluded_subtree(_), do: {:error, :invalid_request}

  defp parse_ancestor_ids(nil), do: {:ok, nil}
  defp parse_ancestor_ids(""), do: {:ok, nil}

  defp parse_ancestor_ids(ancestor_id) when is_binary(ancestor_id) do
    case Ecto.UUID.cast(ancestor_id) do
      {:ok, uuid} -> {:ok, Ankole.Pod.descendant_node_ids(uuid)}
      :error -> {:error, :invalid_request}
    end
  end

  defp parse_ancestor_ids(_), do: {:error, :invalid_request}

  defp parse_scope_ids(nil, _actor, _reachable, _context), do: {:ok, nil}
  defp parse_scope_ids("", _actor, _reachable, _context), do: {:ok, nil}

  defp parse_scope_ids(scope, actor, reachable, context) do
    str = to_string(scope)

    if str not in @valid_scopes do
      {:error, :invalid_request}
    else
      resolve_scope_ids(str, actor, reachable, context)
    end
  end

  defp resolve_scope_ids("all", _actor, _reachable, _context), do: {:ok, nil}

  defp resolve_scope_ids("space", _actor, _reachable, _context) do
    case Ankole.Pod.public_root() do
      {:ok, root} -> {:ok, Ankole.Pod.descendant_node_ids(root.id)}
      _ -> {:ok, []}
    end
  end

  defp resolve_scope_ids("private", actor, _reachable, _context) do
    uid = Ankole.Principals.authority_uid(Actor.uid(actor))

    case Ankole.Pod.private_root(uid) do
      {:ok, root} -> {:ok, Ankole.Pod.descendant_node_ids(root.id)}
      _ -> {:ok, []}
    end
  end

  defp resolve_scope_ids("shared", actor, reachable, context) do
    uid = Ankole.Principals.authority_uid(Actor.uid(actor))

    own_private =
      case Ankole.Pod.private_root(uid) do
        {:ok, root} -> MapSet.new(Ankole.Pod.descendant_node_ids(root.id))
        _ -> MapSet.new()
      end

    with {:ok, shared} <- Access.directly_shared_ids(actor, reachable, context: context) do
      ids =
        shared
        |> Ankole.Pod.shared_root_node_ids(reachable)
        |> Enum.flat_map(&Ankole.Pod.descendant_node_ids/1)
        |> Enum.uniq()
        |> Enum.reject(&MapSet.member?(own_private, &1))

      {:ok, ids}
    end
  end

  defp resolve_scope_ids("conversation", _actor, _reachable, _context) do
    ids =
      Page
      |> Ash.Query.filter(is_root and not is_nil(conversation_id))
      |> Ash.Query.select([:id])
      |> Ankole.Ash.read!()
      |> Enum.flat_map(&Ankole.Pod.descendant_node_ids(&1.id))
      |> Enum.uniq()

    {:ok, ids}
  end

  defp intersect_optional_id_sets(nil, nil), do: {false, []}
  defp intersect_optional_id_sets(list, nil) when is_list(list), do: {true, list}
  defp intersect_optional_id_sets(nil, list) when is_list(list), do: {true, list}

  defp intersect_optional_id_sets(left, right) when is_list(left) and is_list(right) do
    right_set = MapSet.new(right)
    {true, Enum.filter(left, &MapSet.member?(right_set, &1))}
  end

  defp brain_node_ids do
    case Ankole.Pod.Pages.Tree.system_node("ankole_brain") do
      {:ok, root} -> Ankole.Pod.descendant_node_ids(root.id)
      {:error, :not_found} -> []
    end
  end

  defp hidden_brain_source_ids do
    case Ankole.Pod.Pages.Tree.system_node("ankole_brain_sources") do
      {:ok, source} -> Ankole.Pod.descendant_node_ids(source.id)
      {:error, :not_found} -> []
    end
  end
end
