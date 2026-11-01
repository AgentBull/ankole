# Email Adapter

The Email Adapter connects one dedicated mailbox to one Agent binding, reading
inbound mail over IMAP and sending replies over SMTP. Email uses its own
`email` catalog category because anyone on the internet can write to a mailbox
rather than belonging to a single workspace or chat platform; however, that
category affects only Console presentation, and the adapter follows the same
Signals and Conversations contracts as every other Signal adapter.

See [Signals](../Signals.md), [Conversations](../Conversations.md),
[Sessions](../Sessions.md), [Principal](../Principal.md), and
[Authentication](../Authentication.md) for the shared messaging and identity
contracts.

## Provider and Public Identity

On inbound mail, the adapter reports an opaque `provider_conversation_id` and
`provider_message_id`, which `Conversations` resolves to a shared public
Conversation UUID and Message UUID. Every Agent observing that email thread
within the same tenant reads those shared public records while running in its
own `conversation:<public UUID>` Session—a Binding defines an observation and
delivery route rather than owning the thread.

## Current IDs and Features

| Item | Current value |
| --- | --- |
| Plugin ID | `email-adapter` |
| Signal adapter ID | `email` |
| Adapter category | `email` |
| Signal configuration | `signals.email.bindings.<id>` |
| IMAP client | Project `:ssl` client |
| SMTP client | `gen_smtp_client` |
| MIME decoder | Project decoder with `codepagex` charset conversion |
| MIME encoder | `mimemail` |

Each binding configures `address`, `displayName`, `imapHost`, `imapPort`,
`smtpHost`, `smtpPort`, `smtpSecurity`, `username`, encrypted `password`, and
`senderAuthentication`. A given `(imapHost, username)` pair can belong to at
most one enabled Email binding, and all three group-message modes
(`addressed_only`, `observe_all`, and `may_intervene`) are supported.

Inbound support consists solely of `entry_receive`—email has no reactions,
in-place edits, message recalls, or interactive button callbacks, so the adapter
declares none of `entry_removed`, `reaction_add`, `reaction_remove`, or
`action_event`. Outbound support consists of `post_entry` and `reply_entry`
without `edit_entry`, `delete_entry`, reactions, dividers, cards,
`outbound_reconciliation`, or a streaming reply-preview module. Because sent
emails are immutable, `Conversations` suppresses live previews on email channels
and dispatches each final Agent reply once through durable Delivery;
clarification prompts likewise go out as plain-text emails, and the human's
reply supersedes the pending interaction and enters the Agent as ordinary input.

## The Mailbox Belongs to the Agent

Each enabled binding supervises a dedicated mailbox owner process that connects
to IMAP over implicit TLS, authenticates, selects `INBOX`, and loops through
five steps:

1. Run `UID SEARCH UNSEEN` to list messages that Ankole has not yet confirmed.
2. Fetch each unseen UID in ascending order using `UID FETCH` with
   `BODY.PEEK[]` (reading message size and content without mutating flags).
3. Decode the MIME message and pass it to `Conversations.Observe`.
4. Mark the message `\Seen` via `UID STORE` only after ingress durably commits
   the observation or the adapter explicitly drops it.
5. Enter IMAP `IDLE` to await new mail, falling back to fixed-interval polling
   when the server does not advertise `IDLE`.

Here, the IMAP `\Seen` flag serves as the provider-side cursor—analogous to
Telegram's `offset`. If the control plane crashes after committing ingress and
before writing `\Seen`, the next pass fetches the message again and `Signals`
deduplicates it via durable source keys. Consequently, the mailbox must belong
exclusively to the Agent: if a human opens the same mailbox in another mail
client and marks messages read, the Agent will never see them.

Every 30 seconds, the connection reconciler refreshes active mailbox owners from
enabled bindings—replacing the owner when credentials change, stopping it when a
binding is disabled or deleted, and rebuilding owners on control-plane startup.
If IMAP login fails, the owner blocks with `authentication_failed` and retries
after one minute, picking up repaired credentials on the next reconciliation
pass.

## Receive Messages

Ankole uses the stripped `Message-ID` header (without angle brackets) as both
`provider_message_id` and `source_event_id`, falling back to
`uid:<uidvalidity>:<uid>` when a message carries no usable `Message-ID`.

Conversations map one-to-one to email threads identified by
`email:<mailbox address>:thread:<root message id>`. Rather than grouping by
subject line, the adapter extracts message IDs from `In-Reply-To` and
`References` and looks them up against mirrored entries on the binding
(including outbound Agent replies mirrored by `Conversations`): a match joins
that existing thread, while a miss starts a new thread rooted at the incoming
message's ID.

When only the sender and the Agent mailbox participate, the channel kind is
`im_dm`; when additional recipients appear, it becomes `im_group` (counting as
explicit input unless the Agent mailbox appears only in `Cc`). Channel names
strip leading `Re:` prefixes from the root subject, and channel metadata tracks
all participant addresses except the Agent mailbox itself.

Body extraction prefers `text/plain` so leading slash commands stay intact
(converting `text/html` to link-preserving plain text when no plain-text part
exists, and falling back to the subject line when the body is empty while also
storing `subject` in entry metadata). When a reply joins an already mirrored
thread, the adapter strips quoted history below the reply separator and sets
`quoted_text_removed` in metadata because earlier turns are already mirrored;
however, the first message that Ankole sees in a thread—as well as any forwarded
email carrying a forward subject prefix or a forward marker above the first
reply separator—retains its complete body.

MIME decoding handles `7bit`, `8bit`, `binary`, `base64`, and `quoted-printable`
transfer encodings plus RFC 2047 encoded words and RFC 2231 parameters,
converting `UTF-8`, `US-ASCII`, `ISO-8859-1`, `Windows-1252`, `UTF-16`,
`GB2312`, and `GBK` into UTF-8 (for other charsets, it retains printable ASCII
bytes and records the original charset name in metadata).

To prevent auto-responder loops and avoid sending mapping notices to mailing
lists or spoofed senders, the adapter silently drops—and marks `\Seen`—any
message that:

- lists the Agent's own mailbox address or multiple mailboxes in `From`;
- carries an `Auto-Submitted` value other than `no`, a `Precedence` of `bulk`,
  `list`, or `junk`, or any `List-Id` header; or
- fails the binding's sender-authentication policy below.

## Authenticate the Sender

Because raw SMTP `From` headers are unverified claims—and because Ankole matches
the `From` address against `email` identity bindings—accepting an unverified
`From` header would let an attacker impersonate a bound Human Principal. First,
the adapter parses structural RFC 5322 mailbox tokens before decoding RFC 2047
display names so a crafted display name can never smuggle a second address into
`From`. Second, each binding enforces `senderAuthentication`:

- `dmarc` (default): inspects the topmost `Authentication-Results` header added
  by the receiving mail server and accepts the message only if it reports
  `dmarc=pass` with `header.from` matching the exact domain of the parsed `From`
  address; if `header.from` is missing, names a different domain, or reports any
  other DMARC outcome, the adapter drops the message before identity admission.
- `none`: trusts `From` as-is; reserve this setting strictly for isolated
  internal mail servers that accept no external internet mail.

## Admit Email Identities

Inbound senders use provider namespace `email` with the lowercased sender
address as `external_id` (treating the `From` display name only as a UI hint).
Because an unverified email typed into a Human profile does not prove mailbox
control, the adapter reports no contact-matching fields; instead, admission
requires an explicit `email` identity binding established through one of three
paths:

- an administrator approves a `manual_review` mapping request and binds the
  address to a Principal;
- enterprise directory sync or OIDC login binds the provider-verified email
  address, admitting synced employees automatically; or
- `create_standalone` creates a new Human Principal named by the normalized sender
  address and binds that address (since DMARC runs first, any sender passing DMARC can
  open a standalone account when `create_standalone` is enabled).

Even if a sender address happens to match an existing Principal UID string,
Ankole never selects that Principal without an `email` identity binding. A new
account whose name is already occupied returns `principal_uid_taken`. Under
`manual_review`, an unmatched sender receives the fixed localized mapping notice
as a threaded reply (`In-Reply-To` pointing to the held message, addressed
strictly to the sender recorded on the notice row while ignoring any untrusted
`Reply-To` header on the held email), and `Conversations` logs the mapping
request without mirroring the held email.

## Materialize Attachments

Once a message is admitted, `Conversations` commits a pending attachment
projection—ensuring unmapped senders never write blobs—and the adapter writes
each named or non-text MIME part to the file service under
`inbox/<digest>/<name>` ([Files](../Files.md)) and updates the entry. Messages
exceeding 25 MB are fetched as headers only, recording the subject, a size
notice, and `size_limit_exceeded` metadata without downloading attachments.

## Send Replies

Outbound `reply` intents address the target entry's `Reply-To` (or `From`) plus
its `To` and `Cc` recipients—excluding the Agent's own mailbox—using a single
`Re:` prefix on the target subject, setting `In-Reply-To` to the target, and
appending to `References` (capped at the 20 most recent IDs). Outbound `post`
intents address all current thread participants using the thread subject and
`References` pointing to the thread root.

Each outbound email derives a deterministic `Message-ID` from the Delivery
intent key so mail clients deduplicate or thread retries cleanly, encodes prose
as UTF-8 `text/plain`, and attaches files from the file service as
`multipart/mixed` parts (permanently failing if total attachments exceed 20 MB).

SMTP connections verify the server's TLS certificate against the system CA store
under both implicit TLS and `STARTTLS`. Because SMTP offers no post-`DATA`
reconciliation, a dropped socket or unexpected response after `DATA` returns
`unknown`; `4xx` responses are retryable; TLS certificate errors, `5xx` auth
failures, or missing `AUTH`/`STARTTLS` support require operator action; and all
other `5xx` responses fail permanently.

## Limits

- Only password authentication (including app-specific passwords, as required by
  Gmail) is supported; Microsoft 365 / Exchange Online mailboxes that require
  OAuth2 are not supported by this adapter.
- IMAP always uses implicit TLS on `imapPort`, while SMTP uses either `STARTTLS`
  or implicit TLS per `smtpSecurity`.
- Both IMAP and SMTP open direct TCP sockets from the control plane;
  `EgressProxy` proxies only HTTP traffic, so control-plane nodes must have
  direct network egress to the mail servers.
- Outbound bodies are sent strictly as `text/plain` without rendering Markdown
  to HTML.

## Secrets

`AppConfigure` encrypts `password` at rest and keeps it out of connection
status, logs, persisted error details, and raw payloads; public status views
expose only the mailbox address, connection state, latest `UIDVALIDITY`, and
bounded error codes.

## Tests

Automated tests verify plugin declarations, single-binding mailbox ownership,
MIME/charset decoding, RFC 2047 display-name safety, DMARC validation, thread
resolution, sender identity policies, `\Seen` ordering against a fake IMAP
server, the 25 MB fetch cap, outbound MIME assembly and TLS certificate checks
against fake plain/TLS SMTP servers, and SMTP error classification. End-to-end
live mailbox testing requires operator credentials outside the repository.

Implementation paths:

- `plugins/email_adapter/lib/ankole/plugins/email_adapter.ex`
- `plugins/email_adapter/lib/ankole/plugins/email_adapter/`
