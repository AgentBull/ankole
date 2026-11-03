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
                  type: [type: :string, allow_nil?: false]
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
                  link_type: [type: :string, allow_nil?: false]
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
  alias Ankole.Brain.Schemas.{Page, Link}
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
      categories =
        Tree.list_children(root.id)
        |> Enum.filter(
          &(&1.system_key != "ankole_brain_sources" and Access.visible_node?(access, &1))
        )
        |> Enum.map(
          &%{
            id: &1.id,
            name: &1.name,
            can_edit:
              &1.system_key != "ankole_brain_agents" and
                match?(
                  {:ok, _},
                  Ankole.Pod.Access.authorize_reachable(&1, "node_edit", access.reachable)
                )
          }
        )

      excluded =
        [root.id | Enum.map(categories, & &1.id)] ++
          case Namespace.system_node("ankole_brain_sources") do
            {:ok, source} -> Tree.descendants(source.id)
            _ -> []
          end

      nodes =
        Page
        |> Ash.Query.filter(id not in ^excluded and is_nil(deleted_at) and kind == :knowledge)
        |> Access.filter_objects(access)
        |> Ash.Query.sort(title: :asc)
        |> Ash.Query.select([:id, :title, :slug, :type])
        |> Ankole.Ash.read!()

      visible = Enum.map(nodes, & &1.id)

      links =
        Link
        |> Ash.Query.filter(from_page_id in ^visible and to_page_id in ^visible)
        |> Access.filter_links(access)
        |> Ash.Query.select([:from_page_id, :to_page_id, :link_type])
        |> Ankole.Ash.read!()

      {:ok, %{categories: categories, nodes: nodes, links: links}}
    end
  end
end
