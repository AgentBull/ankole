/** Worker-owned webhook CLI socket for the current execution. */
export const WEBHOOK_CLI_SOCKET_ENV = 'ANKOLE_RUNTIME_WEBHOOK_CLI_SOCKET'
/** Worker-owned Automation Job CLI socket for the current execution. */
export const AUTOMATION_JOB_CLI_SOCKET_ENV = 'ANKOLE_RUNTIME_AUTOMATION_JOB_CLI_SOCKET'
/** Worker-owned drive CLI (`ankole-files`) socket for the current execution. */
export const DRIVE_CLI_SOCKET_ENV = 'ANKOLE_RUNTIME_FILES_CLI_SOCKET'
/** Worker-owned Pod CLI socket, bound to the active turn. */
export const POD_CLI_SOCKET_ENV = 'ANKOLE_RUNTIME_POD_CLI_SOCKET'
/** Control-plane model-history context identity (`<conversation_id>:cmp:<checkpoint_id|root>`). */
export const SESSION_CONTEXT_ID_ENV = 'ANKOLE_RUNTIME_SESSION_CONTEXT_ID'
/** Worker-managed pointer file holding the active model context identity for shell CLIs. */
export const CLI_CONTEXT_FILE_ENV = 'ANKOLE_RUNTIME_CLI_CONTEXT_FILE'
/** Worker-managed SQLite ledger directory outside `/workspace` for first-use CLI guidance. */
export const CLI_LEDGER_DIR_ENV = 'ANKOLE_RUNTIME_CLI_LEDGER_DIR'
