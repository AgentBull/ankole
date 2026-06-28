defmodule Ankole.AIAgent.LlmProviders.Provider do
  @moduledoc """
  Operator-configured LLM provider endpoint and encrypted credential row.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias Ankole.AIAgent.ProviderSources
  alias Ankole.SignalsGateway.JsonPayload

  @primary_key false
  @timestamps_opts [type: :utc_datetime_usec]
  @provider_id_format ~r/\A[a-z][a-z0-9_-]{0,62}\z/
  @credential_modes ~w(api_key auth_token)

  schema "llm_providers" do
    field :provider_id, :string, primary_key: true
    field :provider_source, :string
    field :base_url, :string
    field :encrypted_credential, :string
    field :credential_mode, :string, default: "api_key"
    field :connection_options, :map, default: %{}
    field :disabled_at, :utc_datetime_usec

    timestamps()
  end

  @doc """
  Builds a changeset for LLM provider rows.
  """
  @spec changeset(struct(), map()) :: Ecto.Changeset.t()
  def changeset(provider, attrs) do
    provider
    |> cast(attrs, [
      :provider_id,
      :provider_source,
      :base_url,
      :encrypted_credential,
      :credential_mode,
      :connection_options,
      :disabled_at
    ])
    |> normalize_blank([:provider_id, :provider_source, :base_url, :encrypted_credential])
    |> normalize_lower([:provider_id, :provider_source, :credential_mode])
    |> validate_required([:provider_id, :provider_source, :credential_mode, :connection_options])
    |> validate_format(:provider_id, @provider_id_format)
    |> validate_inclusion(:credential_mode, @credential_modes)
    |> validate_source()
    |> validate_connection_options()
    |> validate_credential_mode()
    |> JsonPayload.validate_map(:connection_options, allow_datetime: false)
    |> unique_constraint(:provider_id, name: :llm_providers_pkey)
    |> check_constraint(:provider_id, name: :llm_providers_provider_id_format)
    |> check_constraint(:provider_source, name: :llm_providers_provider_source_check)
    |> check_constraint(:credential_mode, name: :llm_providers_credential_mode_check)
    |> check_constraint(:base_url, name: :llm_providers_base_url_present)
    |> check_constraint(:encrypted_credential, name: :llm_providers_encrypted_credential_present)
    |> check_constraint(:connection_options, name: :llm_providers_connection_options_object)
  end

  defp validate_source(changeset) do
    validate_change(changeset, :provider_source, fn :provider_source, source ->
      case ProviderSources.fetch(source) do
        {:ok, _source} -> []
        {:error, reason} -> [provider_source: inspect(reason)]
      end
    end)
  end

  defp validate_connection_options(changeset) do
    validate_change(changeset, :connection_options, fn :connection_options, options ->
      source = get_field(changeset, :provider_source)

      case ProviderSources.normalize_connection_options(source, options) do
        {:ok, _options} -> []
        {:error, reason} -> [connection_options: inspect(reason)]
      end
    end)
  end

  defp validate_credential_mode(changeset) do
    validate_change(changeset, :credential_mode, fn :credential_mode, mode ->
      source = get_field(changeset, :provider_source)

      case ProviderSources.validate_credential_mode(source, mode) do
        :ok -> []
        {:error, reason} -> [credential_mode: inspect(reason)]
      end
    end)
  end

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
