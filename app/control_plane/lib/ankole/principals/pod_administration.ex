defmodule Ankole.Principals.PodAdministration do
  @moduledoc false
  alias Ankole.{AppConfigure, AuthZ, Principals, Repo, Tenants}
  alias Ankole.Principals.{HumanAccess, PodLoginPolicy}
  alias Ankole.AuthZ.Actor

  def settings do
    with {:ok, tenant} <- Tenants.get(Repo.tenant_id!()),
         {:ok, default_locale} <- Ankole.I18n.configured_default_locale(),
         {:ok, policy} <- PodLoginPolicy.get() do
      {:ok,
       %{
         displayName: tenant.display_name,
         defaultLocale: default_locale,
         allowExternalGuests: Ankole.Pod.Config.allow_external_guests?(),
         loginPolicy: policy,
         emailAvailable: Ankole.Authn.Mailer.configured?()
       }}
    end
  end

  def update_settings(actor, args) do
    with {:ok, default_locale} <- Ankole.I18n.validate_locale(args.defaultLocale),
         {:ok, policy} <- PodLoginPolicy.validate(Ankole.JSON.plain(args.loginPolicy)),
         {:ok, {tenant, writes}} <-
           Repo.transact_top_level(fn ->
             with :ok <-
                    PodLoginPolicy.validate_policy_update_in_tx(policy, Actor.principal(actor)),
                  {:ok, tenant} <-
                    Tenants.change_profile_in_tx(Repo.tenant_id!(), %{
                      display_name: args.displayName
                    }),
                  {:ok, locale_write} <- Ankole.I18n.put_default_locale_in_tx(default_locale),
                  {:ok, guests} <-
                    AppConfigure.put_tenant_by_key_in_tx(
                      "pod.allow_external_guests",
                      args.allowExternalGuests
                    ),
                  {:ok, login} <-
                    AppConfigure.put_tenant_by_key_in_tx("principals.pod_login_policy", policy),
                  do: {:ok, {tenant, [locale_write, guests, login]}}
           end),
         :ok <- Enum.each(writes, &AppConfigure.cache_committed_write/1),
         :ok <- Ankole.Pod.Pages.broadcast_access() do
      {:ok,
       %{
         displayName: tenant.display_name,
         defaultLocale: default_locale,
         allowExternalGuests: args.allowExternalGuests,
         loginPolicy: policy,
         emailAvailable: Ankole.Authn.Mailer.configured?()
       }}
    end
  end

  def members do
    administrators =
      AuthZ.list_memberships!(query: [filter: [group: [name: "pod_admin", built_in: true]]])
      |> MapSet.new(& &1.principal_uid)

    credentials =
      Ankole.Principals.SiteCredential
      |> Ankole.Ash.read!()
      |> Enum.group_by(& &1.principal_uid, &Map.take(&1, [:id, :provider, :identifier, :kind]))

    Principals.list_principals!(query: [filter: [type: :human], load: [:human_user]])
    |> Enum.map(fn principal ->
      %{
        uid: principal.uid,
        displayName: principal.display_name,
        status: principal.status,
        membership: principal.membership,
        email: if(principal.human_user, do: principal.human_user.email),
        administrator:
          principal.status == :active and principal.membership == :member and
            MapSet.member?(administrators, principal.uid),
        credentials: Map.get(credentials, principal.uid, [])
      }
    end)
  end

  def agents do
    Principals.list_principals!(query: [filter: [type: :agent], load: [:agent]])
    |> Enum.map(fn principal ->
      %{
        uid: principal.uid,
        displayName: Principals.display_name(principal),
        status: principal.status,
        type: principal.agent.type,
        ownerUID: principal.agent.owner_principal_uid
      }
    end)
  end

  def credential_views(uid),
    do:
      Principals.principal_site_credentials(uid)
      |> Enum.map(&Map.take(&1, [:id, :provider, :identifier, :kind]))

  def disable(actor, uid, disposition, reason),
    do:
      HumanAccess.disable(
        uid,
        reason,
        Ankole.ActorRef.from_actor(actor),
        Ankole.Ecto.UUIDv7.autogenerate(),
        disposition
      )

  def restore(actor, uid, reason),
    do:
      HumanAccess.restore(
        uid,
        Ankole.ActorRef.from_actor(actor),
        reason,
        Ankole.Ecto.UUIDv7.autogenerate()
      )

  def set_admin(uid, true), do: AuthZ.add_principal_to_group(uid, "pod_admin")
  def set_admin(uid, false), do: AuthZ.remove_principal_from_group(uid, "pod_admin")

  def unbind(uid, id) do
    Repo.transact_top_level(fn -> Principals.unbind_site_credential_in_tx(uid, id) end)
  end
end
