exclude =
  case System.get_env("ANKOLE_REAL_LLM_E2E") do
    "1" -> []
    _ -> [real_llm: true]
  end

ExUnit.start(exclude: exclude)
Ecto.Adapters.SQL.Sandbox.mode(Ankole.Repo, :manual)
