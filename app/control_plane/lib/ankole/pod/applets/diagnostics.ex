defmodule Ankole.Pod.Applets.Diagnostics do
  @moduledoc "Short-lived, revision-pinned authority for a stateless Applet render."
  alias Ankole.Pod.{Access, Pages}
  alias Ankole.Pod.Applets.Revisions
  @salt "applet-diagnostic"
  @ttl 60

  def ticket(actor, params) do
    id = Ankole.Attrs.get(params, :id)
    draft = Ankole.Attrs.get(params, :draft_id)
    props = Ankole.Attrs.get(params, :embed_props, %{})

    with true <- is_map(props),
         encoded_props = JSON.encode!(props),
         true <- byte_size(encoded_props) <= 16_384,
         true <- is_nil(draft) or (is_binary(draft) and match?({:ok, _}, Ecto.UUID.cast(draft))),
         {:ok, target} <-
           Ankole.Repo.transact_top_level(fn ->
             with {:ok, page} <- Pages.lock(id, :share),
                  {:ok, _} <-
                    Access.authorize(actor, page, if(draft, do: "node_edit", else: "node_view"),
                      trash: false
                    ),
                  :ok <- Ankole.Pod.Applets.available(page),
                  do:
                    Revisions.resolve_target_in_tx(
                      page,
                      if(draft, do: "draft:" <> draft, else: page.revision)
                    )
           end) do
      payload = %{
        tenant_id: Ankole.AuthZ.Actor.tenant_id(actor),
        uid: Ankole.AuthZ.Actor.uid(actor),
        turn_authority: actor.turn_authority,
        authn: actor.authn,
        page_id: id,
        target_ref: target.revision
      }

      token = Phoenix.Token.encrypt(AnkoleWeb.Endpoint, @salt, payload)
      base_url = AnkoleWeb.PodURL.current_tenant_url("/pod/applet-diagnostic/" <> token)

      fragment =
        if map_size(props) == 0,
          do: "",
          else: "#props=" <> Base.url_encode64(encoded_props, padding: false)

      {:ok,
       %{
         url: base_url <> fragment,
         expires_at: DateTime.add(DateTime.utc_now(), @ttl, :second)
       }}
    else
      false -> {:error, :invalid_request}
      error -> error
    end
  end

  def snapshot(diagnostic) do
    tx =
      Ankole.Repo.transact_top_level(fn ->
        with {:ok, page} <- Pages.lock(diagnostic.page_id, :share),
             {:ok, target} <- Revisions.resolve_target_in_tx(page, diagnostic.target_ref) do
          file = Enum.find(target.files, &(&1.path == "applet.bindings.json"))
          {:ok, {Map.take(page, [:id, :title, :revision]), file && file.object_id}}
        end
      end)

    with {:ok, {page, object_id}} <- tx,
         {:ok, bindings} <- Ankole.Pod.Applets.Bindings.from_object(page.id, object_id) do
      {:ok, Map.put(bindings, :page, page)}
    end
  end

  def authenticate(token) do
    with {:ok, %{tenant_id: tenant, uid: uid} = payload} <-
           Phoenix.Token.decrypt(AnkoleWeb.Endpoint, @salt, token, max_age: @ttl),
         :ok <- Ankole.Repo.put_tenant_id(tenant),
         {:ok, principal} <- Ankole.Principals.get_principal(uid),
         actor =
           Ankole.AuthZ.Actor.new(principal,
             turn_authority: Map.get(payload, :turn_authority),
             authn: Map.get(payload, :authn, %{})
           ),
         {:ok, _principal} <- Access.principal(actor),
         {:ok, _} <-
           Pages.authorize(
             actor,
             payload.page_id,
             if(is_binary(payload.target_ref), do: "node_edit", else: "node_view")
           ) do
      {:ok,
       %{
         tenant_id: tenant,
         actor: actor,
         page_id: payload.page_id,
         target_ref: payload.target_ref
       }}
    else
      _ -> {:error, :forbidden}
    end
  end
end
