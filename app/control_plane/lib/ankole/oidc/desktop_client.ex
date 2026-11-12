defmodule Ankole.OIDC.DesktopClient do
  @moduledoc """
  Provisions and resolves the per-tenant OIDC public client for Ankole Desktop.

  Each tenant owns a deterministic public PKCE client identifier so native
  desktop workspaces can sign in without manual client registration while
  tenant administrators retain full control to disable or restrict the client
  in Console.
  """

  alias Ankole.{OIDC, Repo, Tenants}
  alias Ankole.OIDC.Client

  @client_name "Ankole Desktop"
  @redirect_uri "ankole://oauth/callback"
  @default_scopes ~w(openid profile email offline_access pod)

  @spec redirect_uri() :: String.t()
  def redirect_uri, do: @redirect_uri

  @spec default_scopes() :: [String.t()]
  def default_scopes, do: @default_scopes

  @doc "Derives the deterministic UUIDv8 client identifier for one tenant."
  @spec client_id(String.t()) :: Ecto.UUID.t()
  def client_id(tenant_id) when is_binary(tenant_id) do
    <<a::48, _version::4, b::12, _variant::2, c::62, _rest::binary>> =
      :crypto.hash(:sha256, ["ankole.oidc.desktop_client:", tenant_id])

    {:ok, uuid} = Ecto.UUID.load(<<a::48, 8::4, b::12, 2::2, c::62>>)
    uuid
  end

  @doc "Returns the active desktop client for the current tenant, creating it on first use."
  @spec ensure() ::
          {:ok, Client.t()} | {:error, :desktop_client_disabled | :tenant_suspended | term()}
  def ensure do
    tenant_id = Repo.tenant_id!()
    id = client_id(tenant_id)

    if Tenants.accepting_work?(tenant_id) do
      case OIDC.get_client(id) do
        {:ok, client} ->
          validate_existing(client)

        {:error, :not_found} ->
          provision(tenant_id, id)
      end
    else
      {:error, :tenant_suspended}
    end
  end

  defp provision(tenant_id, id) do
    Repo.transact_top_level(fn ->
      with {:ok, tenant} <- Tenants.lock_tenant_in_tx(tenant_id, :update),
           true <- Tenants.accepting_work?(tenant) do
        case OIDC.get_client(id) do
          {:ok, client} ->
            validate_existing(client)

          {:error, :not_found} ->
            OIDC.create_client_in_tx(
              %{
                id: id,
                name: @client_name,
                enabled: true,
                client_type: :public,
                secret_ciphertext: nil,
                redirect_uris: [@redirect_uri],
                scopes: @default_scopes,
                model_aliases: %{},
                allowed_group_ids: []
              },
              []
            )
        end
      else
        false -> {:error, :tenant_suspended}
        {:error, :not_found} -> {:error, :tenant_suspended}
      end
    end)
  end

  defp validate_existing(%Client{enabled: true} = client) do
    if "pod" in client.scopes and @redirect_uri in client.redirect_uris do
      {:ok, client}
    else
      {:error, :desktop_client_disabled}
    end
  end

  defp validate_existing(%Client{}), do: {:error, :desktop_client_disabled}
end
