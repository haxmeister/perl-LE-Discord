# Webhook management

The bot REST interface already supports Discord's webhook management
routes. We keep **Discord's documented paths**, instead of implementing
a separate LE::Discord method for every endpoint.

Creating webhooks requires a bot with the `MANAGE_WEBHOOKS` permission.
Server owners who only want a program to *post news* can create the
webhook in Discord's user interface and share only its webhook URL.
The sender then uses `LE::Discord::Webhook` without installing a bot.

## Bot-authenticated webhook administration

Use `$discord->rest` with the same async callback interface as our
REST MVP:

| Task | Method | Discord route |
| --- | --- | --- |
| Create webhook | POST | `/channels/{channel.id}/webhooks` |
| List channel webhooks | GET | `/channels/{channel.id}/webhooks` |
| List guild webhooks | GET | `/guilds/{guild.id}/webhooks` |
| Inspect webhook | GET | `/webhooks/{webhook.id}` |
| Edit webhook | PATCH | `/webhooks/{webhook.id}` |
| Delete webhook | DELETE | `/webhooks/{webhook.id}` |

For example, listing existing webhooks is read-only:

```perl
$discord->rest->get(
    '/channels/{channel.id}/webhooks',
    'channel.id' => $channel_id,
    on_response => sub ($webhooks) {
        for my $webhook (@$webhooks) {
            say "$webhook->{id}: $webhook->{name}";
        }
    },
    on_error => sub ($error) { warn "$error\n" },
);
```

Creation uses the documented JSON body:

```perl
$discord->rest->post(
    '/channels/{channel.id}/webhooks',
    'channel.id' => $channel_id,
    json => { name => 'Server announcements' },
    on_response => sub ($webhook) {
        say "Created webhook $webhook->{id}";
        # The returned token is sensitive. Do not log the whole object.
    },
    on_error => sub ($error) { warn "$error\n" },
);
```

Editing uses `$discord->rest->patch('/webhooks/{webhook.id}', ...)`.
Deleting uses `$discord->rest->delete('/webhooks/{webhook.id}', ...)`.
A successful DELETE responds with no JSON body (`undef` in
`on_response`). Neither operation should be performed implicitly.

Bot administration requests use `Authorization: Bot ...`. Discord
requires `MANAGE_WEBHOOKS` for creating and listing webhooks and for
most bot-authenticated modifications and deletion. A bot may also
retrieve an application-owned webhook under the documented ownership
exception. Ordinary webhook senders do not need these permissions.

## Operations authorized by an existing webhook URL

A webhook URL includes its ID and secret token. In addition to
`$webhook->execute(...)`, the same `LE::Discord::Webhook` object can
retrieve or modify itself and manage **its own messages**, without a
bot token:

```perl
$webhook->get('', on_response => sub ($details) {
    say "Webhook $details->{id}: $details->{name}";
});

$webhook->patch('',
    json => { name => 'Server notices' },
    on_response => sub ($updated) { say $updated->{name} },
);

$webhook->get('/messages/{message.id}',
    'message.id' => $message_id,
    on_response => sub ($message) { say $message->{content} },
);

$webhook->patch('/messages/{message.id}',
    'message.id' => $message_id,
    json => {
        content => 'Updated announcement',
        allowed_mentions => { parse => [] },
    },
    on_response => sub ($message) { say $message->{id} },
);

$webhook->delete('/messages/{message.id}',
    'message.id' => $message_id,
    on_response => sub ($empty) { say 'Deleted message' },
);
```

The suffix must be empty (the webhook itself) or the literal route
`/messages/{message.id}` with a named `message.id` parameter.
The suffix is relative to the stored webhook URL, so applications
never need to repeat webhook credentials. To permanently delete the
webhook, call `$webhook->delete('')` intentionally.

Webhook tokens **cannot** create additional webhooks, list webhooks
in other channels, or manage unrelated Discord objects. They cannot
change the webhook's channel assignment. These operations require
bot/user authorization with the necessary permissions.

Use `query => { thread_id => $thread_id }` for operations on messages
in a thread, as documented by Discord. When editing message content,
include `allowed_mentions` if you need to prevent unexpected pings.
No multipart files or `X-Audit-Log-Reason` customization is implemented
in the current REST client.

Never print or commit a webhook URL or token. The fake-transport
tests exercise these paths without needing real credentials. The
safe `examples/webhook_inspect.pl` example only retrieves metadata.

## Verification

On November 2, 2026, the developer ran
`perl -Ilib examples/webhook_inspect.pl` against a real Discord
webhook and confirmed that it returned the expected webhook metadata.
This uses token-authorized GET without an installed bot and does
not change the webhook or send a message.

The offline bot REST and webhook suites also pass (163 assertions).
Creating, modifying, and deleting webhooks and editing/deleting webhook
messages have been verified with fake HTTP responses, not yet against
live Discord. Those actions can change or delete real data, so do not
run them as an automatic smoke test.

## Roadmap

Receiving Discord's outgoing webhook events, interaction callbacks,
and multipart uploads are distinct follow-up efforts. The Vendetta
Online sighting-batching idea is saved in [webhook notes](WEBHOOKS.md)
for later, not part of management work.

Reference: https://docs.discord.com/developers/resources/webhook
