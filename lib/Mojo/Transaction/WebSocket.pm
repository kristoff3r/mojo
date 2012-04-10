package Mojo::Transaction::WebSocket;
use Mojo::Base 'Mojo::Transaction';

# "I'm not calling you a liar but...
#  I can't think of a way to finish that sentence."
use Config;
use Mojo::Transaction::HTTP;
use Mojo::Util qw/b64_encode decode encode sha1_bytes/;

use constant DEBUG => $ENV{MOJO_WEBSOCKET_DEBUG} || 0;

# Unique value from the spec
use constant GUID => '258EAFA5-E914-47DA-95CA-C5AB0DC85B11';

# Opcodes
use constant {
  CONTINUATION => 0,
  TEXT         => 1,
  BINARY       => 2,
  CLOSE        => 8,
  PING         => 9,
  PONG         => 10
};

has handshake => sub { Mojo::Transaction::HTTP->new };
has 'masked';
has max_websocket_size => sub { $ENV{MOJO_MAX_WEBSOCKET_SIZE} || 262144 };

sub new {
  my $self = shift->SUPER::new(@_);
  $self->on(frame => sub { shift->_message(@_) });
  return $self;
}

sub build_frame {
  my ($self, $fin, $rsv1, $rsv2, $rsv3, $op, $payload) = @_;
  warn "-- Building frame\n" if DEBUG;

  # Head
  my $frame = 0b00000000;
  vec($frame, 0, 8) = $op | 0b10000000 if $fin;
  vec($frame, 0, 8) |= 0b01000000 if $rsv1;
  vec($frame, 0, 8) |= 0b00100000 if $rsv2;
  vec($frame, 0, 8) |= 0b00010000 if $rsv3;

  # Mask payload
  warn "-- Payload\n$payload\n" if DEBUG;
  my $masked = $self->masked;
  if ($masked) {
    warn "-- Masking payload\n" if DEBUG;
    my $mask = pack 'N', int(rand 9999999);
    $payload = $mask . _xor_mask($payload, $mask);
  }

  # Length
  my $len = length $payload;
  $len -= 4 if $masked;

  # Empty prefix
  my $prefix = 0;

  # Small payload
  if ($len < 126) {
    vec($prefix, 0, 8) = $masked ? ($len | 0b10000000) : $len;
    $frame .= $prefix;
  }

  # Extended payload (16bit)
  elsif ($len < 65536) {
    vec($prefix, 0, 8) = $masked ? (126 | 0b10000000) : 126;
    $frame .= $prefix;
    $frame .= pack 'n', $len;
  }

  # Extended payload (64bit)
  else {
    vec($prefix, 0, 8) = $masked ? (127 | 0b10000000) : 127;
    $frame .= $prefix;
    $frame .=
      $Config{ivsize} > 4
      ? pack('Q>', $len)
      : pack('NN', $len >> 32, $len & 0xFFFFFFFF);
  }

  if (DEBUG) {
    warn '-- Head (', unpack('B*', $frame), ")\n";
    warn "-- Opcode ($op)\n";
  }

  return $frame . $payload;
}

sub client_challenge {
  my $self = shift;
  return $self->_challenge($self->req->headers->sec_websocket_key) eq
    $self->res->headers->sec_websocket_accept ? 1 : undef;
}

sub client_handshake {
  my $self = shift;

  # Default headers
  my $headers = $self->req->headers;
  $headers->upgrade('websocket')  unless $headers->upgrade;
  $headers->connection('Upgrade') unless $headers->connection;
  $headers->sec_websocket_protocol('mojo')
    unless $headers->sec_websocket_protocol;
  $headers->sec_websocket_version(13) unless $headers->sec_websocket_version;

  # Generate WebSocket challenge
  $headers->sec_websocket_key(b64_encode(pack('N*', int(rand 9999999)), ''))
    unless $headers->sec_websocket_key;
}

sub client_read  { shift->server_read(@_) }
sub client_write { shift->server_write(@_) }
sub connection   { shift->handshake->connection(@_) }

sub finish {
  my $self = shift;
  $self->send([1, 0, 0, 0, CLOSE, '']);
  $self->{finished} = 1;
  return $self;
}

sub is_websocket {1}

sub kept_alive    { shift->handshake->kept_alive }
sub local_address { shift->handshake->local_address }
sub local_port    { shift->handshake->local_port }

sub parse_frame {
  my ($self, $buffer) = @_;

  # Head
  my $clone = $$buffer;
  return unless length $clone > 2;
  warn "-- Parsing frame\n" if DEBUG;
  my $head = substr $clone, 0, 2;
  warn '-- Head (' . unpack('B*', $head) . ")\n" if DEBUG;

  # FIN
  my $fin = (vec($head, 0, 8) & 0b10000000) == 0b10000000 ? 1 : 0;
  warn "-- FIN ($fin)\n" if DEBUG;

  # RSV1-3
  my $rsv1 = (vec($head, 0, 8) & 0b01000000) == 0b01000000 ? 1 : 0;
  warn "-- RSV1 ($rsv1)\n" if DEBUG;
  my $rsv2 = (vec($head, 0, 8) & 0b00100000) == 0b00100000 ? 1 : 0;
  warn "-- RSV2 ($rsv2)\n" if DEBUG;
  my $rsv3 = (vec($head, 0, 8) & 0b00010000) == 0b00010000 ? 1 : 0;
  warn "-- RSV3 ($rsv3)\n" if DEBUG;

  # Opcode
  my $op = vec($head, 0, 8) & 0b00001111;
  warn "-- Opcode ($op)\n" if DEBUG;

  # Length
  my $len = vec($head, 1, 8) & 0b01111111;
  warn "-- Length ($len)\n" if DEBUG;

  # No payload
  my $hlen = 2;
  if ($len == 0) { warn "-- Nothing\n" if DEBUG }

  # Small payload
  elsif ($len < 126) { warn "-- Small\n" if DEBUG }

  # Extended payload (16bit)
  elsif ($len == 126) {
    return unless length $clone > 4;
    $hlen = 4;
    my $ext = substr $clone, 2, 2;
    $len = unpack 'n', $ext;
    warn "-- Extended 16bit ($len)\n" if DEBUG;
  }

  # Extended payload (64bit)
  elsif ($len == 127) {
    return unless length $clone > 10;
    $hlen = 10;
    my $ext = substr $clone, 2, 8;
    $len =
      $Config{ivsize} > 4
      ? unpack('Q>', $ext)
      : unpack('N', substr($ext, 4, 4));
    warn "-- Extended 64bit ($len)\n" if DEBUG;
  }

  # Check message size
  $self->finish and return if $len > $self->max_websocket_size;

  # Check if whole packet has arrived
  my $masked = vec($head, 1, 8) & 0b10000000;
  return if length $clone < ($len + $hlen + ($masked ? 4 : 0));
  substr $clone, 0, $hlen, '';

  # Payload
  $len += 4 if $masked;
  return if length $clone < $len;
  my $payload = $len ? substr($clone, 0, $len, '') : '';

  # Unmask payload
  if ($masked) {
    warn "-- Unmasking payload\n" if DEBUG;
    $payload = _xor_mask($payload, substr($payload, 0, 4, ''));
  }
  warn "-- Payload\n$payload\n" if DEBUG;
  $$buffer = $clone;

  return [$fin, $rsv1, $rsv2, $rsv3, $op, $payload];
}

sub remote_address { shift->handshake->remote_address }
sub remote_port    { shift->handshake->remote_port }
sub req            { shift->handshake->req(@_) }
sub res            { shift->handshake->res(@_) }

sub resume {
  my $self = shift;
  $self->handshake->resume;
  return $self;
}

sub send {
  my ($self, $frame, $cb) = @_;

  # Binary or raw text
  if (ref $frame eq 'HASH') {
    $frame =
      exists $frame->{text}
      ? [1, 0, 0, 0, TEXT, $frame->{text}]
      : [1, 0, 0, 0, BINARY, $frame->{binary}];
  }

  # Text
  elsif (!ref $frame) { $frame = [1, 0, 0, 0, TEXT, encode('UTF-8', $frame)] }

  # Prepare frame
  $self->once(drain => $cb) if $cb;
  $self->{write} .= $self->build_frame(@$frame);
  $self->{state} = 'write';

  # Resume
  $self->emit('resume');
}

sub server_handshake {
  my $self = shift;

  # WebSocket handshake
  my $res         = $self->res;
  my $res_headers = $res->headers;
  $res->code(101);
  $res_headers->upgrade('websocket');
  $res_headers->connection('Upgrade');
  my $req_headers = $self->req->headers;
  my $protocol = $req_headers->sec_websocket_protocol || '';
  $protocol =~ /^\s*([^\,]+)/;
  $res_headers->sec_websocket_protocol($1) if $1;
  $res_headers->sec_websocket_accept(
    $self->_challenge($req_headers->sec_websocket_key));
}

sub server_read {
  my ($self, $chunk) = @_;

  # Parse frames
  $self->{read} .= $chunk if defined $chunk;
  while (my $frame = $self->parse_frame(\$self->{read})) {
    $self->emit(frame => $frame);
  }

  # Resume
  $self->emit('resume');
}

sub server_write {
  my $self = shift;

  # Drain
  unless (length($self->{write} // '')) {
    $self->{state} = $self->{finished} ? 'finished' : 'read';
    $self->emit('drain');
  }

  # Empty buffer
  return delete $self->{write} // '';
}

sub _challenge { b64_encode(sha1_bytes((pop() || '') . GUID), '') }

sub _message {
  my ($self, $frame) = @_;

  # Assume continuation
  my $op = $frame->[4] || CONTINUATION;

  # Ping/Pong
  return $self->send([1, 0, 0, 0, PONG, $frame->[5]]) if $op == PING;
  return if $op == PONG;

  # Close
  return $self->finish if $op == CLOSE;

  # Append chunk and check message size
  $self->{op} = $op unless exists $self->{op};
  $self->{message} .= $frame->[5];
  $self->finish and last
    if length $self->{message} > $self->max_websocket_size;

  # No FIN bit (Continuation)
  return unless $frame->[0];

  # Message
  my $message = delete $self->{message};
  $message = decode 'UTF-8', $message
    if $message && delete $self->{op} == TEXT;
  $self->emit(message => $message);
}

sub _xor_mask {
  my ($input, $mask) = @_;

  # 512 byte mask
  $mask = $mask x 128;
  my $output = '';
  $output .= $_ ^ $mask while length($_ = substr($input, 0, 512, '')) == 512;
  return $output .= $_ ^ substr($mask, 0, length, '');
}

1;
__END__

=head1 NAME

Mojo::Transaction::WebSocket - WebSocket transaction container

=head1 SYNOPSIS

  use Mojo::Transaction::WebSocket;

  my $ws = Mojo::Transaction::WebSocket->new;

=head1 DESCRIPTION

L<Mojo::Transaction::WebSocket> is a container for WebSocket transactions as
described in RFC 6455.

=head1 EVENTS

L<Mojo::Transaction::WebSocket> inherits all events from L<Mojo::Transaction>
and can emit the following new ones.

=head2 C<drain>

  $ws->on(drain => sub {
    my $ws = shift;
    ...
  });

Emitted once all data has been sent.

  $ws->on(drain => sub {
    my $ws = shift;
    $ws->send(time);
  });

=head2 C<frame>

  $ws->on(frame => sub {
    my ($ws, $frame) = @_;
    ...
  });

Emitted when a WebSocket frame has been received.

  $ws->unsubscribe('frame');
  $ws->on(frame => sub {
    my ($ws, $frame) = @_;
    say "FIN: $frame->[0]";
    say "RSV1: $frame->[1]";
    say "RSV2: $frame->[2]";
    say "RSV3: $frame->[3]";
    say "Opcode: $frame->[4]";
    say "Payload: $frame->[5]";
  });

=head2 C<message>

  $ws->on(message => sub {
    my ($ws, $message) = @_;
    ...
  });

Emitted when a complete WebSocket message has been received.

  $ws->on(message => sub {
    my ($ws, $message) = @_;
    say "Message: $message";
  });

=head1 ATTRIBUTES

L<Mojo::Transaction::WebSocket> inherits all attributes from
L<Mojo::Transaction> and implements the following new ones.

=head2 C<handshake>

  my $handshake = $ws->handshake;
  $ws           = $ws->handshake(Mojo::Transaction::HTTP->new);

The original handshake transaction, defaults to a L<Mojo::Transaction::HTTP>
object.

=head2 C<masked>

  my $masked = $ws->masked;
  $ws        = $ws->masked(1);

Mask outgoing frames with XOR cipher and a random 32bit key.

=head2 C<max_websocket_size>

  my $size = $ws->max_websocket_size;
  $ws      = $ws->max_websocket_size(1024);

Maximum WebSocket message size in bytes, defaults to the value of the
C<MOJO_MAX_WEBSOCKET_SIZE> environment variable or C<262144>.

=head1 METHODS

L<Mojo::Transaction::WebSocket> inherits all methods from
L<Mojo::Transaction> and implements the following new ones.

=head2 C<new>

  my $multi = Mojo::Content::MultiPart->new;

Construct a new L<Mojo::Transaction::WebSocket> object and subscribe to
C<frame> event with default message parser, which also handles C<PING> and
C<CLOSE> frames automatically.

=head2 C<build_frame>

  my $bytes = $ws->build_frame($fin, $rsv1, $rsv2, $rsv3, $op, $payload);

Build WebSocket frame.

  # Continuation frame with FIN bit and payload
  say $ws->build_frame(1, 0, 0, 0, 0, 'World!');

  # Text frame with payload
  say $ws->build_frame(0, 0, 0, 0, 1, 'Hello');

  # Binary frame with FIN bit and payload
  say $ws->build_frame(1, 0, 0, 0, 2, 'Hello World!');

  # Close frame with FIN bit and without payload
  say $ws->build_frame(1, 0, 0, 0, 8, '');

  # Ping frame with FIN bit and payload
  say $ws->build_frame(1, 0, 0, 0, 9, 'Test 123');

  # Pong frame with FIN bit and payload
  say $ws->build_frame(1, 0, 0, 0, 10, 'Test 123');

=head2 C<client_challenge>

  my $success = $ws->client_challenge;

Check WebSocket handshake challenge.

=head2 C<client_handshake>

  $ws->client_handshake;

WebSocket handshake.

=head2 C<client_read>

  $ws->client_read($data);

Read raw WebSocket data.

=head2 C<client_write>

  my $chunk = $ws->client_write;

Raw WebSocket data to write.

=head2 C<connection>

  my $connection = $ws->connection;

Alias for L<Mojo::Transaction/"connection">.

=head2 C<finish>

  $ws = $ws->finish;

Finish the WebSocket connection gracefully.

=head2 C<is_websocket>

  my $true = $ws->is_websocket;

True.

=head2 C<kept_alive>

  my $kept_alive = $ws->kept_alive;

Alias for L<Mojo::Transaction/"kept_alive">.

=head2 C<local_address>

  my $local_address = $ws->local_address;

Alias for L<Mojo::Transaction/"local_address">.

=head2 C<local_port>

  my $local_port = $ws->local_port;

Alias for L<Mojo::Transaction/"local_port">.

=head2 C<parse_frame>

  my $frame = $ws->parse_frame(\$bytes);

Parse WebSocket frame.

  # Parse single frame and remove it from buffer
  my $frame = $ws->parse_frame(\$buffer);
  say "FIN: $frame->[0]";
  say "RSV1: $frame->[1]";
  say "RSV2: $frame->[2]";
  say "RSV3: $frame->[3]";
  say "Opcode: $frame->[4]";
  say "Payload: $frame->[5]";

=head2 C<remote_address>

  my $remote_address = $ws->remote_address;

Alias for L<Mojo::Transaction/"remote_address">.

=head2 C<remote_port>

  my $remote_port = $ws->remote_port;

Alias for L<Mojo::Transaction/"remote_port">.

=head2 C<req>

  my $req = $ws->req;

Alias for L<Mojo::Transaction/"req">.

=head2 C<res>

  my $res = $ws->res;

Alias for L<Mojo::Transaction/"res">.

=head2 C<resume>

  $ws = $ws->resume;

Alias for L<Mojo::Transaction/"resume">.

=head2 C<send>

  $ws->send({binary => $bytes});
  $ws->send({text   => $bytes});
  $ws->send([$fin, $rsv1, $rsv2, $rsv3, $op, $payload]);
  $ws->send('Hi there!');
  $ws->send('Hi there!' => sub {...});

Send message or frame non-blocking via WebSocket, the optional drain callback
will be invoked once all data has been written.

  # Send "Ping" frame
  $ws->send([1, 0, 0, 0, 9, 'Hello World!']);

=head2 C<server_handshake>

  $ws->server_handshake;

WebSocket handshake.

=head2 C<server_read>

  $ws->server_read($data);

Read raw WebSocket data.

=head2 C<server_write>

  my $chunk = $ws->server_write;

Raw WebSocket data to write.

=head1 DEBUGGING

You can set the C<MOJO_WEBSOCKET_DEBUG> environment variable to get some
advanced diagnostics information printed to C<STDERR>.

  MOJO_WEBSOCKET_DEBUG=1

=head1 SEE ALSO

L<Mojolicious>, L<Mojolicious::Guides>, L<http://mojolicio.us>.

=cut
