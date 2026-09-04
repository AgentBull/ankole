defmodule Ankole.OIDC.Client do
  @moduledoc """
  Operator-managed OAuth client and its authorization boundary.
  """

  use Ecto.Schema

  import Ecto.Changeset
  import Ankole.Ecto.Changeset, only: [normalize_blank: 2]

  alias Ankole.OIDC.ClientGroup

  @primary_key {:id, Ankole.Ecto.UUIDv7, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec]

  @scopes ~w(openid profile email offline_access ai_gateway.write)
  @client_types [:public, :confidential]
  @scheme_format ~r/\A[a-z][a-z0-9+.-]*\z/
  @unsafe_native_schemes ~w(about blob data file javascript vbscript)

  schema "oidc_clients" do
    field :name, :string
    field :enabled, :boolean, default: true
    field :client_type, Ecto.Enum, values: @client_types
    field :secret_ciphertext, :string, redact: true
    field :redirect_uris, {:array, :string}, default: []
    field :scopes, {:array, :string}, default: ["openid"]
    field :model_aliases, :map, default: %{}

    has_many :group_links, ClientGroup, foreign_key: :client_id

    timestamps()
  end

  @type t :: %__MODULE__{}

  @doc "Returns the complete scope vocabulary supported by this server."
  @spec supported_scopes() :: [String.t()]
  def supported_scopes, do: @scopes

  @doc "Builds a changeset for an OIDC client row."
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(client, attrs) do
    client
    |> cast(attrs, [
      :name,
      :enabled,
      :client_type,
      :secret_ciphertext,
      :redirect_uris,
      :scopes,
      :model_aliases
    ])
    |> normalize_blank([:name])
    |> normalize_lists()
    |> validate_required([
      :name,
      :enabled,
      :client_type,
      :redirect_uris,
      :scopes,
      :model_aliases
    ])
    |> validate_length(:redirect_uris, min: 1)
    |> validate_subset(:scopes, @scopes)
    |> validate_change(:redirect_uris, &validate_redirect_uris/2)
    |> validate_openid_scope()
    |> validate_secret_shape()
    |> validate_gateway_models()
    |> check_constraint(:name, name: :oidc_clients_name_present)
    |> check_constraint(:client_type, name: :oidc_clients_type)
    |> check_constraint(:secret_ciphertext, name: :oidc_clients_secret_shape)
    |> check_constraint(:scopes, name: :oidc_clients_openid_scope)
    |> check_constraint(:model_aliases, name: :oidc_clients_gateway_models)
  end

  @doc "Returns the HTTP origin of a redirect URI, or nil for a native-app URI."
  @spec redirect_origin(String.t()) :: String.t() | nil
  def redirect_origin(uri) when is_binary(uri) do
    case URI.parse(uri) do
      %URI{scheme: scheme, host: host} = parsed
      when scheme in ["http", "https"] and is_binary(host) ->
        URI.to_string(%URI{
          scheme: parsed.scheme,
          host: String.downcase(parsed.host),
          port: parsed.port
        })

      _uri ->
        nil
    end
  end

  def redirect_origin(_uri), do: nil

  defp normalize_lists(changeset) do
    Enum.reduce([:redirect_uris, :scopes], changeset, fn field, acc ->
      update_change(acc, field, fn values ->
        values
        |> Enum.map(fn
          value when is_binary(value) -> String.trim(value)
          value -> value
        end)
        |> Enum.reject(&(&1 == ""))
        |> Enum.uniq()
      end)
    end)
  end

  defp validate_redirect_uris(field, uris) do
    Enum.flat_map(uris, fn uri ->
      if valid_redirect_uri?(uri), do: [], else: [{field, "contains an invalid redirect URI"}]
    end)
  end

  defp valid_redirect_uri?(uri) when is_binary(uri) do
    parsed = URI.parse(uri)

    cond do
      uri =~ "*" or uri =~ ~r/\s/ -> false
      not is_binary(parsed.scheme) or not Regex.match?(@scheme_format, parsed.scheme) -> false
      not is_nil(parsed.fragment) or not is_nil(parsed.userinfo) -> false
      parsed.scheme == "https" -> is_binary(parsed.host) and parsed.host != ""
      parsed.scheme == "http" -> localhost?(parsed.host)
      parsed.scheme in @unsafe_native_schemes -> false
      true -> native_redirect?(parsed)
    end
  end

  defp valid_redirect_uri?(_uri), do: false

  defp localhost?(host) when is_binary(host),
    do: String.downcase(host) in ["localhost", "127.0.0.1", "::1"]

  defp localhost?(_host), do: false

  defp native_redirect?(%URI{host: host, path: path}) do
    (is_binary(host) and host != "") or (is_binary(path) and path != "")
  end

  defp validate_openid_scope(changeset) do
    if "openid" in get_field(changeset, :scopes, []) do
      changeset
    else
      add_error(changeset, :scopes, "must include openid")
    end
  end

  defp validate_secret_shape(changeset) do
    case {get_field(changeset, :client_type), get_field(changeset, :secret_ciphertext)} do
      {:public, nil} ->
        changeset

      {:confidential, secret} when is_binary(secret) and secret != "" ->
        changeset

      {:public, _secret} ->
        add_error(changeset, :secret_ciphertext, "must be empty for a public client")

      {:confidential, _secret} ->
        add_error(changeset, :secret_ciphertext, "is required")

      _shape ->
        changeset
    end
  end

  defp validate_gateway_models(changeset) do
    if "ai_gateway.write" in get_field(changeset, :scopes, []) and
         map_size(get_field(changeset, :model_aliases, %{})) == 0 do
      add_error(changeset, :model_aliases, "must not be empty with ai_gateway.write")
    else
      changeset
    end
  end
end
