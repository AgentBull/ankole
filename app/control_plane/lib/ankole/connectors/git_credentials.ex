defmodule Ankole.Connectors.GitCredentials do
  @moduledoc "Exchanges a live Turn for an ephemeral Git HTTPS credential on its selected GitHub connection."

  def resolve(context, params) do
    with {:ok, adapter, tools} <- Ankole.Connectors.Registry.toolkit("github"),
         %{} = tool <- Enum.find(tools, &(&1.name == "repos_get")),
         {:ok, connection} <- connection(params, adapter),
         {:ok, credentials} <-
           Ankole.Connectors.resolve_call(
             tool,
             context.actor.principal,
             connection,
             params["account"]
           ),
         {:ok, owner, repo} <- repository(params["url"], adapter.web_url(credentials.auth_config)),
         {:ok, _, used_context} <-
           Ankole.Connectors.Gateway.invoke_toolkit(
             adapter,
             tool,
             %{"owner" => owner, "repo" => repo},
             Map.merge(credentials, context)
           ) do
      {:ok, %{username: "x-access-token", password: used_context.access_token}}
    else
      nil -> {:error, :toolkit_not_found}
      error -> error
    end
  end

  defp connection(%{"connection" => selector}, _adapter) when is_binary(selector),
    do: {:ok, selector}

  defp connection(params, adapter) do
    with {:ok, configs} <- Ankole.Connectors.Store.active_auth_configs("github") do
      matches =
        Enum.filter(configs, fn config ->
          match?({:ok, _, _}, repository(params["url"], adapter.web_url(config)))
        end)

      case Enum.find(matches, & &1.is_default) || List.first(matches) do
        nil -> {:error, :github_repository_url_required}
        config when length(matches) == 1 or config.is_default -> {:ok, config.id}
        _ -> {:error, :connection_required}
      end
    end
  end

  defp repository(url, web_url) when is_binary(url) do
    uri = URI.parse(url)
    allowed = URI.parse(web_url)

    case {uri.scheme, uri.host, uri.port, String.split(uri.path || "", "/", trim: true)} do
      {"https", host, port, [owner, repo]} when host == allowed.host and port == allowed.port ->
        {:ok, owner, String.replace_suffix(repo, ".git", "")}

      _ ->
        {:error, :github_repository_url_required}
    end
  end

  defp repository(_, _), do: {:error, :github_repository_url_required}
end
