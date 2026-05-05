defmodule BullX.ExtTest do
  use ExUnit.Case, async: true

  test "generic_hash/2 returns the expected hex digest" do
    assert BullX.Ext.generic_hash("bullx") ==
             "7f31cabae40697f9404428671c582d3c1f80c8a13d0741f4be8c9b856fcc0706"
  end

  test "bs58_hash/2 returns the expected base58 digest" do
    assert BullX.Ext.bs58_hash("bullx") == "9ZWpCkNYVXH91wFYb4cygXBxLe2xwsK9rBTVxwPMicWZ"
  end

  test "derive_key/3 returns the expected derived key" do
    assert BullX.Ext.derive_key("seed", "tenant-A", "scope-a") ==
             "0553f445a2fb3dfc0fab4efa1e1ed31ef6a103277286cf63874904e341ee0d20"
  end

  test "generate_key/0 returns a hex-encoded 32-byte key" do
    key = BullX.Ext.generate_key()

    assert is_binary(key)
    assert byte_size(key) == 64
    assert key =~ ~r/\A[0-9a-f]{64}\z/
  end

  test "native salt parsing errors remain tagged tuples" do
    assert {:error, reason} = BullX.Ext.generic_hash("abc", "bad")
    assert reason =~ "invalid salt"
  end

  test "nifs normalize invalid argument types" do
    assert BullX.Ext.generic_hash(123) == {:error, "data must be a binary"}
    assert BullX.Ext.generic_hash("abc", 123) == {:error, "salt must be a string or nil"}
    assert BullX.Ext.bs58_hash(123) == {:error, "data must be a binary"}
    assert BullX.Ext.derive_key(123, "tenant-A") == {:error, "key_seed must be a binary"}
    assert BullX.Ext.derive_key("seed", 123) == {:error, "sub_key_id must be a string"}

    assert BullX.Ext.derive_key("seed", "tenant-A", 123) ==
             {:error, "extra_context must be a string or nil"}
  end

  test "uuid helpers generate canonical and short forms" do
    uuid = BullX.Ext.gen_uuid()
    short_uuid = BullX.Ext.uuid_shorten(uuid)

    assert uuid =~ ~r/\A[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\z/
    assert is_binary(short_uuid)
    assert BullX.Ext.short_uuid_expand(short_uuid) == uuid
  end

  test "gen_uuid_v7/0 returns a UUID v7 string" do
    assert BullX.Ext.gen_uuid_v7() =~
             ~r/\A[0-9a-f]{8}-[0-9a-f]{4}-7[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\z/
  end

  test "gen_base36_uuid/0 returns a lowercase base36 string" do
    assert BullX.Ext.gen_base36_uuid() =~ ~r/\A[0-9a-z]+\z/
  end

  test "base58 helpers round trip binary payloads" do
    payload = <<0, 255, 1, 2, 3>>
    encoded = BullX.Ext.base58_encode(payload)

    assert is_binary(encoded)
    assert BullX.Ext.base58_decode(encoded) == payload
  end

  test "base64 helpers use url safe encoding without padding" do
    assert BullX.Ext.base64_url_safe_encode("bullx") == "YnVsbHg"
    assert BullX.Ext.base64_url_safe_decode("YnVsbHg") == "bullx"
  end

  test "any_ascii/1 transliterates unicode strings" do
    assert BullX.Ext.any_ascii("Björk") == "Bjork"
  end

  test "z85 helpers round trip aligned binary payloads" do
    encoded = BullX.Ext.z85_encode("bull")

    assert is_binary(encoded)
    assert BullX.Ext.z85_decode(encoded) == "bull"
  end

  test "z85_encode/1 rejects payloads whose length is not divisible by 4" do
    assert BullX.Ext.z85_encode("abc") == {:error, "input length must be divisible by 4"}
  end

  test "argon2_hash/1 returns a PHC-formatted Argon2id string" do
    phc = BullX.Ext.argon2_hash("correct horse battery staple")

    assert is_binary(phc)
    assert String.starts_with?(phc, "$argon2id$")
  end

  test "argon2_verify/2 accepts the original password and rejects others" do
    phc = BullX.Ext.argon2_hash("correct horse battery staple")

    assert BullX.Ext.argon2_verify("correct horse battery staple", phc) == true
    assert BullX.Ext.argon2_verify("wrong password", phc) == false
  end

  test "argon2_verify/2 returns a tagged error for malformed PHC strings" do
    assert {:error, reason} = BullX.Ext.argon2_verify("anything", "not-a-phc-string")
    assert reason =~ "invalid phc string"
  end

  describe "aead_encrypt/2 and aead_decrypt/2" do
    @aead_key "000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f"
    @wrong_aead_key "1f1e1d1c1b1a191817161514131211100f0e0d0c0b0a09080706050403020100"

    test "round trips arbitrary binary plaintext" do
      plaintext = <<"api-key:", 0, 1, 2, 255>>
      encrypted = BullX.Ext.aead_encrypt(plaintext, @aead_key)

      assert is_binary(encrypted)
      assert [_nonce, _ciphertext] = String.split(encrypted, ".")
      refute String.contains?(encrypted, "=")
      assert BullX.Ext.aead_decrypt(encrypted, @aead_key) == plaintext
    end

    test "uses a random nonce for each encryption" do
      left = BullX.Ext.aead_encrypt("same plaintext", @aead_key)
      right = BullX.Ext.aead_encrypt("same plaintext", @aead_key)

      assert is_binary(left)
      assert is_binary(right)
      assert left != right
    end

    test "decrypting with a wrong key returns a tagged error" do
      encrypted = BullX.Ext.aead_encrypt("secret", @aead_key)

      assert {:error, reason} = BullX.Ext.aead_decrypt(encrypted, @wrong_aead_key)
      assert reason =~ "decryption failed"
    end

    test "malformed ciphertext returns a tagged error" do
      assert {:error, _reason} = BullX.Ext.aead_decrypt("not-a-valid-payload", @aead_key)
      assert {:error, _reason} = BullX.Ext.aead_decrypt("a.b.c", @aead_key)
    end

    test "truncated ciphertext fails AEAD authentication" do
      encrypted = BullX.Ext.aead_encrypt("secret", @aead_key)
      [nonce, ciphertext] = String.split(encrypted, ".")
      decoded = BullX.Ext.base64_url_safe_decode(ciphertext)
      truncated = binary_part(decoded, 0, byte_size(decoded) - 1)
      truncated_ciphertext = BullX.Ext.base64_url_safe_encode(truncated)

      assert {:error, reason} =
               BullX.Ext.aead_decrypt("#{nonce}.#{truncated_ciphertext}", @aead_key)

      assert reason =~ "decryption failed"
    end

    test "invalid inputs return tagged errors" do
      assert BullX.Ext.aead_encrypt(123, @aead_key) ==
               {:error, "plaintext must be a binary"}

      assert BullX.Ext.aead_encrypt("secret", "bad") ==
               {:error, "key must be a 64-character hex string"}

      assert BullX.Ext.aead_decrypt(123, @aead_key) ==
               {:error, "ciphertext must be a string"}
    end
  end

  test "phone_normalize_e164/1 canonicalizes valid international numbers" do
    assert BullX.Ext.phone_normalize_e164("+8613800138000") == "+8613800138000"
    assert BullX.Ext.phone_normalize_e164("+1 415 555 2671") == "+14155552671"
  end

  test "phone_normalize_e164/1 rejects ambiguous or malformed input" do
    assert {:error, reason} = BullX.Ext.phone_normalize_e164("13800138000")
    assert reason =~ "invalid phone number"

    assert {:error, reason} = BullX.Ext.phone_normalize_e164("+1 000")
    assert reason =~ "invalid phone number"

    assert BullX.Ext.phone_normalize_e164(123) == {:error, "phone must be a string"}
  end

  test "authz_eval_loaded_grants/2 evaluates loaded grant tuples in order" do
    request = cedar_request("web_console", "read", %{"business_hours" => true})

    assert {:allow, [{"invalid", reason}]} =
             BullX.Ext.authz_eval_loaded_grants(request, [
               {"mismatch", "other", "this is invalid cedar"},
               {"invalid", "web_*", "this is invalid cedar"},
               {"allow", "web_*", "context.request.business_hours"},
               {"after_allow", "web_*", "this is invalid cedar"}
             ])

    assert reason =~ "invalid cedar condition"
  end

  test "authz_eval_loaded_grants/2 returns deny without parsing nonmatching grants" do
    request = cedar_request("web_console", "read", %{})

    assert {:deny, []} =
             BullX.Ext.authz_eval_loaded_grants(request, [
               {"mismatch", "other", "this is invalid cedar"}
             ])
  end

  describe "jwt_sign/3 and jwt_verify/3" do
    @one_day_in_seconds 24 * 60 * 60

    test "round trips an HS256 token with default settings" do
      token =
        BullX.Ext.jwt_sign(%{"email" => "foo@bar.hk", "exp" => utc_now() + 1000}, "mock-secret")

      assert is_binary(token)
      claims = BullX.Ext.jwt_verify(token, "mock-secret")
      assert claims["email"] == "foo@bar.hk"
      assert claims["exp"] >= utc_now()
    end

    test "round trips with HS512 and explicit algorithm validation" do
      claims = %{"email" => "foo@bar.hk", "exp" => utc_now() + 1000}

      token =
        BullX.Ext.jwt_sign(claims, "mock-secret", %{algorithm: :hs512})

      decoded = BullX.Ext.jwt_verify(token, "mock-secret", %{algorithms: [:hs512, :hs256]})

      assert decoded["email"] == "foo@bar.hk"
      assert decoded["exp"] == claims["exp"]
    end

    test "auto-inserts iat when missing" do
      before = utc_now()
      token = BullX.Ext.jwt_sign(%{"email" => "foo@bar", "exp" => utc_now() + 1000}, "secret")
      after_ = utc_now()

      claims = BullX.Ext.jwt_verify(token, "secret")
      assert claims["iat"] >= before
      assert claims["iat"] <= after_
    end

    test "preserves caller-provided iat" do
      claims = %{"email" => "foo@bar", "iat" => 1_700_000_000, "exp" => utc_now() + 1000}
      token = BullX.Ext.jwt_sign(claims, "secret")

      assert BullX.Ext.jwt_verify(token, "secret")["iat"] == 1_700_000_000
    end

    test "preserves nested data structures" do
      data = %{
        "id" => "f81d4fae-7dec-11d0-a765-00a0c91e6bf6",
        "pr" => 33,
        "isM" => true,
        "set" => ["KL", "TV", "JI"],
        "nest" => %{"id" => "poly"}
      }

      claims = %{"data" => data, "exp" => utc_now() + @one_day_in_seconds}

      token = BullX.Ext.jwt_sign(claims, "secret")
      decoded = BullX.Ext.jwt_verify(token, "secret")

      assert decoded["data"] == data
      assert decoded["exp"] == claims["exp"]
    end

    test "rejects expired tokens" do
      claims = %{
        "iat" => utc_now() - @one_day_in_seconds * 2,
        "exp" => utc_now() - @one_day_in_seconds
      }

      token = BullX.Ext.jwt_sign(claims, "secret")

      assert {:error, reason} = BullX.Ext.jwt_verify(token, "secret")
      assert reason =~ "ExpiredSignature"
    end

    test "rejects tampered signatures" do
      token = BullX.Ext.jwt_sign(%{"email" => "foo@bar", "exp" => utc_now() + 1000}, "secret")

      assert {:error, reason} = BullX.Ext.jwt_verify(token, "wrong-secret")
      assert reason =~ "InvalidSignature"
    end

    test "rejects tokens signed with a non-listed algorithm" do
      token =
        BullX.Ext.jwt_sign(%{"email" => "foo@bar", "exp" => utc_now() + 1000}, "secret", %{
          algorithm: :hs256
        })

      assert {:error, reason} =
               BullX.Ext.jwt_verify(token, "secret", %{algorithms: [:hs512]})

      assert reason =~ "InvalidAlgorithm"
    end

    test "validate_signature: false returns claims without checking the secret" do
      token = BullX.Ext.jwt_sign(%{"email" => "foo@bar", "exp" => utc_now() + 1000}, "secret")

      decoded =
        BullX.Ext.jwt_verify(token, "wrong-secret", %{validate_signature: false})

      assert decoded["email"] == "foo@bar"
    end

    test "audience validation enforces membership" do
      claims = %{"aud" => "service-a", "exp" => utc_now() + 1000}
      token = BullX.Ext.jwt_sign(claims, "secret")

      assert %{"aud" => "service-a"} =
               BullX.Ext.jwt_verify(token, "secret", %{aud: ["service-a"]})

      assert {:error, reason} =
               BullX.Ext.jwt_verify(token, "secret", %{aud: ["service-b"]})

      assert reason =~ "InvalidAudience"
    end

    test "leeway allows clock skew on exp" do
      claims = %{"exp" => utc_now() - 5}
      token = BullX.Ext.jwt_sign(claims, "secret")

      assert %{} = BullX.Ext.jwt_verify(token, "secret", %{leeway: 30})
      assert {:error, _} = BullX.Ext.jwt_verify(token, "secret", %{leeway: 0})
    end

    test "RS256 round trip with PEM keys" do
      private_pem = test_rsa_private_pem()
      public_pem = test_rsa_public_pem()

      claims = %{
        "data" => %{"id" => "abc"},
        "exp" => utc_now() + @one_day_in_seconds
      }

      token = BullX.Ext.jwt_sign(claims, private_pem, %{algorithm: :rs256})
      decoded = BullX.Ext.jwt_verify(token, public_pem, %{algorithms: [:rs256]})

      assert decoded["data"] == %{"id" => "abc"}
      assert decoded["exp"] == claims["exp"]
    end
  end

  describe "jwt_decode_header/1" do
    test "returns header fields without verifying the signature" do
      token =
        BullX.Ext.jwt_sign(%{"email" => "foo@bar", "exp" => utc_now() + 1000}, "secret", %{
          algorithm: :hs512,
          key_id: "kid-1"
        })

      assert %{algorithm: :hs512, key_id: "kid-1", type: "JWT"} =
               BullX.Ext.jwt_decode_header(token)
    end

    test "rejects malformed tokens" do
      assert {:error, reason} = BullX.Ext.jwt_decode_header("not-a-jwt")
      assert reason =~ "jwt header decode failed"
    end
  end

  defp utc_now, do: System.system_time(:second)

  defp test_rsa_public_pem do
    """
    -----BEGIN PUBLIC KEY-----
    MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEAzq7L/V03tpy3QTYOP51C
    T0fY2Sp5spejcja9brkEZoLYFcvLSeNnsXtPg/Sr7PwbykiXoY++xo7+6o2VfPnb
    iEFV8fNap+4tWDmxeZfPifmCEA58BFncnK8z5luxR+syeRuI/9IUHllGxsKoQAbF
    ECZoNCR+I5H/ynqhm9rvk89iNsh5EGxknOq2GmMaKRZ3nHZtVuwUj3BlwgsmP28Z
    AofMN/xM8bugHS1nNNHmRh6Ubg0Od3r2FH0+3df86ZzJ013M/LG1189aGNPXDOH4
    guBh7TPficw9nUnhIghiEFrxhAvIOQjClbhFud931T+UqD5BsF/ZarJ1VkaUa3Uj
    xwIDAQAB
    -----END PUBLIC KEY-----
    """
  end

  defp test_rsa_private_pem do
    """
    -----BEGIN RSA PRIVATE KEY-----
    MIIEowIBAAKCAQEAzq7L/V03tpy3QTYOP51CT0fY2Sp5spejcja9brkEZoLYFcvL
    SeNnsXtPg/Sr7PwbykiXoY++xo7+6o2VfPnbiEFV8fNap+4tWDmxeZfPifmCEA58
    BFncnK8z5luxR+syeRuI/9IUHllGxsKoQAbFECZoNCR+I5H/ynqhm9rvk89iNsh5
    EGxknOq2GmMaKRZ3nHZtVuwUj3BlwgsmP28ZAofMN/xM8bugHS1nNNHmRh6Ubg0O
    d3r2FH0+3df86ZzJ013M/LG1189aGNPXDOH4guBh7TPficw9nUnhIghiEFrxhAvI
    OQjClbhFud931T+UqD5BsF/ZarJ1VkaUa3UjxwIDAQABAoIBAQDGYRB7B9ZJ+PIM
    LY5PkOnsntGM4DAfM102a0Q32m5W1pABm7JsIVGOEQWpalb7CKDD8BlagVZjzyzu
    hSdO5aPJjKyppyMEvJ/ZZsbqJsSVcl9cegqfQoF2AtSV7ryigyXXCI7evQ2Cc75z
    WLOVgOn1LmgmZECOc7xI5JvptKLwAwrIuLE4wnuLgSdxxVZ8uwJHW7+hTCQ8x0cS
    ID1POy3q39kEEdqi+yNOrVFZV7DGJ6T5gYWDe53fWpks++tr7D6Wbq1mRdX5T62I
    dG/G4q9/vA2tSR+5hZWMxMqZ+GUBmIH2zPU16yc4hfwne/C5WQkRUaPBIl/u5swF
    LHwxNIqBAoGBAPsCOB5T7/oO9Y/LyD6SCDLiKpKQhwPPZJ76/Nu9yNXM2sLINGDq
    6RUXmaflifoKSRxFqApBHXqcP8NRzrYT+eY5Q0/m2Nvt4MvoMRoNDx2FVnQY8yo4
    AdSpQl2fNhMdXc1R2Wc3EJdWZd+2J9xGBTbLZ5nUem9zdVdZr0YbMrwpAoGBANLK
    7txwi/YSYfHo+S0KZqqO32CAN8m0s6Clnz1SomZY4TX1nQQyfbzT06AG/7vtVf5r
    oc4t1JrX08Qelu7VBOCH2Y2jEYyX1M6e7sJbl+Z5LYqOQkiAW+GBF3gvn/IvQ1Ir
    jzd8MF/5wfyafaeE5mxoAtDOGW/BfcwORIoAOt5vAoGAHHjx+K64x/qubDNHcaGL
    AIqbHaj7R7lcxpPd3uc2QtpL7lBbcKr06YmVym/FKPHFvUlBeHhOabwTl4pOEmVN
    sYnJUuTysG/ZUgfymevlTQn09pJl8uILgx34AzquHZj1LPcd3BFo9mG8iJXXC6t9
    p+uGwvJRORc1tkTcFu264ZECgYB9sygXakH8PmAL6vrUQhSQ9tv75tndvZU0Yi+A
    WQug7rV2AP5eJ2HVvZfAIQxVW6VhL3vwwGG86KFOnVMyHvNmlXxFOw3XAh+UCzCj
    1AzUEkT3D/g01d50rg95yySdPlPt5y3jT3plcUGdyd7Oi7EAylGLhKukegTzLzrt
    9E8mnwKBgBx+31YGB/sxdLXKN7CKvkB9+PUQ1ywDZshzuXfSL+lEcgls6MT/AjMP
    49eEu14698S4VHnhMu/671TwJXS6NpCTCGjrUJoKymuaBGYvgFRqcqjVtHzyz+YM
    kFQISvi/DurN5CN4C1Yiv7EDFQC+69fcOo4tP9S9EFya189IvJsJ
    -----END RSA PRIVATE KEY-----
    """
  end

  defp cedar_request(resource, action, request_context) do
    %{
      "principal" => %{
        "type" => "BullXUser",
        "id" => "019dc9bc-0000-7000-8000-000000000001",
        "attrs" => %{
          "id" => "019dc9bc-0000-7000-8000-000000000001"
        }
      },
      "action" => %{
        "type" => "BullXAction",
        "id" => action
      },
      "resource" => %{
        "type" => "BullXResource",
        "id" => resource
      },
      "context" => %{"request" => request_context}
    }
  end
end
