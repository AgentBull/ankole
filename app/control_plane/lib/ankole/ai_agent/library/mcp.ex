defmodule Ankole.AIAgent.Library.MCP do
  @moduledoc "Resolves MCP declarations and credentials from an executing Principal's enabled Skills."
  alias Ankole.AIAgent.Library

  def resolve(principal, skill, name, opts \\ [])

  def resolve(principal, skill, name, opts) when is_binary(skill) and is_binary(name) do
    with {:ok, uid} <- agent_uid(principal),
         {:ok, %{"content" => yaml}} <- Library.skill_view(uid, skill, "agents/openai.yaml", opts),
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

  def resolve(_, _, _, _), do: {:error, :mcp_skill_and_server_required}

  def credential_env_keys do
    with {:ok, files} <- Ankole.AIAgent.Library.Skills.mcp_metadata_files() do
      objects = files |> Enum.map(& &1.object_id) |> Enum.uniq() |> Enum.sort()

      Library.SourceCache.fetch({__MODULE__, Ankole.Repo.tenant_id!()}, objects, 60_000, fn ->
        credential_keys(objects)
      end)
    end
  end

  defp credential_keys(objects) do
    Enum.reduce_while(objects, {:ok, []}, fn object_id, {:ok, keys} ->
      with {:ok, yaml} <- Ankole.Files.read_object(object_id),
           do: {:cont, {:ok, credential_env_keys_from_yaml(yaml) ++ keys}},
           else: (error -> {:halt, error})
    end)
  end

  defp credential_env_keys_from_yaml(yaml) do
    case YamlElixir.read_from_string(yaml) do
      {:ok, metadata} ->
        for %{"type" => "mcp", "bearer_token_env_var" => key} <- declarations(metadata),
            is_binary(key),
            do: key

      {:error, _} ->
        []
    end
  end

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
