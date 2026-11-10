defmodule AnkoleWeb.Plugs.RequestHost do
  @moduledoc """
  The build-selected Host classification for HTTP and Worker connections.

  A Host context is `:site`, `:cloud_api`, or `{:pod, tenant_id}`. The default FOSS
  classification recognizes Site and Pod hosts only. An edition that serves another Host
  category registers a classifier through `config :ankole, :request_host_classifier` (or
  `register_classifier/1`); it must export `classify/1`, accept a `URI.t()`, and return
  `{:ok, context}` for a claimed host or `:error` to leave the host to the build-selected
  `:host_policy`.
  """

  @behaviour Plug

  @type context :: :site | :cloud_api | {:pod, Ecto.UUID.t()}
  @type classifier :: module() | {module(), atom()} | (URI.t() -> {:ok, context()} | :error)

  @callback classify(URI.t()) :: {:ok, context()} | :error
  @callback domain() :: String.t()
  @callback pod_origin(%Ankole.Tenants.Tenant{}) :: String.t()
  @callback canonical_origin(:site | :cloud_api | {:pod, Ecto.UUID.t()}) :: String.t()
  @callback login_url(Ankole.Tenants.Tenant.t() | nil, map()) :: String.t()
  @callback membership_login_url(Plug.Conn.t(), Ankole.Tenants.Tenant.t(), atom(), map()) ::
              {:ok, String.t()} | {:error, atom()}
  @callback site_admin_console_origin() :: String.t()
  @optional_callbacks site_admin_console_origin: 0

  @classifier_key :request_host_classifier
  @policy Application.compile_env(:ankole, :host_policy)

  @doc "Returns the origin of the proxy-normalized request."
  @spec origin(Plug.Conn.t()) :: String.t()
  def origin(conn) do
    URI.to_string(%URI{scheme: Atom.to_string(conn.scheme), host: conn.host, port: conn.port})
  end

  @doc "Registers the Host classifier consulted before the build-selected policy."
  @spec register_classifier(classifier()) :: :ok
  def register_classifier(classifier) do
    Application.put_env(:ankole, @classifier_key, classifier)
    :ok
  end

  @doc "Removes the registered Host classifier."
  @spec unregister_classifier() :: :ok
  def unregister_classifier do
    Application.delete_env(:ankole, @classifier_key)
    :ok
  end

  @doc "Returns the registered Host classifier, if any."
  @spec classifier() :: classifier() | nil
  def classifier, do: Application.get_env(:ankole, @classifier_key)

  @doc "Classifies a request URI, consulting the registered classifier first."
  def classify_uri(%URI{} = uri) do
    case classify_registered(uri) do
      {:ok, context} -> {:ok, context}
      :error -> classify_build(uri)
    end
  end

  def classify_uri(uri), do: classify_build(uri)

  @impl true
  def init(opts), do: opts

  if @policy do
    @impl true
    def call(conn, _opts) do
      case classify_uri(Plug.Conn.request_url(conn) |> URI.parse()) do
        {:ok, {:pod, tenant_id} = context} ->
          :ok = Ankole.Repo.put_tenant_id(tenant_id)
          Plug.Conn.assign(conn, :host_context, context)

        {:ok, :cloud_api} ->
          Plug.Conn.assign(conn, :host_context, :cloud_api)

        {:ok, :site} ->
          Plug.Conn.assign(conn, :host_context, :site)

        _ ->
          conn |> Plug.Conn.send_resp(400, "Invalid host") |> Plug.Conn.halt()
      end
    end

    def worker_allowed?(uri), do: is_struct(uri, URI) and classify_uri(uri) == {:ok, :site}
  else
    @impl true
    def call(conn, _opts) do
      case classify_uri(Plug.Conn.request_url(conn) |> URI.parse()) do
        {:ok, {:pod, tenant_id} = context} ->
          :ok = Ankole.Repo.put_tenant_id(tenant_id)
          Plug.Conn.assign(conn, :host_context, context)

        {:ok, :cloud_api} ->
          Plug.Conn.assign(conn, :host_context, :cloud_api)

        {:ok, context} ->
          conn = Plug.Conn.assign(conn, :host_context, context)

          if conn.method == "GET" and conn.host in ["localhost", "127.0.0.1", "::1"] and
               browser_shell?(conn.request_path) and
               URI.parse(AnkoleWeb.PodURL.site_origin(conn)).host != conn.host do
            if Map.has_key?(URI.decode_query(conn.query_string), "oauth_request") do
              conn
              |> Plug.Conn.send_resp(
                401,
                "The sign-in address changed. Open #{AnkoleWeb.PodURL.site_origin(conn)} to sign in again."
              )
              |> Plug.Conn.halt()
            else
              query = if conn.query_string == "", do: "", else: "?" <> conn.query_string

              conn
              |> Phoenix.Controller.redirect(
                external: AnkoleWeb.PodURL.site_origin(conn) <> conn.request_path <> query
              )
              |> Plug.Conn.halt()
            end
          else
            conn
          end

        :error ->
          conn |> Plug.Conn.send_resp(404, "Pod not found") |> Plug.Conn.halt()
      end
    end

    def worker_allowed?(_uri), do: true

    defp browser_shell?(path) do
      console = AnkoleWeb.SiteAdminConsole.path()

      path in ["/", "/setup", "/sessions/new", console] or
        String.starts_with?(path, ["/setup/", console <> "/"])
    end
  end

  if @policy do
    defp classify_build(uri), do: @policy.classify(uri)
  else
    defp classify_build(uri), do: AnkoleWeb.PodURL.local_host(uri)
  end

  defp classify_registered(uri) do
    case classifier() do
      nil -> :error
      classifier -> classifier |> invoke_classifier(uri) |> validate_classification(uri)
    end
  end

  defp invoke_classifier({module, fun}, uri) when is_atom(module) and is_atom(fun) do
    _ = Code.ensure_loaded(module)

    if function_exported?(module, fun, 1) do
      apply(module, fun, [uri])
    else
      raise ArgumentError, "Host classifier #{inspect(module)} does not export #{fun}/1"
    end
  end

  defp invoke_classifier(module, uri) when is_atom(module) do
    _ = Code.ensure_loaded(module)

    if function_exported?(module, :classify, 1) do
      module.classify(uri)
    else
      raise ArgumentError, "Host classifier #{inspect(module)} does not export classify/1"
    end
  end

  defp invoke_classifier(fun, uri) when is_function(fun, 1), do: fun.(uri)

  defp invoke_classifier(other, _uri) do
    raise ArgumentError, "invalid Host classifier: #{inspect(other)}"
  end

  defp validate_classification({:ok, context}, _uri) when context in [:site, :cloud_api],
    do: {:ok, context}

  defp validate_classification({:ok, {:pod, tenant_id}}, _uri) when is_binary(tenant_id),
    do: {:ok, {:pod, tenant_id}}

  defp validate_classification(:error, _uri), do: :error

  defp validate_classification(other, uri) do
    raise ArgumentError, "invalid Host classification #{inspect(other)} for #{URI.to_string(uri)}"
  end
end
