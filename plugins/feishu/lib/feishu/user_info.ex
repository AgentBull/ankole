defmodule Feishu.UserInfo do
  @moduledoc false

  alias Feishu.Source

  import BullX.Utils.Map, only: [maybe_put: 3]

  @authn_userinfo_path "/open-apis/authen/v1/user_info"
  @contact_user_path "/open-apis/contact/v3/users/:user_id"

  @spec fetch_authn(Source.t(), String.t()) :: {:ok, map()} | {:error, map()}
  def fetch_authn(%Source{} = source, access_token)
      when is_binary(access_token) and access_token != "" do
    source
    |> Source.client!()
    |> FeishuOpenAPI.get(@authn_userinfo_path, user_access_token: access_token)
    |> normalize_authn_response()
  end

  @spec fetch_contact(Source.t(), String.t()) :: {:ok, map()} | {:error, map()}
  @spec fetch_contact(Source.t(), String.t(), String.t()) :: {:ok, map()} | {:error, map()}
  def fetch_contact(%Source{} = source, user_id, id_type \\ "open_id")
      when is_binary(user_id) and user_id != "" and is_binary(id_type) and id_type != "" do
    source
    |> Source.client!()
    |> FeishuOpenAPI.get(@contact_user_path,
      path_params: %{user_id: user_id},
      query: [user_id_type: id_type]
    )
    |> normalize_contact_response()
  end

  @spec open_id(map()) :: {:ok, String.t()} | {:error, map()}
  def open_id(userinfo) when is_map(userinfo) do
    case first_string(userinfo, ["open_id", "sub"]) do
      open_id when is_binary(open_id) -> {:ok, open_id}
      _value -> {:error, Feishu.Error.payload("Feishu userinfo is missing open_id")}
    end
  end

  @spec profile(map()) :: map()
  def profile(userinfo) when is_map(userinfo) do
    %{}
    |> maybe_put("uid", first_string(userinfo, ["user_id"]))
    |> maybe_put(
      "display_name",
      first_string(userinfo, ["name", "display_name", "nickname", "en_name"])
    )
    |> maybe_put("email", normalized_email(first_string(userinfo, ["enterprise_email", "email"])))
    |> maybe_put_phone(first_string(userinfo, ["mobile", "phone"]))
    |> maybe_put("avatar_url", avatar_url(userinfo))
    |> maybe_put("open_id", first_string(userinfo, ["open_id", "sub"]))
    |> maybe_put("union_id", first_string(userinfo, ["union_id"]))
    |> maybe_put("user_id", first_string(userinfo, ["user_id"]))
  end

  defp normalize_authn_response({:ok, %{"data" => data}}) when is_map(data), do: {:ok, data}
  defp normalize_authn_response({:ok, data}) when is_map(data), do: {:ok, data}
  defp normalize_authn_response({:error, error}), do: {:error, Feishu.Error.map(error)}

  defp normalize_contact_response({:ok, %{"data" => %{"user" => user}}}) when is_map(user),
    do: {:ok, user}

  defp normalize_contact_response({:ok, %{"data" => data}}) when is_map(data), do: {:ok, data}
  defp normalize_contact_response({:ok, data}) when is_map(data), do: {:ok, data}
  defp normalize_contact_response({:error, error}), do: {:error, Feishu.Error.map(error)}

  defp avatar_url(userinfo) do
    first_string(userinfo, ["avatar_url", "avatar_thumb", "avatar_middle", "picture"]) ||
      avatar_map_url(Map.get(userinfo, "avatar") || Map.get(userinfo, :avatar))
  end

  defp avatar_map_url(avatar) when is_map(avatar) do
    first_string(avatar, ["avatar_origin", "avatar_640", "avatar_240", "avatar_72"])
  end

  defp avatar_map_url(_avatar), do: nil

  defp first_string(map, keys) do
    Enum.find_value(keys, fn key ->
      case Map.get(map, key) || Map.get(map, known_atom_key(key)) do
        value when is_binary(value) and value != "" -> value
        _value -> nil
      end
    end)
  end

  defp known_atom_key("avatar_middle"), do: :avatar_middle
  defp known_atom_key("avatar_thumb"), do: :avatar_thumb
  defp known_atom_key("avatar_url"), do: :avatar_url
  defp known_atom_key("display_name"), do: :display_name
  defp known_atom_key("email"), do: :email
  defp known_atom_key("en_name"), do: :en_name
  defp known_atom_key("enterprise_email"), do: :enterprise_email
  defp known_atom_key("mobile"), do: :mobile
  defp known_atom_key("name"), do: :name
  defp known_atom_key("nickname"), do: :nickname
  defp known_atom_key("open_id"), do: :open_id
  defp known_atom_key("phone"), do: :phone
  defp known_atom_key("picture"), do: :picture
  defp known_atom_key("sub"), do: :sub
  defp known_atom_key("union_id"), do: :union_id
  defp known_atom_key("user_id"), do: :user_id
  defp known_atom_key(_key), do: nil

  defp normalized_email(nil), do: nil
  defp normalized_email(email), do: email |> String.trim() |> String.downcase()

  defp maybe_put_phone(map, nil), do: map

  defp maybe_put_phone(map, phone) do
    phone
    |> phone_candidates()
    |> Enum.find_value(fn candidate ->
      case BullX.Ext.phone_normalize_e164(candidate) do
        normalized when is_binary(normalized) -> normalized
        _other -> nil
      end
    end)
    |> case do
      nil -> map
      normalized -> Map.put(map, "phone", normalized)
    end
  end

  defp phone_candidates(phone) do
    trimmed = String.trim(phone)
    digits = String.replace(trimmed, ~r/\D/, "")

    case String.length(digits) == 11 and String.starts_with?(digits, "1") do
      true -> [trimmed, "+86" <> digits]
      false -> [trimmed]
    end
  end
end
