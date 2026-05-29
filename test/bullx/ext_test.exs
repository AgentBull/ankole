defmodule BullX.ExtTest do
  use ExUnit.Case, async: true

  alias BullX.Ext

  @aead_key "000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f"
  @aead_ciphertext "vveE4WxRjp0KO8YVx7o09aQ5_q9ZzqX2.gb1S9PmqEp_5UuejAzvKErXrdE4-sQ"
  @argon2_phc "$argon2id$v=19$m=19456,t=2,p=1$5AURxkoXzehpXS96gkd73g$WlcJSF+Z1iFJuD5jJp/A9WFCd28MpGcRFD1oSg1AZX0"
  @jwt_secret "test-secret"
  @jwt_token "eyJ0eXAiOiJKV1QiLCJhbGciOiJIUzI1NiIsImtpZCI6ImtpZC0xIn0.eyJleHAiOjQxMDI0NDQ4MDAsInN1YiI6ImV4YW1wbGUiLCJpYXQiOjE3Nzg1ODU3OTB9.naTAjrx6QGV-MDGZYbkz7Z7AtoSF6vqUOK-lTmHh_Z8"
  @uuid "550e8400-e29b-41d4-a716-446655440000"
  @short_uuid "BWBeN28Vb7cMEx7Ym8AUzs"

  test "generic_hash/2 returns a hex digest" do
    assert Ext.generic_hash("bullx") ==
             "7f31cabae40697f9404428671c582d3c1f80c8a13d0741f4be8c9b856fcc0706"
  end

  test "bs58_hash/2 returns a base58 digest" do
    assert Ext.bs58_hash("bullx") == "9ZWpCkNYVXH91wFYb4cygXBxLe2xwsK9rBTVxwPMicWZ"
  end

  test "derive_key/3 returns a derived key" do
    assert Ext.derive_key("seed", "tenant-A", "scope-a") ==
             "0553f445a2fb3dfc0fab4efa1e1ed31ef6a103277286cf63874904e341ee0d20"
  end

  test "generate_key/0 returns a hex-encoded 32-byte key" do
    assert Ext.generate_key() =~ ~r/\A[0-9a-f]{64}\z/
  end

  test "aead_encrypt/2 returns a compact encrypted payload" do
    encrypted = Ext.aead_encrypt("secret", @aead_key)

    assert [_nonce, _ciphertext] = String.split(encrypted, ".")
    refute String.contains?(encrypted, "=")
  end

  test "aead_decrypt/2 returns plaintext" do
    assert Ext.aead_decrypt(@aead_ciphertext, @aead_key) == "secret"
  end

  test "argon2_hash/1 returns a PHC string" do
    assert Ext.argon2_hash("secret") =~ ~r/\A\$argon2id\$/
  end

  test "argon2_verify/2 accepts a matching PHC string" do
    assert Ext.argon2_verify("secret", @argon2_phc) == true
  end

  test "phone_normalize_e164/1 canonicalizes an international number" do
    assert Ext.phone_normalize_e164("+1 415 555 2671") == "+14155552671"
  end

  test "uuid_shorten/1 returns base58 UUID bytes" do
    assert Ext.uuid_shorten(@uuid) == @short_uuid
  end

  test "gen_uuid/0 returns a UUID v4 string" do
    assert Ext.gen_uuid() =~
             ~r/\A[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\z/
  end

  test "gen_uuid_v7/0 returns a UUID v7 string" do
    assert Ext.gen_uuid_v7() =~
             ~r/\A[0-9a-f]{8}-[0-9a-f]{4}-7[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\z/
  end

  test "gen_base36_uuid/0 returns a lowercase base36 string" do
    assert Ext.gen_base36_uuid() =~ ~r/\A[0-9a-z]+\z/
  end

  test "short_uuid_expand/1 expands base58 UUID bytes" do
    assert Ext.short_uuid_expand(@short_uuid) == @uuid
  end

  test "base58_encode/1 returns Bitcoin-alphabet base58" do
    assert Ext.base58_encode("Hello World!") == "2NEpo7TZRRrLZSi2U"
  end

  test "base58_decode/1 decodes Bitcoin-alphabet base58" do
    assert Ext.base58_decode("2NEpo7TZRRrLZSi2U") == "Hello World!"
  end

  test "base64_url_safe_encode/1 returns unpadded URL-safe base64" do
    assert Ext.base64_url_safe_encode("bullx") == "YnVsbHg"
  end

  test "base64_url_safe_decode/1 decodes unpadded URL-safe base64" do
    assert Ext.base64_url_safe_decode("YnVsbHg") == "bullx"
  end

  test "any_ascii/1 transliterates unicode text" do
    assert Ext.any_ascii("Björk") == "Bjork"
  end

  test "z85_encode/1 encodes aligned binary payloads" do
    assert Ext.z85_encode("bull") == "vS=H6"
  end

  test "z85_decode/1 decodes aligned binary payloads" do
    assert Ext.z85_decode("vS=H6") == "bull"
  end

  test "rule_engine_cel_condition_validate/1 accepts a CEL condition" do
    assert Ext.rule_engine_cel_condition_validate("true") == true
    assert Ext.rule_engine_cel_condition_validate("principal.uid") == true
  end

  test "authz_resource_pattern_validate/1 accepts resource globs" do
    assert Ext.authz_resource_pattern_validate("resource-*") == true
    assert Ext.authz_resource_pattern_validate("workspace:**:member") == true
    assert {:error, reason} = Ext.authz_resource_pattern_validate("[")
    assert reason =~ "invalid resource glob"
  end

  test "authz_cel_eval_loaded_grants/2 evaluates request context conditions" do
    assert {:allow, []} =
             Ext.authz_cel_eval_loaded_grants(cel_env(%{"business_hours" => true}), [
               loaded_grant("grant-1", "resource-*", "context.request.business_hours")
             ])
  end

  test "authz_cel_eval_loaded_grants/2 allows the first matching grant" do
    assert {:allow, []} =
             Ext.authz_cel_eval_loaded_grants(cel_env(%{}), [
               loaded_grant("grant-1", "resource-*", "true")
             ])
  end

  test "authz_cel_eval_loaded_grants/2 filters resource globs inside the decision NIF" do
    assert {:allow, []} =
             Ext.authz_cel_eval_loaded_grants(
               %{cel_env(%{}) | "resource" => "workspace:foo:bar:member"},
               [
                 loaded_grant("grant-1", "workspace:**:viewer", "not valid cel"),
                 loaded_grant("grant-2", "workspace:**:member", "true")
               ]
             )
  end

  test "jwt_sign/3 returns a compact JWS" do
    token = Ext.jwt_sign(%{"sub" => "example", "exp" => 4_102_444_800}, @jwt_secret)

    assert [_header, _claims, _signature] = String.split(token, ".")
  end

  test "jwt_verify/3 returns claims for a valid token" do
    assert %{"sub" => "example", "exp" => 4_102_444_800} =
             Ext.jwt_verify(@jwt_token, @jwt_secret)
  end

  test "jwt_decode_header/1 returns unverified header fields" do
    assert %{algorithm: :hs256, key_id: "kid-1", type: "JWT"} =
             Ext.jwt_decode_header(@jwt_token)
  end

  defp cel_env(context) do
    %{
      "principal" => %{
        "uid" => "principal-1",
        "type" => "human",
        "status" => "active"
      },
      "action" => "read",
      "resource" => "resource-1",
      "context" => %{"request" => context}
    }
  end

  defp loaded_grant(id, resource_pattern, condition) do
    %{
      "id" => id,
      "resource_pattern" => resource_pattern,
      "condition" => condition
    }
  end
end
