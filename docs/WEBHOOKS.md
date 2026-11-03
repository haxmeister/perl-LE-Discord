# Webhook support

Discord calls a sender's URL an *incoming webhook* because messages travel into Discord. Discord's *outgoing webhook events* are HTTP events sent from Discord to an application. LE::Discord will support these as separate capabilities; this stage only implements sending messages.

## Sending to a Discord channel without installing a bot

A server owner creates a webhook for a particular channel and shares its secret URL with the external notification program. No bot user, bot token, or server-wide bot permissions are needed.

    use Linux::Event::Loop;
    use LE::Discord::Webhook;

    my $loop = Linux::Event::Loop->new;
    my $webhook = LE::Discord::Webhook->new(
        loop => $loop,
        url => $ENV{DISCORD_WEBHOOK_URL},
    );
    $webhook->execute(
        json => {
            content => "News from my server",
            allowed_mentions => { parse => [] },
        },
        on_response => sub ($message) {
            say "Sent message ", $message->{id};
            $loop->stop;
        },
        on_error => sub ($error) {
            warn "$error\n";
            $loop->stop;
        },
    );
    $loop->run;
    $webhook->shutdown;

The example in examples/webhook_hello.pl works the same way. Set DISCORD_WEBHOOK_URL locally and do not commit or share it. The URL contains a secret token.

execute accepts the documented JSON payload through json => {...}; query => {...} can specify wait, thread_id, and other documented parameters. By default wait=true requests a confirmed Message response. Use query => { wait => 'false' } for Discord's default 204 no-wait response.

## Rate limiting and reliability

The webhook sender delegates to the same LE::Discord::REST queue and timer-based scheduler as bot requests. Unlike bot requests, webhook sends have no Authorization header. The URL credential is only used in the documented webhook path.

- Response headers teach the scheduler bucket identities, remaining capacity and reset delays. An explicit 429 is retried after the indicated delay, up to two times. An ambiguous network failure is not retried because it could produce duplicate messages.
- The current scheduler sends one request at a time. The queue is bounded (256 pending requests by default; configure max_queue when constructing the Webhook object).
- Reuse the same Webhook object for repeated sends. Creating separate objects or processes for the same webhook gives each an independent rate limiter. Applications sharing an IP address or webhook can still encounter 429 responses.
- For messages originating from untrusted strings, consider allowed_mentions => { parse => [] } to avoid unintentionally mentioning many users.
- Discord warns against repeatedly retrying webhook URLs that return HTTP 404. The sender now disables further dispatch after a webhook 404 (or HTTP 401) to prevent an invalid-request storm. Use a fresh Webhook object after correcting or replacing the URL.

## Later webhook work

- Bot-authenticated webhook management (create, inspect, edit, delete).
- Receiving Discord webhook events using Linux::Event::HTTP::Server and signature verification.
- Interaction webhooks for slash commands and other interactions.
- Multipart file uploads and attachment support.

Reference: https://docs.discord.com/developers/resources/webhook
Reference: https://docs.discord.com/developers/topics/rate-limits
Reference: https://docs.discord.com/developers/events/webhook-events
