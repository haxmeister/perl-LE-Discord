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

## Direct HTTPS test with Discord

A reverse proxy is **not required**. The library's HTTP server supports
TLS directly. A sample direct listener is
`examples/webhook_events_https.pl`. It requires all of the following:

- A public DNS hostname you control, resolving to your public IP.
- A trusted TLS certificate valid for that hostname, plus its matching
  private key. For Let's Encrypt, use the `fullchain.pem` certificate
  and `privkey.pem` private key. A self-signed certificate will not
  pass public HTTPS validation.
- Your app's **Public Key** from the Discord Developer Portal
  (`DISCORD_PUBLIC_KEY`), **not** its bot token or the URL of a
  message-sending webhook.
- In your router/firewall, forward public **TCP 443** to the listening
  host's port **8443** (or bind directly to port 443, if permitted).
  Forward only the port you intend to test. NAT/CGNAT and upstream
  firewalls can prevent external reachability.
- An explicit bind address. Use `0.0.0.0` only when ready to receive
  connections from outside your machine. This server accepts HTTPS;
  do not expose the plain-HTTP example.

Example environment setup (replace paths with your own certificate
and key locations; never put secrets in the repository):

```sh
export DISCORD_PUBLIC_KEY='YOUR_APP_PUBLIC_KEY'
export DISCORD_APPLICATION_ID='YOUR_APP_ID'
export DISCORD_TLS_CERT_FILE='/path/to/fullchain.pem'
export DISCORD_TLS_KEY_FILE='/path/to/privkey.pem'
export DISCORD_EVENT_BIND_HOST='0.0.0.0'
export DISCORD_EVENT_BIND_PORT=8443
perl -Ilib examples/webhook_events_https.pl
```

On the public network, use the following URL in the Discord Developer
Portal's **Webhooks → Endpoint** field:

```text
https://YOUR-HOSTNAME/discord/events
```

If forwarding **443 → 8443**, the URL does not need an explicit port.
If you expose 8443 directly instead, its URL would include `:8443`,
but use public 443 for the simplest Discord compatibility.

Before configuring Discord, use a different network to verify that
`curl -v https://YOUR-HOSTNAME/discord/events` negotiates trusted
TLS and gets **HTTP 405** for an ordinary unsigned GET. That status
is expected because only POST is accepted at this path.
An unsigned POST must receive **401**. Don't disable certificate
verification (no `curl -k`).

In the Discord Developer Portal, choose your application, then
**Webhooks**, paste the public URL as the endpoint and save.
Discord immediately sends a signed PING. The example prints
`Verified Discord webhook PING; acknowledged HTTP 204`
when it validates and acknowledges that PING. Event subscriptions can
then be enabled for the event types available to your application.
If no events are triggered, no further output is expected.

This is a short testing procedure, not production deployment guidance:
keep the TLS key private, expose no unrelated routes, close the router
forwarding/firewall rule after testing, and stop the listener. Real
Discord event delivery is not yet verified by the repository tests.

## Local HTTP integration test

After the offline tests pass, run:

```sh
perl -Ilib examples/webhook_events_local_test.pl
```

This creates a temporary Ed25519 key in memory, binds a real
`Linux::Event::HTTP::Server` to an automatically selected localhost
port, and sends three HTTP requests using
`Linux::Event::HTTP::Client`: a signed PING, a signed event, and an
invalid signature. It checks the response statuses and that only the
valid event reached the application callback. No public endpoint,
Discord token, or access to the Internet is required.

**Local verification completed November 2, 2026:** the developer
ran `perl -Ilib examples/webhook_events_local_test.pl` on Linux and
confirmed HTTP 204 for a signed PING, HTTP 204 for a signed event,
HTTP 401 for an invalid signature, and exactly one application event
callback. The example reported PASS. This validates the actual
Linux::Event HTTP transport with the Ed25519 receiver, without
exposing an endpoint to the Internet.

The remaining integration milestone is a live Discord verification
through a publicly accessible HTTPS endpoint. That has not yet been
performed.

CryptX (`Crypt::PK::Ed25519`) is a required LE::Discord dependency.
It is declared in `Makefile.PL` and installed with the distribution.
The GitHub Actions workflow also installs CryptX to run its tests.

## Future work

- Receiving interaction webhooks (separate PING and callback semantics).
- Application-specific event routing and durable replay/deduplication.
- Multipart uploads and optional event message batching (saved elsewhere).

Official source:
https://docs.discord.com/developers/events/webhook-events
