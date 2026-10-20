defmodule WeComOpenAPI.Media do
  @moduledoc """
  Fetch-and-decrypt for bot callback media.

  Callback media URLs are valid for five minutes and their bytes are encrypted
  with the per-item `aeskey` (`WeComOpenAPI.MediaCrypto`), so callers pull the
  bytes immediately and never persist the URL or key.
  """

  alias WeComOpenAPI.{Error, MediaCrypto}

  @doc """
  Download an encrypted media URL and decrypt it. `req_options` is merged into
  the `Req` request (local fakes only). Returns the plaintext bytes and any
  filename from `content-disposition`.
  """
  @spec download(String.t(), String.t(), keyword()) ::
          {:ok, %{body: binary(), filename: String.t() | nil}} | {:error, Error.t()}
  def download(url, aeskey, req_options \\ [])
      when is_binary(url) and is_binary(aeskey) do
    with {:ok, %{body: ciphertext, filename: filename}} <-
           WeComOpenAPI.download(url, req_options),
         {:ok, plaintext} <- MediaCrypto.decrypt(ciphertext, aeskey) do
      {:ok, %{body: plaintext, filename: filename}}
    end
  end
end
