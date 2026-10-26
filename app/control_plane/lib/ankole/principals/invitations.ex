defmodule Ankole.Principals.Invitations do
  @moduledoc false
  require Ash.Query
  alias Ankole.Authn.SecretDigest
  alias Ankole.Principals.{Invitation, PodLoginPolicy, SiteCredentials}
  alias Ankole.{Principals, Repo}

  def create(uid, attrs) do
    token = SecretDigest.token()
    code = :crypto.strong_rand_bytes(9) |> Base.url_encode64(padding: false) |> String.upcase()

    with :ok <- valid_invitation(attrs),
         {:ok, invitation} <-
           Repo.transact_top_level(fn ->
             with :ok <- allow_invitation(attrs),
                  :ok <-
                    Ankole.Plugins.Hook.before_commit_in_tx(
                      :create_invitation,
                      Map.put(attrs, :created_by_principal_uid, uid)
                    ),
                  do:
                    Ankole.Ash.create(
                      Invitation,
                      :create_in_tx,
                      Map.merge(attrs, %{
                        created_by_principal_uid: uid,
                        token_digest: SecretDigest.digest("invitation", token),
                        code_digest: SecretDigest.digest("invitation-code", code)
                      })
                    )
           end),
         do: {:ok, %{invitation: invitation, token: token, code: code}}
  end

  defp valid_invitation(attrs) do
    with true <- DateTime.compare(attrs.expires_at, DateTime.utc_now()) == :gt,
         {:ok, policy} <- PodLoginPolicy.get(),
         true <- attrs.kind != :link or policy["allow_invite_links"],
         true <-
           is_nil(attrs.invited_email) or
             (is_binary(attrs.invited_email) and
                Regex.match?(~r/\A[^\s@]+@[^\s@]+\.[^\s@]+\z/, attrs.invited_email)),
         do: :ok,
         else: (_ -> {:error, :invalid_invitation})
  end

  defp allow_invitation(%{membership: :guest}) do
    if Ankole.Pod.Config.allow_external_guests?(),
      do: :ok,
      else: {:error, :external_guests_disabled}
  end

  defp allow_invitation(_), do: :ok

  def list, do: Invitation |> Ash.Query.sort(inserted_at: :desc) |> Ankole.Ash.read!()

  def for_login(nil), do: {:ok, nil}

  def for_login(id) do
    with %Invitation{} = invitation <-
           Invitation |> Ash.Query.filter(id == ^id) |> Ankole.Ash.read_one!(),
         :ok <- usable?(invitation),
         do: {:ok, invitation},
         else: (_ -> {:error, :invitation_unavailable})
  end

  def revoke(id) do
    Repo.transact_top_level(fn ->
      with %Invitation{} = invitation <-
             Invitation |> Ash.Query.filter(id == ^id) |> Ankole.Ash.read_one!(),
           do: Ankole.Ash.update(invitation, :revoke_in_tx, %{}),
           else: (_ -> {:error, :not_found})
    end)
  end

  def locate(secret) when is_binary(secret) do
    token = SecretDigest.digest("invitation", secret)
    code = SecretDigest.digest("invitation-code", String.upcase(String.trim(secret)))

    case Invitation
         |> Ash.Query.for_read(:read_across_tenants)
         |> Ash.Query.filter(token_digest == ^token or code_digest == ^code)
         |> Ankole.Ash.read_across_tenants!() do
      [invitation] ->
        with :ok <- usable?(invitation), do: {:ok, invitation}

      _ ->
        {:error, :invitation_unavailable}
    end
  end

  def locate(_), do: {:error, :invitation_unavailable}

  def pending(email) when is_binary(email) do
    now = DateTime.utc_now()

    Invitation
    |> Ash.Query.for_read(:read_across_tenants)
    |> Ash.Query.filter(
      kind == :email and invited_email == ^email and is_nil(revoked_at) and
        expires_at > ^now and (is_nil(max_uses) or used_count < max_uses)
    )
    |> Ash.Query.sort(inserted_at: :desc)
    |> Ankole.Ash.read_across_tenants!()
    |> Enum.filter(&Ankole.Tenants.accepting_work?(&1.tenant_id))
  end

  def pending(_), do: []

  def accept_site_in_tx(id, proof) do
    :ok = Repo.require_transaction()

    with :ok <- Ankole.Pod.Pages.lock_tree(),
         {:ok, invitation} <- lock(id),
         :ok <- usable?(invitation),
         :ok <- require_email(invitation, proof.verified_email),
         :ok <- require_current_claim(proof),
         {:ok, principal, created?} <- invited_member(invitation, proof),
         :ok <- require_policy(principal, proof),
         {:ok, _} <- SiteCredentials.bind_in_tx(principal.uid, proof),
         :ok <- consume(invitation, created?) do
      {:ok, principal}
    end
  end

  defp require_email(%{invited_email: email}, verified) when email in [nil, verified], do: :ok
  defp require_email(_, _), do: {:error, :invitation_identity_mismatch}

  defp require_current_claim(proof),
    do:
      if(SiteCredentials.claim_current?(proof),
        do: :ok,
        else: {:error, :reauthentication_required}
      )

  defp require_policy(principal, proof),
    do:
      if(PodLoginPolicy.authentication_allowed?(principal, proof.provider_id, proof),
        do: :ok,
        else: {:error, :login_policy_rejected}
      )

  defp invited_member(invitation, proof) do
    existing =
      SiteCredentials.list(proof.provider_id, proof.subject_id)
      |> Enum.find(&(&1.tenant_id == Repo.tenant_id!()))

    if existing do
      with {:ok, %{status: :active} = principal} <-
             Principals.lock_principal_in_tx(existing.principal_uid, :share),
           do: {:ok, principal, false},
           else: (_ -> {:error, :human_access_revoked})
    else
      candidate =
        proof
        |> SiteCredentials.pending_memberships()
        |> Enum.find(&(&1.tenant_id == Repo.tenant_id!()))

      join_member(candidate, invitation, proof)
    end
  end

  defp join_member(nil, invitation, proof) do
    with {:ok, %{principal: principal}} <-
           Principals.create_human_in_tx(%{
             display_name: proof.verified_email,
             email: proof.verified_email,
             membership: invitation.membership
           }),
         do: {:ok, principal, true}
  end

  defp join_member(candidate, _invitation, _proof) do
    with {:ok, %{status: :active} = principal} <-
           Principals.lock_principal_in_tx(candidate.uid, :share),
         do: {:ok, principal, false},
         else: (_ -> {:error, :human_access_revoked})
  end

  def prepare_oidc_in_tx(nil, _login), do: {:ok, nil}

  def prepare_oidc_in_tx(id, login) do
    :ok = Repo.require_transaction()

    with {:ok, invitation} <- lock(id),
         :ok <- usable?(invitation),
         true <-
           is_nil(invitation.invited_email) or attested_email?(invitation.invited_email, login),
         do: {:ok, invitation},
         else: (
           false -> {:error, :invitation_identity_mismatch}
           error -> error
         )
  end

  def accept_oidc_in_tx(nil, observed), do: {:ok, observed.principal}

  def accept_oidc_in_tx(invitation, observed) do
    with true <- invitation.tenant_id == observed.principal.tenant_id,
         :ok <- consume(invitation, observed.created?),
         do: {:ok, observed.principal},
         else: (
           false -> {:error, :invitation_identity_mismatch}
           error -> error
         )
  end

  defp consume(_invitation, false), do: :ok

  defp consume(invitation, true) do
    with {:ok, _} <- Ankole.Ash.update(invitation, :use_in_tx, %{}), do: :ok
  end

  defp attested_email?(email, login) do
    user = login.user

    Enum.any?(
      [
        user["email"],
        user["enterprise_email"],
        user["work_email"],
        user["org_email"],
        user["biz_mail"],
        user["primaryEmail"],
        user["mail"],
        user["userPrincipalName"]
      ],
      &(Principals.normalize_email(&1) == email)
    )
  end

  defp lock(id) do
    with %Invitation{} = invitation <-
           Invitation
           |> Ash.Query.filter(id == ^id)
           |> Ash.Query.lock(:for_update)
           |> Ankole.Ash.read_one!(),
         do: {:ok, invitation},
         else: (_ -> {:error, :invitation_unavailable})
  end

  defp usable?(invitation) do
    with true <-
           is_nil(invitation.revoked_at) and
             DateTime.compare(invitation.expires_at, DateTime.utc_now()) == :gt,
         true <- is_nil(invitation.max_uses) or invitation.used_count < invitation.max_uses,
         true <- Ankole.Tenants.accepting_work?(invitation.tenant_id) do
      Repo.with_tenant(invitation.tenant_id, fn ->
        with {:ok, policy} <- PodLoginPolicy.get(),
             true <- invitation.kind != :link or policy["allow_invite_links"],
             do: allow_invitation(%{membership: invitation.membership}),
             else: (_ -> {:error, :invitation_unavailable})
      end)
    else
      _ -> {:error, :invitation_unavailable}
    end
  end
end
