defmodule Ankole.Kernel do
  @moduledoc """
  Native kernel helpers shared by the Bun and Elixir runtimes.
  """

  use Rustler,
    otp_app: :ankole_kernel,
    crate: "ankole_kernel",
    path: ".",
    default_features: false,
    features: ["nif"]

  @type error_reason :: String.t()
  @type result(value) :: value | {:error, error_reason()}
  @type salt :: String.t() | nil
  @type extra_context :: String.t() | nil
  @type initial_crc32_state :: non_neg_integer() | nil
  @type authz_snapshot :: map()
  @type authz_decision :: map()

  @doc """
  Decrypts a compact AEAD token produced by `aead_encrypt/2`.

  The plaintext is returned as a binary so encrypted values can contain arbitrary
  bytes, not only UTF-8 text.
  """
  @spec aead_decrypt(String.t(), String.t()) :: result(binary())
  def aead_decrypt(_ciphertext, _key), do: :erlang.nif_error(:nif_not_loaded)

  @doc """
  Encrypts a binary payload with the shared kernel AEAD format.

  The returned string is safe to copy through URLs, environment variables, and
  config files because it uses padding-free base64url segments.
  """
  @spec aead_encrypt(binary(), String.t()) :: result(String.t())
  def aead_encrypt(_plaintext, _key), do: :erlang.nif_error(:nif_not_loaded)

  @doc """
  Authorizes one exact action on one concrete resource.

  The snapshot must contain every Principal, group, grant, resource, action, and
  request-context value the kernel needs. The native layer never loads database
  state itself.
  """
  @spec authz_authorize(authz_snapshot()) :: result(authz_decision())
  def authz_authorize(snapshot) when is_map(snapshot) do
    snapshot
    |> Torque.encode!()
    |> authz_authorize_json()
    |> Torque.decode!()
  end

  @doc """
  Authorizes every requested action against one concrete resource.
  """
  @spec authz_authorize_all(authz_snapshot()) :: result(authz_decision())
  def authz_authorize_all(snapshot) when is_map(snapshot) do
    snapshot
    |> Torque.encode!()
    |> authz_authorize_all_json()
    |> Torque.decode!()
  end

  @doc false
  @spec authz_authorize_json(String.t()) :: result(String.t())
  def authz_authorize_json(_snapshot_json), do: :erlang.nif_error(:nif_not_loaded)

  @doc false
  @spec authz_authorize_all_json(String.t()) :: result(String.t())
  def authz_authorize_all_json(_snapshot_json), do: :erlang.nif_error(:nif_not_loaded)

  @doc """
  Returns `true` when a CEL authorization condition compiles.
  """
  @spec authz_validate_condition(String.t()) :: result(boolean())
  def authz_validate_condition(_condition), do: :erlang.nif_error(:nif_not_loaded)

  @doc """
  Returns whether a resource pattern is valid.
  """
  @spec authz_validate_resource_pattern(String.t()) :: result(boolean())
  def authz_validate_resource_pattern(_pattern), do: :erlang.nif_error(:nif_not_loaded)

  @doc """
  Returns whether a resource pattern matches a concrete resource key.
  """
  @spec authz_match_resource_pattern(String.t(), String.t()) :: result(boolean())
  def authz_match_resource_pattern(_pattern, _resource), do: :erlang.nif_error(:nif_not_loaded)

  @doc """
  Converts Unicode text into a best-effort ASCII representation.

  This is intended for slugs, search keys, and display fallbacks. It is not a
  reversible encoding.
  """
  @spec any_ascii(String.t()) :: result(String.t())
  def any_ascii(_input), do: :erlang.nif_error(:nif_not_loaded)

  @doc """
  Decodes Base58 text into a binary.
  """
  @spec base58_decode(String.t()) :: result(binary())
  def base58_decode(_input), do: :erlang.nif_error(:nif_not_loaded)

  @doc """
  Encodes a binary as Base58 text for compact human-copyable identifiers.
  """
  @spec base58_encode(binary()) :: result(String.t())
  def base58_encode(_input), do: :erlang.nif_error(:nif_not_loaded)

  @doc """
  Decodes the padding-free URL-safe Base64 form used by kernel tokens.
  """
  @spec base64_url_safe_decode(String.t()) :: result(binary())
  def base64_url_safe_decode(_input), do: :erlang.nif_error(:nif_not_loaded)

  @doc """
  Encodes a binary with the URL-safe Base64 alphabet and no padding.
  """
  @spec base64_url_safe_encode(binary()) :: result(String.t())
  def base64_url_safe_encode(_input), do: :erlang.nif_error(:nif_not_loaded)

  @doc """
  Hashes data with BLAKE3 and returns the digest in Base58 form.

  When `salt` is present, it must be a 64-character hex key. The strict key shape
  keeps Elixir and Bun callers on the same keyed-hash contract.
  """
  @spec bs58_hash(binary(), salt()) :: result(String.t())
  def bs58_hash(data, salt \\ nil)
  def bs58_hash(_data, _salt), do: :erlang.nif_error(:nif_not_loaded)

  @doc """
  Computes CRC32 over a binary, optionally continuing from a previous state.

  The optional state supports chunked checksum workflows without making callers
  leave the native implementation.
  """
  @spec crc32(binary(), initial_crc32_state()) :: result(non_neg_integer())
  def crc32(input, initial_state \\ nil)
  def crc32(_input, _initial_state), do: :erlang.nif_error(:nif_not_loaded)

  @doc """
  Computes CRC32 and returns the value as lowercase hexadecimal text.
  """
  @spec crc32_hex(binary(), initial_crc32_state()) :: result(String.t())
  def crc32_hex(input, initial_state \\ nil)
  def crc32_hex(_input, _initial_state), do: :erlang.nif_error(:nif_not_loaded)

  @doc """
  Derives a deterministic BLAKE3 sub-key from a seed and labeled context.

  `sub_key_id` names the logical key being derived. `extra_context` separates
  call sites that need different keys under the same logical id.
  """
  @spec derive_key(binary(), String.t(), extra_context()) :: result(String.t())
  def derive_key(key_seed, sub_key_id, extra_context \\ nil)
  def derive_key(_key_seed, _sub_key_id, _extra_context), do: :erlang.nif_error(:nif_not_loaded)

  @doc """
  Generates a random UUIDv4 encoded as lowercase Base36 text.
  """
  @spec gen_base36_uuid() :: String.t()
  def gen_base36_uuid, do: :erlang.nif_error(:nif_not_loaded)

  @doc """
  Generates a random 32-byte hex key for kernel cryptographic helpers.
  """
  @spec generate_key() :: String.t()
  def generate_key, do: :erlang.nif_error(:nif_not_loaded)

  @doc """
  Hashes data with BLAKE3 and returns the digest as lowercase hexadecimal text.

  When `salt` is present, it must be a 64-character hex key and is used as the
  BLAKE3 keyed-hash key.
  """
  @spec generic_hash(binary(), salt()) :: result(String.t())
  def generic_hash(data, salt \\ nil)
  def generic_hash(_data, _salt), do: :erlang.nif_error(:nif_not_loaded)

  @doc """
  Validates and canonicalizes an international phone number as E.164 text.

  No default region is assumed. Provider adapters that accept local national
  numbers must build explicit country-code candidates before calling this.
  """
  @spec phone_normalize_e164(String.t()) :: result(String.t())
  def phone_normalize_e164(_phone), do: :erlang.nif_error(:nif_not_loaded)

  @doc """
  Generates a random UUIDv4 encoded from raw UUID bytes as Base58.
  """
  @spec gen_short_uuid() :: String.t()
  def gen_short_uuid, do: :erlang.nif_error(:nif_not_loaded)

  @doc """
  Generates a standard hyphenated UUIDv4 string.
  """
  @spec gen_uuid() :: String.t()
  def gen_uuid, do: :erlang.nif_error(:nif_not_loaded)

  @doc """
  Generates a standard hyphenated UUIDv7 string for time-sortable identifiers.
  """
  @spec gen_uuid_v7() :: String.t()
  def gen_uuid_v7, do: :erlang.nif_error(:nif_not_loaded)
end
