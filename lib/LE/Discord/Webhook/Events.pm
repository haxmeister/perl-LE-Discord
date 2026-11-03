package LE::Discord::Webhook::Events;
use v5.36;
use Carp qw(croak);
use JSON::PP ();
use Crypt::PK::Ed25519;

our $VERSION = '0.001';
my $JSON = JSON::PP->new->utf8;

sub new ($class, %args) {
    my $loop = delete $args{loop} // croak 'loop is required';
    my $hex = delete $args{public_key} // croak 'Discord application public_key is required';
    croak 'public_key must be 64 hexadecimal characters'
        unless !ref($hex) && $hex =~ /\A[0-9a-fA-F]{64}\z/;
    my $path = delete($args{path}) // '/discord/events';
    croak 'path must be an absolute path without a query or fragment'
        unless defined($path) && !ref($path)
            && $path =~ m{\A/} && $path !~ /[?#]/;
    my $on_event = delete $args{on_event}
        // croak 'on_event callback is required';
    croak 'on_event must be a coderef' unless ref($on_event) eq 'CODE';
    my $on_error = delete $args{on_error};
    croak 'on_error must be a coderef'
        if defined($on_error) && ref($on_error) ne 'CODE';
    my $application_id = delete $args{application_id};
    croak 'application_id must be a decimal Snowflake string'
        if defined($application_id)
            && (ref($application_id) || $application_id !~ /\A[0-9]+\z/);
    my $max_body_bytes = delete($args{max_body_bytes}) // 1_048_576;
    croak 'max_body_bytes must be a positive integer'
        unless !ref($max_body_bytes) && $max_body_bytes =~ /\A[1-9][0-9]*\z/;
    croak 'unknown event receiver options: ' . join(', ', sort keys %args)
        if %args;

    my $key = Crypt::PK::Ed25519->new;
    $key->import_key_raw(pack('H*', $hex), 'public');

    return bless {
        loop => $loop, key => $key, path => $path,
        on_event => $on_event, on_error => $on_error,
        application_id => $application_id, max_body_bytes => $max_body_bytes,
    }, $class;
}

sub handle ($self, $tx, $req) {
    # on_request in Linux::Event::HTTP::Server runs after the raw
    # request body is complete. Nothing has been JSON-decoded yet.
    return _respond($tx, 404) unless $req->target eq $self->{path};
    return _respond($tx, 405) unless $req->method eq 'POST';

    my $signature = $req->header('x-signature-ed25519');
    my $timestamp = $req->header('x-signature-timestamp');
    return _respond($tx, 401)
        unless defined($signature) && !ref($signature)
            && $signature =~ /\A[0-9A-Fa-f]{128}\z/
            && defined($timestamp) && !ref($timestamp)
            && $timestamp =~ /\A[0-9]{1,20}\z/;

    my $body = $req->body;
    return _respond($tx, 400) unless defined($body) && !ref($body)
        && !utf8::is_utf8($body)
        && length($body) <= $self->{max_body_bytes};

    # Signature covers the exact timestamp header and raw body bytes.
    # No normalization or JSON re-encoding may happen before this.
    my $valid = eval {
        $self->{key}->verify_message(
            pack('H*', $signature), $timestamp . $body,
        );
    };
    return _respond($tx, 401) unless $valid;

    my $payload = eval { $JSON->decode($body) };
    return _respond($tx, 400)
        unless ref($payload) eq 'HASH'
            && defined($payload->{type}) && !ref($payload->{type})
            && (("$payload->{type}" eq '0') || ("$payload->{type}" eq '1'))
            && (!defined($self->{application_id})
                || (defined($payload->{application_id})
                    && !ref($payload->{application_id})
                    && "$payload->{application_id}" eq $self->{application_id}));

    # Discord's webhook-event PING (type 0) is not the same as
    # interaction PING (type 1). Both webhook PING and events return 204.
    return _respond($tx, 204) if "$payload->{type}" eq '0';

    return _respond($tx, 400)
        unless ref($payload->{event}) eq 'HASH'
            && defined($payload->{event}{type})
            && !ref($payload->{event}{type});

    # Queue application handling on the next loop turn. The HTTP
    # acknowledgement must not wait for application event processing.
    _respond($tx, 204);
    $self->{loop}->defer(sub {
        my $ok = eval {
            $self->{on_event}->($payload->{event}, $payload);
            1;
        };
        return if $ok;
        if (my $cb = $self->{on_error}) {
            eval { $cb->('Discord webhook event callback failed'); 1 }
                or warn "LE::Discord webhook error callback failed\n";
        } else {
            warn "LE::Discord webhook event callback failed\n";
        }
    });
    return;
}

sub _respond ($tx, $status) {
    $tx->respond(status => $status, body => '');
    return;
}

1;

__END__

=head1 NAME

LE::Discord::Webhook::Events - Receive signed Discord webhook events

=head1 SYNOPSIS

    use Linux::Event::Loop;
    use Linux::Event::HTTP::Server;
    use LE::Discord::Webhook::Events;

    my $loop = Linux::Event::Loop->new;
    my $receiver = LE::Discord::Webhook::Events->new(
        loop => $loop,
        public_key => $ENV{DISCORD_PUBLIC_KEY},
        path => '/discord/events',
        on_event => sub ($event, $payload) {
            say "Discord event: ", $event->{type};
        },
    );
    my $server = Linux::Event::HTTP::Server->new(
        loop => $loop,
        host => '127.0.0.1',
        port => 8080,
        on_request => sub ($tx, $req) {
            $receiver->handle($tx, $req);
        },
    );
    $loop->run;

=head1 DESCRIPTION

Discord sends events to a public HTTPS endpoint configured in the
Developer Portal, under Webhooks. This receiver validates the
C<X-Signature-Ed25519> and C<X-Signature-Timestamp> headers against
the exact raw HTTP body, using the application's public key and
L<Crypt::PK::Ed25519>. It rejects invalid signatures with HTTP 401.

A signed webhook-event PING (C<type =E<gt> 0>) is acknowledged with
HTTP 204 and an empty body. A signed event (C<type =E<gt> 1>) also
receives HTTP 204. C<on_event($event, $payload)> is deferred to the
next Linux::Event loop turn so it does not hold up the acknowledgement.
The C<$event> argument is the inner event object containing C<type>,
C<timestamp>, and C<data>. The second argument is the entire outer
payload. Bad JSON and malformed payloads produce HTTP 400.

C<path> defaults to C</discord/events>. Supply a C<public_key> as
64 hexadecimal characters from your application's General Information
page. Optional C<application_id> checks that the signed payload is
for the expected app. The maximum raw body is 1 MiB by default;
use C<max_body_bytes> for a smaller limit. Configure the HTTP server's
own buffering limit separately if necessary.

This is a request handler, not a second HTTP server. Wire it to
C<Linux::Event::HTTP::Server-E<gt>new(on_request =E<gt> ...)> or a
router that supplies complete raw request bodies. For TLS, use the
server's TLS options or a trusted HTTPS reverse proxy.

Discord webhook events can arrive out of order and may be retried.
The receiving application must handle duplicate events where needed.
Do not perform slow/blocking work inside C<on_event>, and do not
conflate these webhook events with interaction callbacks, which have
different PING and response formats.

=cut
