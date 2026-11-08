defmodule Ankole.Principals.Avatars do
  @moduledoc false

  require Ash.Query

  alias Ankole.AuthZ.Actor
  alias Ankole.Principals.{Humans, Principal, ProfileAvatar}
  alias Ankole.{AuthZ, Files, Repo, Tenants}

  @max_avatar_bytes 5 * 1024 * 1024
  @space_key "space"

  def upload_member(%Actor{} = actor, source, content_type) do
    uid = Actor.uid(actor)
    key = "member:#{uid}"

    with {:ok, principal} <- Humans.get_principal(uid),
         :ok <- Humans.ensure_principal_type(principal, :human) do
      upload(source, content_type, key, fn avatar_url ->
        with {:ok, locked} <- Humans.lock_principal_in_tx(uid),
             :ok <- Humans.ensure_principal_type(locked, :human),
             {:ok, _updated} <-
               Humans.update_principal_profile(locked, %{avatar_url: avatar_url}),
             do: :ok
      end)
    end
  end

  def upload_space(%Actor{} = actor, source, content_type) do
    if AuthZ.pod_admin?(Actor.uid(actor)) do
      upload(source, content_type, @space_key, fn avatar_url ->
        with {:ok, _tenant} <-
               Tenants.change_profile_in_tx(Repo.tenant_id!(), %{avatar_url: avatar_url}),
             do: :ok
      end)
    else
      {:error, :forbidden}
    end
  end

  def fetch(key) when is_binary(key) do
    ProfileAvatar
    |> Ash.Query.filter(key == ^key)
    |> Ankole.Ash.read_one()
    |> case do
      {:ok, %ProfileAvatar{} = avatar} -> {:ok, avatar}
      {:ok, nil} -> {:error, :not_found}
      {:error, _reason} = error -> error
    end
  end

  def fetch(_key), do: {:error, :not_found}

  @doc false
  def rename_member_in_tx(%Principal{type: :human} = principal, old_uid, new_uid) do
    old_key = "member:" <> old_uid
    new_key = "member:" <> new_uid

    with :ok <- move_avatar_row_in_tx(old_key, new_key) do
      rewrite_member_avatar_url_in_tx(principal, old_key, new_key)
    end
  end

  def rename_member_in_tx(%Principal{} = principal, _old_uid, _new_uid), do: {:ok, principal}

  defp move_avatar_row_in_tx(old_key, new_key) do
    case ProfileAvatar |> Ash.Query.filter(key == ^old_key) |> Ankole.Ash.read_one!() do
      nil ->
        :ok

      %ProfileAvatar{} = avatar ->
        with {:ok, _moved} <-
               Ankole.Ash.create(ProfileAvatar, :put_in_tx, %{
                 key: new_key,
                 object_id: avatar.object_id,
                 content_type: avatar.content_type
               }),
             {:ok, _deleted} <- Ankole.Ash.destroy(avatar, :remove),
             do: :ok
    end
  end

  defp rewrite_member_avatar_url_in_tx(%Principal{avatar_url: url} = principal, old_key, new_key)
       when is_binary(url) do
    old_prefix = "/api/v2/pod/avatars/" <> URI.encode_www_form(old_key) <> "?"

    if String.starts_with?(url, old_prefix) do
      suffix = String.replace_prefix(url, old_prefix, "")
      new_url = "/api/v2/pod/avatars/" <> URI.encode_www_form(new_key) <> "?" <> suffix
      Humans.update_principal_profile(principal, %{avatar_url: new_url})
    else
      {:ok, principal}
    end
  end

  defp rewrite_member_avatar_url_in_tx(%Principal{} = principal, _old_key, _new_key),
    do: {:ok, principal}

  defp upload(source, content_type, key, write_owner) do
    with :ok <- Files.validate_image_source(source, content_type, @max_avatar_bytes),
         {:ok, stored} <- Files.store(source),
         avatar_url = avatar_url(key, stored.sha256),
         :ok <-
           Repo.transact_top_level(fn ->
             with :ok <- write_owner.(avatar_url),
                  {:ok, _object} <- Files.complete_object_in_tx(stored),
                  {:ok, _avatar} <- store_reference_in_tx(key, stored, content_type),
                  do: :ok
           end) do
      {:ok, %{avatarURL: avatar_url}}
    end
  end

  defp store_reference_in_tx(key, stored, content_type) do
    Ankole.Ash.create(ProfileAvatar, :put_in_tx, %{
      key: key,
      object_id: stored.object_id,
      content_type: content_type
    })
  end

  defp avatar_url(key, version) do
    "/api/v2/pod/avatars/#{URI.encode_www_form(key)}?v=#{URI.encode_www_form(version)}"
  end
end
