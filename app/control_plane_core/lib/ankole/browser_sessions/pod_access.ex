defmodule Ankole.BrowserSessions.PodAccess do
  @moduledoc """
  Multi-tenant Pod access proofs bound to site browser authentications.
  """
  require Ash.Query

  alias Ankole.BrowserSessions.{Authentication, Identity, PodAuthentication}
  alias Ankole.Repo

  def accept_invitation(reference, tenant_id, invitation_id) do
    Repo.transact_top_level(fn ->
      with_site_authentication(reference, fn authentication ->
        Repo.with_tenant(tenant_id, fn ->
          proof = Map.from_struct(authentication)

          with {:ok, principal} <-
                 Ankole.Principals.accept_site_invitation_in_tx(invitation_id, proof),
               {:ok, _} <- record_pod_access(authentication, principal),
               {:ok, _} <-
                 Identity.activate_in_tx(
                   %{"id" => authentication.browser_id},
                   reference,
                   tenant_id
                 ),
               do: {:ok, principal}
        end)
      end)
    end)
  end

  def claim_membership(ref, tenant_id) do
    Repo.transact_top_level(fn ->
      with_site_authentication(ref, fn authentication ->
        proof =
          authentication |> Map.from_struct() |> Map.put(:provider_id, authentication.provider_id)

        case Enum.find(
               Ankole.Principals.pending_site_memberships(proof),
               &(&1.tenant_id == tenant_id)
             ) do
          nil ->
            claim_invitation(authentication, tenant_id, proof)

          candidate ->
            Repo.with_tenant(tenant_id, fn ->
              claim_pending(authentication, candidate, proof)
            end)
        end
      end)
    end)
  end

  defp claim_pending(authentication, candidate, proof) do
    with :ok <- claim_current(proof),
         {:ok, %{status: :active} = principal} <-
           Ankole.Principals.lock_principal_in_tx(candidate.uid, :share),
         true <-
           Ankole.Principals.PodLoginPolicy.authentication_allowed?(
             principal,
             authentication.provider_id,
             proof
           ),
         {:ok, _} <-
           Ankole.Principals.bind_site_credential_in_tx(
             principal.uid,
             Map.put(proof, :subject_id, authentication.subject_id)
           ),
         {:ok, _} <- record_pod_access(authentication, principal),
         do: {:ok, principal},
         else: (
           false -> {:error, :login_policy_rejected}
           error -> error
         )
  end

  defp claim_current(proof) do
    if Ankole.Principals.site_credential_claim_current?(proof),
      do: :ok,
      else: {:error, :reauthentication_required}
  end

  defp claim_invitation(authentication, tenant_id, proof) do
    case Enum.find(
           Ankole.Principals.pending_invitations(proof.verified_email),
           &(&1.tenant_id == tenant_id)
         ) do
      nil ->
        {:error, :not_a_member}

      invitation ->
        Repo.with_tenant(tenant_id, fn ->
          with {:ok, principal} <-
                 Ankole.Principals.accept_site_invitation_in_tx(invitation.id, proof),
               {:ok, _} <- record_pod_access(authentication, principal),
               do: {:ok, principal}
        end)
    end
  end

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
           true <- Identity.current_binding?(authentication, %{principal_uid: principal.uid}),
           true <-
             Ankole.Principals.PodLoginPolicy.authentication_allowed?(
               principal,
               authentication.provider_id,
               Map.from_struct(authentication)
             ) do
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
