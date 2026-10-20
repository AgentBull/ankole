defmodule AnkoleWeb.PodPresence do
  @moduledoc false
  use Phoenix.Presence, otp_app: :ankole, pubsub_server: Ankole.PubSub
end
