# Receiving Discord webhook events

Discord webhook events are sent **from Discord to your application**.
This differs from sending messages **into Discord** using a webhook URL.

Only certain Discord events can be subscribed to this way, such as
application authorization changes and entitlement events. It is **not**
a replacement for Gateway events such as regular guild message events.
For those, LE::Discord will still need Gateway support.


## Protocol requirements

- Configure a publicly accessible HTTPS endpoint on the Discord Developer
  Portal's Webhooks page and select the desired event subscriptions.
- Discord signs each request with Ed25519. Verify the hexadecimal
  `X-Signature-Ed25519` header against the exact bytes
  `X-Signature-Timestamp + raw_request_body`, using the public key from
  your application's General Information page.
- Invalid signatures must receive **401**. Discord actively checks this.
- A signed webhook PING with `type: 0` receives **204 No Content**.
  Ordinary webhook events with `type: 1` also receive **204 No Content**
  within three seconds, with an empty body.
- Discord can retry deliveries for up to ten minutes if acknowledgement
  fails. Delivery is not guaranteed to be in order or real time; process
  duplicate deliveries appropriately in your application.
- **Interaction endpoints are different:** their PING is `type: 1`
  and requires a JSON PONG response. Do not direct interactions to this
  webhook-event receiver.

## Perl integration

`LE::Discord::Webhook::Events` is a request handler. It deliberately
reuses `Linux::Event::HTTP::Server`, rather than creating another
HTTP server abstraction.

```perl
use Linux::Event::Loop;
use Linux::Event::HTTP::Server;
use LE::Discord::Webhook::Events;

my $loop = Linux::Event::Loop->new;
my $receiver = LE::Discord::Webhook::Events->new(
    loop => $loop,
    public_key => $ENV{DISCORD_PUBLIC_KEY},
    path => '/discord/events',
    on_event => sub ($event, $payload) {
        say "Received $event->{type}";
    },
);

my $server = Linux::Event::HTTP::Server->new(
    loop => $loop,
    host => '127.0.0.1', port => 8080,
    on_request => sub ($tx, $req) { $receiver->handle($tx, $req) },
);
$loop->run;
```

The sample `examples/webhook_events.pl` binds to localhost only.
For live Discord validation, expose the endpoint over public HTTPS
through a trusted reverse proxy or configure TLS on the HTTP server.

The public key is not the bot token and is not the webhook URL token.
`Crypt::PK::Ed25519` (from CryptX) supplies signature verification.
No private key is needed.

The handler acknowledges a verified event before scheduling your
`on_event($event, $payload)` callback on the next event loop turn.
Callbacks should remain short and nonblocking; slow work belongs
in application-level jobs, with deduplication if needed.

Only the exact configured `path` and POST method are accepted.
Bad signatures return 401; malformed JSON returns 400.
Unsupported request method returns 405; unrelated paths return 404.
The server's buffered request-body limit is 1 MiB by default, matching
the receiver default. A smaller maximum can be set explicitly.

The initial tests use locally generated Ed25519 keys and fake
requests/transactions to verify signatures and responses. A real
Discord endpoint test still requires reachable HTTPS hosting.

## Future work

- Receiving interaction webhooks (separate PING and callback semantics).
- Application-specific event routing and durable replay/deduplication.
- Multipart uploads and optional event message batching (saved elsewhere).

Official source:
https://docs.discord.com/developers/events/webhook-events
