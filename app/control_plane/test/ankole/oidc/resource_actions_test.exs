defmodule Ankole.OIDC.ResourceActionsTest do
  use Ankole.DataCase, async: false
  alias Ankole.OIDC
  alias Ankole.OIDC.{Client, SigningKeyRecord}

  test "configuration edits cannot replace the Client identity, type, or secret" do
    {:ok, client} =
      Repo.transact(fn _repo -> Ankole.Ash.create(Client, :create_in_tx, attrs()) end)

    assert {:error, error} =
             Repo.transact(fn _repo ->
               Ankole.Ash.update(client, :configure_in_tx, %{
                 id: Ankole.Ecto.UUIDv7.autogenerate(),
                 client_type: :confidential,
                 secret_ciphertext: "unverified-secret"
               })
             end)

    assert Enum.sort(Enum.map(error.errors, & &1.input)) == [
             :client_type,
             :id,
             :secret_ciphertext
           ]

    Ankole.DataCase.assert_persisted_equal(Repo.get!(Client, client.id), client)
  end

  test "the persistence action enforces Client protocol policy without an HTTP caller" do
    count = Repo.aggregate(Client, :count)

    for {overrides, field} <- [
          {%{secret_ciphertext: "public-client-secret"}, :secret_ciphertext},
          {%{scopes: ["profile"]}, :scopes},
          {%{redirect_uris: ["https://rp.example/callback#fragment"]}, :redirect_uris},
          {%{allow_insecure_local_logout: true}, :allow_insecure_local_logout}
        ] do
      assert {:error, error} =
               Repo.transact(fn _repo ->
                 Ankole.Ash.create(Client, :create_in_tx, Map.merge(attrs(), overrides))
               end)

      assert [_ | _] = Map.fetch!(errors_on(error), field)
    end

    assert Repo.aggregate(Client, :count) == count
  end

  test "a skipped key initialization returns the installed identity without changing it" do
    installed = Ankole.Ash.read_one!(SigningKeyRecord)
    assert installed.id == "primary"

    assert {:ok, kept} =
             Repo.transact(fn _repo ->
               Ankole.Ash.create(SigningKeyRecord, :initialize_in_tx, %{
                 id: "primary",
                 kid: "unused-candidate",
                 public_jwk: %{},
                 private_key_ciphertext: "unused-candidate"
               })
             end)

    assert_persisted_equal(kept, installed)
    assert_persisted_equal(Ankole.Ash.read_one!(SigningKeyRecord), installed)
  end

  test "public Client lookup requires the explicit cross-tenant scope" do
    {:ok, client} =
      Repo.transact(fn _repo -> Ankole.Ash.create(Client, :create_in_tx, attrs()) end)

    Repo.without_tenant(fn ->
      assert_raise Ankole.TenantContextMissing, fn -> OIDC.get_active_client(client.id) end
      assert {:ok, found} = Repo.across_tenants(fn -> OIDC.get_active_client(client.id) end)
      assert found.id == client.id
      assert found.tenant_id == client.tenant_id
    end)

    assert_raise ArgumentError, ~r/global reads require Repo.across_tenants/, fn ->
      Ash.Query.for_read(Client, :lookup_across_tenants)
    end
  end

  defp attrs,
    do: %{
      name: "Typed Client",
      client_type: :public,
      redirect_uris: ["https://rp.example/callback"],
      scopes: ["openid"]
    }
end
