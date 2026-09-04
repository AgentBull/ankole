defmodule Ankole.OIDC.SigningKey do
  @moduledoc """
  Loads the installation's one RSA signing key before the web endpoint starts.

  The database owns key identity. The process validates and publishes one immutable
  runtime projection. A stored key that cannot be decrypted or does not match its
  public JWK stops startup instead of replacing the installation identity.
  """

  use GenServer

  alias Ankole.OIDC.Crypto
  alias Ankole.OIDC.SigningKeyRecord
  alias Ankole.Repo

  @name __MODULE__
  @record_id "primary"
  @runtime_key {__MODULE__, :runtime_key}

  @type key :: %{kid: String.t(), private_key_pem: String.t(), public_jwk: map()}

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(_opts), do: GenServer.start_link(__MODULE__, :ok, name: @name)

  @spec get() :: {:ok, key()} | {:error, term()}
  def get do
    owner = Process.whereis(@name)

    case :persistent_term.get(@runtime_key, nil) do
      {^owner, key} when is_pid(owner) -> {:ok, key}
      _missing_or_stale -> {:error, :signing_key_unavailable}
    end
  end

  @spec public_jwk() :: {:ok, map()} | {:error, term()}
  def public_jwk do
    with {:ok, %{public_jwk: public_jwk}} <- get(), do: {:ok, public_jwk}
  end

  @impl true
  def init(:ok) do
    case load_or_create() do
      {:ok, key} ->
        :persistent_term.put(@runtime_key, {self(), key})
        {:ok, :ready}

      {:error, reason} ->
        :persistent_term.erase(@runtime_key)
        {:stop, {:oidc_signing_key_unavailable, reason}}
    end
  end

  @impl true
  def terminate(_reason, _state) do
    case :persistent_term.get(@runtime_key, nil) do
      {owner, _key} when owner == self() -> :persistent_term.erase(@runtime_key)
      _missing_or_replaced -> :ok
    end

    :ok
  end

  defp load_or_create do
    with {:ok, row} <- ensure_row(),
         {:ok, private_key_pem} <-
           Crypto.unseal(row.private_key_ciphertext, "signing_key", @record_id),
         {:ok, public_jwk, kid} <- public_jwk_from_private_pem(private_key_pem),
         true <- row.kid == kid and row.public_jwk == public_jwk do
      {:ok, %{kid: kid, private_key_pem: private_key_pem, public_jwk: public_jwk}}
    else
      false -> {:error, :public_key_mismatch}
      {:error, reason} -> {:error, reason}
    end
  end

  defp ensure_row do
    Repo.transact(fn repo ->
      case repo.get(SigningKeyRecord, @record_id) do
        %SigningKeyRecord{} = row ->
          {:ok, row}

        nil ->
          with {:ok, private_key_pem, public_jwk, kid} <- generate_key(),
               {:ok, ciphertext} <- Crypto.seal(private_key_pem, "signing_key", @record_id),
               {:ok, _inserted} <-
                 %SigningKeyRecord{}
                 |> SigningKeyRecord.changeset(%{
                   id: @record_id,
                   kid: kid,
                   public_jwk: public_jwk,
                   private_key_ciphertext: ciphertext
                 })
                 |> repo.insert(on_conflict: :nothing),
               %SigningKeyRecord{} = row <- repo.get(SigningKeyRecord, @record_id) do
            {:ok, row}
          else
            nil -> {:error, :signing_key_insert_failed}
            {:error, reason} -> {:error, reason}
          end
      end
    end)
  end

  defp generate_key do
    private_key = :public_key.generate_key({:rsa, 2048, 65_537})
    private_entry = :public_key.pem_entry_encode(:RSAPrivateKey, private_key)
    private_key_pem = :public_key.pem_encode([private_entry])

    with {:ok, public_jwk, kid} <- public_jwk_from_private_key(private_key) do
      {:ok, private_key_pem, public_jwk, kid}
    end
  rescue
    error -> {:error, {:rsa_generation_failed, error.__struct__, Exception.message(error)}}
  end

  defp public_jwk_from_private_pem(private_key_pem) do
    with [entry] <- :public_key.pem_decode(private_key_pem),
         private_key <- :public_key.pem_entry_decode(entry) do
      public_jwk_from_private_key(private_key)
    else
      _invalid -> {:error, :invalid_private_key_pem}
    end
  rescue
    _error -> {:error, :invalid_private_key_pem}
  end

  defp public_jwk_from_private_key(
         {:RSAPrivateKey, _version, modulus, public_exponent, _private_exponent, _prime1, _prime2,
          _exponent1, _exponent2, _coefficient, _other_prime_infos}
       ) do
    n = integer_base64url(modulus)
    e = integer_base64url(public_exponent)
    kid = :crypto.hash(:sha256, ~s({"e":"#{e}","kty":"RSA","n":"#{n}"})) |> base64url()

    {:ok,
     %{
       "alg" => "RS256",
       "e" => e,
       "kid" => kid,
       "kty" => "RSA",
       "n" => n,
       "use" => "sig"
     }, kid}
  end

  defp public_jwk_from_private_key(_key), do: {:error, :invalid_rsa_private_key}

  defp integer_base64url(integer), do: integer |> :binary.encode_unsigned() |> base64url()
  defp base64url(binary), do: Base.url_encode64(binary, padding: false)
end
