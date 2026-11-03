defmodule Ankole.AIAgent.Library.MCP do
  @moduledoc "Resolves MCP declarations and credentials from an executing Principal's enabled Skills."
  alias Ankole.AIAgent.Library

  def resolve(principal, skill, name) when is_binary(skill) and is_binary(name) do
    with {:ok, uid} <- agent_uid(principal),
         {:ok, %{"content" => yaml}} <- Library.skill_view(uid, skill, "agents/openai.yaml"),
         {:ok, metadata} when is_map(metadata) <- YamlElixir.read_from_string(yaml),
         %{"type" => "mcp", "value" => ^name} = declaration <-
           Enum.find(declarations(metadata), &match?(%{"type" => "mcp", "value" => ^name}, &1)),
         {:ok, headers} <- headers(uid, declaration) do
      {:ok, Map.put(declaration, "headers", headers)}
    else
      nil -> {:error, :mcp_server_not_found}
      {:ok, _invalid_metadata} -> {:error, :invalid_mcp_metadata}
      {:error, _} = error -> error
    end
  end

  def resolve(_, _, _), do: {:error, :mcp_skill_and_server_required}

  defp declarations(%{"dependencies" => %{"tools" => tools}}) when is_list(tools), do: tools
  defp declarations(_), do: []

  defp agent_uid(%{type: :agent, uid: uid}), do: {:ok, uid}

  defp agent_uid(%{type: :human, uid: uid}) do
    case Ankole.Principals.personal_assistant(uid) do
      nil -> {:error, :personal_assistant_not_found}
      agent -> {:ok, agent.uid}
    end
  end

  defp agent_uid(_), do: {:error, :forbidden}

  defp headers(uid, %{"bearer_token_env_var" => key}) do
    with {:ok, env} <- Ankole.AgentWorkers.effective_env_parts(uid),
         value when is_binary(value) and value != "" <- Map.merge(env.operator, env.binding)[key],
         do: {:ok, [{"authorization", "Bearer " <> value}]},
         else: (
           {:error, _} = error -> error
           _ -> {:error, :mcp_credential_unavailable}
         )
  end

  defp headers(_, _), do: {:ok, []}
end
