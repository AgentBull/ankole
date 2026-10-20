defmodule AnkoleWeb.PodURL do
  @moduledoc "Canonical tenant origins and browser paths; durable IDs stay UUIDs."
  alias Ankole.{Kernel, Repo, Tenants}

  @host_policy Application.compile_env(:ankole, :host_policy)

  def origin(conn, %Tenants.Tenant{} = tenant) do
    if @host_policy do
      apply(@host_policy, :pod_origin, [tenant])
    else
      URI.to_string(%URI{
        scheme: to_string(conn.scheme),
        host: tenant.slug <> "." <> domain(),
        port: conn.port
      })
    end
  end

  def site_origin(conn) do
    if @host_policy do
      apply(@host_policy, :canonical_origin, [:site])
    else
      URI.to_string(%URI{scheme: to_string(conn.scheme), host: domain(), port: conn.port})
    end
  end

  def local_host(%URI{host: host}) when is_binary(host) do
    host = host |> String.downcase() |> String.trim_trailing(".")
    suffix = "." <> domain()

    if String.ends_with?(host, suffix) do
      slug = String.replace_suffix(host, suffix, "")

      case Repo.get_by(Tenants.Tenant, slug: slug) do
        %Tenants.Tenant{suspended_at: nil, deleting_at: nil} = tenant ->
          {:ok, {:pod, tenant.id}}

        _ ->
          :error
      end
    else
      {:ok, :site}
    end
  end

  def local_host(_), do: :error

  def path(conn) do
    segments =
      case conn.path_info do
        ["pod" | rest] -> rest
        rest -> rest
      end

    with {:ok, path} <- browser_path(segments) do
      query =
        conn.query_string
        |> URI.decode_query()
        |> Map.delete("tenant_id")
        |> Map.new(fn
          {"chat", value} -> {"chat", short_id(value) || value}
          entry -> entry
        end)
        |> URI.encode_query()

      {:ok, path <> if(query == "", do: "", else: "?" <> query)}
    end
  end

  defp browser_path([]), do: {:ok, "/"}

  defp browser_path(["content", scope])
       when scope in ~w(space private shared recent favorites trash search),
       do: {:ok, "/content/" <> scope}

  defp browser_path(["content", _scope]), do: {:ok, "/content/space"}

  defp browser_path([kind, value]) when kind in ~w(pages conversations) do
    case short_id(value) do
      nil -> {:error, :not_found}
      short -> {:ok, "/" <> kind <> "/" <> short}
    end
  end

  defp browser_path(_), do: {:error, :not_found}

  defp short_id(value) do
    case Kernel.uuid_shorten(value) do
      short when is_binary(short) -> short
      _ -> if is_binary(Kernel.uuid_expand(value)), do: value
    end
  end

  defp domain do
    host = AnkoleWeb.Endpoint.config(:url)[:host] || "localhost"
    if host in ["127.0.0.1", "::1"], do: "localhost", else: host
  end
end
