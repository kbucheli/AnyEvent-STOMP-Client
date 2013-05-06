package AnyEvent::STOMP::Client;

use strict;
use warnings;

use AnyEvent;
use AnyEvent::Handle;
use List::Util 'max';
use parent 'Object::Event';

our $VERSION = 0.02;

my $TIMEOUT_MARGIN = 1000;
my $EOL = chr(10); # or chr(13).chr(10)
my $NULL = chr(0);
my $HEARTBEAT = '0,0';


sub connect {
    my $class = shift;
    my $self = $class->SUPER::new;

    $self->{connected} = 0;
    $self->{host} = shift;
    $self->{port} = shift || 61613;
    $self->{heartbeat}{config}{client} = shift || $HEARTBEAT;

    $self->{handle} = AnyEvent::Handle->new(
        connect => [$self->{host}, $self->{port}],
        keep_alive => 1,
        on_connect => sub {
            $self->send_frame(
                'CONNECT',
                {
                    'accept-version' => '1.2',
                    'host' => $self->{host},
                    'heart-beat' => $self->{heartbeat}{config}{client},
                    # add login, passcode headers
                }
            );
        },
        on_connect_error => sub {
            my ($handle, $message) = @_;
            $handle->destroy;
            $self->{connected} = 0;
            $self->event('DISCONNECTED');
        },
        on_error => sub {
            my ($handle, $message) = @_;
            $handle->destroy;
            $self->{connected} = 0;
            $self->event('DISCONNECTED');
        },
        on_read => sub {
            $self->receive_frame;
        },
    );

    return bless $self, $class;
}

sub disconnect {
    shift->send_frame('DISCONNECT', {receipt => int(rand(1000)),});
}

sub DESTROY {
    shift->disconnect;
}

sub is_connected {
    return shift->{connected};
}

sub set_heartbeat_intervals {
    my $self = shift;
    $self->{heartbeat}{config}{server} = shift;

    my ($cx, $cy) = split ',', $self->{heartbeat}{config}{client};
    my ($sx, $sy) = split ',', $self->{heartbeat}{config}{server};

    if ($cx == 0 or $sy == 0) {
        $self->{heartbeat}{interval}{client} = 0;
    }
    else {
        $self->{heartbeat}{interval}{client} = max($cx, $sy);
    }

    if ($sx == 0 or $cy == 0) {
        $self->{heartbeat}{interval}{server} = 0;
    }
    else {
        $self->{heartbeat}{interval}{server} = max($sx, $cy);
    }
}

sub reset_client_heartbeat_timer {
    my $self = shift;
    my $interval = $self->{heartbeat}{interval}{client};

    unless (defined $interval and $interval > 0) {
        return;
    }

    $self->{heartbeat}{timer}{client} = AnyEvent->timer(
        after => ($interval/1000),
        cb => sub {
            $self->send_heartbeat;
        }
    );
}

sub reset_server_heartbeat_timer {
    my $self = shift;
    my $interval = $self->{heartbeat}{interval}{server};

    unless (defined $interval and $interval > 0) {
        return;
    }

    $self->{heartbeat}{timer}{server} = AnyEvent->timer(
        after => ($interval/1000+$TIMEOUT_MARGIN),
        cb => sub {
            $self->{connected} = 0;
            $self->event('DISCONNECTED');
        }
    );
}

sub subscribe {
    my $self = shift;
    my $destination = shift;
    my $ack_mode = shift || 'auto';

    unless (defined $self->{subscriptions}{$destination}) {
        my $subscription_id = shift || int(rand(1000));
        $self->{subscriptions}{$destination} = $subscription_id;
        $self->send_frame(
            'SUBSCRIBE',
            {destination => $destination, id => $subscription_id, ack => $ack_mode,},
            undef
            );
    }

    return $self->{subscriptions}{$destination};
}

sub unsubscribe {
    my $self = shift;
    my $subscription_id = shift;

    $self->send_frame(
        'UNSUBSCRIBE',
        {id => $subscription_id,},
        undef
    );
}

sub header_hash2string {
    my $header_hashref = shift;
    return join($EOL, map { "$_:$header_hashref->{$_}" } keys %$header_hashref);
}

sub header_string2hash {
    my $header_string = shift;
    my $result_hashref = {};

    foreach (split /\n/, $header_string) {
        if (m/([^\r\n:]+):([^\r\n:]*)/) {
            # add header decoding
            $result_hashref->{$1} = $2 unless defined $result_hashref->{$1};
        }
    }
    
    return $result_hashref;
}

sub encode_header {
    my $header_hashref = shift;

    my $ESCAPE_MAP = {
        chr(92) => '\\\\',
        chr(13) => '\\r',
        chr(10) => '\\n',
        chr(58) => '\c',
    };
    my $ESCAPE_KEYS = '['.join('', map(sprintf('\\x%02x', ord($_)), keys(%$ESCAPE_MAP))).']';

    my $result_hashref;

    while (my ($k, $v) = each(%$header_hashref)) {
        $v =~ s/($ESCAPE_KEYS)/$ESCAPE_MAP->{$1}/ego;
        $k =~ s/($ESCAPE_KEYS)/$ESCAPE_MAP->{$1}/ego;
        $result_hashref->{$k} = $v;
    }

    return $result_hashref;
}

sub decode_header {
    my $header_hashref = shift;
    # treat escape sequences like \t as fatal error

    return $header_hashref;
}

sub send_frame {
    my ($self, $command, $header_hashref, $body) = @_;

    my $header;
    if ($command eq 'CONNECT') {
        $header = header_hash2string($header_hashref);
    }
    else {
        $header = header_hash2string(encode_header($header_hashref));
    }

    my $frame;
    if ($command eq 'SEND') {
        $frame = $command.$EOL.$header.$EOL.$EOL.$body.$NULL;
    }
    else {
        $frame = $command.$EOL.$header.$EOL.$EOL.$NULL;
    }

    $self->event('SEND_FRAME', $frame);
    $self->{handle}->push_write($frame);
    $self->reset_client_heartbeat_timer;
}

sub ack {
    my $self = shift;
    my $msg_id = shift;

    $self->send_frame('ACK', {id => $msg_id,});
}

sub nack {
    my $self = shift;
    my $msg_id = shift;

    $self->send_frame('NACK', {id => $msg_id,});
}

sub send_heartbeat {
    my $self = shift;
    $self->{handle}->push_write($EOL);
    $self->reset_client_heartbeat_timer;
}

sub send {
    my $self = shift;
    my ($destination, $headers, $body) = @_;

    unless (defined $headers->{'content-length'}) {
        $headers->{'content-length'} = length $body || 0;
    }
    $headers->{destination} = $destination;

    $self->send_frame('SEND', $headers, $body);
}

sub receive_frame {
    my $self = shift;
    $self->{handle}->unshift_read(
        line => sub {
            my ($handle, $command, $eol) = @_;

            $self->reset_server_heartbeat_timer;

            unless ($command =~ /CONNECTED|MESSAGE|RECEIPT|ERROR/) {
                return;
            }

            $self->{handle}->unshift_read(
                regex => qr<\r?\n\r?\n>,
                cb => sub {
                    my ($handle, $header_string) = @_;
                    my $header_hashref = header_string2hash($header_string);
                    my $args;

                    if ($command =~ m/MESSAGE|ERROR/) {
                        if (defined $header_hashref->{'content-length'}) {
                            $args->{chunk} = $header_hashref->{'content-length'};
                        }
                        else {
                            $args->{regex} = qr<[^\000]*\000>;
                        }

                        $self->{handle}->unshift_read(
                            %$args,
                            cb => sub {
                                my ($handle, $body) = @_;
                                $self->event($command, $header_hashref, $body);
                            }
                        );
                    }
                    else {
                        if ($command eq 'CONNECTED') {
                            $self->{connected} = 1;
                            $self->{session} = $header_hashref->{session};
                            $self->{version} = $header_hashref->{version};
                            $self->{server} = $header_hashref->{server};

                            $self->set_heartbeat_intervals($header_hashref->{'heart-beat'});
                        }

                        $self->event($command, $header_hashref);
                    }
                },
            );
        },
    );
}

sub on_send_frame {
    shift->reg_cb('SEND_FRAME', shift);
}

sub on_connected {
    shift->reg_cb('CONNECTED', shift);
}

sub on_disconnected {
    shift->reg_cb('DISCONNECTED', shift);
}

sub on_message {
    shift->reg_cb('MESSAGE', shift);
}

sub on_receipt {
    shift->reg_cb('RECEIPT', shift);
}

sub on_error {
    shift->reg_cb('ERROR', shift);
}

1;