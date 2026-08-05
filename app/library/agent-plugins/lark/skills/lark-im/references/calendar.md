# Calendar

The bot operates application-visible calendars (`lark-cli calendar --help` lists operations not shown here); it does not inherit a human's personal calendar.

The typed surface covers calendars, events, attendees, meeting chat linkage, free/busy, exchange bindings, and calendar access controls. Use help and schema before each resource call:

```bash
lark-cli calendar calendars list --as bot --format json
lark-cli calendar calendars get --calendar-id <calendar_id> --as bot --format json
lark-cli schema calendar.events.create
lark-cli calendar events create --calendar-id <calendar_id> --data @event.json --as bot --format json
lark-cli calendar events search_event --calendar-id <calendar_id> --data @event-search.json --page-all --as bot --format json
lark-cli calendar freebusys list --data @freebusy.json --as bot --format json
```

Use the installed help if a command name differs; the schema identifier shown by command help is canonical. Supported workflows include:

- create, get, list, search, update, and delete calendars;
- create, get, list, search, update, and delete events;
- add, list, and remove event attendees;
- query free/busy intervals for explicit IDs;
- manage meeting chat or access-control resources when command help allows bot identity.

Preserve the tenant timezone and RFC 3339 offsets in event payloads. Before a write, echo the intended calendar, start/end time, timezone, recurrence, and attendee IDs in the plan or use `--dry-run`. Do not assume the bot's default calendar is a particular employee's calendar.
