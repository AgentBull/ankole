defmodule BullX.Principals.AuthNTest do
  use BullX.DataCase, async: false

  import Ecto.Changeset

  alias BullX.Principals
  alias BullX.Principals.ActivationCode
  alias BullX.Principals.ExternalIdentity
  alias BullX.Principals.Principal
  alias BullX.Principals.PrincipalLoginAuthCode
  alias BullX.Repo

  setup do
    previous = Application.get_env(:bullx, :principals)

    on_exit(fn -> restore_principals_config(previous) end)

    :ok
  end

  test "match_or_create_human_from_channel binds an existing Human by configured rule" do
    put_principals_config(
      authn_auto_create_humans: false,
      authn_match_rules: [
        %{
          "result" => "bind_existing_human",
          "op" => "equals_human_field",
          "source_path" => "profile.email",
          "human_field" => "email"
        }
      ]
    )

    {:ok, %{principal: principal}} =
      Principals.create_human(%{
        uid: "alice",
        display_name: "Alice",
        email: "alice@example.com"
      })

    input = channel_input("chat", "workplace", "user_alice", %{"email" => "ALICE@example.com"})

    assert {:ok, ^principal, %ExternalIdentity{} = identity} =
             Principals.match_or_create_human_from_channel(input)

    assert identity.kind == :channel_actor
    assert {:ok, ^principal} = Principals.resolve_channel_actor(:chat, "workplace", "user_alice")
  end

  test "disabled bound Principals cannot resolve as active subjects" do
    {:ok, %{principal: principal}} =
      Principals.create_human(%{uid: "disabled-human", display_name: "Disabled"})

    insert_channel_identity!(principal, "chat", "workplace", "user_disabled")

    principal
    |> change(%{status: :disabled})
    |> Repo.update!()

    assert {:error, :principal_disabled} =
             Principals.resolve_channel_actor("chat", "workplace", "user_disabled")
  end

  test "unmatched channel actors require activation with the default policy" do
    assert {:error, :activation_required} =
             Principals.match_or_create_human_from_channel(
               channel_input("chat", "workplace", "user_new", %{"email" => "new@example.com"})
             )
  end

  test "activation codes create a new Human and first channel binding exactly once" do
    {:ok, %{code: plaintext, activation_code: activation_code}} =
      Principals.create_activation_code(nil, %{"purpose" => "test"})

    stored = Repo.get!(ActivationCode, activation_code.id)
    refute stored.code_hash == plaintext

    input =
      channel_input("chat", "workplace", "user_activated", %{"email" => "activated@example.com"})

    assert {:ok, %Principal{type: :human} = principal, %ExternalIdentity{} = identity} =
             Principals.consume_activation_code(plaintext, input)

    assert identity.principal_id == principal.id

    used = Repo.get!(ActivationCode, activation_code.id)
    assert used.used_by_principal_id == principal.id
    assert used.used_by_adapter == "chat"
    assert used.used_by_external_id == "user_activated"

    other_input =
      channel_input("chat", "workplace", "user_second", %{"email" => "second@example.com"})

    assert {:error, :invalid_or_expired_code} =
             Principals.consume_activation_code(plaintext, other_input)
  end

  test "activation does not consume a code when automatic matching binds an existing Human" do
    put_principals_config(
      authn_auto_create_humans: false,
      authn_match_rules: [
        %{
          "result" => "bind_existing_human",
          "op" => "equals_human_field",
          "source_path" => "profile.email",
          "human_field" => "email"
        }
      ]
    )

    {:ok, %{principal: principal}} =
      Principals.create_human(%{uid: "matched", email: "matched@example.com"})

    {:ok, %{code: plaintext, activation_code: activation_code}} =
      Principals.create_activation_code(nil, %{"purpose" => "test"})

    input =
      channel_input("chat", "workplace", "user_matched", %{"email" => "matched@example.com"})

    assert {:ok, ^principal, %ExternalIdentity{}} =
             Principals.consume_activation_code(plaintext, input)

    refute Repo.get!(ActivationCode, activation_code.id).used_at
  end

  test "login auth codes issue and consume for active Human channel actors" do
    {:ok, %{principal: principal}} =
      Principals.create_human(%{uid: "login-human", display_name: "Login Human"})

    insert_channel_identity!(principal, "chat", "workplace", "user_login")

    assert {:ok, plaintext} = Principals.issue_login_auth_code("chat", "workplace", "user_login")
    assert {:ok, ^principal} = Principals.consume_login_auth_code(plaintext)
    refute Repo.exists?(from code in PrincipalLoginAuthCode, select: 1)
    assert {:error, :invalid_or_expired_code} = Principals.consume_login_auth_code(plaintext)
  end

  test "login auth code issuance rejects Agent Principals" do
    {:ok, %{principal: principal}} =
      Principals.create_agent(%{
        uid: "login-agent",
        profile: %{}
      })

    insert_channel_identity!(principal, "chat", "workplace", "user_agent")

    assert {:error, :not_human} =
             Principals.issue_login_auth_code("chat", "workplace", "user_agent")
  end

  defp channel_input(adapter, channel_id, external_id, profile) do
    %{
      adapter: adapter,
      channel_id: channel_id,
      external_id: external_id,
      profile: profile,
      metadata: %{"tenant_key" => "tenant_xxx"}
    }
  end

  defp insert_channel_identity!(principal, adapter, channel_id, external_id) do
    %ExternalIdentity{}
    |> ExternalIdentity.changeset(%{
      principal_id: principal.id,
      kind: :channel_actor,
      adapter: adapter,
      channel_id: channel_id,
      external_id: external_id,
      metadata: %{}
    })
    |> Repo.insert!()
  end

  defp put_principals_config(config) do
    Application.put_env(:bullx, :principals, config)
  end

  defp restore_principals_config(nil), do: Application.delete_env(:bullx, :principals)
  defp restore_principals_config(config), do: Application.put_env(:bullx, :principals, config)
end
