defmodule Ankole.Pod.WebPushSubscription do
  @moduledoc "One browser's Web Push subscription for the Human signed in to it."

  use Ankole.Ash.Resource,
    tenancy: :tenant,
    tenant_in_primary_key: true,
    domain: Ankole.Pod

  postgres do
    table("web_push_subscriptions")
    repo(Ankole.Repo)
    migrate?(false)
    foreign_key_names([{:principal_uid, "web_push_subscriptions_principal_uid_fkey"}])
    unique_index_names([{[:endpoint], "web_push_subscriptions_pkey"}])

    check_constraints do
      check_constraint(:endpoint, "web_push_subscriptions_endpoint_https")
    end
  end

  attributes do
    # The push service URL identifies the browser, so a browser that signs in
    # as another Human moves its subscription to that Human.
    attribute(:endpoint, :string,
      primary_key?: true,
      allow_nil?: false,
      constraints: [trim?: false]
    )

    attribute(:principal_uid, Ankole.Ash.Types.PrincipalKey, allow_nil?: false)
    attribute(:p256dh, :string, allow_nil?: false, constraints: [trim?: false])
    attribute(:auth, :string, allow_nil?: false, constraints: [trim?: false])
    attribute(:user_agent, :string, constraints: [trim?: false])
    create_timestamp(:inserted_at)
    update_timestamp(:updated_at)
  end

  actions do
    defaults([:read])

    create :put do
      transaction?(false)
      accept([:endpoint, :principal_uid, :p256dh, :auth, :user_agent])
      upsert?(true)
      upsert_fields([:principal_uid, :p256dh, :auth, :user_agent, :updated_at])
    end

    destroy :remove do
      transaction?(false)
      require_atomic?(true)
    end
  end

  @type t :: %__MODULE__{}
end
