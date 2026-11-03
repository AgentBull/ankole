defmodule Ankole.Principals.MetaBrowser do
  @moduledoc "The Pod's AI colleagues and the current member's assistant."
  use Ankole.Ash.OperationResource,
    domain: Ankole.Principals,
    authorizers: [Ankole.AuthZ.Authorizer],
    extensions: [Ankole.AuthZ.Extension]

  alias Ankole.Ash.Types.PrincipalKey

  authz do
    scope(:pod)
    for name <- [:list, :show, :create, :update], do: allow(name, check: :guardrail)
  end

  json_api do
    type("meta_agent")
  end

  @agent [
    uid: [type: PrincipalKey, allow_nil?: false],
    display_name: [type: :string, allow_nil?: false],
    avatar_url: [type: :string],
    role: [type: :string],
    type: [type: :string, allow_nil?: false],
    can_edit: [type: :boolean, allow_nil?: false],
    can_bind: [type: :boolean, allow_nil?: false]
  ]
  actions do
    action :list, :map do
      transaction?(false)

      constraints(
        fields: [
          agents: [
            type: {:array, :map},
            constraints: [items: [fields: @agent]],
            allow_nil?: false
          ],
          can_create: [type: :boolean, allow_nil?: false]
        ]
      )

      run(__MODULE__.Actions)
    end

    action :show, :map do
      transaction?(false)
      argument(:uid, PrincipalKey, allow_nil?: false)
      constraints(fields: @agent)
      run(__MODULE__.Actions)
    end

    for name <- [:create, :update] do
      action name, :map do
        transaction?(false)
        argument(:uid, PrincipalKey, allow_nil?: false)
        argument(:display_name, :string, allow_nil?: false)
        argument(:avatar_url, :string)
        if name == :create, do: argument(:role, :string, allow_nil?: false)
        constraints(fields: @agent)
        run(__MODULE__.Actions)
      end
    end
  end
end

defmodule Ankole.Principals.MetaBrowser.Actions do
  @moduledoc false
  use Ash.Resource.Actions.Implementation
  alias Ankole.AIAgent.Library.Management
  alias Ankole.Principals

  def run(input, _, %{actor: actor}) do
    with(
      :ok <- Management.member(actor),
      do: action(input.action.name, input.arguments, actor)
    )
    |> Ankole.Pod.APIError.result()
  end

  defp action(:list, _, actor) do
    agents =
      Principals.list_agents(status: :active)
      |> Enum.filter(fn %{agent: agent} ->
        agent.type == :ai_colleague or agent.owner_principal_uid == actor.principal.uid
      end)

    {:ok,
     %{
       agents: Enum.map(agents, &serialize(&1, actor)),
       can_create: Management.authorize(actor, "tenant_console:agents") == :ok
     }}
  end

  defp action(:show, %{uid: uid}, actor) do
    with :ok <- Management.agent(actor, uid, "read"),
         {:ok, agent} <- Principals.get_agent(uid),
         do: {:ok, serialize(agent, actor)}
  end

  defp action(:create, args, actor) do
    with :ok <- Management.authorize(actor, "tenant_console:agents"),
         {:ok, agent} <-
           Principals.create_agent(
             Map.merge(args, %{
               type: :ai_colleague,
               owner_principal_uid: actor.principal.uid,
               created_by: Ankole.ActorRef.from_actor(actor)
             })
           ),
         do: {:ok, serialize(agent, actor)}
  end

  defp action(:update, args, actor) do
    with :ok <- Management.agent(actor, args.uid, "update"),
         {:ok, agent} <-
           Principals.update_agent(args.uid, Map.take(args, [:display_name, :avatar_url])),
         do: {:ok, serialize(agent, actor)}
  end

  defp serialize(%{principal: principal, agent: agent}, actor),
    do: %{
      uid: principal.uid,
      display_name: principal.display_name || principal.uid,
      avatar_url: principal.avatar_url,
      type: to_string(agent.type),
      role: agent.role,
      can_edit: Management.agent(actor, principal.uid, "update") == :ok,
      can_bind: Management.binding(actor, principal.uid) == :ok
    }
end
