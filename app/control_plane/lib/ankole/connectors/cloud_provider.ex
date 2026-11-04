defmodule Ankole.Connectors.CloudProvider do
  @moduledoc "JSON contracts between a consuming Pod and its configured Ankole Cloud service."

  @callback available_connectors() :: {:ok, [map()]} | {:error, term()}
  @callback begin_oauth(map()) :: {:ok, map()} | {:error, term()}
  @callback exchange_ticket(map()) :: {:ok, map()} | {:error, term()}
  @callback claim_account(map()) :: {:ok, map()} | {:error, term()}
  @callback access_token(map()) :: {:ok, map()} | {:error, term()}
  @callback execute_tool(map()) :: {:ok, map()} | {:error, term()}
  @callback revoke_account(map()) :: {:ok, map()} | {:error, term()}
  @callback reconcile_trigger(map()) :: {:ok, map()} | {:error, term()}

  @callbacks [
    available_connectors: 0,
    begin_oauth: 1,
    exchange_ticket: 1,
    claim_account: 1,
    access_token: 1,
    execute_tool: 1,
    revoke_account: 1,
    reconcile_trigger: 1
  ]

  def validate_declaration(%{module: module}) when is_atom(module) and not is_nil(module) do
    with {:module, _} <- Code.ensure_loaded(module) do
      case Enum.reject(@callbacks, fn {name, arity} -> function_exported?(module, name, arity) end) do
        [] -> :ok
        missing -> {:error, {:missing_cloud_provider_callbacks, module, missing}}
      end
    end
  end

  def validate_declaration(declaration), do: {:error, {:invalid_cloud_provider, declaration}}

  def available_connectors do
    case provider() do
      {:ok, module} -> module.available_connectors()
      {:error, :cloud_unavailable} -> {:ok, []}
      error -> error
    end
  end

  for {operation, 1} <- @callbacks do
    def unquote(operation)(request) do
      with {:ok, module} <- provider() do
        request = Map.put(request, "tenant_id", Ankole.Repo.tenant_id!())
        apply(module, unquote(operation), [request])
      end
    end
  end

  defp provider do
    case Ankole.Plugins.Registry.adapter_declarations("connectors.cloud_provider") do
      [%{module: module}] -> {:ok, module}
      [] -> {:error, :cloud_unavailable}
      _ -> {:error, :multiple_cloud_providers}
    end
  end
end
