real_llm_exclude =
  case System.get_env("ANKOLE_REAL_LLM_E2E") do
    "1" -> []
    _ -> [real_llm: true]
  end

ExUnit.start(exclude: real_llm_exclude)
Ecto.Adapters.SQL.Sandbox.mode(Ankole.Repo, :manual)
