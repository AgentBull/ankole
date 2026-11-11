defmodule Ankole.Brain.Browser do
  @moduledoc "The member's visible Brain ontology and semantic graph."
  use Ankole.Ash.OperationResource,
    domain: Ankole.Brain,
    authorizers: [Ankole.AuthZ.Authorizer],
    extensions: [Ankole.AuthZ.Extension]

  alias Ankole.Ash.Types.UUIDv7

  authz do
    scope(:pod)
    allow(:graph, check: :guardrail)
  end

  json_api do
    type("meta_brain")
  end

  actions do
    action :graph, :map do
      transaction?(false)

      constraints(
        fields: [
          categories: [
            type: {:array, :map},
            allow_nil?: false,
            constraints: [
              items: [
                fields: [
                  id: [type: UUIDv7, allow_nil?: false],
                  name: [type: :string, allow_nil?: false],
                  entity_type: [type: :string, allow_nil?: false],
                  primitive: [type: :string, allow_nil?: false],
                  can_edit: [type: :boolean, allow_nil?: false]
                ]
              ]
            ]
          ],
          nodes: [
            type: {:array, :map},
            allow_nil?: false,
            constraints: [
              items: [
                fields: [
                  id: [type: UUIDv7, allow_nil?: false],
                  title: [type: :string, allow_nil?: false],
                  slug: [type: :string, allow_nil?: false],
                  type: [type: :string, allow_nil?: false],
                  subtype: [type: :string, allow_nil?: true],
                  parent_id: [type: UUIDv7, allow_nil?: true]
                ]
              ]
            ]
          ],
          links: [
            type: {:array, :map},
            allow_nil?: false,
            constraints: [
              items: [
                fields: [
                  from_page_id: [type: UUIDv7, allow_nil?: false],
                  to_page_id: [type: UUIDv7, allow_nil?: false],
                  link_type: [type: :string, allow_nil?: false],
                  relation_kind: [type: :string, allow_nil?: false]
                ]
              ]
            ]
          ]
        ]
      )

      run(__MODULE__.Actions)
    end
  end
end

defmodule Ankole.Brain.Browser.Actions do
  @moduledoc false
  use Ash.Resource.Actions.Implementation
  require Ash.Query
  alias Ankole.Brain.{Access, Namespace}
  alias Ankole.Brain.Schemas.{Claim, Link, Page, SchemaType, Timeline}
  alias Ankole.Pod.Pages.Tree

  def run(_, _, %{actor: actor}) do
    with :ok <- Ankole.AIAgent.Library.Management.member(actor) do
      Ankole.Repo.transact_repeatable_read_only(fn -> graph(actor) end)
    end
    |> Ankole.Pod.APIError.result()
  end

  defp graph(actor) do
    with {:ok, root} <- Namespace.root(),
         {:ok, access} <-
           Access.for_context(%{
             querier_uid: actor.principal.uid,
             disclosure: %{mode: :relaxed, asker_uid: nil, present_uids: []}
           }) do
      schema_by_category =
        SchemaType
        |> Ash.Query.select([:name, :primitive, :slug_prefix])
        |> Ankole.Ash.read!()
        |> Map.new(fn schema_type ->
          {String.trim_trailing(schema_type.slug_prefix, "/"),
           %{entity_type: schema_type.name, primitive: schema_type.primitive}}
        end)

      categories =
        Tree.list_children(root.id)
        |> Enum.filter(
          &(&1.system_key != "ankole_brain_sources" and Access.visible_node?(access, &1))
        )
        |> Enum.map(fn category ->
          schema =
            Map.get(schema_by_category, category.name, %{
              entity_type: category.name,
              primitive: "concept"
            })

          %{
            id: category.id,
            name: category.name,
            entity_type: schema.entity_type,
            primitive: schema.primitive,
            can_edit:
              category.system_key != "ankole_brain_agents" and
                match?(
                  {:ok, _},
                  Ankole.Pod.Access.authorize_reachable(category, "node_edit", access.reachable)
                )
          }
        end)

      category_ids = MapSet.new(categories, & &1.id)

      excluded =
        [root.id | MapSet.to_list(category_ids)] ++
          case Namespace.system_node("ankole_brain_sources") do
            {:ok, source} -> Tree.descendants(source.id)
            _ -> []
          end

      # A file joins the graph once source learning has covered it, as the
      # evidence source of the facts extracted from it.
      raw_nodes =
        Page
        |> Ash.Query.filter(
          id not in ^excluded and is_nil(deleted_at) and
            (kind == :knowledge or (kind == :file and learned?))
        )
        |> Access.filter_objects(access)
        |> Ash.Query.sort(title: :asc)
        |> Ash.Query.select([:id, :title, :slug, :type, :subtype, :parent_id])
        |> Ankole.Ash.read!()

      visible_ids = MapSet.new(raw_nodes, & &1.id)
      known_parents = MapSet.union(category_ids, visible_ids)

      nodes =
        Enum.map(raw_nodes, fn node ->
          %{
            id: node.id,
            title: node.title,
            slug: node.slug,
            type: node.type,
            subtype: node.subtype,
            parent_id: resolve_visible_parent(node, known_parents)
          }
        end)

      links = collect_links(nodes, visible_ids, access)

      {:ok, %{categories: categories, nodes: nodes, links: links}}
    end
  end

  defp resolve_visible_parent(%{parent_id: nil}, _known_parents), do: nil

  defp resolve_visible_parent(%{id: id, parent_id: parent_id}, known_parents) do
    cond do
      parent_id == id ->
        nil

      MapSet.member?(known_parents, parent_id) ->
        parent_id

      true ->
        case Tree.path(%{id: id, parent_id: parent_id}) do
          {:ok, ancestors} ->
            ancestors
            |> Enum.reject(&(&1.id == id))
            |> Enum.reverse()
            |> Enum.find_value(fn ancestor ->
              if MapSet.member?(known_parents, ancestor.id), do: ancestor.id
            end)

          _ ->
            nil
        end
    end
  end

  defp collect_links([], _visible_ids, _access), do: []

  defp collect_links(nodes, visible_ids, access) do
    visible = MapSet.to_list(visible_ids)
    id_by_slug = Map.new(nodes, &{&1.slug, &1.id})
    explicit = explicit_edges(visible, access)
    explicit_pairs = MapSet.new(explicit, &{&1.from_page_id, &1.to_page_id})

    (explicit ++
       hierarchy_edges(nodes, visible_ids) ++
       ownership_edges(id_by_slug) ++
       claim_edges(visible, access, explicit_pairs) ++
       timeline_edges(visible, visible_ids, access, explicit_pairs))
    |> Enum.uniq_by(&{&1.from_page_id, &1.to_page_id, &1.link_type})
    |> Enum.sort_by(&{&1.from_page_id, &1.to_page_id, &1.link_type})
  end

  defp explicit_edges(visible, access) do
    Link
    |> Ash.Query.filter(
      from_page_id in ^visible and to_page_id in ^visible and from_page_id != to_page_id
    )
    |> Access.filter_links(access)
    |> Ash.Query.select([:from_page_id, :to_page_id, :link_type, :link_source])
    |> Ankole.Ash.read!()
    |> Enum.map(fn link ->
      %{
        from_page_id: link.from_page_id,
        to_page_id: link.to_page_id,
        link_type: if(link.link_type == "", do: "relates_to", else: link.link_type),
        relation_kind:
          if(link.link_type == "references" or link.link_source in ["mention", "frontmatter"],
            do: "reference",
            else: "semantic"
          )
      }
    end)
  end

  defp hierarchy_edges(nodes, visible_ids) do
    nodes
    |> Enum.filter(&(&1.parent_id != nil and MapSet.member?(visible_ids, &1.parent_id)))
    |> Enum.map(fn node ->
      %{
        from_page_id: node.parent_id,
        to_page_id: node.id,
        link_type: "contains",
        relation_kind: "hierarchy"
      }
    end)
  end

  defp ownership_edges(id_by_slug) do
    Ankole.Principals.list_agents()
    |> Enum.flat_map(fn %{agent: agent} ->
      from_id = Map.get(id_by_slug, "agents/" <> agent.uid)

      to_id =
        if is_binary(agent.owner_principal_uid),
          do: Map.get(id_by_slug, "people/" <> agent.owner_principal_uid)

      if from_id && to_id && from_id != to_id do
        link_type = if agent.type == :personal_assistant, do: "assists", else: "owned_by"

        [
          %{
            from_page_id: from_id,
            to_page_id: to_id,
            link_type: link_type,
            relation_kind: "ownership"
          }
        ]
      else
        []
      end
    end)
  end

  defp claim_edges(visible, access, explicit_pairs) do
    claim_sources =
      Claim
      |> Ash.Query.filter(
        source_node_id in ^visible and not is_nil(subject_page_id) and
          subject_page_id in ^visible and source_node_id != subject_page_id
      )
      |> Access.filter_current_claims()
      |> Access.filter_claims(access)
      |> Ash.Query.select([:source_node_id, :subject_page_id])
      |> Ankole.Ash.read!()
      |> Enum.reject(&MapSet.member?(explicit_pairs, {&1.source_node_id, &1.subject_page_id}))
      |> Enum.map(fn claim ->
        %{
          from_page_id: claim.source_node_id,
          to_page_id: claim.subject_page_id,
          link_type: "evidences",
          relation_kind: "evidence"
        }
      end)

    take_holders =
      Claim
      |> Ash.Query.filter(
        claim_type == :take and holder in ^visible and not is_nil(subject_page_id) and
          subject_page_id in ^visible
      )
      |> Access.filter_current_claims()
      |> Access.filter_claims(access)
      |> Ash.Query.select([:holder, :subject_page_id])
      |> Ankole.Ash.read!()
      |> Enum.filter(&(&1.holder != &1.subject_page_id))
      |> Enum.map(fn claim ->
        %{
          from_page_id: claim.holder,
          to_page_id: claim.subject_page_id,
          link_type: "holds_take",
          relation_kind: "evidence"
        }
      end)

    claim_sources ++ take_holders
  end

  defp timeline_edges(visible, visible_ids, access, explicit_pairs) do
    Timeline
    |> Ash.Query.filter(
      not is_nil(subject_page_id) and subject_page_id in ^visible and
        (source_node_id in ^visible or event_page_id in ^visible)
    )
    |> Access.filter_timelines(access)
    |> Ash.Query.select([:source_node_id, :event_page_id, :subject_page_id])
    |> Ankole.Ash.read!()
    |> Enum.flat_map(&timeline_row_edges(&1, visible_ids, explicit_pairs))
  end

  defp timeline_row_edges(timeline, visible_ids, explicit_pairs) do
    event_edge =
      if timeline.event_page_id && MapSet.member?(visible_ids, timeline.event_page_id) &&
           timeline.event_page_id != timeline.subject_page_id do
        [
          %{
            from_page_id: timeline.event_page_id,
            to_page_id: timeline.subject_page_id,
            link_type: "involves",
            relation_kind: "semantic"
          }
        ]
      else
        []
      end

    source_edge =
      if MapSet.member?(visible_ids, timeline.source_node_id) &&
           timeline.source_node_id != timeline.subject_page_id &&
           not MapSet.member?(explicit_pairs, {timeline.source_node_id, timeline.subject_page_id}) do
        [
          %{
            from_page_id: timeline.source_node_id,
            to_page_id: timeline.subject_page_id,
            link_type: "evidences",
            relation_kind: "evidence"
          }
        ]
      else
        []
      end

    event_edge ++ source_edge
  end
end
