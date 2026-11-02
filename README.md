# LE::Discord

A planned Discord bot client built directly on the **Linux::Event** ecosystem.

**Status:** research and planning. There is no bot client implementation in this repository yet.

The intent is an approachable Perl interface to Discord without a framework-neutral intermediary or a second event loop. The eventual client will use `Linux::Event::HTTP` for Discord REST calls and `Linux::Event::WebSocket` for Gateway traffic.

## First milestone

Begin with a **REST-only, outbound bot** that uses a bot token to identify itself and send one message to a configured test channel. This is intentionally smaller than an interactive bot. It lets us test the real Discord API and our HTTP integration before adding Gateway sessions and incoming events.

See [the proposed first milestone](docs/FIRST-MILESTONE.md) for setup, scope, trade-offs, and acceptance criteria.

## Research

[Research sources and findings](docs/RESEARCH.md) preserves the official Discord documentation, machine-readable API references, recommended SDK implementations in other languages, existing Perl projects, and the exact parts we intend to learn from.

## Design direction

- One distribution, `LE::Discord`, specifically for Linux::Event; no Unblock-style framework-neutral layer.
- A simple application-facing API; keep networking and event-loop integration explicit and predictable.
- Separate Discord REST policy from the HTTP transport; similarly, separate Gateway state from the WebSocket transport.
- Prefer lightweight objects. Preserve Snowflake IDs as decimal strings. Never silently fetch additional objects.
- Explore generating routine REST endpoint definitions from a pinned Discord OpenAPI revision **after** the smallest working bot is verified. The specification is preview-quality, not a substitute for Discord's written documentation.
- Keep potentially reusable pieces (queues, timer scheduling, rate-limit mechanics, schema accessors) internally separable, but do not extract another distribution without a demonstrated second use case.
- Use previous SDKs as research, not source to copy without a specific license and compatibility review.

This repository already contains an MIT `LICENSE`. No credentials should ever be committed.
