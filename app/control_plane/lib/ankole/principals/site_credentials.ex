defmodule Ankole.Principals.SiteCredentials do
  @moduledoc false
  require Ash.Query

  alias Ankole.Principals.{AccessEvent, ExternalIdentity, HumanUser, SiteCredential}

  def list(provider, identifier) do
    SiteCredential
    |> Ash.Query.for_read(:read_across_tenants)
    |> Ash.Query.filter(provider == ^provider and identifier == ^identifier)
    |> Ash.Query.sort(tenant_id: :asc)
    |> Ankole.Ash.read_across_tenants!()
  end

  def bound?(uid, provider, identifier) do
    SiteCredential
    |> Ash.Query.filter(
      principal_uid == ^uid and provider == ^provider and identifier == ^identifier
    )
    |> Ankole.Ash.exists?()
  end

  def for_principal(uid) do
    SiteCredential |> Ash.Query.filter(principal_uid == ^uid) |> Ankole.Ash.read!()
  end

  def resolve_email_otp_principal(tenant_id, email) when is_binary(tenant_id) do
    with {:ok, tenant_id} <- Ecto.UUID.cast(tenant_id),
         normalized when is_binary(normalized) <- Ankole.Principals.normalize_email(email) do
      Ankole.Repo.with_tenant(tenant_id, fn ->
        case SiteCredential
             |> Ash.Query.filter(provider == "email_otp" and identifier == ^normalized)
             |> Ankole.Ash.read_one!() do
          %SiteCredential{principal_uid: uid} ->
            case Ankole.Principals.get_principal(uid) do
              {:ok, %{type: :human} = principal} -> principal
              _ -> nil
            end

          nil ->
            resolve_unbound_email_principal(normalized)
        end
      end)
    else
      _ -> nil
    end
  end

  def resolve_email_otp_principal(_tenant_id, _email), do: nil

  defp resolve_unbound_email_principal(email) do
    contacts =
      HumanUser
      |> Ash.Query.filter(email == ^email)
      |> Ankole.Ash.read!()

    emails =
      ExternalIdentity
      |> Ash.Query.filter(
        provider == "email" and external_id == ^email and
          fragment("?->>'origin' = 'directory'", metadata)
      )
      |> Ankole.Ash.read!()

    case (contacts ++ emails) |> Enum.map(& &1.principal_uid) |> Enum.uniq() do
      [uid] ->
        with {:ok, %{type: :human} = principal} <- Ankole.Principals.get_principal(uid),
             false <- Enum.any?(for_principal(uid), &(&1.provider == "email_otp")) do
          principal
        else
          _ -> nil
        end

      _ ->
        nil
    end
  end

  def pending_memberships(proof) do
    email = Map.get(proof, :verified_email)
    phone = Map.get(proof, :verified_phone)

    if is_nil(email) and is_nil(phone) do
      []
    else
      filter = []
      filter = if email, do: [[email: email] | filter], else: filter
      filter = if phone, do: [[mobile: phone] | filter], else: filter

      contacts =
        HumanUser
        |> Ash.Query.for_read(:read_across_tenants)
        |> Ash.Query.do_filter(or: filter)
        |> Ankole.Ash.read_across_tenants!()

      emails =
        if email do
          ExternalIdentity
          |> Ash.Query.for_read(:read_across_tenants)
          |> Ash.Query.filter(
            provider == "email" and external_id == ^email and
              fragment("?->>'origin' = 'directory'", metadata)
          )
          |> Ankole.Ash.read_across_tenants!()
        else
          []
        end

      (contacts ++ emails)
      |> Enum.map(&{&1.tenant_id, &1.principal_uid})
      |> Enum.uniq()
      |> Enum.group_by(&elem(&1, 0))
      |> Enum.flat_map(fn
        {tenant_id, [{_, uid}]} ->
          Ankole.Repo.with_tenant(tenant_id, fn ->
            with true <- Ankole.Tenants.accepting_work?(tenant_id),
                 {:ok, %{type: :human, status: :active} = principal} <-
                   Ankole.Principals.get_principal(uid),
                 false <- Enum.any?(for_principal(uid), &(&1.provider == proof.provider_id)) do
              [principal]
            else
              _ -> []
            end
          end)

        _ ->
          []
      end)
    end
  end

  def bind_in_tx(uid, proof) do
    :ok = Ankole.Repo.require_transaction()
    provider = Map.fetch!(proof, :provider_id)
    identifier = Map.fetch!(proof, :subject_id)

    case SiteCredential
         |> Ash.Query.filter(provider == ^provider and identifier == ^identifier)
         |> Ankole.Ash.read_one!() do
      %SiteCredential{principal_uid: ^uid} = binding ->
        {:ok, binding}

      %SiteCredential{} ->
        {:error, :site_credential_already_bound}

      nil ->
        Ankole.Ash.create(SiteCredential, :bind_in_tx, %{
          principal_uid: uid,
          kind: Map.get(proof, :kind, :otp),
          provider: provider,
          identifier: identifier,
          verified_email: Map.get(proof, :verified_email),
          metadata: Map.get(proof, :metadata, %{})
        })
    end
  end

  def unbind_in_tx(uid, id) do
    with {:ok, %{status: :active} = principal} <-
           Ankole.Principals.lock_principal_in_tx(uid, :update),
         %SiteCredential{} = credential <-
           SiteCredential
           |> Ash.Query.filter(principal_uid == ^uid and id == ^id)
           |> Ankole.Ash.read_one!(),
         :ok <- Ankole.Principals.PodLoginPolicy.validate_credential_removal_in_tx(principal, id),
         {:ok, _} <- Ankole.Ash.destroy(credential, :unbind_in_tx),
         do: {:ok, %{ok: true}},
         else: (
           nil -> {:error, :not_found}
           error -> error
         )
  end

  def replace_in_tx(uid, proof) do
    owned = for_principal(uid) |> Enum.filter(&(&1.provider == proof.provider_id))

    with :ok <-
           Enum.reduce_while(owned, :ok, fn binding, :ok ->
             case Ankole.Ash.destroy(binding, :unbind_in_tx) do
               {:ok, _} -> {:cont, :ok}
               error -> {:halt, error}
             end
           end),
         {:ok, _} <- bind_in_tx(uid, proof),
         :ok <- replace_profile_email(uid, owned, proof),
         do: :ok
  end

  defp replace_profile_email(uid, owned, %{provider_id: "email_otp", verified_email: email}) do
    human = HumanUser |> Ash.Query.filter(principal_uid == ^uid) |> Ankole.Ash.read_one!()
    previous = Enum.map(owned, & &1.verified_email)

    if is_nil(human.email) or human.email in previous do
      with {:ok, _} <- Ankole.Ash.update(human, :profile_in_tx, %{email: email}), do: :ok
    else
      :ok
    end
  end

  defp replace_profile_email(_uid, _owned, _proof), do: :ok

  def release_in_tx(principal) do
    :ok = Ankole.Repo.require_transaction()

    human =
      HumanUser |> Ash.Query.filter(principal_uid == ^principal.uid) |> Ankole.Ash.read_one!()

    credentials = for_principal(principal.uid)

    emails =
      ExternalIdentity
      |> Ash.Query.filter(principal_uid == ^principal.uid)
      |> Ankole.Ash.read!()
      |> Enum.filter(&(&1.provider == "email"))

    identifiers =
      [email_key(human.email), phone_key(human.mobile)] ++
        Enum.flat_map(credentials, fn credential ->
          [
            email_key(credential.verified_email),
            if(credential.provider == "phone_otp", do: phone_key(credential.identifier))
          ]
        end) ++ Enum.map(emails, &email_key(&1.external_id))

    identifiers = identifiers |> Enum.reject(&is_nil/1) |> Enum.uniq() |> Enum.sort()

    with {:ok, _} <-
           SiteCredential
           |> Ash.Query.filter(principal_uid == ^principal.uid)
           |> Ankole.Ash.destroy_where(:unbind_in_tx),
         {:ok, _} <-
           ExternalIdentity
           |> Ash.Query.filter(
             principal_uid == ^principal.uid and id in ^Enum.map(emails, & &1.id)
           )
           |> Ankole.Ash.destroy_where(:unbind_in_tx),
         {:ok, _} <- Ankole.Ash.update(human, :profile_in_tx, %{email: nil, mobile: nil}) do
      {:ok, identifiers}
    end
  end

  def claim_current?(%{challenge_started_at: started_at} = proof) do
    keys =
      [email_key(Map.get(proof, :verified_email)), phone_key(Map.get(proof, :verified_phone))]
      |> Enum.reject(&is_nil/1)

    latest =
      AccessEvent
      |> Ash.Query.filter(fragment("? && ?::text[]", released_identifiers, ^keys))
      |> Ash.Query.sort(inserted_at: :desc)
      |> Ash.Query.limit(1)
      |> Ankole.Ash.read_one!()

    is_nil(latest) or DateTime.compare(started_at, latest.inserted_at) == :gt
  end

  defp email_key(nil), do: nil
  defp email_key(value), do: "email:" <> Ankole.Principals.normalize_email(value)
  defp phone_key(nil), do: nil
  defp phone_key(value), do: "phone:" <> value
end
