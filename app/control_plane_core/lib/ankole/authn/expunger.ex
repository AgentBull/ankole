defmodule Ankole.Authn.Expunger do
  @moduledoc false
  require Ash.Query

  def expire(now) do
    oldest = DateTime.add(now, -86_400)

    with {:ok, _} <-
           Ankole.Authn.Challenge
           |> Ash.Query.filter(challenge_started_at < ^oldest)
           |> Ankole.Ash.destroy_where(:expire_in_tx),
         do: Ankole.BrowserSessions.cleanup_expired(now)
  end
end
