defmodule AnkoleWeb.PodSocket do
  @moduledoc "One authenticated realtime connection for a browser's Pod tab."
  use Phoenix.Socket
  channel "page:*", AnkoleWeb.PodPageChannel
  channel "table:*", AnkoleWeb.PodRoomChannel
  channel "applet:*", AnkoleWeb.PodRoomChannel

  def token(conn), do: token(conn.assigns.current_principal_uid, AnkoleWeb.Session.authentication_reference(conn))

  def token(uid, authentication) do
    Phoenix.Token.sign(AnkoleWeb.Endpoint, "pod-socket", %{
      tenant_id: Ankole.Repo.tenant_id!(),
      uid: uid,
      authentication: authentication
    })
  end

  @impl true
  def connect(%{"token" => token}, socket, info) do
    with {:ok, attrs} <-
           Phoenix.Token.verify(AnkoleWeb.Endpoint, "pod-socket", token, max_age: 60),
         {:ok, {:pod, tenant_id}} <- AnkoleWeb.Plugs.RequestHost.classify_uri(info[:uri]),
         true <- tenant_id == attrs.tenant_id,
         true <- active?(attrs),
         do: {:ok, assign(socket, attrs)},
         else: (_ -> :error)
  end

  def connect(_, _, _), do: :error
  @impl true
  def id(socket), do: "pod:#{socket.assigns.tenant_id}:#{socket.assigns.uid}"

  def active?(attrs) do
    Ankole.Repo.with_tenant(attrs.tenant_id, fn ->
      with %{"principal_uid" => uid} <-
             Ankole.BrowserSessions.authentication(attrs.authentication, :pod),
           true <- uid == attrs.uid,
           {:ok, _} <- Ankole.Pod.Access.principal(uid),
           do: true,
           else: (_ -> false)
    end)
  end
end
