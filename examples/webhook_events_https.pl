#!/usr/bin/env perl
use v5.36;
use Linux::Event::Loop;
use Linux::Event::HTTP::Server;
use LE::Discord::Webhook::Events;

# Direct HTTPS listener for verifying Discord's webhook-event endpoint.
# Intentionally requires explicit TLS certificate/key and an explicit
# bind address. This example never sends unsigned HTTP responses over
# a publicly accessible cleartext listener.
my $key = $ENV{DISCORD_PUBLIC_KEY}
    // die "Set DISCORD_PUBLIC_KEY (64 hex characters from Developer Portal)\n";
my $cert_file = $ENV{DISCORD_TLS_CERT_FILE}
    // die "Set DISCORD_TLS_CERT_FILE to the trusted full certificate chain\n";
my $key_file = $ENV{DISCORD_TLS_KEY_FILE}
    // die "Set DISCORD_TLS_KEY_FILE to the private TLS key file\n";
my $host = $ENV{DISCORD_EVENT_BIND_HOST}
    // die "Set DISCORD_EVENT_BIND_HOST explicitly (such as 0.0.0.0)\n";
my $port = $ENV{DISCORD_EVENT_BIND_PORT} // 8443;
die "DISCORD_EVENT_BIND_PORT must be between 1 and 65535\n"
    unless $port =~ /\A[0-9]+\z/ && $port >= 1 && $port <= 65535;
die "Certificate not readable\n" unless -r $cert_file;
die "TLS private key not readable\n" unless -r $key_file;

my $loop = Linux::Event::Loop->new;
my %receiver_opt;
$receiver_opt{application_id} = $ENV{DISCORD_APPLICATION_ID}
    if defined $ENV{DISCORD_APPLICATION_ID}
        && length $ENV{DISCORD_APPLICATION_ID};

my $receiver = LE::Discord::Webhook::Events->new(
    loop => $loop,
    public_key => $key,
    path => '/discord/events',
    %receiver_opt,
    on_ping => sub ($payload) {
        say "Verified Discord webhook PING; acknowledged HTTP 204";
    },
    on_event => sub ($event, $payload) {
        say "Verified Discord event: ", $event->{type};
    },
    on_error => sub ($message) { warn "$message\n" },
);

my $server = Linux::Event::HTTP::Server->new(
    loop => $loop,
    host => $host,
    port => $port,
    tls => {
        cert_file => $cert_file,
        key_file => $key_file,
    },
    on_request => sub ($tx, $request) {
        $receiver->handle($tx, $request);
    },
    on_listener_error => sub ($listener, $error) {
        warn "HTTPS listener error: $error\n";
    },
);

say "HTTPS Discord event receiver listening at $host:", $server->port,
    "/discord/events";
say "Configure a publicly reachable HTTPS hostname and port forwarding.";
say "Public URL: https://YOUR-HOSTNAME/discord/events";
say "Press Ctrl+C to stop.";
$loop->run;
