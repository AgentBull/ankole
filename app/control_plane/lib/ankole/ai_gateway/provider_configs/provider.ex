defmodule Ankole.AIGateway.ProviderConfigs.Provider do
  @moduledoc """
  Operator-configured AIGateway provider endpoint and encrypted option row.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias Ankole.AIGateway.Providers
  alias Ankole.SignalsGateway.JsonPayload

  @primary_key {:id, Ankole.Ecto.UUIDv7, autogenerate: true}
  @timestamps_opts [type: :utc_datetime_usec]
  @slug_format ~r/\A[a-z][a-z0-9_-]{0,62}\z/

  schema "ai_gateway_providers" do
    field(:provider_id, :string)
    field(:provider_kind, :string)
    field(:base_url, :string)
    field(:encrypted_options, :map, default: %{})
    field(:connection_options, :map, default: %{})
    field(:disabled_at, :utc_datetime_usec)

    timestamps()
  end

  @doc """
  Builds a changeset for AIGateway provider rows.

  PostgreSQL only enforces slug/object shape for extensible fields such as
  `provider_kind`. The selected provider implementation performs the semantic
  validation so plugins can add provider kinds without a database migration.
  """
  @spec changeset(struct(), map()) :: Ecto.Changeset.t()
  def changeset(provider, attrs) do
    provider
    |> cast(attrs, [
      :provider_id,
      :provider_kind,
      :base_url,
      :encrypted_options,
      :connection_options,
      :disabled_at
    ])
    |> normalize_blank([:provider_id, :provider_kind, :base_url])
    |> normalize_lower([:provider_id, :provider_kind])
    |> validate_required([:provider_id, :provider_kind, :connection_options, :encrypted_options])
    |> validate_format(:provider_id, @slug_format)
    |> validate_format(:provider_kind, @slug_format)
    |> validate_base_url()
    |> validate_provider_kind()
    |> validate_connection_options()
    |> JsonPayload.validate_map(:connection_options, allow_datetime: false)
    |> JsonPayload.validate_map(:encrypted_options, allow_datetime: false)
    |> unique_constraint(:provider_id, name: :ai_gateway_providers_provider_id_index)
    |> check_constraint(:provider_id, name: :ai_gateway_providers_provider_id_format)
    |> check_constraint(:provider_kind, name: :ai_gateway_providers_provider_kind_format)
    |> check_constraint(:base_url, name: :ai_gateway_providers_base_url_present)
    |> check_constraint(:connection_options,
      name: :ai_gateway_providers_connection_options_object
    )
    |> check_constraint(:encrypted_options,
      name: :ai_gateway_providers_encrypted_options_object
    )
  end

  # Provider kind is an implementation id, not a DB enum. This validates against
  # built-ins and active plugin providers at the application boundary.
  defp validate_provider_kind(changeset) do
    validate_change(changeset, :provider_kind, fn :provider_kind, provider_kind ->
      case Providers.fetch(provider_kind) do
        {:ok, _provider} -> []
        {:error, reason} -> [provider_kind: inspect(reason)]
      end
    end)
  end

  defp validate_base_url(changeset) do
    validate_change(changeset, :base_url, fn :base_url, base_url ->
      case URI.new(base_url) do
        {:ok, %URI{scheme: scheme, host: host}}
        when scheme in ["http", "https"] and is_binary(host) ->
          []

        _value ->
          [base_url: "must be an absolute http(s) URL"]
      end
    end)
  end

  # Connection options are provider-specific, so their allowed keys come from
  # the selected provider module instead of a global schema.
  defp validate_connection_options(changeset) do
    validate_change(changeset, :connection_options, fn :connection_options, options ->
      provider_kind = get_field(changeset, :provider_kind)

      case Providers.normalize_connection_options(provider_kind, options) do
        {:ok, _options} -> []
        {:error, reason} -> [connection_options: inspect(reason)]
      end
    end)
  end

  # Blank strings from forms are stored as nil so database constraints and
  # runtime fallback logic see the same absence value.
  defp normalize_blank(changeset, fields) when is_list(fields) do
    Enum.reduce(fields, changeset, fn field, changeset -> normalize_blank(changeset, field) end)
  end

  defp normalize_blank(changeset, field) do
    update_change(changeset, field, fn
      value when is_binary(value) ->
        case String.trim(value) do
          "" -> nil
          trimmed -> trimmed
        end

      value ->
        value
    end)
  end

  # Provider ids are operator-facing stable slugs. Lowercasing them at the
  # changeset boundary keeps model selectors case-insensitive without adding
  # alternate lookup paths.
  defp normalize_lower(changeset, fields) when is_list(fields) do
    Enum.reduce(fields, changeset, fn field, changeset -> normalize_lower(changeset, field) end)
  end

  defp normalize_lower(changeset, field) do
    update_change(changeset, field, fn
      value when is_binary(value) -> String.downcase(value)
      value -> value
    end)
  end
end
