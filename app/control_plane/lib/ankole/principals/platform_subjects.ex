defmodule Ankole.Principals.PlatformSubjects do
  @moduledoc false

  require Ash.Query

  alias Ankole.Kernel, as: NativeKernel
  alias Ankole.Logging
  alias Ankole.Principals
  alias Ankole.Principals.{ExternalIdentity, Humans, HumanUser, MappingRequest, Principal}
  alias Ankole.Repo

  @provider_format ~r/\A[a-z][a-z0-9_-]*\z/

  def bind_external_identity(attrs) when is_map(attrs) do
    changeset = Ankole.Ash.for_create(ExternalIdentity, :bind_in_tx, attrs)

    with {:ok, normalized} <- Ash.Changeset.apply_attributes(changeset) do
      case fetch_platform_subject(normalized.provider, normalized.external_id) do
        %ExternalIdentity{principal_uid: principal_uid} = identity
        when principal_uid == normalized.principal_uid ->
          {:ok, identity}

        %ExternalIdentity{} ->
          {:error, :platform_subject_already_bound}

        nil ->
          Ankole.Ash.create(ExternalIdentity, :bind_in_tx, attrs)
      end
    end
  end

  def upsert_platform_subject_human(attrs) when is_map(attrs) do
    Repo.transact_top_level(fn -> upsert_platform_subject_human_in_tx(attrs) end)
  end

  def upsert_platform_subject_human_in_tx(attrs) do
    email = normalized_email_attr(attrs)
    mobile = normalized_mobile_attr(attrs)

    with {:ok, provider} <- required_provider(attrs, :provider),
         {:ok, _external_id} <- Humans.required_text(attrs, :external_id),
         {:ok, external_ids} <- candidate_external_ids(attrs),
         {:ok, metadata} <- metadata_attrs(attrs),
         :ok <- lock_platform_subjects(provider, external_ids),
         :ok <-
           Ankole.IdentityProviders.DirectoryAccess.guard_subject(provider, external_ids),
         :ok <- maybe_lock_human_contact("principal_human_email", email),
         :ok <- maybe_lock_human_contact("principal_human_mobile", mobile),
         existing_identity <- fetch_platform_subject_by_ids(provider, external_ids),
         {:ok, selection} <-
           platform_subject_principal_uid(existing_identity, attrs, email),
         {:ok, principal} <- upsert_human_principal(selection, attrs),
         profile_attrs <-
           contact_profile(principal, provider, attrs),
         {:ok, human_user} <- Humans.upsert_human_user(principal.uid, profile_attrs),
         {:ok, identities} <-
           upsert_platform_subject_identities(principal, provider, external_ids, metadata),
         :ok <- delete_pending_mapping_requests(provider, external_ids) do
      identity = hd(identities)

      {:ok,
       %{
         principal: principal,
         human_user: human_user,
         identity: identity,
         created?: elem(selection, 0) == :new
       }}
    end
  end

  defp contact_profile(principal, provider, attrs) do
    profile = Humans.take_attrs(attrs, Humans.human_profile_fields())

    if Humans.fetch_attr(attrs, :access_observation) in [
         {:ok, "departure"},
         {:ok, "enterprise_exit"},
         {:ok, "directory_removal"}
       ] or
         Ankole.Principals.HumanAccess.offboarded_in_current_cycle?(principal) do
      Map.drop(profile, [:email, :mobile])
    else
      drop_conflicting_contacts(provider, principal.uid, profile)
    end
  end

  def resolve_platform_subject(provider, external_id) do
    with {:ok, provider} <- normalize_provider(provider),
         {:ok, external_id} <- Humans.normalize_required_text(external_id) do
      provider_subject_principal(provider, external_id)
      |> active_human_result()
    end
  end

  def match_platform_subject_human(attrs) when is_map(attrs) do
    with {:ok, provider} <- required_provider(attrs, :provider),
         {:ok, external_ids} <- candidate_external_ids(attrs) do
      case provider_subject_principal_by_ids(provider, external_ids) do
        nil when provider == "email" ->
          contact_owner_principal(:email, Principals.normalize_email(hd(external_ids)))
          |> active_human_result()

        nil ->
          {:error, :not_found}

        provider_match ->
          active_human_result(provider_match)
      end
    end
  end

  def resolve_platform_subject_uid(provider, external_id) do
    with {:ok, provider} <- normalize_provider(provider),
         {:ok, external_id} <- Humans.normalize_required_text(external_id) do
      case fetch_platform_subject(provider, external_id) do
        %ExternalIdentity{principal_uid: principal_uid} -> {:ok, principal_uid}
        nil -> {:error, :not_found}
      end
    end
  end

  def lock_platform_subject(provider, external_id)
      when is_binary(provider) and is_binary(external_id) do
    advisory_xact_lock(
      "principal_external_identity:platform_subject:#{Repo.tenant_id!()}:#{provider}:#{external_id}"
    )
  end

  def delete_pending_mapping_request(provider, external_id)
      when is_binary(provider) and is_binary(external_id) do
    delete_pending_mapping_requests(provider, [external_id])
  end

  defp upsert_human_principal({:new, uid}, attrs) do
    Humans.insert_principal(Humans.human_principal_attrs(attrs, uid))
  end

  defp upsert_human_principal({:selected, uid}, attrs) do
    case Humans.lock_principal_in_tx(uid) do
      {:ok, %Principal{type: :human} = principal} ->
        Humans.update_principal_profile(principal, observed_profile_attrs(principal, attrs))

      {:ok, %Principal{}} ->
        {:error, :not_human}

      {:error, :not_found} ->
        {:error, :principal_not_found}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # A message or roster observation must not rename a person who already has a
  # display name; only an authoritative source (directory sync) may replace it.
  # Attrs can carry atom or string keys, so both spellings must be dropped.
  defp observed_profile_attrs(%Principal{display_name: current}, attrs) do
    cond do
      Humans.fetch_attr(attrs, :authoritative_profile) == {:ok, true} ->
        attrs

      is_binary(current) and String.trim(current) != "" ->
        attrs |> Map.delete(:display_name) |> Map.delete("display_name")

      true ->
        attrs
    end
  end

  defp upsert_external_identity(attrs) do
    changeset = Ankole.Ash.for_create(ExternalIdentity, :bind_in_tx, attrs)

    with {:ok, normalized} <- Ash.Changeset.apply_attributes(changeset) do
      case fetch_platform_subject(normalized.provider, normalized.external_id) do
        %ExternalIdentity{principal_uid: principal_uid} = identity
        when principal_uid == normalized.principal_uid ->
          Ankole.Ash.update(identity, :observe_in_tx, %{metadata: normalized.metadata})

        %ExternalIdentity{} ->
          {:error, :platform_subject_already_bound}

        nil ->
          Ankole.Ash.create(ExternalIdentity, :bind_in_tx, attrs)
      end
    end
  end

  defp fetch_platform_subject(provider, external_id) do
    ExternalIdentity
    |> Ash.Query.filter(provider == ^provider and external_id == ^external_id)
    |> Ankole.Ash.read_one!()
  end

  defp fetch_platform_subject_by_ids(provider, external_ids) do
    Enum.find_value(external_ids, &fetch_platform_subject(provider, &1))
  end

  defp lock_platform_subjects(provider, external_ids) do
    external_ids
    |> Enum.sort()
    |> Enum.reduce_while(:ok, fn external_id, :ok ->
      case lock_platform_subject(provider, external_id) do
        :ok -> {:cont, :ok}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp delete_pending_mapping_requests(provider, external_ids) do
    MappingRequest
    |> Ash.Query.filter(provider == ^provider and external_id in ^external_ids)
    |> Ankole.Ash.destroy_where(:delete_in_tx)
    |> case do
      {:ok, _requests} -> :ok
      {:error, _reason} = error -> error
    end
  end

  defp maybe_lock_human_contact(_prefix, nil), do: :ok

  defp maybe_lock_human_contact(prefix, value) do
    advisory_xact_lock("#{prefix}:#{Repo.tenant_id!()}:#{value}")
  end

  defp advisory_xact_lock(lock_key) do
    case Ankole.AdvisoryLock.lock(Repo, lock_key) do
      {:ok, _result} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  # Stable provider subjects take priority. A first binding can join an active
  # member by an unambiguous email; a released identity cannot rejoin by email.
  defp platform_subject_principal_uid(
         %ExternalIdentity{principal_uid: principal_uid},
         _attrs,
         _email
       ) do
    {:ok, {:selected, principal_uid}}
  end

  defp platform_subject_principal_uid(nil, attrs, email) do
    case Humans.fetch_attr(attrs, :uid) do
      {:ok, uid} ->
        with {:ok, uid} <- Principals.normalize_uid(uid), do: {:ok, {:selected, uid}}

      :error ->
        {:ok, provider} = required_provider(attrs, :provider)
        contacts = [email | Enum.map(Map.get(attrs, :contact_emails, []), & &1.email)]

        uids =
          contacts
          |> Enum.map(&Principals.normalize_email/1)
          |> Enum.reject(&is_nil/1)
          |> Enum.flat_map(&email_owner_uids/1)
          |> Enum.uniq()

        case uids do
          [uid] ->
            with {:ok, %Principal{type: :human, status: :active} = principal} <-
                   Principals.get_principal(uid),
                 false <- Principals.HumanAccess.offboarded_in_current_cycle?(principal),
                 false <-
                   ExternalIdentity
                   |> Ash.Query.filter(principal_uid == ^uid and provider == ^provider)
                   |> Ankole.Ash.exists?() do
              {:ok, {:selected, uid}}
            else
              _ -> new_subject_uid(attrs)
            end

          [] ->
            new_subject_uid(attrs)

          _ ->
            {:error, :ambiguous_contact_identity}
        end
    end
  end

  defp new_subject_uid(attrs) do
    with {:ok, uid} <- Principals.normalize_uid(Ankole.Attrs.get(attrs, :external_id)),
         do: {:ok, {:new, uid}}
  end

  defp email_owner_uids(email) do
    contact = List.wrap(contact_owner_uid(:email, email))

    identities =
      ExternalIdentity
      |> Ash.Query.filter(
        provider == "email" and external_id == ^email and
          fragment("?->>'origin' = 'directory'", metadata)
      )
      |> Ankole.Ash.read!()

    credentials =
      Ankole.Principals.SiteCredential
      |> Ash.Query.filter(provider == "email_otp" and identifier == ^email)
      |> Ankole.Ash.read!()

    contact ++ Enum.map(identities ++ credentials, & &1.principal_uid)
  end

  defp normalized_email_attr(attrs) do
    case Humans.fetch_attr(attrs, :email) do
      {:ok, value} -> Principals.normalize_email(value)
      :error -> nil
    end
  end

  defp normalized_mobile_attr(attrs) do
    case Humans.fetch_attr(attrs, :mobile) do
      {:ok, value} -> normalized_contact_mobile(value)
      :error -> nil
    end
  end

  defp candidate_external_ids(attrs) do
    listed =
      case Humans.fetch_attr(attrs, :external_ids) do
        {:ok, ids} when is_list(ids) -> ids
        _other -> []
      end

    single =
      case Humans.fetch_attr(attrs, :external_id) do
        {:ok, id} -> [id]
        :error -> []
      end

    normalized =
      (single ++ listed)
      |> Enum.flat_map(fn value ->
        case Humans.normalize_required_text(value) do
          {:ok, id} -> [id]
          {:error, _reason} -> []
        end
      end)
      |> Enum.uniq()

    case normalized do
      [] -> {:error, {:missing, :external_id}}
      ids -> {:ok, ids}
    end
  end

  defp provider_subject_principal_by_ids(provider, external_ids) do
    Enum.find_value(external_ids, fn external_id ->
      provider_subject_principal(provider, external_id)
    end)
  end

  defp contact_owner_principal(_field, nil), do: nil

  defp contact_owner_principal(field, value) do
    case HumanUser
         |> Ash.Query.do_filter([{field, value}])
         |> Ash.Query.load(:principal)
         |> Ankole.Ash.read_one!() do
      %HumanUser{principal: principal} -> %{principal: principal}
      nil -> nil
    end
  end

  # Unique-owned contact fields are dropped rather than failed on: a unique
  # violation would abort the whole transaction, and the conflicting field is
  # the other provider's problem to reconcile, not this subject's.
  defp drop_conflicting_contacts(provider, principal_uid, profile_attrs) do
    profile_attrs
    |> drop_conflicting_contact(provider, principal_uid, :email, &Principals.normalize_email/1)
    |> drop_conflicting_contact(provider, principal_uid, :mobile, &normalized_contact_mobile/1)
  end

  defp drop_conflicting_contact(profile_attrs, provider, principal_uid, field, normalize) do
    with {:ok, value} <- Map.fetch(profile_attrs, field),
         normalized when is_binary(normalized) <- normalize.(value),
         owner_uid when is_binary(owner_uid) <- contact_owner_uid(field, normalized) do
      if owner_uid == principal_uid do
        profile_attrs
      else
        Logging.warning(
          "principals.platform_subject.contact_conflict",
          "Platform subject contact field dropped: value belongs to another principal",
          %{
            field: field,
            provider: provider,
            principal_uid: principal_uid,
            owner_principal_uid: owner_uid
          }
        )

        Map.delete(profile_attrs, field)
      end
    else
      _absent_or_unowned -> profile_attrs
    end
  end

  defp contact_owner_uid(_field, nil), do: nil

  defp contact_owner_uid(field, value) do
    case HumanUser |> Ash.Query.do_filter([{field, value}]) |> Ankole.Ash.read_one!() do
      %HumanUser{principal_uid: principal_uid} -> principal_uid
      nil -> nil
    end
  end

  defp normalized_contact_mobile(value) when is_binary(value) do
    case NativeKernel.phone_normalize_e164(value) do
      normalized when is_binary(normalized) -> normalized
      {:error, _reason} -> nil
    end
  end

  defp normalized_contact_mobile(_value), do: nil

  defp platform_subject_identity_attrs(
         principal,
         provider,
         external_id,
         metadata,
         existing_identity
       ) do
    existing_metadata =
      case existing_identity do
        %ExternalIdentity{metadata: metadata} when is_map(metadata) -> metadata
        _identity -> %{}
      end

    %{
      principal_uid: principal.uid,
      provider: provider,
      external_id: external_id,
      metadata:
        existing_metadata
        |> Map.merge(metadata)
        |> Map.put("provider", provider)
        |> Map.put("external_id", external_id)
    }
  end

  defp upsert_platform_subject_identities(principal, provider, external_ids, metadata) do
    external_ids
    |> Enum.reduce_while({:ok, []}, fn external_id, {:ok, identities} ->
      attrs =
        platform_subject_identity_attrs(
          principal,
          provider,
          external_id,
          metadata,
          fetch_platform_subject(provider, external_id)
        )

      case upsert_external_identity(attrs) do
        {:ok, identity} -> {:cont, {:ok, [identity | identities]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, identities} -> {:ok, Enum.reverse(identities)}
      {:error, _reason} = error -> error
    end
  end

  defp provider_subject_principal(provider, external_id) do
    case ExternalIdentity
         |> Ash.Query.filter(provider == ^provider and external_id == ^external_id)
         |> Ash.Query.load(:principal)
         |> Ankole.Ash.read_one!() do
      %ExternalIdentity{principal: principal} = identity ->
        %{identity: identity, principal: principal}

      nil ->
        nil
    end
  end

  defp active_human_result(nil), do: {:error, :not_found}

  defp active_human_result(%{principal: %Principal{status: :disabled}}),
    do: {:error, :principal_disabled}

  defp active_human_result(%{principal: %Principal{type: :agent}}), do: {:error, :not_human}

  defp active_human_result(%{principal: %Principal{type: :human, status: :active} = principal}),
    do: {:ok, principal}

  defp required_provider(attrs, key) do
    with {:ok, value} <- Humans.required_text(attrs, key) do
      normalize_provider(value)
    end
  end

  defp normalize_provider(value) do
    with {:ok, text} <- Humans.normalize_required_text(value) do
      case Regex.match?(@provider_format, text) do
        true -> {:ok, text}
        false -> {:error, :invalid_provider}
      end
    end
  end

  defp metadata_attrs(attrs) do
    case Humans.fetch_attr(attrs, :metadata) do
      {:ok, metadata} when is_map(metadata) -> {:ok, metadata}
      {:ok, _metadata} -> {:error, :invalid_metadata}
      :error -> {:ok, %{}}
    end
  end
end
