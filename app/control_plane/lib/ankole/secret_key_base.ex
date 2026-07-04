defmodule Ankole.SecretKeyBase do
  @moduledoc false

  @doc """
  Reads the Phoenix endpoint root secret from application config.
  """
  @spec fetch() ::
          {:ok, String.t()} | {:error, :invalid_secret_key_base | :missing_secret_key_base}
  def fetch do
    :ankole
    |> Application.get_env(AnkoleWeb.Endpoint, [])
    |> Keyword.fetch(:secret_key_base)
    |> case do
      {:ok, secret} when is_binary(secret) and secret != "" -> {:ok, secret}
      {:ok, _secret} -> {:error, :invalid_secret_key_base}
      :error -> {:error, :missing_secret_key_base}
    end
  end
end
