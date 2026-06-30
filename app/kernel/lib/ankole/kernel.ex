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
  @type signals_gateway_filter_context :: map()
  @type runtime_fabric_envelope :: map()
  @type jwt_claims :: map()
  @type jwt_header :: map()
  @type jwt_validation :: map()
  @type runtime_fabric_router :: reference()
  @type universal_ai_client_stream :: reference()

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
    |> authz_authorize_nif()
    |> Torque.decode!()
  end

  @doc """
  Authorizes every requested action against one concrete resource.
  """
  @spec authz_authorize_all(authz_snapshot()) :: result(authz_decision())
  def authz_authorize_all(snapshot) when is_map(snapshot) do
    snapshot
    |> Torque.encode!()
    |> authz_authorize_all_nif()
    |> Torque.decode!()
  end

  @spec authz_authorize_nif(String.t()) :: result(String.t())
  defp authz_authorize_nif(_snapshot), do: :erlang.nif_error(:nif_not_loaded)

  @spec authz_authorize_all_nif(String.t()) :: result(String.t())
  defp authz_authorize_all_nif(_snapshot), do: :erlang.nif_error(:nif_not_loaded)

  @doc """
  Encodes a RuntimeFabric v1 envelope as protobuf bytes.

  The public Elixir shape is a map. The native kernel validates protocol
  version, lane, durability, body type, and boundary rules before returning
  bytes that may be sent over the runtime fabric.
  """
  @spec runtime_fabric_encode_envelope(runtime_fabric_envelope()) :: result(binary())
  def runtime_fabric_encode_envelope(envelope) when is_map(envelope) do
    envelope
    |> Torque.encode!()
    |> runtime_fabric_encode_envelope_nif()
  end

  @spec runtime_fabric_encode_envelope_nif(String.t()) :: result(binary())
  defp runtime_fabric_encode_envelope_nif(_envelope),
    do: :erlang.nif_error(:nif_not_loaded)

  @doc """
  Decodes RuntimeFabric v1 protobuf bytes into the public Elixir map shape.
  """
  @spec runtime_fabric_decode_envelope(binary()) :: result(runtime_fabric_envelope())
  def runtime_fabric_decode_envelope(envelope_bytes) when is_binary(envelope_bytes) do
    envelope_bytes
    |> runtime_fabric_decode_envelope_nif()
    |> decode_json_result()
  end

  @spec runtime_fabric_decode_envelope_nif(binary()) :: result(String.t())
  defp runtime_fabric_decode_envelope_nif(_envelope_bytes),
    do: :erlang.nif_error(:nif_not_loaded)

  @doc false
  @spec runtime_fabric_router_start(String.t(), pid(), String.t()) ::
          result(runtime_fabric_router())
  def runtime_fabric_router_start(_endpoint, _owner_pid, _opts_json),
    do: :erlang.nif_error(:nif_not_loaded)

  @doc false
  @spec runtime_fabric_router_endpoint(runtime_fabric_router()) :: result(String.t())
  def runtime_fabric_router_endpoint(_router), do: :erlang.nif_error(:nif_not_loaded)

  @doc false
  @spec runtime_fabric_router_send_mandatory(runtime_fabric_router(), String.t(), String.t()) ::
          result(String.t())
  def runtime_fabric_router_send_mandatory(_router, _transport_route, _envelope_json),
    do: :erlang.nif_error(:nif_not_loaded)

  @doc false
  @spec runtime_fabric_router_send_file_frame(runtime_fabric_router(), String.t(), [binary()]) ::
          result(String.t())
  def runtime_fabric_router_send_file_frame(_router, _transport_route, _frames),
    do: :erlang.nif_error(:nif_not_loaded)

  @doc false
  @spec runtime_fabric_router_stop(runtime_fabric_router()) :: result(boolean())
  def runtime_fabric_router_stop(_router), do: :erlang.nif_error(:nif_not_loaded)

  @doc false
  @spec universal_ai_client_open_nif(String.t(), pid(), reference()) ::
          {:ok, universal_ai_client_stream()} | {:error, map()}
  def universal_ai_client_open_nif(_encoded_spec, _owner_pid, _stream_ref),
    do: :erlang.nif_error(:nif_not_loaded)

  @doc false
  @spec universal_ai_client_read_nif(universal_ai_client_stream(), non_neg_integer()) ::
          result(:ok)
  def universal_ai_client_read_nif(_stream, _count), do: :erlang.nif_error(:nif_not_loaded)

  @doc false
  @spec universal_ai_client_cancel_nif(universal_ai_client_stream()) :: result(:ok)
  def universal_ai_client_cancel_nif(_stream), do: :erlang.nif_error(:nif_not_loaded)

  @doc false
  @spec universal_ai_client_model_request_nif(String.t()) :: {:ok, map()} | {:error, map()}
  def universal_ai_client_model_request_nif(_encoded_spec), do: :erlang.nif_error(:nif_not_loaded)

  @doc false
  @spec universal_ai_client_raw_request_nif(String.t()) :: {:ok, map()} | {:error, map()}
  def universal_ai_client_raw_request_nif(_encoded_spec), do: :erlang.nif_error(:nif_not_loaded)

  @doc """
  Returns `true` when a CEL authorization condition compiles.
  """
  @spec authz_validate_condition(String.t()) :: result(boolean())
  def authz_validate_condition(_condition), do: :erlang.nif_error(:nif_not_loaded)

  @doc """
  Returns `true` when a SignalsGateway CEL admission filter compiles.
  """
  @spec signals_gateway_validate_filter(String.t()) :: result(boolean())
  def signals_gateway_validate_filter(_filter_source), do: :erlang.nif_error(:nif_not_loaded)

  @doc """
  Evaluates a SignalsGateway CEL admission filter against a normalized context.

  The context must contain only the host-supplied `binding` and `signal`
  variables. The native layer does not load database or runtime state while
  evaluating the expression.
  """
  @spec signals_gateway_filter_match(String.t(), signals_gateway_filter_context()) ::
          result(boolean())
  def signals_gateway_filter_match(filter_source, context)
      when is_binary(filter_source) and is_map(context) do
    signals_gateway_filter_match_nif(filter_source, Torque.encode!(context))
  end

  @spec signals_gateway_filter_match_nif(String.t(), String.t()) :: result(boolean())
  defp signals_gateway_filter_match_nif(_filter_source, _context),
    do: :erlang.nif_error(:nif_not_loaded)

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
  Computes a non-cryptographic XXH3 128-bit observation fingerprint.

  This is for file observations and change detection. It is not a security
  digest and must not be used for provenance or signature checks.
  """
  @spec xxh3_128_hex(binary()) :: result(String.t())
  def xxh3_128_hex(_input), do: :erlang.nif_error(:nif_not_loaded)

  @doc """
  Compresses one worker-file lane block into a self-contained zstd frame.

  The wire is a concatenation of independent frames, one per `DATA` chunk, so a
  receiver decompresses each chunk in isolation. `level` follows the zstd CLI
  scale (1..=22).
  """
  @spec zstd_compress_block(binary(), integer()) :: result(binary())
  def zstd_compress_block(_input, _level), do: :erlang.nif_error(:nif_not_loaded)

  @doc """
  Decompresses one worker-file lane zstd frame with a hard output bound.

  `max_out` rejects oversized payloads, capping zip-bomb exposure at one block.
  """
  @spec zstd_decompress_block(binary(), non_neg_integer()) :: result(binary())
  def zstd_decompress_block(_input, _max_out), do: :erlang.nif_error(:nif_not_loaded)

  @doc """
  Derives a deterministic BLAKE3 sub-key from a seed and labeled context.

  `sub_key_id` names the logical key being derived. `extra_context` separates
  call sites that need different keys under the same logical id.
  """
  @spec derive_key(binary(), String.t(), extra_context()) :: result(String.t())
  def derive_key(key_seed, sub_key_id, extra_context \\ nil)
  def derive_key(_key_seed, _sub_key_id, _extra_context), do: :erlang.nif_error(:nif_not_loaded)

  @doc """
  Decodes a JWT header without validating the token signature.
  """
  @spec jwt_decode_header(String.t()) :: result(jwt_header())
  def jwt_decode_header(token) when is_binary(token) do
    token
    |> jwt_decode_header_nif()
    |> decode_json_result()
  end

  @spec jwt_decode_header_nif(String.t()) :: result(String.t())
  defp jwt_decode_header_nif(_token), do: :erlang.nif_error(:nif_not_loaded)

  @doc """
  Signs JSON-compatible JWT claims with the provided key and header options.
  """
  @spec jwt_sign(jwt_claims(), binary(), jwt_header()) :: result(String.t())
  def jwt_sign(claims, key, header \\ %{})
      when is_map(claims) and is_binary(key) and is_map(header) do
    jwt_sign_nif(Torque.encode!(claims), key, Torque.encode!(header))
  end

  @spec jwt_sign_nif(String.t(), binary(), String.t()) :: result(String.t())
  defp jwt_sign_nif(_claims, _key, _header), do: :erlang.nif_error(:nif_not_loaded)

  @doc """
  Verifies a JWT and returns its JSON-compatible claims.
  """
  @spec jwt_verify(String.t(), binary(), jwt_validation()) :: result(jwt_claims())
  def jwt_verify(token, key, validation \\ %{})
      when is_binary(token) and is_binary(key) and is_map(validation) do
    token
    |> jwt_verify_nif(key, Torque.encode!(validation))
    |> decode_json_result()
  end

  @spec jwt_verify_nif(String.t(), binary(), String.t()) :: result(String.t())
  defp jwt_verify_nif(_token, _key, _validation), do: :erlang.nif_error(:nif_not_loaded)

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

  defp decode_json_result({:error, _reason} = error), do: error
  defp decode_json_result(json) when is_binary(json), do: Torque.decode!(json)
end
