defmodule Ankole.Plugins.LinearAdapter.Connector do
  @moduledoc "Linear OAuth and its official Streamable HTTP MCP service."
  @behaviour Ankole.Connectors.Connector
  alias Ankole.Connectors.{HTTP, RemoteMCP, ToolSpec}
  defdelegate tools(), to: Ankole.Plugins.LinearAdapter.Tools
  @endpoint "https://mcp.linear.app/mcp"

  def call(tool, args, context) do
    opts = [
      idempotent: ToolSpec.retry_safe?(tool),
      cache_key:
        {context.auth_config.tenant_id, context.auth_config.id,
         context.auth_config.secret_version, context.account && context.account.id,
         context.account && context.account.credentials_version},
      deadline: Map.get(context, :deadline)
    ]

    with {:ok, result} <-
           RemoteMCP.call(
             @endpoint,
             [{"authorization", "Bearer " <> context.access_token}],
             tool.operation,
             args,
             opts
           ),
         {:ok, value} <- normalize_result(tool, result) do
      {:ok, %{"result" => value}}
    else
      {:error, {:mcp_protocol, 401, _}} ->
        Ankole.Connectors.Credentials.invalidate_access_token(
          context.auth_config,
          context.account,
          context.access_token
        )

        Ankole.Connectors.OAuth.consent_required(context.auth_config.slug, tool.scopes, %{
          "toolkit" => tool.toolkit
        })

      error ->
        error
    end
  end

  def normalize_result(%{name: "list_" <> _ = name}, result) do
    with {:ok, value} <- structured(result) do
      key =
        %{
          "list_issues" => "issues",
          "list_projects" => "projects",
          "list_cycles" => "cycles",
          "list_comments" => "comments",
          "list_teams" => "teams",
          "list_issue_labels" => "labels",
          "list_issue_statuses" => "statuses",
          "list_users" => "users"
        }[name]

      case value do
        values when is_list(values) ->
          {:ok, %{"items" => values, "has_next_page" => false, "cursor" => nil}}

        values when is_map(values) ->
          case values[key] || values["nodes"] || values["items"] do
            items when is_list(items) ->
              {:ok,
               %{
                 "items" => items,
                 "has_next_page" => values["hasNextPage"] == true,
                 "cursor" => values["cursor"]
               }}

            _ ->
              {:error, %{code: "upstream_contract_changed", retryable: false}}
          end
      end
    end
  end

  def normalize_result(_tool, result), do: structured(result)

  def oauth_authorize_url(_config, secret, params) do
    {kind, params} = Map.pop(params, :subject_kind)
    requested = String.split(params["scope"] || "", ~r/[ ,]+/, trim: true)

    scopes =
      if requested == [] do
        tools()
        |> Enum.filter(&(kind == "app" or &1.annotations["readOnlyHint"] == true))
        |> Enum.flat_map(& &1.scopes)
        |> Enum.uniq()
      else
        requested
      end

    params =
      Map.merge(params, %{
        "client_id" => client_id(secret),
        "response_type" => "code",
        "scope" => Enum.join(scopes, ","),
        "actor" => if(kind == "app", do: "app", else: "user")
      })

    {:ok, "https://linear.app/oauth/authorize?" <> URI.encode_query(params)}
  end

  def oauth_exchange(config, secret, params) do
    with {:ok, tokens} <-
           tokens(config, secret, Map.put(params, "grant_type", "authorization_code")),
         {:ok, %{status: status, body: %{"data" => %{"viewer" => %{"id" => id} = viewer}}}}
         when status in 200..299 <-
           Ankole.Files.HTTP.json(
             "POST",
             "https://api.linear.app/graphql",
             [
               {"authorization", "Bearer " <> tokens["access_token"]},
               {"content-type", "application/json"}
             ],
             %{"query" => "{ viewer { id name } }"},
             idempotent: true
           ) do
      {:ok,
       tokens
       |> Map.put("external_subject_id", id)
       |> Map.put("public_metadata", %{"name" => viewer["name"]})}
    else
      {:error, _} = error -> error
      _ -> {:error, :external_subject_required}
    end
  end

  def refresh_token(config, secret, credentials),
    do:
      tokens(config, secret, %{
        "grant_type" => "refresh_token",
        "refresh_token" => credentials["refresh_token"]
      })

  defp tokens(_config, secret, params) do
    params =
      Map.merge(params, %{
        "client_id" => client_id(secret),
        "client_secret" => secret["client_secret"] || secret["clientSecret"]
      })

    with {:ok, response} <-
           Ankole.Files.HTTP.request(
             "POST",
             "https://api.linear.app/oauth/token",
             [{"content-type", "application/x-www-form-urlencoded"}],
             URI.encode_query(params)
           ) do
      case Torque.decode(response.body) do
        {:ok, %{"error" => "invalid_grant"}} -> {:error, :invalid_grant}
        {:ok, %{"access_token" => _} = tokens} when response.status in 200..299 -> {:ok, tokens}
        _ -> HTTP.decode(response)
      end
    end
  end

  defp client_id(secret), do: secret["client_id"] || secret["clientID"]

  defp structured(%{"isError" => true} = result),
    do: {:error, %{code: "upstream_tool_error", retryable: false, content: result["content"]}}

  defp structured(%{"structuredContent" => data}) when is_map(data) or is_list(data),
    do: {:ok, data}

  defp structured(%{"content" => [%{"type" => "text", "text" => text}]}) do
    case Torque.decode(text) do
      {:ok, value} when is_map(value) or is_list(value) -> {:ok, value}
      _ -> {:error, %{code: "upstream_contract_changed", retryable: false}}
    end
  end

  defp structured(_), do: {:error, %{code: "upstream_contract_changed", retryable: false}}
end
