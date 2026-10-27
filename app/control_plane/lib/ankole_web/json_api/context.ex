defmodule AnkoleWeb.JSONAPI.Context do
  @moduledoc "Sets the explicit Ash Actor, tenant, and canonical request targets."
  import Plug.Conn
  alias Ankole.AuthZ.Checks.GrantCheck

  def before_dispatch(conn, :open_api, _scope),
    do: put_resp_content_type(conn, "application/json")

  def before_dispatch(conn, :not_found, _scope), do: conn

  def before_dispatch(conn, %{resource: resource, params: params}, scope) do
    site? = scope in [:site, :saas_site]

    with true <- site? or is_binary(Ankole.Repo.tenant_id()),
         {:ok, params} <- canonical_targets(resource, params) do
      conn = %{
        conn
        | path_params: Map.merge(conn.path_params, params)
      }

      conn
      |> Ash.PlugHelpers.set_tenant(if(site?, do: nil, else: Ankole.Repo.tenant_id()))
      |> Ash.PlugHelpers.set_actor(conn.assigns[:authz_actor])
      |> Ash.PlugHelpers.set_context(browser_context(conn))
    else
      false -> reject(conn, 403, "tenant_required")
      {:error, _} -> reject(conn, 400, "invalid_target")
    end
  end

  def browser_context(conn) do
    origin =
      with id when is_binary(id) <- Ankole.Repo.tenant_id(),
           {:ok, tenant} <- Ankole.Tenants.get(id),
           do: AnkoleWeb.PodURL.origin(conn, tenant),
           else: (_ -> nil)

    %{
      browser_reference: AnkoleWeb.Session.browser_reference(conn),
      client_ip: to_string(:inet.ntoa(conn.remote_ip)),
      pod_origin: origin,
      authentication_ref: AnkoleWeb.Session.authentication_reference(conn)
    }
  end

  defp canonical_targets(resource, params) do
    fun = fn ->
      Enum.reduce_while(
        Ankole.AuthZ.Dsl.params(resource),
        {:ok, params},
        fn param, {:ok, acc} ->
          key = to_string(param.name)

          case Map.fetch(acc, key) do
            {:ok, value} ->
              case GrantCheck.resolve(param.type, value) do
                {:ok, value} -> {:cont, {:ok, Map.put(acc, key, value)}}
                error -> {:halt, error}
              end

            :error ->
              {:cont, {:ok, acc}}
          end
        end
      )
    end

    if is_nil(Ankole.Repo.tenant_id()) and
         Spark.Dsl.Extension.get_opt(resource, [:authz], :scope, nil) == :site_console do
      with {:ok, id} <- Ankole.Tenants.privileged_id(), do: Ankole.Repo.with_tenant(id, fun)
    else
      fun.()
    end
  end

  defp reject(conn, status, code) do
    conn
    |> put_resp_content_type("application/vnd.api+json")
    |> send_resp(status, Jason.encode!(%{errors: [%{status: to_string(status), code: code}]}))
    |> halt()
  end
end
