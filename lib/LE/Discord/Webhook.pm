package LE::Discord::Webhook;
use v5.36;
use Carp qw(croak);
use LE::Discord::REST;

our $VERSION = '0.001';

sub new ($class, %args) {
    my $url = delete $args{url} // croak 'webhook URL is required';
    my $loop = delete $args{loop} // croak 'loop is required';

    # Restrict the destination to Discord, not an arbitrary host.
    # Never include the URL or token in an error message.
    my ($id, $token) = $url =~ m{
        \A https://discord\.com/api/(?:v10/)?webhooks/
        ([0-9]+) / ([A-Za-z0-9._-]+) /? \z
    }x;
    croak 'invalid Discord webhook URL'
        unless defined($id) && defined($token) && length($token);

    croak 'do not pass bot credentials to a webhook client'
        if exists $args{token} || exists $args{auth_mode};

    my $rest = LE::Discord::REST->new(
        loop => $loop,
        token => $token,
        auth_mode => 'webhook',
        %args,
    );
    return bless {
        rest => $rest,
        id => $id,
        token => $token,
    }, $class;
}

sub execute ($self, %args) {
    croak 'execute requires json => {...}' unless exists $args{json};
    my $query = delete($args{query}) // {};
    croak 'query must be a hash reference' unless ref($query) eq 'HASH';
    # wait=true requests confirmation and returns a Message object. Discord
    # otherwise defaults to 204 with no confirmation that a message was saved.
    $query = { wait => 'true', %$query };
    return $self->{rest}->post(
        '/webhooks/{webhook.id}/{webhook.token}',
        'webhook.id' => $self->{id},
        'webhook.token' => $self->{token},
        query => $query,
        %args,
    );
}

sub shutdown ($self) { $self->{rest}->shutdown }

1;

__END__

=head1 NAME

LE::Discord::Webhook - Send messages to a Discord webhook without a bot

=head1 SYNOPSIS

    use Linux::Event::Loop;
    use LE::Discord::Webhook;

    my $loop = Linux::Event::Loop->new;
    my $webhook = LE::Discord::Webhook->new(
        loop => $loop,
        url  => $ENV{DISCORD_WEBHOOK_URL},
    );
    $webhook->execute(
        json => {
            content => 'News from my server',
            allowed_mentions => { parse => [] },
        },
        on_response => sub ($message) {
            say "Message ", $message->{id};
            $loop->stop;
        },
        on_error => sub ($error) {
            warn "$error\n";
            $loop->stop;
        },
    );
    $loop->run;
    $webhook->shutdown;

=head1 DESCRIPTION

A webhook URL contains its own credential. This client sends through
Discord's C<POST /webhooks/{webhook.id}/{webhook.token}> route without
sending an Authorization header or needing a bot user in the server.

Use C<execute(json =E<gt> {...}, on_response =E<gt> ..., on_error =E<gt> ...)>.
The JSON hash is passed to Discord. You can use Discord's documented
C<content>, C<embeds>, C<username>, C<avatar_url>, and other JSON
fields without a separate LE::Discord method for every field.

By default C<execute> sends C<wait=true>, so a successful response is
a Message hash. To use Discord's fire-and-forget mode, pass
C<query =E<gt> { wait =E<gt> 'false' }>; success then provides
C<undef> because Discord normally replies with HTTP 204.

Webhook requests use the same asynchronous rate-limit queue, bucket
tracking, and bounded HTTP 429 retries as bot REST requests. Reuse one
Webhook object for a given URL; multiple processes or client instances
do not share rate-limit state. No automatic retry occurs after an
ambiguous transport failure.

C<execute> returns a cancellable request handle. Call C<shutdown>
to stop queued and active work and release owned HTTP resources.

Only official C<https://discord.com/api/webhooks/...> and
C<https://discord.com/api/v10/webhooks/...> URLs are accepted.
Keep webhook URLs private; they contain a secret token.

This first version sends webhook messages. Receiving Discord webhook
events, webhook management, interaction responses, and multipart
uploads are separate future features.

=cut
