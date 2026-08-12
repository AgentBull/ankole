# The WS client logs every frame at info level; keep test output readable.
Logger.configure(level: :warning)
ExUnit.start()
