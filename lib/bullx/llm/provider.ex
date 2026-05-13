defmodule BullX.LLM.Provider do
  use Ecto.Schema
  import Ecto.Changeset

  @provider_id_format ~r/^[a-z][a-z0-9_-]{0,62}$/
  @req_llm_provider_format ~r/^[a-z][a-z0-9_]{0,62}$/

  @primary_key {:id, BullX.Ecto.UUIDv7, autogenerate: true}
  schema "llm_providers" do
    field :provider_id, :string
    field :req_llm_provider, :string
    field :base_url, :string
    field :encrypted_api_key, :string
    field :provider_options, :map, default: %{}

    timestamps(type: :utc_datetime_usec)
  end

  @type t :: %__MODULE__{
          id: Ecto.UUID.t() | nil,
          provider_id: String.t() | nil,
          req_llm_provider: String.t() | nil,
          base_url: String.t() | nil,
          encrypted_api_key: String.t() | nil,
          provider_options: map(),
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(provider, attrs) do
    provider
    |> cast(attrs, [
      :provider_id,
      :req_llm_provider,
      :base_url,
      :encrypted_api_key,
      :provider_options
    ])
    |> validate_required([:provider_id, :req_llm_provider, :provider_options])
    |> validate_format(:provider_id, @provider_id_format)
    |> validate_format(:req_llm_provider, @req_llm_provider_format)
    |> validate_change(:base_url, &validate_base_url/2)
    |> validate_change(:provider_options, &validate_provider_options/2)
    |> unique_constraint(:provider_id)
    |> check_constraint(:provider_id, name: :llm_providers_provider_id_format)
    |> check_constraint(:req_llm_provider, name: :llm_providers_req_llm_provider_format)
    |> check_constraint(:provider_options, name: :llm_providers_provider_options_object)
    |> check_constraint(:encrypted_api_key, name: :llm_providers_encrypted_api_key_not_empty)
  end

  defp validate_base_url(:base_url, nil), do: []

  defp validate_base_url(:base_url, value) when is_binary(value) do
    case URI.parse(value) do
      %URI{scheme: scheme, host: host} when scheme in ["http", "https"] and is_binary(host) ->
        []

      _other ->
        [base_url: "must be an absolute http or https URL"]
    end
  end

  defp validate_base_url(:base_url, _value),
    do: [base_url: "must be an absolute http or https URL"]

  defp validate_provider_options(:provider_options, value)
       when is_map(value) and not is_struct(value),
       do: []

  defp validate_provider_options(:provider_options, _value),
    do: [provider_options: "must be a JSON object"]
end
