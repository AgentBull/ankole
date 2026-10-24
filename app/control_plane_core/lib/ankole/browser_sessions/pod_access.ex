defmodule Ankole.BrowserSessions.PodAccess do
  @moduledoc """
  Multi-tenant Pod access proofs bound to site browser authentications.
  """
  require Ash.Query

  alias Ankole.BrowserSessions.{Authentication, Identity, PodAuthentication}
  alias Ankole.Repo

  @doc """
  Records initial access in the same transaction that creates a Pod and its Human.

  `create` runs in that transaction, so it calls only `_in_tx` functions.
  """
  def create_pod_access(authentication_ref, create) when is_function(create, 1) do
    Repo.transact_top_level(fn -> create_pod_access_in_tx(authentication_ref, create) end)
  end

  @doc false
  def create_pod_access_in_tx(authentication_ref, create) do
    with_site_authentication(authentication_ref, fn authentication ->
      with {:ok, %{principal: principal} = created} <- create.(authentication),
           true <- is_nil(principal.access_revoked_at),
           {:ok, _} <- record_pod_access(authentication, principal) do
        {:ok, created}
      else
        false -> {:error, :invalid_authentication}
        error -> error
      end
    end)
  end

  @doc """
  Connects a verified Pod identity without refreshing the parent authentication.

  `connect` runs in the transaction of the connection, so it calls only
  `_in_tx` functions.
  """
  def connect_pod_access(authentication_ref, verified_ref, tenant_id, connect)
      when is_function(connect, 2) do
    Repo.transact_top_level(fn ->
      connect_pod_access_in_tx(authentication_ref, verified_ref, tenant_id, connect)
    end)
  end

  @doc false
  def connect_pod_access_in_tx(authentication_ref, verified_ref, tenant_id, connect) do
    with_site_authentication(authentication_ref, fn authentication ->
      Repo.with_tenant(tenant_id, fn ->
        with {:ok, verified} <- Identity.fetch_authentication(verified_ref),
             true <- verified.browser_id == authentication.browser_id,
             %{} = proof <- Identity.identity(verified_ref, tenant_id),
             {:ok, principal} <- Identity.lock_human(proof),
             {:ok, result} <- connect.(authentication, principal),
             {:ok, _} <- record_pod_access(authentication, principal) do
          {:ok, result}
        else
          false -> {:error, :invalid_authentication}
          nil -> {:error, :invalid_authentication}
          error -> error
        end
      end)
    end)
  end

  @doc false
  def save_pod_authentications(authentication, principals) do
    tenant_ids =
      PodAuthentication
      |> Ash.Query.for_read(:lookup_across_tenants)
      |> Ash.Query.filter(authentication_id == ^authentication.id)
      |> Ankole.Ash.read_across_tenants!()
      |> Enum.map(& &1.tenant_id)
      |> Enum.uniq()

    with :ok <- remove_pod_authentications(authentication, tenant_ids) do
      Enum.reduce_while(principals, :ok, fn principal, :ok ->
        result =
          Repo.with_tenant(principal.tenant_id, fn ->
            Ankole.Ash.create(PodAuthentication, :record_in_tx, %{
              authentication_id: authentication.id,
              principal_uid: principal.uid,
              access_version: principal.access_version
            })
          end)

        case result do
          {:ok, _} -> {:cont, :ok}
          error -> {:halt, error}
        end
      end)
    end
  end

  defp with_site_authentication(ref, action) do
    Identity.in_transaction!(:with_site_authentication)

    with {:ok, authentication} <- Identity.fetch_authentication(ref),
         {:ok, _} <- Identity.fetch_browser(%{"id" => authentication.browser_id}, true),
         {:ok, %Authentication{purpose: :site} = authentication} <-
           Identity.fetch_authentication(ref),
         true <- Ankole.IdentityProviders.SiteSources.registered?(authentication.provider_id) do
      action.(authentication)
    else
      false -> {:error, :invalid_authentication}
      {:ok, _} -> {:error, :invalid_authentication}
      error -> error
    end
  end

  defp record_pod_access(authentication, principal) do
    Repo.with_tenant(principal.tenant_id, fn ->
      with {:ok, principal} <-
             Identity.lock_human(%{
               "principal_uid" => principal.uid,
               "access_version" => principal.access_version
             }),
           true <- Ankole.Tenants.accepting_work?(principal.tenant_id),
           true <- Identity.current_binding?(authentication, %{principal_uid: principal.uid}) do
        Ankole.Ash.create(PodAuthentication, :record_in_tx, %{
          authentication_id: authentication.id,
          principal_uid: principal.uid,
          access_version: principal.access_version
        })
      else
        false -> {:error, :invalid_authentication}
        error -> error
      end
    end)
  end

  defp remove_pod_authentications(authentication, tenant_ids) do
    Enum.reduce_while(tenant_ids, :ok, fn tenant_id, :ok ->
      result =
        Repo.with_tenant(tenant_id, fn ->
          PodAuthentication
          |> Ash.Query.filter(authentication_id == ^authentication.id)
          |> Ankole.Ash.destroy_where(:remove_in_tx)
        end)

      case result do
        {:ok, _} -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end
end
