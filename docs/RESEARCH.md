# Discord research references

Research captured **2026-11-01** for the `LE::Discord` project. Links are intentionally retained so future work can locate the evidence and implementation patterns without restarting the investigation.

## Source of truth: Discord

| Resource | Link | What to read it for |
|---|---|---|
| Developer documentation | https://docs.discord.com/developers/ | Canonical behavioral requirements and API semantics; prefer this if specifications disagree |
| First bot guide | https://docs.discord.com/developers/quick-start/getting-started | Creating an application/bot, server install, scopes, `Send Messages` permission, testing |
| User resource | https://docs.discord.com/developers/resources/user | `GET /users/@me`: simplest authenticated REST test; User fields |
| Message resource | https://docs.discord.com/developers/resources/message | `POST /channels/{channel_id}/messages`, message payloads, mentions, response object |
| Rate limits | https://docs.discord.com/developers/topics/rate-limits | `X-RateLimit-*` headers, bucket IDs, major resources, global limits, `Retry-After`, 429 and invalid-request handling |
| Gateway lifecycle | https://docs.discord.com/developers/events/gateway | HELLO before IDENTIFY, heartbeats and ACK, intents, reconnect, resume URL, compression, sharding |
| Gateway events | https://docs.discord.com/developers/events/gateway-events | Opcodes, READY/RESUMED, MESSAGE_CREATE, INTERACTION_CREATE, partial payloads |
| Slash commands | https://docs.discord.com/developers/interactions/application-commands | Registering commands, guild-scoped testing, permissions and command options |
| Interactions | https://docs.discord.com/developers/interactions/receiving-and-responding | Initial response deadline, deferral, HTTP interactions vs Gateway delivery |
| Community resources | https://docs.discord.com/developers/developer-tools/community-resources | Discord's listed community-maintained libraries. Discord does **not** maintain these SDKs |

### Machine-readable definitions

- **Official OpenAPI preview:** https://github.com/discord/discord-api-spec — `specs/openapi.json` for stable public REST operations, `specs/openapi_preview.json` for preview features. An inspection on 2026-11-01 found **157 paths, 250 operations with unique operationId values, and 542 named schemas** in the standard v10 specification. These are a point-in-time count, not a coverage guarantee. The project itself warns that the spec is a preview and may change.
- **Discord API documentation repository:** https://github.com/discord/discord-api-docs — track authoritative documentation changes and corrections.
- **discord-api-types:** https://github.com/discordjs/discord-api-types — maintained versioned definitions for REST **and** Gateway types, request and result payloads, flags, constants, and Snowflake-related fields. Cross-check types where OpenAPI is insufficient.
- **OpenAPI Generator's Perl target:** https://openapi-generator.tech/docs/generators/perl/ — investigate as a point of comparison, *not* an adopted runtime. Generic generated clients do not automatically integrate with Linux::Event, and Discord's schema unions require care.

**Generation strategy (later):** pin the input revision; generate only the mechanical parts (route metadata, request paths, parameters, selected field accessors); handwrite the event-loop-aware transport, request scheduling, and user conveniences. Review generated changes against the docs before release. Do not build a generator for the first live REST test.

## Discord-listed implementations in other languages

These are architecture and correctness references, **not** direct dependencies.

| Library | Source | Most useful areas to study |
|---|---|---|
| **discord.js** | https://github.com/discordjs/discord.js | `packages/rest/src/lib/REST.ts` and `handlers/SequentialHandler.ts`: rate-limit bucket normalization, major parameters, global limits, queues, 429/sublimits. `packages/ws/src/ws/WebSocketShard.ts`: HELLO/IDENTIFY ordering, heartbeat state and resume behavior |
| **discord.py** | https://github.com/Rapptz/discord.py | `discord/http.py`: route keys, rate-limit buckets and asynchronous waiting; `discord/message.py`: readable object methods such as `reply()` and clearly documented network effects; `discord/gateway.py`: connection state |
| **DiscordGo** | https://github.com/bwmarrin/discordgo | `wsapi.go`: HELLO before IDENTIFY/RESUME, session recovery and resume URL; `ratelimit.go`: bucket bookkeeping; `events.go` and `interactions.go`: typed event data and interactions |
| **Hikari** | https://github.com/hikari-py/hikari | `GatewayBot` vs `RESTBot` as contrasting entry points; `hikari/snowflakes.py`: ID utilities; explicit intents and events; selective caching |
| **discordrb** | https://github.com/shardlab/discordrb | `lib/discordrb/bot.rb`, `events/`, and `cache.rb`: beginner-friendly callbacks, bot behavior and cache design |
| **Discordia** | https://github.com/SinisterRectus/Discordia | `libs/client/Client.lua`, `Shard`, and `Cache`: compact event-driven organization; caching and intents |
| **Serenity** | https://github.com/serenity-rs/serenity | `src/gateway`, `src/http`, `src/model`: protocol modeling, separation of data objects from transport |

Special attention: **discord.js** for REST scheduling; **DiscordGo** for Gateway lifecycle; **discord.py** for readable application-facing methods. Avoid copying the scale and package structure of these much larger SDKs.

### Important architectural lesson

A comprehensive SDK may expose one convenient client, but its REST rate policy, Gateway session state, and local data objects should be separable internally. Discord's REST and Gateway are different interfaces; one should not be forced to start a Gateway session merely to send a REST message.

## Existing Perl implementations: source audit

These modules are not selected as the foundation. Audit was source-level, not live certification.

### Mojo::Discord

- Source: https://github.com/vsTerminus/Mojo-Discord
- Useful: `lib/Mojo/Discord/Gateway.pm`, `REST.pm`, `Guild.pm`, `User.pm`, and sample application. It separates Gateway and REST, exposes bot conveniences, and caches guild/user state.
- Observed: Gateway v10 is configurable, but the connection callback sends IDENTIFY/RESUME before receiving HELLO; `on_heartbeat_req` calls misspelled `send_hearbeat`; resume connection uses the earlier gateway URL rather than the READY resume URL; default intents include privileged intents; rate limiting is not a comprehensive global/429 scheduler. In REST, the rate-limited `remove_guild_member_role` retry mistakenly invokes `add_guild_member_role`.
- Tests were sparse (two test files). **MIT license**, but any adapted code needs explicit license/copyright handling and current-protocol verification.
- Best use: ideas for object boundaries and user-facing conveniences; *do not fork wholesale*.

### AnyEvent::Discord

- Source: https://github.com/nmelnick/AnyEvent-Discord
- CPAN: https://metacpan.org/pod/AnyEvent::Discord
- Useful: simple `on` / `off` event registration, payload wrapper, reconnection backoff, randomized first heartbeat.
- Observed: Gateway `v=6`, IDENTIFY without intents, IDENTIFY on socket open, blocking LWP REST calls, incomplete session-resume and missing-ACK management.
- Best use: simple callbacks, not transport implementation.

### AnyEvent::Discord::Client

- Source: https://github.com/topaz/perl-AnyEvent-Discord-Client
- CPAN: https://metacpan.org/pod/AnyEvent::Discord::Client
- Useful: approachable bot command registration, event callbacks, message sending, and simple per-bot state.
- Observed: Gateway `v=6`, no intents in IDENTIFY, heartbeat ACK explicitly ignored, no complete resume, blocking Gateway discovery, no comprehensive REST scheduling. Prefix commands predate modern interactions.
- License: **Artistic 2.0**. Use as interface inspiration, not copied implementation.

### WebService::Discord::Webhook

- CPAN: https://metacpan.org/pod/WebService::Discord::Webhook
- Useful: narrow webhook-oriented message formats.
- Not a bot Gateway or general bot client, and not a foundation for the project.

## Open questions and follow-up experiments

1. After the first successful REST-only bot, validate precisely how `Linux::Event::HTTP::Client` exposes response status, headers, body, cancellation, errors, and HTTP 429. Do not assume that HTTP 429 invokes `on_error`: it is an HTTP response.
2. Can a small generated endpoint table provide broad REST coverage without generating hundreds of classes? Prototype separately after the REST base works.
3. Confirm the smallest reliable Gateway state machine with a fake Gateway and then live Discord: HELLO, jittered first heartbeat, ACK checking, IDENTIFY, READY, RESUME, close codes.
4. Consider generic extraction only if another *real* Linux::Event consumer needs the code. Discord bucket policy remains specific to LE::Discord.

**Scope note:** These findings reflect sources reviewed on 2026-11-01. Recheck live upstream APIs, licensing, and release status before incorporating or copying any implementation.
