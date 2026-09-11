# Email Adapter

The Email Adapter connects one dedicated mailbox to one Agent binding. It
receives mail over IMAP and sends mail over SMTP. Email has its own adapter
category, because its senders are neither directory members nor users of one
platform: anyone on the internet can write to the mailbox. The category
changes catalog and Console presentation only; the adapter uses the same
SignalsGateway contracts as every other Signal adapter.

Read [SignalsGateway](../SignalsGateway.md), [Principal](../Principal.md), and
[Local Password Identity Provider](../LocalPasswordIdentityProvider.md) for the
common message and identity rules.

## Current IDs and Features

| Item | Current value |
| --- | --- |
| Plugin ID | `email-adapter` |
| Signal adapter ID | `email` |
| Adapter category | `email` |
| Signal configuration | `signals_gateway.email.bindings.<id>` |
| IMAP client | Project `:ssl` client |
| SMTP client | `gen_smtp_client` |
| MIME decoder | Project decoder with `codepagex` charset conversion |
| MIME encoder | `mimemail` |

The binding settings are `address`, `displayName`, `imapHost`, `imapPort`,
`smtpHost`, `smtpPort`, `smtpSecurity`, `username`, the encrypted `password`,
and `senderAuthentication`. One `(imapHost, username)` pair can belong to only
one enabled Email binding.

The adapter supports all three group modes: `addressed_only`, `observe_all`,
and `may_intervene`.

The only inbound capability is `entry_receive`. Email has no reactions, no
edits, no removal events, and no callback buttons, so the adapter does not
declare `entry_removed`, `reaction_add`, `reaction_remove`, or `action_event`.

The outbound capabilities are `post_entry` and `reply_entry`. The adapter does
not declare `edit_entry`, `delete_entry`, `add_reaction`, `remove_reaction`,
`divider`, `card`, or `outbound_reconciliation`, and it does not declare a
reply-preview module. Because the adapter cannot edit a sent message,
SignalsGateway shows no streaming preview on an email channel and sends the
final Agent reply through the durable outbox, so an Agent reply is one
immutable email. A clarification
prompt goes out as plain text; the human answers with a normal reply, which
supersedes the pending interaction and enters the Agent as ordinary input.

## The Mailbox Belongs to the Agent

Each enabled binding has one supervised mailbox owner. The owner opens one
IMAP connection over implicit TLS, logs in, selects `INBOX`, and then repeats
this cycle:

1. `UID SEARCH UNSEEN` lists the messages that Ankole has not confirmed.
2. For each UID in ascending order, `UID FETCH` reads the size and the full
   message with `BODY.PEEK[]`, so the fetch itself does not change flags.
3. The adapter decodes the message and calls SignalsGateway ingress.
4. Only after ingress durably accepts the message, or the adapter explicitly
   ignores it, the owner sets `\Seen` with `UID STORE`.
5. The owner waits in `IDLE` for new mail, or polls on a fixed interval when
   the server does not offer `IDLE`.

The `\Seen` flag is the provider-side confirmation, in the same way that the
Telegram `offset` is. A control-plane crash between ingress and the flag write
delivers the same message again. SignalsGateway deduplicates it with its
durable source keys, so the adapter keeps no cursor table.

This makes the mailbox an Agent-owned resource: a person must not read the same
mailbox with another mail client, because a message that another client marks
as read never reaches the Agent.

The connection reconciler reads the current enabled bindings every 30 seconds.
A credential change replaces the old owner, and a disabled or deleted binding
stops its owner. A control-plane restart rebuilds the owners from binding
state.

An authentication failure blocks the owner and reports
`authentication_failed`. The owner tries again after one minute, and a saved
binding repair takes effect at the next reconciliation.

## Receive Messages

The source entry ID is the `Message-ID` header without its angle brackets. A
message without a usable `Message-ID` uses `uid:<uidvalidity>:<uid>`. The
source event ID is the same value.

The signal channel is the email thread. The channel ID is
`email:<mailbox address>:thread:<root message id>`. To place a message, the
adapter collects the IDs in its `In-Reply-To` and `References` headers and
looks them up in the binding's mirrored entries. A hit joins that entry's
channel. A miss starts a new thread whose root is the message's own ID. This
lookup also finds the replies that Ankole sent, because SignalsGateway mirrors
every successful outbound send. The adapter does not group messages by
subject.

The channel kind is `im_dm` when the sender and the mailbox are the only
participants, and `im_group` when other recipients are present. A message is
explicit input unless the mailbox address appears only in `Cc`. The channel
name is the thread root subject without its `Re:` prefix. The channel metadata
keeps the current participant addresses, which are the sender and every
recipient except the mailbox itself.

The message text is the `text/plain` part, so a control command at the start
of the body keeps its meaning. The subject is the channel name and the
`subject` entry metadata; a message without a body carries its subject as the
text. When only `text/html` is present, the adapter converts it to plain text
and keeps links. When a message joins a thread that Ankole already mirrors,
the adapter removes the quoted text below a reply separator and records
`quoted_text_removed` in the entry metadata; the mirrored entries already
hold the earlier messages. The first message Ankole sees in a thread keeps
its complete body, and so does a forwarded message: a forward marker line
above the first reply separator, or a subject with a forward prefix, stops
the cut.

The decoder supports the `7bit`, `8bit`, `binary`, `base64`, and
`quoted-printable` transfer encodings, RFC 2047 encoded words, and RFC 2231
parameter values. It converts `UTF-8`, `US-ASCII`, `ISO-8859-1`,
`Windows-1252`, `UTF-16`, `GB2312`, and `GBK` text to UTF-8. Text in another
charset keeps only its printable ASCII bytes and records the charset in the
entry metadata.

The adapter ignores these messages without a notice and confirms them with
`\Seen`:

- a message whose `From` is the mailbox address itself;
- a message with `Auto-Submitted` other than `no`, a `Precedence` of `bulk`,
  `list`, or `junk`, or a `List-Id` header;
- a message whose sender fails the sender authentication rule below.

These rules stop auto-responder loops and keep the fixed mapping notice away
from bulk senders.

## Authenticate the Sender

The `From` header is a claim, not a platform identity. The sender address
selects the `email` binding that admits the sender, so a forged `From` would
act as the person who owns that binding. The adapter parses the address
structure before it decodes RFC 2047 display names, so an encoded name cannot
insert another mailbox into the header. The binding also owns a
`senderAuthentication` setting:

- `dmarc` (default): the adapter reads the first `Authentication-Results`
  header, which the receiving mail server adds above every earlier header. The
  message passes when that header contains `dmarc=pass` and its `header.from`
  domain, when present, equals the `From` domain. Any other result refuses the
  message before admission.
- `none`: the adapter trusts the `From` header. Use this only for a mail
  server on a private network that admits no outside mail.

## Admit Email Identities

The author provider is `email`, and the stable external identity is the
lowercase sender address. The adapter reports no contact fields: an address
is also what an operator types into a profile or uses as a local sign-in
name, and neither proves that the account holder controls the mailbox. A
sender is therefore identified only by an `email` identity binding, which
has three sources:

- an administrator maps the address to a Principal from the mapping request
  that `manual_review` records;
- directory sync and provider sign-in bind the address that the provider
  reports for the user, so employees of an organization with a synced
  directory are admitted without a manual step;
- `create_standalone` creates a standalone human Principal whose UID is the
  address.

The display name from `From` is a display hint.

The binding owns `unmatched_sender_policy`. With `manual_review`, an unmatched
sender receives the fixed mapping notice as a reply email, and SignalsGateway
records a mapping request under provider `email`. The held message is never
mirrored, so the adapter addresses the notice to the sender that
SignalsGateway recorded on the notice row, with `In-Reply-To` set to the held
message; a `Reply-To` header on the held message is not honored. With
`create_standalone`, the gateway creates a standalone human Principal. Because
the DMARC rule refuses unauthenticated senders first, the standalone policy
carries the same risk as on Telegram: anyone who can send authenticated mail
can get an account. A sender whose address is already a Principal UID, such
as the installation's local administrator, is never joined automatically
under either policy: the message waits for review, and the administrator
binds the address once.

## Materialize Attachments

SignalsGateway first commits the admitted message with a pending attachment
projection. The adapter then writes each MIME part that carries a filename, or
that is not text, to the Agent's `user-files` lane under
`inbox/<attachment id>/<name>` and updates the same entry. An unmatched
sender cannot make Ankole write a file.

A message larger than 25 MB is fetched as headers only. Its entry keeps the
subject and a size notice, records `size_limit_exceeded` in the metadata, and
has no attachments.

## Send Replies

A `reply` targets one mirrored entry. Its recipients are the target's
`Reply-To` or `From` address plus the target's `To` and `Cc` addresses, without
the mailbox address. The subject is the target subject with one `Re:` prefix.
`In-Reply-To` names the target, and `References` continues the target's
references, bounded to the newest twenty IDs. A `post` sends to the channel's
current participants with the thread subject and `References` to the thread
root.

The adapter derives the outbound `Message-ID` from the outbox key, so a resend
after an uncertain result carries the same ID and mail clients thread or
deduplicate it. The body is `text/plain` in UTF-8. Attachments come from the
Agent's `user-files` lane as `multipart/mixed` parts; a message whose
attachments exceed 20 MB fails permanently.

The SMTP session verifies the server certificate against the system CA store
in both modes: implicit TLS passes the options to the connection, and
`STARTTLS` passes them to the upgrade. The adapter does not reconcile an
uncertain send. A connection failure after `DATA` can mean that the server
accepted the message, so the adapter returns `unknown` for a network failure
and an unexpected response. A `4xx` reply is retryable. A certificate
failure, a `5xx` authentication reply, and a missing `AUTH` or `STARTTLS`
requirement need operator action. Any other `5xx` reply is permanent.

## Limits

- Only password authentication is supported, including app passwords. Gmail
  needs an app password. Exchange Online has retired basic authentication, so
  a Microsoft 365 mailbox needs OAuth support that this adapter does not have.
- IMAP uses implicit TLS on the configured port. SMTP uses `STARTTLS` or
  implicit TLS as configured.
- IMAP and SMTP are direct TCP connections. `EgressProxy` covers only HTTP
  requests, so the control plane must reach the mail servers directly.
- The reply body is plain text. Markdown is not rendered to HTML.

## Secrets

AppConfigure encrypts the mailbox password. The password does not enter
connection status, logs, persisted errors, or stored raw provider payloads.
Public status contains only the mailbox address, connection state, the last
UID validity, and a bounded error classification.

## Tests

Repository tests cover declaration validation, credential ownership, MIME
decoding and charset conversion, encoded display names, sender
authentication, thread placement, identity policies, the `\Seen`
confirmation order against a fake IMAP server, the size limit, outbound
message construction against plain and TLS fake SMTP servers, certificate
verification, and failure classification. Real mailbox acceptance needs operator credentials
that the repository does not contain.

The implementation sources are:

- `plugins/email_adapter/lib/ankole/plugins/email_adapter.ex`
- `plugins/email_adapter/lib/ankole/plugins/email_adapter/`
