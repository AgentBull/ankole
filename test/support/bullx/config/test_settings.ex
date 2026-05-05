defmodule BullX.Config.TestSettings do
  use BullX.Config

  @envdoc false
  bullx_env(:test_integer,
    type: :integer,
    default: 10,
    zoi: Zoi.integer(gte: 1, lte: 20)
  )

  @envdoc false
  bullx_env(:test_boolean,
    type: :boolean,
    default: false
  )

  @envdoc false
  bullx_env(:test_mode,
    type: :binary,
    default: "safe",
    zoi: Zoi.enum(["safe", "fast", "strict"])
  )

  @envdoc false
  bullx_env(:test_secret,
    type: :binary,
    default: nil,
    secret: true
  )

  @envdoc false
  bullx_env(:test_generated_secret,
    type: :generated_secret,
    default: nil,
    secret: true
  )
end
