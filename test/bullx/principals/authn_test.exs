defmodule BullX.Principals.AuthNTest do
  use BullX.DataCase, async: false

  import Ecto.Changeset

  alias BullX.AuthZ
  alias BullX.Principals
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

    input =
      channel_input("chat", "workplace", "user_alice", %{"email" => "ALICE@example.com"})
      |> Map.put(:trusted_realm_by_default, true)

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

  test "unmatched channel actors auto-create unverified identities with the default policy" do
    assert {:ok, %Principal{type: :human}, %ExternalIdentity{} = identity} =
             Principals.match_or_create_human_from_channel(
               channel_input("chat", "workplace", "user_new", %{"email" => "new@example.com"})
             )

    refute Principals.channel_identity_verified?(identity)

    assert {:error, :identity_unverified} =
             Principals.resolve_channel_actor("chat", "workplace", "user_new")
  end

  test "IM message human actors are created before admission" do
    assert {:ok, %Principal{type: :human} = principal, %ExternalIdentity{} = identity} =
             Principals.ensure_human_from_channel_actor(
               channel_input("chat", "workplace", "user_fact", %{"email" => "fact@example.com"})
             )

    assert identity.kind == :channel_actor
    assert identity.principal_id == principal.id
    refute Principals.channel_identity_verified?(identity)

    assert {:error, :identity_unverified} =
             Principals.resolve_channel_actor("chat", "workplace", "user_fact")
  end

  test "IM message human actors can reference disabled bound Humans" do
    {:ok, %{principal: principal}} =
      Principals.create_human(%{uid: "disabled-fact-human", display_name: "Disabled Fact"})

    insert_channel_identity!(principal, "chat", "workplace", "user_disabled_fact")

    principal
    |> change(%{status: :disabled})
    |> Repo.update!()

    assert {:ok, %Principal{status: :disabled} = disabled, %ExternalIdentity{} = identity} =
             Principals.ensure_human_from_channel_actor(
               channel_input("chat", "workplace", "user_disabled_fact", %{})
             )

    assert disabled.id == principal.id
    assert identity.principal_id == principal.id
  end

  test "trusted channel actors are verified when created" do
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

    input =
      channel_input("chat", "workplace", "user_matched", %{"email" => "matched@example.com"})
      |> Map.put(:trusted_realm_by_default, true)

    assert {:ok, ^principal, %ExternalIdentity{} = identity} =
             Principals.match_or_create_human_from_channel(input)

    assert Principals.channel_identity_verified?(identity)
  end

  test "root init uses a process-local bootstrap code to create the first admin" do
    assert {:ok, %{code: plaintext, code_hash: code_hash}} =
             Principals.create_or_refresh_bootstrap_activation_code()

    assert {:ok, ^code_hash} = Principals.verify_bootstrap_activation_code_for_setup(plaintext)

    input =
      channel_input("chat", "workplace", "user_root", %{
        "display_name" => "Root User",
        "email" => "root@example.com"
      })

    assert {:ok, %Principal{type: :human} = principal, %ExternalIdentity{} = identity} =
             Principals.root_init_with_bootstrap_code(plaintext, input)

    assert identity.principal_id == principal.id
    assert Principals.channel_identity_verified?(identity)

    assert {:ok, groups} = AuthZ.list_principal_groups(principal)
    assert Enum.any?(groups, &(&1.name == "admin" and &1.built_in))
    assert Enum.any?(groups, &(&1.name == "all_humans" and &1.built_in))

    assert {:error, :root_init_closed} =
             Principals.root_init_with_bootstrap_code(plaintext, input)
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

  test "login subjects bind to existing Humans by trusted profile identity facts" do
    {:ok, %{principal: uid_principal}} =
      Principals.create_human(%{uid: "feishu-user-id", display_name: "UID Human"})

    {:ok, %{principal: email_principal}} =
      Principals.create_human(%{
        uid: "email-human",
        display_name: "Email Human",
        email: "ada@example.com"
      })

    {:ok, %{principal: phone_principal}} =
      Principals.create_human(%{
        uid: "phone-human",
        display_name: "Phone Human",
        phone: "+8618511112441"
      })

    assert {:ok, ^uid_principal, %ExternalIdentity{}} =
             Principals.match_or_create_human_from_login_subject(
               login_subject_input("feishu:ou_uid", %{"uid" => "FEISHU-USER-ID"})
             )

    assert {:ok, ^email_principal, %ExternalIdentity{}} =
             Principals.match_or_create_human_from_login_subject(
               login_subject_input("feishu:ou_email", %{"email" => "ADA@example.com"})
             )

    assert {:ok, ^phone_principal, %ExternalIdentity{}} =
             Principals.match_or_create_human_from_login_subject(
               login_subject_input("feishu:ou_phone", %{"phone" => "+8618511112441"})
             )
  end

  test "login subjects bind to an existing channel actor from metadata channel ref" do
    {:ok, %{principal: principal}} =
      Principals.create_human(%{uid: "feishu-user", display_name: "Feishu User"})

    insert_channel_identity!(principal, "feishu", "main", "feishu:ou_user")

    input = %{
      provider: "main",
      external_id: "feishu:ou_user",
      profile: %{"uid" => "user_x", "email" => "ada@example.com"},
      metadata: %{"adapter" => "feishu", "source_id" => "main"}
    }

    assert {:ok, ^principal, %ExternalIdentity{} = identity} =
             Principals.match_or_create_human_from_login_subject(input)

    assert identity.kind == :login_subject
    assert identity.provider == "main"
    assert identity.external_id == "feishu:ou_user"
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

  defp login_subject_input(external_id, profile) do
    %{
      provider: "main",
      external_id: external_id,
      profile: profile,
      metadata: %{"adapter" => "feishu", "source_id" => "main"}
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
      verified_at: DateTime.utc_now(:microsecond),
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
