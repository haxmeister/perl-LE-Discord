package LE::Discord;
use v5.36;
use Carp qw(croak);
use LE::Discord::REST;

our $VERSION = '0.001';

sub new ($class, %option) {
    my $loop = delete $option{loop} // croak 'loop is required';
    my $token = delete $option{token} // croak 'bot token is required';
    croak 'bot token must not be empty' unless length $token;
    my $rest = LE::Discord::REST->new(
        loop  => $loop,
        token => $token,
        %option,
    );
    return bless { loop => $loop, rest => $rest }, $class;
}

sub loop ($self) { $self->{loop} }
sub rest ($self) { $self->{rest} }

1;

__END__

=head1 NAME

LE::Discord - Asynchronous Discord client for Linux::Event

=head1 SYNOPSIS

    use Linux::Event::Loop;
    use LE::Discord;

    my $loop = Linux::Event::Loop->new;
    my $discord = LE::Discord->new(
        loop => $loop,
        token => $ENV{DISCORD_BOT_TOKEN},
    );

    $discord->rest->get('/users/@me',
        on_response => sub ($user) {
            say $user->{username};
            $loop->stop;
        },
        on_error => sub ($error) {
            warn "$error\n";
            $loop->stop;
        },
    );
    $loop->run;

=head1 DESCRIPTION

The first milestone provides a small route-based Discord REST client.
Use Discord's documented routes, with named placeholders supplied as
Perl arguments. See L<LE::Discord::REST> and Discord's REST documentation.
Gateway support is not implemented.

=cut
