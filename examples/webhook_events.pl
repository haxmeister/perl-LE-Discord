#!/usr/bin/env perl
use v5.36;
use Linux::Event::Loop;
use Linux::Event::HTTP::Server;
use LE::Discord::Webhook::Events;

my $public_key = $ENV{DISCORD_PUBLIC_KEY}
    // die "Set DISCORD_PUBLIC_KEY to your application's public key\n";
my $loop = Linux::Event::Loop->new;
my $receiver = LE::Discord::Webhook::Events->new(
    loop => $loop,
    public_key => $public_key,
    path => '/discord/events',
    on_event => sub ($event, $payload) {
        say "Discord event: ", $event->{type};
    },
    on_error => sub ($message) { warn "$message\n" },
);

# Bind locally and terminate TLS at a trusted HTTPS reverse proxy,
# or configure TLS directly on the Linux::Event HTTP server.
my $server = Linux::Event::HTTP::Server->new(
    loop => $loop,
    host => '127.0.0.1',
    port => 8080,
    on_request => sub ($tx, $request) {
        $receiver->handle($tx, $request);
    },
);
say "Listening on http://127.0.0.1:8080/discord/events";
$loop->run;
