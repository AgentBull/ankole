defmodule Ankole.Plugins.LineAdapter.Profile do
  @moduledoc """
  Author hydrator for LINE senders.

  A LINE webhook carries only the sender's user id, so a console mapping
  request or a standalone account would show `U…` instead of a name. The
  gateway calls this hydrator for an unmatched sender; the profile holds no
  email or phone number, so it never feeds the contact match.
  """

  alias Ankole.Plugins.LineAdapter.{Client, Config}
  alias Ankole.Plugins.MapHelpers

  @spec hydrate_author(map(), map()) :: {:ok, map()} | {:error, term()}
  def hydrate_author(config, author) when is_map(config) and is_map(author) do
    with {:ok, user_id} <- subject(author),
         {:ok, config} <- Config.validate_binding_config(config) do
      case Client.get(Config.client(config), profile_path(author, user_id)) do
        {:ok, %{"displayName" => name}} when is_binary(name) and name != "" ->
          {:ok, %{"display_name" => name}}

        {:ok, _profile} ->
          {:ok, %{}}

        # A user who has not added the Official Account, or who left the group,
        # has no readable profile. The mapping request then keeps the user id.
        {:error, %Client.Error{status: 404}} ->
          {:ok, %{}}

        {:error, _reason} = error ->
          error
      end
    end
  end

  defp subject(author) do
    case MapHelpers.optional_text(author, "platform_subject") do
      nil -> {:error, :missing_author_subject}
      user_id -> {:ok, user_id}
    end
  end

  defp profile_path(author, user_id) do
    metadata = MapHelpers.fetch_map(author, "metadata", %{})

    cond do
      group_id = MapHelpers.optional_text(metadata, "group_id") ->
        "/v2/bot/group/#{URI.encode(group_id)}/member/#{URI.encode(user_id)}"

      room_id = MapHelpers.optional_text(metadata, "room_id") ->
        "/v2/bot/room/#{URI.encode(room_id)}/member/#{URI.encode(user_id)}"

      true ->
        "/v2/bot/profile/#{URI.encode(user_id)}"
    end
  end
end
