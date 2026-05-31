defmodule BullX.Config.Secrets do
  @moduledoc """
  Startup-only secret configuration that must not be sourced from the database.

  These values protect the database-backed configuration layer itself. They
  therefore come from the operating environment only, before any encrypted
  runtime config can be read.
  """

  use BullX.Config

  @envdoc """
  Root secret used to derive all application keys (Phoenix secret_key_base, LiveView
  signing_salt, etc.). Must be set via `BULLX_SECRET_BASE` environment variable.
  Generate with `mix phx.gen.secret`. No default; absence raises at startup.
  Database configuration is intentionally disallowed for this setting.
  """
  bullx_env(:secret_base,
    type: :binary,
    required: true,
    binding_order: [BullX.Config.SystemBinding],
    binding_skip: [:system, :config],
    zoi: Zoi.string() |> Zoi.min(64)
  )
end
