defmodule BullX.Ext do
  @moduledoc """
  Native helpers for utility functions.

  Backed by Rust NIFs; most calls run on the dirty-CPU scheduler. Every
  function returns the raw value on success and `{:error, reason}` on
  failure — including argument type errors. Nothing here raises for bad
  user input, so callers can pattern-match uniformly.
  """

  use Rustler, otp_app: :bullx, crate: "bullx_ext"

  @type error_reason :: String.t()
  @type result(value) :: value | {:error, error_reason}
  @type salt :: String.t() | nil
  @type extra_context :: String.t() | nil

  @doc """
  BLAKE3 digest, hex-encoded (64 chars). Not a password hash.

  With a `salt`, switches to `keyed_hash` mode — the salt must be a
  32-byte hex string (64 hex chars), otherwise the call returns
  `{:error, "invalid salt: ..."}`.
  """
  @spec generic_hash(binary(), salt()) :: result(String.t())
  def generic_hash(data, salt \\ nil)
  def generic_hash(_data, _salt), do: :erlang.nif_error(:nif_not_loaded)

  @doc """
  Like `generic_hash/2`, but Base58-encoded (Bitcoin alphabet, 43–44 chars).
  """
  @spec bs58_hash(binary(), salt()) :: result(String.t())
  def bs58_hash(data, salt \\ nil)
  def bs58_hash(_data, _salt), do: :erlang.nif_error(:nif_not_loaded)

  @doc """
  BLAKE3 `derive_key` from a master seed, returned as hex-encoded 32 bytes.

  `sub_key_id` is used verbatim and case-sensitive — treat it as part of
  the key namespace. `extra_context` may be low-entropy and non-secret.
  """
  @spec derive_key(binary(), String.t(), extra_context()) :: result(String.t())
  def derive_key(key_seed, sub_key_id, extra_context \\ nil)
  def derive_key(_key_seed, _sub_key_id, _extra_context), do: :erlang.nif_error(:nif_not_loaded)

  @doc """
  Fresh 32-byte master key as a 64-char hex string.

  Seeded from the OS RNG via ChaCha12 and run through BLAKE3 `derive_key`
  with a fixed context, so raw RNG output is never exposed.
  """
  @spec generate_key() :: result(String.t())
  def generate_key, do: :erlang.nif_error(:nif_not_loaded)

  @doc """
  XChaCha20-Poly1305-IETF authenticated encryption.

  `key` is a 64-character hex string (32 bytes). The output is
  `"<base64url(nonce)>.<base64url(ciphertext)>"` with no padding and is
  safe to store as a single column. A fresh 24-byte nonce is generated per
  call; the ciphertext half includes the AEAD tag.
  """
  @spec aead_encrypt(binary(), String.t()) :: result(String.t())
  def aead_encrypt(_plaintext, _key), do: :erlang.nif_error(:nif_not_loaded)

  @doc """
  Inverse of `aead_encrypt/2`. Returns the original plaintext as a binary.

  A malformed ciphertext, wrong key, or failed authentication yields
  `{:error, reason}`.
  """
  @spec aead_decrypt(String.t(), String.t()) :: result(binary())
  def aead_decrypt(_ciphertext, _key), do: :erlang.nif_error(:nif_not_loaded)

  @doc """
  Argon2id PHC string with OWASP default parameters and a 16-byte
  per-call OS-RNG salt.

  ## Example

      BullX.Ext.argon2_hash("correct horse battery staple")
      #=> "$argon2id$v=19$m=19456,t=2,p=1$<salt>$<digest>"
  """
  @spec argon2_hash(binary()) :: result(String.t())
  def argon2_hash(_password), do: :erlang.nif_error(:nif_not_loaded)

  @doc """
  Verify against an `argon2_hash/1` PHC string (constant-time).

  `true`/`false` for match/mismatch; only a malformed PHC string yields
  `{:error, reason}` — a wrong password is a plain `false`.
  """
  @spec argon2_verify(binary(), String.t()) :: result(boolean())
  def argon2_verify(_password, _phc), do: :erlang.nif_error(:nif_not_loaded)

  @doc """
  Validate and canonicalize an E.164 phone number via libphonenumber.

  Input must be in international format (leading `+` and country code);
  ambiguous national-only numbers are rejected. Returns the canonical
  E.164 form on success, or `{:error, reason}` on parse failure or an
  invalid number.

  ## Example

      iex> BullX.Ext.phone_normalize_e164("+8613800000000")
      "+8613800000000"
  """
  @spec phone_normalize_e164(String.t()) :: result(String.t())
  def phone_normalize_e164(_phone), do: :erlang.nif_error(:nif_not_loaded)

  @doc """
  Base58 of the 16 raw UUID bytes. Despite the parameter name, any
  parseable UUID is accepted — version/variant bits round-trip unchanged
  through `short_uuid_expand/1`.

  ## Example

      iex> BullX.Ext.uuid_shorten("550e8400-e29b-41d4-a716-446655440000")
      "BWBeN28Vb7cMEx7Ym8AUzs"
  """
  @spec uuid_shorten(String.t()) :: result(String.t())
  def uuid_shorten(_uuid_v4), do: :erlang.nif_error(:nif_not_loaded)

  @doc """
  UUIDv4 in canonical hyphenated form.
  """
  @spec gen_uuid() :: String.t()
  def gen_uuid, do: :erlang.nif_error(:nif_not_loaded)

  @doc """
  UUIDv7 from the current Unix timestamp — lexicographically sortable by
  creation time.
  """
  @spec gen_uuid_v7() :: String.t()
  def gen_uuid_v7, do: :erlang.nif_error(:nif_not_loaded)

  @doc """
  UUIDv4 rendered as a lowercase base36 integer — variable length (up to
  26 chars), no leading zeros, no inverse helper in this module. Reach
  for `uuid_shorten/1` when you need round-tripping.

  ## Example

      BullX.Ext.gen_base36_uuid()
      #=> "3i743arjajh3q5x8v4vppbucd"
  """
  @spec gen_base36_uuid() :: String.t()
  def gen_base36_uuid, do: :erlang.nif_error(:nif_not_loaded)

  @doc """
  Inverse of `uuid_shorten/1`. Returns a tagged error for inputs that
  aren't valid Base58 or don't decode to exactly 16 bytes.
  """
  @spec short_uuid_expand(String.t()) :: result(String.t())
  def short_uuid_expand(_short_uuid), do: :erlang.nif_error(:nif_not_loaded)

  @doc """
  Base58 encode (Bitcoin alphabet).
  """
  @spec base58_encode(binary()) :: result(String.t())
  def base58_encode(_input), do: :erlang.nif_error(:nif_not_loaded)

  @doc """
  Base58 decode. Ambiguous glyphs (`0`, `O`, `I`, `l`) are rejected.
  """
  @spec base58_decode(String.t()) :: result(binary())
  def base58_decode(_input), do: :erlang.nif_error(:nif_not_loaded)

  @doc """
  URL-safe Base64, no padding (RFC 4648 §5, no `=`).

  ## Example

      iex> BullX.Ext.base64_url_safe_encode("bullx")
      "YnVsbHg"
  """
  @spec base64_url_safe_encode(binary()) :: result(String.t())
  def base64_url_safe_encode(_input), do: :erlang.nif_error(:nif_not_loaded)

  @doc """
  Inverse of `base64_url_safe_encode/1`.
  """
  @spec base64_url_safe_decode(String.t()) :: result(binary())
  def base64_url_safe_decode(_input), do: :erlang.nif_error(:nif_not_loaded)

  @doc """
  Unicode-to-ASCII transliteration (e.g. `"Björk" → "Bjork"`). Lossy and
  one-way.
  """
  @spec any_ascii(String.t()) :: result(String.t())
  def any_ascii(_input), do: :erlang.nif_error(:nif_not_loaded)

  @doc """
  Z85 (ZeroMQ RFC 32) encode — 5 ASCII chars per 4 bytes, no padding.

  Input length must be a multiple of 4; otherwise returns
  `{:error, "input length must be divisible by 4"}`.

  ## Example

      iex> BullX.Ext.z85_encode("bull")
      "vS=H6"
  """
  @spec z85_encode(binary()) :: result(String.t())
  def z85_encode(_input), do: :erlang.nif_error(:nif_not_loaded)

  @doc """
  Inverse of `z85_encode/1`. Input length must be a multiple of 5.
  """
  @spec z85_decode(String.t()) :: result(binary())
  def z85_decode(_input), do: :erlang.nif_error(:nif_not_loaded)

  @doc """
  Validate a CEL condition string through the shared rule-engine CEL runtime.

  Validation compiles the expression only. It does not prove the expression
  returns a boolean for a future request environment.
  """
  @spec rule_engine_cel_condition_validate(String.t()) :: true | {:error, error_reason()}
  def rule_engine_cel_condition_validate(_condition), do: :erlang.nif_error(:nif_not_loaded)

  @doc """
  Validate an AuthZ resource glob used by persisted permission grants.

  Authorization runtime still evaluates loaded grants through
  `authz_cel_eval_loaded_grants/2`; this validation wrapper is for write-time
  schema checks and operator feedback.
  """
  @spec authz_resource_pattern_validate(String.t()) :: true | {:error, error_reason()}
  def authz_resource_pattern_validate(_pattern), do: :erlang.nif_error(:nif_not_loaded)

  @doc """
  Evaluate a routing context against MailBox delivery-rule candidates.
  """
  @spec mailbox_match_delivery_rule([map()], map()) ::
          {:matched, String.t(), [{String.t(), atom(), String.t()}]}
          | {:no_match, [{String.t(), atom(), String.t()}]}
          | {:error, error_reason()}
  def mailbox_match_delivery_rule(_rules, _routing_context),
    do: :erlang.nif_error(:nif_not_loaded)

  @doc """
  Evaluate already-loaded AuthZ computed groups against a Principal-only CEL
  environment.

  Ecto remains responsible for loading candidate computed groups. The native
  boundary receives the Principal environment plus loaded group structs, then
  evaluates each group condition in one dirty-CPU call.
  """
  @spec authz_cel_eval_computed_groups(
          map(),
          [map()]
        ) ::
          {:ok, [String.t()], [{String.t(), atom(), error_reason()}]}
          | {:error, error_reason()}
  def authz_cel_eval_computed_groups(_env, _loaded_groups),
    do: :erlang.nif_error(:nif_not_loaded)

  @doc """
  Evaluate already-loaded AuthZ grants against a normalized CEL environment.

  Ecto remains responsible for Principal, group, and action filtering. The
  native boundary receives the request environment plus loaded grant structs,
  then performs resource-pattern matching and CEL condition evaluation in one
  dirty-CPU call, short-circuiting on the first allow.
  """
  @spec authz_cel_eval_loaded_grants(
          map(),
          [map()]
        ) ::
          {:allow | :deny, [{String.t(), atom(), String.t(), error_reason()}]}
          | {:error, error_reason()}
  def authz_cel_eval_loaded_grants(_env, _loaded_grants),
    do: :erlang.nif_error(:nif_not_loaded)

  @typedoc """
  JWS algorithm atom. Mirrors `jsonwebtoken::Algorithm` — HMAC, RSA-PKCS1-v1.5,
  RSA-PSS, ECDSA, and Edwards-curve EdDSA — using the `:ed_dsa` snake_case form
  to keep with Elixir convention.
  """
  @type jwt_algorithm ::
          :hs256
          | :hs384
          | :hs512
          | :rs256
          | :rs384
          | :rs512
          | :ps256
          | :ps384
          | :ps512
          | :es256
          | :es384
          | :ed_dsa

  @typedoc """
  Optional header overrides. The `:type` field is always set to `"JWT"` by the
  NIF so callers don't need to provide it.
  """
  @type jwt_header :: %{
          optional(:algorithm) => jwt_algorithm(),
          optional(:content_type) => String.t(),
          optional(:json_key_url) => String.t(),
          optional(:key_id) => String.t(),
          optional(:x5_url) => String.t(),
          optional(:x5_cert_chain) => [String.t()],
          optional(:x5_cert_thumbprint) => String.t(),
          optional(:x5t_s256_cert_thumbprint) => String.t()
        }

  @typedoc """
  Validation knobs handed to `jsonwebtoken::Validation`. Defaults match the
  upstream library: HS256 only, validate `exp`, 60-second leeway, all other
  claim checks off.

  Setting `:validate_signature` to `false` switches to
  `jsonwebtoken::dangerous::insecure_decode` — the only path that returns
  claims without proving authenticity. Treat with care.
  """
  @type jwt_validation :: %{
          optional(:aud) => [String.t()],
          optional(:required_spec_claims) => [String.t()],
          optional(:leeway) => non_neg_integer(),
          optional(:validate_exp) => boolean(),
          optional(:validate_nbf) => boolean(),
          optional(:sub) => String.t(),
          optional(:algorithms) => [jwt_algorithm()],
          optional(:iss) => [String.t()],
          optional(:validate_signature) => boolean()
        }

  @doc """
  Sign a JWT.

  `claims` is any map keyed by atoms or strings; nested maps and lists round
  trip cleanly. `key` is the raw HMAC secret for HS\\* algorithms or a
  PEM-encoded private key for RS/PS/ES/EdDSA. `header` defaults to HS256 with
  `typ=JWT`.

  An `iat` claim is inserted automatically if missing — matching the JS
  reference port — so signed tokens always carry a creation time.

  ## Example

      iex> token = BullX.Ext.jwt_sign(%{email: "foo@bar"}, "secret")
      iex> {:ok, _claims} = BullX.Ext.jwt_verify(token, "secret")
  """
  @spec jwt_sign(map(), binary(), jwt_header() | nil) :: result(String.t())
  def jwt_sign(claims, key, header \\ nil)
  def jwt_sign(_claims, _key, _header), do: :erlang.nif_error(:nif_not_loaded)

  @doc """
  Verify a JWT and return its claims.

  Returns the claims map on success or `{:error, reason}` on signature
  failure, expiration, malformed token, or any validation rejection.

  Pass `validation` to override defaults — see `t:jwt_validation/0`.
  """
  @spec jwt_verify(String.t(), binary(), jwt_validation() | nil) :: result(map())
  def jwt_verify(token, key, validation \\ nil)
  def jwt_verify(_token, _key, _validation), do: :erlang.nif_error(:nif_not_loaded)

  @doc """
  Decode the JWT header without verifying the signature — useful for
  selecting a key by `key_id`/`algorithm` before paying the verification
  cost.
  """
  @spec jwt_decode_header(String.t()) :: result(map())
  def jwt_decode_header(_token), do: :erlang.nif_error(:nif_not_loaded)
end
