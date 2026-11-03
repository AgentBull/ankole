defmodule Ankole.AIAgent.Library.Console.Actions do
  @moduledoc false
  use Ash.Resource.Actions.Implementation

  alias Ankole.AIAgent.Library
  alias Ankole.AIAgent.Library.{AgentPlugins, RuntimeCapabilityChanges}

  @impl true
  def run(input, _opts, context) do
    input.action.name
    |> dispatch(input.arguments, context.actor)
    |> Ankole.Errors.wrap(&describe/1)
  end

  defp action(:global_capabilities, args) do
    with {:ok, defaults} <- AgentPlugins.Config.defaults(args.defaults_scope),
         do: Library.global_capabilities(agent_library_defaults: defaults)
  end

  defp action(:agent_capabilities, args), do: Library.capabilities_for_agent(args.agent_uid)

  defp action(:set_global_plugin, args) do
    with {:ok, _value} <-
           AgentPlugins.set_global_default(args.id, args.enabled,
             config_scope: args.defaults_scope
           ),
         {:ok, capabilities} <- action(:global_capabilities, args),
         :ok <- notify_defaults(args.defaults_scope, {:agent_plugin, args.id}),
         do: {:ok, capabilities}
  end

  defp action(:set_agent_plugin, args) do
    with {:ok, _value} <- AgentPlugins.set_agent_override(args.agent_uid, args.id, args[:enabled]),
         {:ok, capabilities} <- Library.capabilities_for_agent(args.agent_uid),
         :ok <-
           RuntimeCapabilityChanges.notify_agent(args.agent_uid, {:agent_plugin, args.id},
             capabilities: capabilities
           ),
         do: {:ok, capabilities}
  end

  defp action(:documents, args) do
    with {:ok, documents} <- Library.list_agent_documents(args.agent_uid),
         do: {:ok, %{library_documents: documents}}
  end

  defp dispatch(:set_agent_plugin, args, actor) do
    with :ok <- Library.Management.agent(actor, args.agent_uid, "update"),
         do: action(:set_agent_plugin, args)
  end

  defp dispatch(:set_global_skill, args, actor) do
    slug = args.id |> String.split(":") |> List.last()

    with {:ok, _} <- Library.Skills.set_all(actor, slug, args.enabled, args.base_revision),
         do: Library.global_capabilities()
  end

  defp dispatch(:set_agent_skill, args, actor) do
    slug = args.id |> String.split(":") |> List.last()

    with {:ok, _} <-
           Library.Skills.set_binding(
             actor,
             slug,
             args.agent_uid,
             args.enabled
           ),
         do: Library.capabilities_for_agent(args.agent_uid)
  end

  defp dispatch(name, args, actor) when name in [:documents, :agent_capabilities] do
    with :ok <- Library.Management.agent(actor, args.agent_uid, "read"), do: action(name, args)
  end

  defp dispatch(name, args, _actor), do: action(name, args)

  def default_read_permissions(args, _attrs, resource, action),
    do:
      default_permissions(
        args,
        resource,
        action,
        ["ai_agent.library.agent_plugin_defaults"]
      )

  def default_plugin_permissions(args, _attrs, resource, action),
    do: default_permissions(args, resource, action, ["ai_agent.library.agent_plugin_defaults"])

  def default_skill_permissions(args, _attrs, resource, action),
    do: default_permissions(args, resource, action, [])

  defp default_permissions(args, resource, action, keys) do
    if args["defaults_scope"] in [:global, "global"],
      do: [{resource, action} | Enum.map(keys, &{"site_console:app_configuration:#{&1}", action})],
      else: [{resource, action}]
  end

  defp notify_defaults(:tenant, capability),
    do: RuntimeCapabilityChanges.notify_global(capability)

  defp notify_defaults(:global, capability) do
    Ankole.Tenants.map_active(fn -> RuntimeCapabilityChanges.notify_global(capability) end)
    :ok
  end

  defp describe(reason) when reason in [:not_found, :agent_plugin_not_found, :skill_not_found],
    do: Ankole.Errors.Invalid.NotFound.exception(resource: Library.Console)

  defp describe(:forbidden), do: Ash.Error.Forbidden.exception([])
  defp describe({:forbidden, _}), do: Ash.Error.Forbidden.exception([])

  defp describe(_reason), do: {"Agent Library capability is invalid", []}
end
