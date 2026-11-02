# First milestone: real Discord REST connection

**Status: first REST implementation committed on feature/rest-mvp-foundation; offline tests added but not executed with the complete Linux::Event stack; live verification outstanding.**

## Decision proposed: REST first

The shortest meaningful live-Discord test is an **outbound-only bot** that authenticates with a bot token, retrieves its identity, and posts a message into a test channel. This exercises real bot authentication, HTTPS, asynchronous request/response, JSON, Snowflake IDs, and a Discord message response.

It is an outbound notification bot—not yet a listener or interactive command bot. The first interactive bot requires an incoming interaction transport (Gateway or an HTTP interactions endpoint).

### Why not Gateway first?

| REST-first outbound test | Gateway-first event test |
|---|---|
| Two HTTPS operations, no persistent connection | WebSocket connection plus HELLO, heartbeat interval/ACK, IDENTIFY and READY |
| No Gateway intents or session-resume behavior | Correct intents, session transitions, close-code/reconnect behavior |
| Directly verifies sending a visible message | Initially proves only incoming connection/events |
| Simple to run and stop | Requires a persistent loop and correct periodic timers |

The Gateway is a valuable **second milestone**, but a half-implemented Gateway session is not a sound shortcut. Discord interactions over HTTP are another possibility, but require an HTTP endpoint reachable by Discord plus request-signature verification; that is not less work for our first test.

## Real Discord setup

1. Create a test application and bot in the Discord Developer Portal, or select an existing test bot.
2. Install the bot on a **test server**, requesting the `bot` scope and **Send Messages** permission. The destination channel must permit the bot to send messages.
3. Record the test text channel's Snowflake ID as a **string**.
4. Set environment variables locally: `DISCORD_BOT_TOKEN` and `DISCORD_CHANNEL_ID`. Do not commit, display, or log the token.
5. Run the sample on Linux with installed `Linux::Event` and `Linux::Event::HTTP`. No WebSocket dependency is needed until the Gateway phase.

No Message Content privileged intent is needed merely to send a message via REST.

## Concrete live calls

1. `GET https://discord.com/api/v10/users/@me`
   - Header: `Authorization: Bot <token>`
   - Expected: HTTP 200 with the bot's `id` (Snowflake string) and `username`.
2. `POST https://discord.com/api/v10/channels/{channel_id}/messages`
   - Same authorization, `Content-Type: application/json`.
   - Small body such as `{"content":"Hello from LE::Discord"}`.
   - Expected: successful Message response containing `id` and `channel_id`, matching the channel observed in Discord.

For repeated manual tests, make sending deliberate (explicit `send` command or explicit channel configuration), not a message sent automatically on every module load. Avoid uncontrolled posting on startup or after reconnect.

## Proposed minimal implementation

- `LE::Discord`: stores the Loop and bot token, without creating its own Loop.
- `LE::Discord::REST`: documented-route GET/POST/PUT/PATCH/DELETE, backed by `Linux::Event::HTTP::Client`, with named placeholders.
- `examples/rest_hello.pl`: `GET /users/@me` followed by an optional explicit `POST /channels/{channel.id}/messages`.
- JSON encode/decode, request headers, explicit HTTP statuses and errors; no silent synchronous HTTP calls.
- Preserve received Snowflakes as decimal strings. Raw hashes are sufficient for milestone one; object classes are not required to prove the transport.
- Carefully separate HTTP status failures (401, 403, 404, 429, 5xx) from connection/TLS errors. 401 should fail closed; 403 should explain permission failure; 429 must respect `Retry-After` or the JSON `retry_after` and must not loop aggressively.
- The first implementation uses a single in-flight request and a FIFO queue with response-driven bucket waits, a conservative global submission budget, and bounded 429 retries. Concurrent bucket scheduling remains a later milestone.
- Keep the bot token out of logs, error bodies where possible, and test fixtures.

**Application-facing interface implemented on the feature branch (not live-verified):**

```perl
$discord->rest->post(
    '/channels/{channel.id}/messages',
    'channel.id' => $ENV{DISCORD_CHANNEL_ID},
    json => { content => 'Hello from LE::Discord' },
    on_response => sub ($message) {
        say "Sent message $message->{id}";
        $loop->stop;
    },
    on_error => sub ($error) {
        warn "$error\n";
        $loop->stop;
    },
);
```

Callback conventions were checked against the current `Linux::Event::HTTP::Client` source; this implementation uses its completed `on_response` and terminal `on_finish` semantics.

## Tests and completion criteria

- No-credential tests: fake HTTP responses for successful bot identity and message creation, malformed JSON, timeout/TLS error, unauthorized token, forbidden channel, unexpected 5xx, and a 429 retry delay (with an explicit cap).
- Live test, run by a developer using local credentials: authenticate; send a single message; verify it visibly appears in the configured test channel; record the returned message and channel IDs; finish and stop the Loop.
- Repeated runs leave no active timers, in-flight requests, or leaked callback ownership.
- No live test runs in public CI, and no credentials or real test identifiers appear in committed fixtures.
- Document exactly what works and what has not yet been built.

## Follow-up milestones (not prerequisites)

**REST reliability:** normalized routes/major resource IDs, observed rate-limit buckets, queueing, global limit handling, bounded retries, tests. Study discord.js `REST.ts` and `SequentialHandler.ts`, and discord.py `http.py`.

**Gateway listener:** connect using `Linux::Event::WebSocket`; wait for HELLO; heartbeat with jitter and ACK failure detection; IDENTIFY with narrowly chosen intents; READY; clean disconnect; then RESUME/reconnect. First demo prints events, then add a simple command/interaction. Study DiscordGo `wsapi.go` and discord.js `WebSocketShard.ts`.

**Conveniences and coverage:** lightweight User/Message/Channel/Guild/Interaction objects, async reply helpers, pinned OpenAPI generation experiments, more endpoints. Only extract generic Linux::Event components when there is a demonstrated second user.

## Open design choice for discussion

Should the first visible output be a one-shot **send-and-exit** program (recommended), or a running periodic notification bot? One-shot is safer, smaller, and a sufficient live API proof; continuous scheduling can follow after the REST transport is stable.

## Relevant docs

- https://docs.discord.com/developers/quick-start/getting-started
- https://docs.discord.com/developers/resources/user
- https://docs.discord.com/developers/resources/message
- https://docs.discord.com/developers/topics/rate-limits
- https://docs.discord.com/developers/events/gateway

For the current implementation and deferred work, see [REST-DESIGN.md](REST-DESIGN.md).
