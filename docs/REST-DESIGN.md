# LE::Discord REST design

Status: first implementation on feature/rest-mvp-foundation. Live verification remains outstanding.

## Public API

Use Discord's documented HTTP method, route, and placeholder names:

    $discord->rest->post(
        '/channels/{channel.id}/messages',
        'channel.id' => $channel_id,
        json => { content => 'Hello!' },
        on_response => sub ($message) { say $message->{id} },
        on_error => sub ($error) { warn "$error\n" },
    );

The path is relative to https://discord.com/api/v10; never supply a full URL or query string. Each placeholder receives an exactly matching named argument. The engine URL-encodes values as individual path segments. Use query => {...} and json => {...} for Discord's documented query and JSON parameters. The generic interface includes get, post, put, patch and delete. No endpoint-specific methods, route registry or bound-route objects are required.

Successful callbacks receive decoded JSON (hash or array) or undef for an empty response. Errors receive an LE::Discord::Error with a kind and optional HTTP status. Calls return handles with cancel, state and is_terminal. A default on_error can be supplied to the client.

## HTTP transport lifecycle

One LE::Discord instance uses a single Linux::Event::HTTP::Client and the caller's loop. REST maps the HTTP client's completed on_response($tx,$res), on_error(...), and on_finish into one terminal Discord callback. HTTP 4xx and 5xx are normal HTTP responses, not transport errors. An ambiguous network failure is never automatically retried: a message might already have reached Discord.

The request owns its callback state while queued or active. When the HTTP client's on_finish fires, the REST engine releases its active slot, calls the appropriate user callback, and pumps the queue. Queued cancellation immediately removes the request and reports cancellation, even while another request is active; active cancellation delegates to the underlying HTTP operation.

## Scheduler and rate limiting

The first scheduler deliberately permits only one active request per client and keeps a FIFO queue. It recognizes route keys from the original method and template, and the top-level major resource from channel.id, guild.id or webhook.id (+ webhook.token where present). No route matching or OpenAPI generator is needed.

A provisional key is (HTTP method, route template, major resource). When Discord returns X-RateLimit-Bucket, the engine maps that route to the learned bucket ID plus its major resource. It uses X-RateLimit-Remaining and X-RateLimit-Reset-After to postpone work in exhausted buckets. Global retry deadlines are kept separately. Requests are capped conservatively at 45 dispatches per second per client.

An explicit 429 can be retried at most twice, after Retry-After or JSON retry_after. Even after the retry budget is exhausted, an otherwise valid retry deadline continues to block other queued requests. Global 429s suspend all requests; per-route and shared-resource 429s suspend the effective bucket. A retry delay above one hour is reported as an error rather than silently tying up a client indefinitely. On 401 the client stops dispatching further requests. Other HTTP errors are delivered without automatic retries.

This is a correctness-first scheduler, **not** the final bucket-parallel implementation. FIFO may cause head-of-line blocking. A later milestone will add independently scheduled buckets, capacity reservations, concurrent dispatch, and fairness tests. Do not promise those features yet.

## Limits and tests

MVP supports JSON bodies only. Multipart attachments, streaming, OAuth2, webhook-specific unauthenticated requests, and Gateway support are deferred. Sensitive tokens must not be printed in errors or logs.

Offline tests should cover route values and encoding, query construction, JSON, HTTP status errors, timeout/transport failures, queued and active cancellation, FIFO scheduling, 401 fail-closed, 429 retry and global suspension. The manual live example uses GET /users/@me and an explicitly requested POST /channels/{channel.id}/messages.

References:
- https://docs.discord.com/developers/topics/rate-limits
- https://docs.discord.com/developers/resources/message
- https://github.com/haxmeister/perl-Linux-Event-HTTP/blob/main/lib/Linux/Event/HTTP/Client.pm
