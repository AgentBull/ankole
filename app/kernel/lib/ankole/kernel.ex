defmodule Ankole.Kernel do
  @moduledoc """
  Native kernel helpers shared by the Bun and Elixir runtimes.
  """

  @rustler_mode if(Mix.env() == :prod, do: :release, else: :debug)
  @rustler_feature if(Mix.env() == :prod, do: "nif_prod", else: "nif_dev")

  Mix.shell().info("Building Ankole.Kernel NIF with #{@rustler_feature} in #{@rustler_mode} mode")

  use Rustler,
    otp_app: :ankole_kernel,
    crate: "ankole_kernel",
    # Rustler compares this path verbatim when excluding target artifacts from
    # Elixir external resources, so keep it absolute instead of using `.`.
    path: Path.expand("../..", __DIR__),
    default_features: false,
    features: [@rustler_feature],
    mode: @rustler_mode

  @type error_reason :: String.t()
  @type result(value) :: value | {:error, error_reason()}
  @type salt :: String.t() | nil
  @type extra_context :: String.t() | nil
  @type authz_snapshot :: map()
  @type authz_decision :: map()
  @type signals_gateway_filter_context :: map()
  @type jwt_claims :: map()
  @type jwt_header :: map()
  @type jwt_validation :: map()
  @type runtime_fabric_router :: reference()
  @type universal_ai_client_stream :: reference()
  @type reciprocal_rank_fusion_result :: %{
          required(String.t()) => String.t() | float()
        }
  @type web_url_facts :: %{
          scheme: String.t(),
          host: String.t() | nil,
          host_class: :metadata | :private | :public | nil
        }

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
  Transliterates Unicode text to an ASCII approximation.
  """
  @spec any_ascii(String.t()) :: String.t()
  def any_ascii(_input), do: :erlang.nif_error(:nif_not_loaded)

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

  @doc false
  @spec runtime_fabric_router_start(String.t(), pid(), String.t()) ::
          result(runtime_fabric_router())
  def runtime_fabric_router_start(_endpoint, _owner_pid, _opts_json),
    do: :erlang.nif_error(:nif_not_loaded)

  @doc false
  @spec runtime_fabric_router_endpoint(runtime_fabric_router()) :: result(String.t())
  def runtime_fabric_router_endpoint(_router), do: :erlang.nif_error(:nif_not_loaded)

  @doc false
  @spec runtime_fabric_router_send_mandatory(runtime_fabric_router(), String.t(), binary()) ::
          result(String.t())
  def runtime_fabric_router_send_mandatory(_router, _transport_route, _envelope_bytes),
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
  Estimates token count with the provider-neutral `o200k_base` vocabulary.

  This is a budgeting helper only; it does not infer or select a concrete model.
  """
  @spec estimate_o200k_base_tokens(String.t()) :: non_neg_integer()
  def estimate_o200k_base_tokens(_text), do: :erlang.nif_error(:nif_not_loaded)

  @doc """
  Combines multiple ordered result ID lists with reciprocal-rank fusion.

  Each route contributes `1 / (k + rank)` for an ID's first occurrence in that
  route. Results are ordered by descending fused score; equal scores preserve
  the IDs' first appearance order across the supplied routes.
  """
  @spec reciprocal_rank_fusion([[String.t()]], non_neg_integer()) ::
          result([reciprocal_rank_fusion_result()])
  def reciprocal_rank_fusion(ranked_lists, k \\ 60)

  def reciprocal_rank_fusion(ranked_lists, k)
      when is_list(ranked_lists) and is_integer(k) and k >= 0 do
    ranked_lists
    |> Torque.encode!()
    |> reciprocal_rank_fusion_nif(k)
    |> decode_json_result()
  end

  @spec reciprocal_rank_fusion_nif(String.t(), non_neg_integer()) :: result(String.t())
  defp reciprocal_rank_fusion_nif(_ranked_lists, _k),
    do: :erlang.nif_error(:nif_not_loaded)

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
  Signs JSON-compatible JWT claims with an RSA private key in PEM form.

  Only RS256/RS384/RS512 are accepted (default RS256); HMAC signing stays on
  `jwt_sign/3`. The header map takes the same fields as `jwt_sign/3`,
  including `key_id`/`kid`.
  """
  @spec jwt_sign_pem(jwt_claims(), String.t(), jwt_header()) :: result(String.t())
  def jwt_sign_pem(claims, private_key_pem, header \\ %{})
      when is_map(claims) and is_binary(private_key_pem) and is_map(header) do
    jwt_sign_pem_nif(Torque.encode!(claims), private_key_pem, Torque.encode!(header))
  end

  @spec jwt_sign_pem_nif(String.t(), String.t(), String.t()) :: result(String.t())
  defp jwt_sign_pem_nif(_claims, _private_key_pem, _header),
    do: :erlang.nif_error(:nif_not_loaded)

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
  Verifies an RSA-signed JWT against an RFC 7517 JWK and returns its claims.

  `jwk` is one JWK map with `"kty" => "RSA"` and base64url `"n"`/`"e"`
  components, as served by provider JWKS documents. Only RS256/RS384/RS512 are
  accepted; HMAC verification stays on `jwt_verify/3`.
  """
  @spec jwt_verify_jwk(String.t(), map(), jwt_validation()) :: result(jwt_claims())
  def jwt_verify_jwk(token, jwk, validation \\ %{})
      when is_binary(token) and is_map(jwk) and is_map(validation) do
    token
    |> jwt_verify_jwk_nif(Torque.encode!(jwk), Torque.encode!(validation))
    |> decode_json_result()
  end

  @spec jwt_verify_jwk_nif(String.t(), String.t(), String.t()) :: result(String.t())
  defp jwt_verify_jwk_nif(_token, _jwk, _validation), do: :erlang.nif_error(:nif_not_loaded)

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

  @doc false
  @spec program_run_nif(String.t(), String.t()) :: result(String.t())
  def program_run_nif(_run_id, _request_json), do: :erlang.nif_error(:nif_not_loaded)

  @doc false
  @spec program_cancel_nif(String.t()) :: result(boolean())
  def program_cancel_nif(_run_id), do: :erlang.nif_error(:nif_not_loaded)

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

  @doc """
  Parses a web URL with WHATWG semantics and classifies its host.

  `host_class` drives the shared web URL policy: `:metadata` hosts are cloud
  credential endpoints Ankole always rejects, `:private` hosts are rejected
  only when `security.ssrf_filter` is enabled, and `:public` hosts are
  allowed. Most callers want `validate_web_url/3`, which applies that policy;
  reach for raw facts only when a caller needs the parsed pieces themselves.
  Both Elixir and Bun consume this one classifier.
  """
  @spec web_url_facts(String.t()) :: result(web_url_facts())
  def web_url_facts(url) when is_binary(url), do: web_url_facts_nif(url)

  @spec web_url_facts_nif(String.t()) :: result(web_url_facts())
  defp web_url_facts_nif(_url), do: :erlang.nif_error(:nif_not_loaded)

  @doc """
  Validates one web URL against the shared SSRF policy.

  Returns `:ok` when the URL scheme is in `schemes` and the classified host
  allows the request: `:public` hosts always pass, `:private` hosts pass only
  when `ssrf_filter?` is disabled, and `:metadata` cloud credential endpoints
  never pass. Returns `{:error, :metadata | :private | :invalid}` so each
  caller keeps its own scheme list and error vocabulary.
  """
  @spec validate_web_url(String.t(), [String.t()], boolean()) ::
          :ok | {:error, :metadata | :private | :invalid}
  def validate_web_url(url, schemes, ssrf_filter?)
      when is_binary(url) and is_list(schemes) and is_boolean(ssrf_filter?) do
    case web_url_facts(url) do
      %{host_class: :metadata} ->
        {:error, :metadata}

      %{scheme: scheme, host_class: :private} ->
        if scheme in schemes and not ssrf_filter?, do: :ok, else: {:error, :private}

      %{scheme: scheme, host_class: :public} ->
        if scheme in schemes, do: :ok, else: {:error, :invalid}

      _unparseable ->
        {:error, :invalid}
    end
  end

  defp decode_json_result({:error, _reason} = error), do: error
  defp decode_json_result(json) when is_binary(json), do: Torque.decode!(json)
end
