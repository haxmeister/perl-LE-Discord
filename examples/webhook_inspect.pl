#!/usr/bin/env perl
use v5.36;
use Linux::Event::Loop;
use LE::Discord::Webhook;

my $url = $ENV{DISCORD_WEBHOOK_URL} // die "Set DISCORD_WEBHOOK_URL\n";
my $loop = Linux::Event::Loop->new;
my $webhook = LE::Discord::Webhook->new(loop => $loop, url => $url);

# Read-only. Only display non-secret fields; webhook details may contain
# a token and must never be dumped wholesale.
$webhook->get('',
    on_response => sub ($details) {
        say "Webhook: ", $details->{id};
        say "Name:    ", $details->{name} // '(unnamed)';
        say "Channel: ", $details->{channel_id} // '(unknown)';
        $loop->stop;
    },
    on_error => sub ($error) {
        warn "$error\n";
        $loop->stop;
    },
);
$loop->run;
$webhook->shutdown;
