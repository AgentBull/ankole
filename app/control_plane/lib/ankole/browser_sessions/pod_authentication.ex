defmodule Ankole.BrowserSessions.PodAuthentication do
  @moduledoc false
  use Ankole.Schema, tenancy: :tenant, tenant_in_primary_key: true

  @primary_key false
  @timestamps_opts [type: :utc_datetime_usec]

  schema "browser_pod_authentications" do
    field :authentication_id, Ankole.Ecto.UUIDv7, primary_key: true
    field :principal_uid, Ankole.Ecto.PrincipalKey
    field :access_version, :integer
    timestamps()
  end
end
