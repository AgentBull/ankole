# The IM-gateway mock integration suite is heavy and excluded from the default
# `mix test`. Run it via `mix im_gateway_integration_test`.
ExUnit.start(exclude: [:im_gateway_integration])
Ecto.Adapters.SQL.Sandbox.mode(BullX.Repo, :manual)
