# LE::Discord

A planned Discord bot client built directly on the **Linux::Event** ecosystem.

**Status:** first REST-only implementation on [feature/rest-mvp-foundation](https://github.com/haxmeister/perl-LE-Discord/tree/feature/rest-mvp-foundation). On 2026-11-02, a real test bot successfully authenticated and created a message through the generic REST client. Further integration and cleanup validation remain.

The intent is an approachable Perl interface to Discord without a framework-neutral intermediary or a second event loop. The eventual client will use `Linux::Event::HTTP` for Discord REST calls and `Linux::Event::WebSocket` for Gateway traffic.

## First milestone

Begin with a **REST-only, outbound bot** that uses a bot token to identify itself and send one message to a configured test channel. This is intentionally smaller than an interactive bot. It lets us test the real Discord API and our HTTP integration before adding Gateway sessions and incoming events.

See [the first milestone](docs/FIRST-MILESTONE.md) for setup and acceptance criteria, and [REST design](docs/REST-DESIGN.md) for the public API and scheduling lifecycle.

## Research

[Research sources and findings](docs/RESEARCH.md) preserves the official Discord documentation, machine-readable API references, recommended SDK implementations in other languages, existing Perl projects, and the exact parts we intend to learn from.

## Design direction

- One distribution, `LE::Discord`, specifically for Linux::Event; no Unblock-style framework-neutral layer.
- A simple application-facing API; keep networking and event-loop integration explicit and predictable.
- Separate Discord REST policy from the HTTP transport; similarly, separate Gateway state from the WebSocket transport.
- Prefer lightweight objects. Preserve Snowflake IDs as decimal strings. Never silently fetch additional objects.
- Accept Discord's documented REST routes and named placeholders directly. The first milestone needs no OpenAPI route registry or endpoint-specific methods.
- Keep potentially reusable pieces (queues, timer scheduling, rate-limit mechanics, schema accessors) internally separable, but do not extract another distribution without a demonstrated second use case.
- Use previous SDKs as research, not source to copy without a specific license and compatibility review.

This repository already contains an MIT `LICENSE`. No credentials should ever be committed.

## REST interface (first implementation)

```perl
$discord->rest->post(
    '/channels/{channel.id}/messages',
    'channel.id' => $channel_id,
    json => { content => 'Hello from Perl!' },
    on_response => sub ($message) { say $message->{id} },
);
```

Using a test bot, run `perl -Ilib examples/rest_hello.pl identify` to request bot identity. Sending a message is a separate, explicit `send` command and requires `DISCORD_CHANNEL_ID`. Both commands succeeded against the real Discord API on 2026-11-02. The implementation currently schedules one request at a time.
