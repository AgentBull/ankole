defmodule AnkoleWeb.PodURL do
  @moduledoc "Canonical tenant origins and browser paths; durable IDs stay UUIDs."
  alias Ankole.{Kernel, Tenants}

  @host_policy Application.compile_env(:ankole, :host_policy)
  @short_uuid_len 26
  @max_incoming_slug_len 120
  @max_page_slug_len 60
  @min_word_boundary_len 16
  @incoming_slug_pattern ~r/\A[A-Za-z0-9]+(?:[-_][A-Za-z0-9]+)*\z/

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

  def tenant_origin(%Tenants.Tenant{} = tenant) do
    if @host_policy do
      apply(@host_policy, :pod_origin, [tenant])
    else
      uri = URI.parse(AnkoleWeb.Endpoint.url())

      URI.to_string(%URI{
        scheme: uri.scheme || "http",
        host: tenant.slug <> "." <> domain(),
        port: uri.port
      })
    end
  end

  def current_tenant_url(path) when is_binary(path) do
    normalized_path = if String.starts_with?(path, "/"), do: path, else: "/" <> path

    base =
      with tenant_id when is_binary(tenant_id) <- Ankole.Repo.tenant_id(),
           {:ok, %Tenants.Tenant{} = tenant} <- Tenants.get(tenant_id) do
        String.trim_trailing(tenant_origin(tenant), "/")
      else
        _ -> String.trim_trailing(AnkoleWeb.Endpoint.url(), "/")
      end

    base <> normalized_path
  end

  def site_origin(conn) do
    if @host_policy do
      apply(@host_policy, :canonical_origin, [:site])
    else
      URI.to_string(%URI{scheme: to_string(conn.scheme), host: domain(), port: conn.port})
    end
  end

  def login_url(conn, tenant, params \\ %{}) do
    if @host_policy,
      do: apply(@host_policy, :login_url, [tenant, params]),
      else: append_query(origin(conn, tenant) <> "/sessions/new", params)
  end

  def membership_login_url(conn, tenant, reason, params) do
    if @host_policy,
      do: apply(@host_policy, :membership_login_url, [conn, tenant, reason, params]),
      else: {:ok, login_url(conn, tenant, params)}
  end

  def oidc_authorization_url(conn, tenant, provider_id),
    do: origin(conn, tenant) <> oidc_authorization_path(provider_id)

  def oidc_authorization_path(provider_id),
    do: "/sessions/oidc/" <> URI.encode(provider_id) <> "/authorization"

  def oauth_return_to(conn, request) do
    if @host_policy do
      {:ok, tenant} = Tenants.get(request.tenant_id)

      if Ankole.OIDC.LoginPolicy.authorization_ready?(request),
        do: origin(conn, tenant) <> "/oauth/authorize/resume?oauth_request=" <> request.id,
        else: login_url(conn, tenant, %{"oauth_request" => request.id})
    else
      path =
        if Ankole.OIDC.LoginPolicy.authorization_ready?(request),
          do: "/oauth/authorize/resume",
          else: "/sessions/new"

      path <> "?oauth_request=" <> request.id
    end
  end

  defp append_query(url, params) when map_size(params) == 0, do: url
  defp append_query(url, params), do: url <> "?" <> URI.encode_query(params)

  def local_host(%URI{host: host}) when is_binary(host) do
    host = host |> String.downcase() |> String.trim_trailing(".")
    suffix = "." <> domain()

    if String.ends_with?(host, suffix) do
      slug = String.replace_suffix(host, suffix, "")

      case Tenants.active_by_slug(slug) do
        {:ok, tenant} ->
          {:ok, {:pod, tenant.id}}

        _ ->
          :error
      end
    else
      {:ok, :site}
    end
  end

  def local_host(_), do: :error

  def page_path(id, title \\ nil) when is_binary(id) do
    short = short_id(id) || raise ArgumentError, "invalid Page ID: #{inspect(id)}"
    slug = if is_binary(title) and title != "", do: Kernel.page_url_slug(title), else: ""
    if slug == "", do: "/pages/" <> short, else: "/pages/" <> slug <> "-" <> short
  end

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

  defp browser_path([path]) when path in ["settings", "me", "connectors"],
    do: {:ok, "/" <> path}

  defp browser_path([]), do: {:ok, "/"}

  defp browser_path(["meta" | rest]),
    do:
      {:ok,
       "/" <>
         Enum.map_join(["meta" | rest], "/", &URI.encode(&1, fn c -> URI.char_unreserved?(c) end))}

  defp browser_path(["dm", uid]), do: {:ok, "/dm/" <> URI.encode(uid, &URI.char_unreserved?/1)}

  defp browser_path(["content", scope])
       when scope in ~w(all space private shared recent favorites trash search),
       do: {:ok, "/content/" <> scope}

  defp browser_path(["content", _scope]), do: {:ok, "/content/space"}

  defp browser_path(["pages", value]) do
    case page_segment(value) do
      nil -> {:error, :not_found}
      segment -> {:ok, "/pages/" <> segment}
    end
  end

  defp browser_path(["conversations", value]) do
    case short_id(value) do
      nil -> {:error, :not_found}
      short -> {:ok, "/conversations/" <> short}
    end
  end

  defp browser_path(_), do: {:error, :not_found}

  defp page_segment(value) do
    case short_id(value) do
      short when is_binary(short) -> short
      nil -> slugged_page_segment(value)
    end
  end

  defp slugged_page_segment(value) when byte_size(value) > @short_uuid_len + 1 do
    prefix_len = byte_size(value) - @short_uuid_len - 1

    case value do
      <<prefix::binary-size(^prefix_len), "-", suffix::binary-size(@short_uuid_len)>>
      when prefix_len <= @max_incoming_slug_len ->
        with true <- Regex.match?(@incoming_slug_pattern, prefix),
             short when is_binary(short) <- canonical_short_id(suffix) do
          slug =
            prefix
            |> String.downcase(:ascii)
            |> String.replace("_", "-")
            |> truncate_page_slug()

          slug <> "-" <> short
        else
          _ -> nil
        end

      _ ->
        nil
    end
  end

  defp slugged_page_segment(_), do: nil

  defp truncate_page_slug(slug) when byte_size(slug) <= @max_page_slug_len, do: slug

  defp truncate_page_slug(slug) do
    sliced =
      slug
      |> binary_part(0, @max_page_slug_len)
      |> String.trim_trailing("-")

    case List.last(:binary.matches(sliced, "-")) do
      {index, 1} when index >= @min_word_boundary_len -> binary_part(sliced, 0, index)
      _ -> sliced
    end
  end

  defp short_id(value) when is_binary(value) do
    case Kernel.uuid_shorten(value) do
      short when is_binary(short) -> short
      _ -> canonical_short_id(value)
    end
  end

  defp short_id(_), do: nil

  defp canonical_short_id(value) when byte_size(value) == @short_uuid_len do
    lower = String.downcase(value, :ascii)
    if is_binary(Kernel.uuid_expand(lower)), do: lower
  end

  defp canonical_short_id(_), do: nil

  defp domain do
    host = AnkoleWeb.Endpoint.config(:url)[:host] || "localhost"
    if host in ["127.0.0.1", "::1"], do: "localhost", else: host
  end
end
