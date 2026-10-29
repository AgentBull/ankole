real_llm_exclude =
  case System.get_env("ANKOLE_REAL_LLM_E2E") do
    "1" -> []
    _ -> [real_llm: true]
  end

# The SaaS edition signs in on the accounts host instead of the Pod sign-in pages.
sign_in_exclude =
  if Application.get_env(:ankole, :edition) == :saas, do: [foss_sign_in: true], else: []

ExUnit.start(exclude: [:regenerate_golden | real_llm_exclude ++ sign_in_exclude])
Ecto.Adapters.SQL.Sandbox.mode(Ankole.Repo, :manual)
