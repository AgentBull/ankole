defmodule Ankole.AIAgent.Library.Console.Actions do
  @moduledoc false
  use Ash.Resource.Actions.Implementation

  alias Ankole.AIAgent.Library
  alias Ankole.AIAgent.Library.{AgentPlugins, RuntimeCapabilityChanges}

  @impl true
  def run(input, _opts, _context) do
    input.action.name |> action(input.arguments) |> Ankole.Errors.wrap(&describe/1)
  end

  defp action(:global_capabilities, _args), do: Library.global_capabilities()
  defp action(:agent_capabilities, args), do: Library.capabilities_for_agent(args.agent_uid)

  defp action(:set_global_plugin, args) do
    with {:ok, _value} <- AgentPlugins.set_global_default(args.id, args.enabled),
         {:ok, capabilities} <- Library.global_capabilities(),
         :ok <- RuntimeCapabilityChanges.notify_global({:agent_plugin, args.id}),
         do: {:ok, capabilities}
  end

  defp action(:set_global_skill, args) do
    with {:ok, _value} <- Library.set_global_skill_default(args.id, args.enabled),
         {:ok, capabilities} <- Library.global_capabilities(),
         :ok <- RuntimeCapabilityChanges.notify_global({:skill, args.id}),
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

  defp action(:set_agent_skill, args) do
    with {:ok, _value} <-
           Library.set_agent_skill_override(args.agent_uid, args.id, args[:enabled]),
         {:ok, capabilities} <- Library.capabilities_for_agent(args.agent_uid),
         :ok <-
           RuntimeCapabilityChanges.notify_agent(args.agent_uid, {:skill, args.id},
             capabilities: capabilities
           ),
         do: {:ok, capabilities}
  end

  defp action(:documents, args) do
    with {:ok, documents} <- Library.list_agent_documents(args.agent_uid),
         do: {:ok, %{library_documents: documents}}
  end

  defp action(:replace_document, args) do
    with {:ok, document} <-
           Library.replace_agent_document(
             args.agent_uid,
             args.document_kind,
             args.content,
             args.expected_content_hash
           ),
         do: {:ok, %{library_document: document}}
  end

  defp describe(reason) when reason in [:not_found, :agent_plugin_not_found, :skill_not_found],
    do: Ankole.Errors.Invalid.NotFound.exception(resource: Library.Console)

  defp describe(:agent_library_document_conflict),
    do: {:conflict, "Agent library document changed since it was loaded", []}

  defp describe(reason) when reason in [:invalid_document_kind, :invalid_agent_document],
    do: {"Agent library document is invalid", []}

  defp describe(_reason), do: {"Agent Library capability is invalid", []}
end
