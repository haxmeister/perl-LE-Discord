#!/usr/bin/env perl
use v5.36;
use Linux::Event::Loop;
use LE::Discord;

my $mode = shift(@ARGV) // 'identify';
die "Usage: $0 [identify|send]\n" unless $mode eq 'identify' || $mode eq 'send';
my $token = $ENV{DISCORD_BOT_TOKEN} // die "Set DISCORD_BOT_TOKEN\n";
my $channel = $ENV{DISCORD_CHANNEL_ID};
die "Set DISCORD_CHANNEL_ID for send\n" if $mode eq 'send' && !$channel;

my $loop = Linux::Event::Loop->new;
my $discord = LE::Discord->new(
    loop => $loop,
    token => $token,
    on_error => sub ($error) {
        warn "$error\n";
        $loop->stop;
    },
);

$discord->rest->get('/users/@me',
    on_response => sub ($user) {
        say "Authenticated as $user->{username} ($user->{id})";
        if ($mode eq 'identify') {
            $loop->stop;
            return;
        }
        # A message is sent only when explicitly requested.
        $discord->rest->post(
            '/channels/{channel.id}/messages',
            'channel.id' => $channel,
            json => { content => 'Hello from LE::Discord!' },
            on_response => sub ($message) {
                say "Sent message $message->{id} to channel $message->{channel_id}";
                $loop->stop;
            },
        );
    },
);
$loop->run;
