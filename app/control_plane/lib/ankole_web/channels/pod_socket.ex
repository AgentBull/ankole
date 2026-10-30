defmodule AnkoleWeb.PodSocket do
  @moduledoc "One authenticated realtime connection for a browser's Pod tab."
  use Phoenix.Socket
  channel "content", AnkoleWeb.PodContentChannel
  channel "page:*", AnkoleWeb.PodPageChannel
  channel "table:*", AnkoleWeb.PodRoomChannel
  channel "applet:*", AnkoleWeb.PodRoomChannel

  def token(conn),
    do:
      token(conn.assigns.current_principal_uid, AnkoleWeb.Session.authentication_reference(conn))

  def token(uid, authentication) do
    Phoenix.Token.sign(AnkoleWeb.Endpoint, "pod-socket", %{
      tenant_id: Ankole.Repo.tenant_id!(),
      uid: uid,
      authentication: authentication
    })
  end

  @impl true
  def connect(%{"token" => token}, socket, %{peer_data: %{address: address}} = info) do
    with {:ok, attrs} <-
           Phoenix.Token.verify(AnkoleWeb.Endpoint, "pod-socket", token, max_age: 60),
         {:ok, {:pod, tenant_id}} <- AnkoleWeb.Plugs.RequestHost.classify_uri(info[:uri]),
         true <- tenant_id == attrs.tenant_id,
         true <- active?(attrs),
         {:ok, actor} <- actor(attrs, request_context(address, info)),
         do: {:ok, assign(socket, Map.put(attrs, :actor, actor))},
         else: (_ -> :error)
  end

  def connect(_, _, _), do: :error
  @impl true
  def id(socket), do: "pod:#{socket.assigns.tenant_id}:#{socket.assigns.uid}"

  defp request_context(address, info) do
    ip = AnkoleWeb.Endpoint.client_ip(address, Map.get(info, :x_headers, []))
    %{"surface" => "pod_browser", "ip" => ip |> :inet.ntoa() |> to_string()}
  end

  def actor(attrs, context) do
    Ankole.Repo.with_tenant(attrs.tenant_id, fn ->
      with %{} = authentication <-
             Ankole.BrowserSessions.identity(attrs.authentication, attrs.tenant_id),
           {:ok, principal} <- Ankole.Principals.get_principal(attrs.uid),
           do:
             {:ok,
              Ankole.AuthZ.Actor.from_browser(
                principal,
                authentication,
                "pod_browser",
                context["ip"]
              )},
           else: (_ -> {:error, :forbidden})
    end)
  end

  def active?(attrs) do
    Ankole.Repo.with_tenant(attrs.tenant_id, fn ->
      with %{"principal_uid" => uid} <-
             Ankole.BrowserSessions.identity(attrs.authentication, attrs.tenant_id),
           true <- uid == attrs.uid,
           {:ok, principal} <- Ankole.Principals.get_principal(uid),
           {:ok, _} <- Ankole.Pod.Access.principal(Ankole.AuthZ.Actor.new(principal)),
           do: true,
           else: (_ -> false)
    end)
  end
end
