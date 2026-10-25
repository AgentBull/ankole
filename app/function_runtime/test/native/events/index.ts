export {}

const events = new EventManager()
for await (const event of events) {
  if (event) console.warn(`NATIVE_DIAGNOSTIC_EVENT ${JSON.stringify(event)}`)
}
