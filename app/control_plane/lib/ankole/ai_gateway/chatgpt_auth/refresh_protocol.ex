defmodule Ankole.AIGateway.ChatGPTAuth.RefreshProtocol do
  @moduledoc """
  Builds ChatGPT OAuth refresh requests and decodes token response fields.

  Callers validate the issuer and own transport, account binding, and storage.
  """

  @issuer "https://auth.openai.com"
  @client_id "app_EMoamEEZ73f0CkXaXp7hrann"

  @type request :: %{
          method: :post,
          url: String.t(),
          json: %{String.t() => String.t()}
        }
  @type field :: :omitted | :invalid | {:value, String.t()}
  @type fields :: %{access_token: field(), refresh_token: field(), id_token: field()}

  @doc "Returns the commercial issuer and OAuth client ID."
  @spec commercial_authority() :: {String.t(), String.t()}
  def commercial_authority, do: {@issuer, @client_id}

  @doc "Builds the token request for a caller-validated issuer."
  @spec request(String.t(), String.t()) :: request()
  def request(issuer, refresh_token) do
    %{
      method: :post,
      url: issuer <> "/oauth/token",
      json: %{
        "client_id" => @client_id,
        "grant_type" => "refresh_token",
        "refresh_token" => refresh_token
      }
    }
  end

  @doc "Decodes the optional credential fields in a successful response."
  @spec decode_tokens(term()) :: {:ok, fields()} | {:error, :invalid_body}
  def decode_tokens(body) when is_map(body) do
    {:ok,
     %{
       access_token: field(Map.get(body, "access_token")),
       refresh_token: field(Map.get(body, "refresh_token")),
       id_token: field(Map.get(body, "id_token"))
     }}
  end

  def decode_tokens(_), do: {:error, :invalid_body}

  defp field(nil), do: :omitted
  defp field(value) when is_binary(value) and value != "", do: {:value, value}
  defp field(_), do: :invalid
end
