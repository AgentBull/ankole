defmodule AnkoleWeb.Plugs.RequestHost do
  @moduledoc "The build-selected Host classification for HTTP and Worker connections."
  @behaviour Plug

  @callback classify(URI.t()) :: {:ok, :site | :public | {:pod, Ecto.UUID.t()}} | :error
  @policy Application.compile_env(:ankole, :host_policy)

  @impl true
  def init(opts), do: opts

  if @policy do
    @impl true
    def call(conn, _opts) do
      case @policy.classify(Plug.Conn.request_url(conn) |> URI.parse()) do
        {:ok, {:pod, tenant_id} = context} ->
          :ok = Ankole.Repo.put_tenant_id(tenant_id)
          Plug.Conn.assign(conn, :host_context, context)

        {:ok, context} when context in [:site, :public] ->
          Plug.Conn.assign(conn, :host_context, context)

        _ ->
          conn |> Plug.Conn.send_resp(400, "Invalid host") |> Plug.Conn.halt()
      end
    end

    def worker_allowed?(uri), do: is_struct(uri, URI) and @policy.classify(uri) == {:ok, :site}
  else
    @impl true
    def call(conn, _opts), do: conn
    def worker_allowed?(_uri), do: true
  end
end
