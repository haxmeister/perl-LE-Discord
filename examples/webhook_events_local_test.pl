#!/usr/bin/env perl
use v5.36;
use Linux::Event::Loop;
use Linux::Event::HTTP::Server;
use Linux::Event::HTTP::Client;
use Linux::Event::Kernel::Timer;
use LE::Discord::Webhook::Events;
use Crypt::PK::Ed25519;

# Local HTTP integration check: uses an ephemeral Ed25519 key and localhost.
# It does not need any Discord credentials or an Internet connection.

my $signer = Crypt::PK::Ed25519->new->generate_key;
my $public_key = unpack('H*', $signer->export_key_raw('public'));
my $loop = Linux::Event::Loop->new;
my @observed;
my @errors;
my @statuses;
my $event_count = 0;
my $timed_out = 0;

my $receiver = LE::Discord::Webhook::Events->new(
    loop => $loop,
    public_key => $public_key,
    application_id => '123456789012345678',
    on_event => sub ($event, $envelope) {
        push @observed, $event->{type};
        ++$event_count;
    },
    on_error => sub ($message) { push @errors, $message },
);

my $server = Linux::Event::HTTP::Server->new(
    loop => $loop,
    host => '127.0.0.1',
    port => 0,
    on_request => sub ($tx, $request) {
        $receiver->handle($tx, $request);
    },
);
my $port = $server->port;
die "Could not bind a local HTTP port\n" unless $port;

my $client = Linux::Event::HTTP::Client->new(loop => $loop);
my $url = "http://127.0.0.1:$port/discord/events";
my $timestamp = '1793660000';
my @cases = (
    {
        name => 'Signed PING',
        body => '{"version":1,"application_id":"123456789012345678","type":0}',
        expected => 204,
    },
    {
        name => 'Signed event',
        body => '{"version":1,"application_id":"123456789012345678","type":1,"event":{"type":"APPLICATION_AUTHORIZED","data":{}}}',
        expected => 204,
    },
    {
        name => 'Invalid signature',
        body => '{"version":1,"application_id":"123456789012345678","type":0}',
        invalid_signature => 1,
        expected => 401,
    },
);
my $index = 0;
my $send_next;
$send_next = sub {
    my $case = $cases[$index];
    my $signature = unpack('H*',
        $signer->sign_message($timestamp . $case->{body}));
    $signature = '00' x 64 if $case->{invalid_signature};
    $client->post(
        $url,
        timeout => 5,
        headers => [
            ['Content-Type', 'application/json'],
            ['X-Signature-Timestamp', $timestamp],
            ['X-Signature-Ed25519', $signature],
        ],
        body => $case->{body},
        on_response => sub ($tx, $response) {
            push @statuses, $response->status;
        },
        on_error => sub ($object, $error, @details) {
            push @errors, "$case->{name}: HTTP transport error";
        },
        on_finish => sub {
            ++$index;
            if ($index == @cases) {
                $loop->stop;
            } else {
                $loop->defer($send_next);
            }
        },
    );
};

my $watchdog = Linux::Event::Kernel::Timer->new(
    loop => $loop,
    after => 15,
    on_timer => sub ($timer) {
        $timed_out = 1;
        $loop->stop;
    },
);
$send_next->();
$loop->run;
$watchdog->cancel;

for my $i (0 .. $#cases) {
    my $received = defined($statuses[$i]) ? $statuses[$i] : 'missing';
    say "$cases[$i]{name}: HTTP $received (expected $cases[$i]{expected})";
    push @errors, "$cases[$i]{name}: incorrect status"
        if "$received" ne "$cases[$i]{expected}";
}
say "Application events delivered: $event_count (expected 1)";
push @errors, 'event callback count mismatch' unless $event_count == 1;
push @errors, 'event type mismatch'
    unless @observed == 1 && $observed[0] eq 'APPLICATION_AUTHORIZED';
push @errors, 'local test timed out' if $timed_out;

$server->close;
if (@errors) {
    warn "FAIL: $_\n" for @errors;
    exit 1;
}
say "PASS: Signed webhook event receiver works through real Linux::Event HTTP";
