defmodule Ankole.Principals.PodLoginPolicy do
  @moduledoc "The current Pod's login and member credential policy."
  alias Ankole.AppConfigure
  alias Ankole.AppConfigure.Schema

  @key "principals.pod_login_policy"
  @defaults %{
    "allow_email_otp" => true,
    "allow_member_credential_change" => true,
    "allowed_email_domains" => [],
    "require_sso_for_members" => false,
    "allow_invite_links" => true
  }

  def definition do
    AppConfigure.define(
      key: @key,
      scope: :tenant,
      encrypted: false,
      schema: Schema.new(&validate/1),
      default_value: @defaults,
      console_writable: false,
      description: "Pod member login and invitation policy."
    )
  end

  def get do
    if Ankole.Repo.in_transaction?(),
      do: AppConfigure.get_in_tx(definition()),
      else: AppConfigure.get(definition())
  end

  def validate(value) when is_map(value) do
    value = Map.merge(@defaults, value)
    booleans = Map.keys(@defaults) -- ["allowed_email_domains"]
    domains = value["allowed_email_domains"]

    if Map.keys(value) |> Enum.all?(&Map.has_key?(@defaults, &1)) and
         Enum.all?(booleans, &is_boolean(value[&1])) and is_list(domains) and
         Enum.all?(
           domains,
           &(is_binary(&1) and Regex.match?(~r/\A[a-z0-9][a-z0-9.-]*\.[a-z]{2,}\z/, &1))
         ) do
      {:ok, value}
    else
      {:error, :invalid_login_policy}
    end
  end

  def validate(_), do: {:error, :invalid_login_policy}

  def authentication_allowed?(principal, provider_id, proof) do
    with {:ok, policy} <- get(),
         do: allowed?(policy, principal, provider_id, proof),
         else: (_ -> false)
  end

  defp allowed?(_policy, %{status: status}, _provider, _proof) when status != :active, do: false

  defp allowed?(policy, principal, provider_id, proof) do
    site? = Ankole.IdentityProviders.SiteSources.registered?(provider_id)
    email = Ankole.Attrs.get(proof, :verified_email)

    cond do
      principal.membership == :guest and not Ankole.Pod.Config.allow_external_guests?() ->
        false

      site? and principal.membership == :member and policy["require_sso_for_members"] ->
        false

      provider_id == "email_otp" and not policy["allow_email_otp"] ->
        false

      site? and policy["allowed_email_domains"] != [] ->
        is_binary(email) and
          List.last(String.split(email, "@")) in policy["allowed_email_domains"]

      true ->
        true
    end
  end

  def validate_policy_update_in_tx(policy, principal) do
    :ok = Ankole.Repo.require_transaction()

    with {:ok, old} <- get() do
      tightened? =
        (not policy["allow_email_otp"] and old["allow_email_otp"]) or
          (policy["require_sso_for_members"] and not old["require_sso_for_members"]) or
          (policy["allowed_email_domains"] != [] and
             policy["allowed_email_domains"] != old["allowed_email_domains"])

      if tightened? and not has_allowed_binding?(policy, principal),
        do: {:error, :administrator_lockout},
        else: :ok
    end
  end

  def validate_credential_removal_in_tx(principal, id) do
    :ok = Ankole.Repo.require_transaction()

    with {:ok, policy} <- get() do
      if has_allowed_binding?(policy, principal, credential_id: id),
        do: :ok,
        else: {:error, :last_login_method}
    end
  end

  def validate_provider_removal_in_tx(provider_id) do
    :ok = Ankole.Repo.require_transaction()

    with {:ok, policy} <- get() do
      admins =
        Ankole.AuthZ.list_memberships!(
          query: [
            filter: [group: [name: "pod_admin", built_in: true], principal: [status: :active]],
            load: [:principal]
          ]
        )

      if admins == [] or
           Enum.any?(
             admins,
             &has_allowed_binding?(policy, &1.principal, provider_id: provider_id)
           ),
         do: :ok,
         else: {:error, :administrator_lockout}
    end
  end

  def has_allowed_binding?(policy, principal, excluded \\ []) do
    personal =
      Ankole.Principals.principal_site_credentials(principal.uid)
      |> Enum.reject(&(&1.id == excluded[:credential_id]))

    personal? =
      Ankole.Authn.Mailer.configured?() and
        Enum.any?(
          personal,
          &allowed?(policy, principal, &1.provider, %{verified_email: &1.verified_email})
        )

    {:ok, providers} = Ankole.IdentityProviders.Login.list_login_providers()
    enabled = Enum.map(providers, & &1["provider_id"]) -- List.wrap(excluded[:provider_id])

    personal? or
      Enum.any?(
        Ankole.Principals.list_external_identities!(
          query: [filter: [principal_uid: principal.uid]]
        ),
        &(&1.provider in enabled)
      )
  end
end
