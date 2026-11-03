#!/usr/bin/env perl
use v5.36;
use Linux::Event::Loop;
use LE::Discord::Webhook;

my $url = $ENV{DISCORD_WEBHOOK_URL} // die "Set DISCORD_WEBHOOK_URL\n";
my $loop = Linux::Event::Loop->new;
my $webhook = LE::Discord::Webhook->new(loop => $loop, url => $url);

$webhook->execute(
    json => {
        content => 'Hello from LE::Discord webhook!',
        allowed_mentions => { parse => [] },
    },
    on_response => sub ($message) {
        say "Webhook message sent: $message->{id}";
        $loop->stop;
    },
    on_error => sub ($error) {
        warn "$error\n";
        $loop->stop;
    },
);
$loop->run;
$webhook->shutdown;
