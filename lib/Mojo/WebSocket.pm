package Mojo::WebSocket;
use Mojo::Base -strict;

use Exporter 'import';
use Config;
use Mojo::Util qw(b64_encode sha1_bytes xor_encode);

our @EXPORT_OK
  = qw(challenge client_handshake parse_frame server_handshake MAX_WEBSOCKET_SIZE);

# Unique value from RFC 6455
use constant GUID => '258EAFA5-E914-47DA-95CA-C5AB0DC85B11';

use constant DEBUG => $ENV{MOJO_WEBSOCKET_DEBUG} || 0;
use constant MAX_WEBSOCKET_SIZE => 262144;

# Perl with support for quads
use constant MODERN =>
  (($Config{use64bitint} // '') eq 'define' || $Config{longsize} >= 8);

sub challenge {
  my $tx = shift;

  # "permessage-deflate" extension
  my $headers = $tx->res->headers;
  $tx->compressed(1)
    if ($headers->sec_websocket_extensions // '') =~ /permessage-deflate/;

  return _challenge($tx->req->headers->sec_websocket_key) eq
    $headers->sec_websocket_accept;
}

sub client_handshake {
  my $tx = shift;

  my $headers = $tx->req->headers;
  $headers->upgrade('websocket')      unless $headers->upgrade;
  $headers->connection('Upgrade')     unless $headers->connection;
  $headers->sec_websocket_version(13) unless $headers->sec_websocket_version;

  # Generate 16 byte WebSocket challenge
  my $challenge = b64_encode sprintf('%16u', int(rand 9 x 16)), '';
  $headers->sec_websocket_key($challenge) unless $headers->sec_websocket_key;

  return $tx;
}

sub parse_frame {
  my $buffer = shift;
  my $max_websocket_size = shift || MAX_WEBSOCKET_SIZE;

  # Head
  return undef unless length $$buffer >= 2;
  my ($first, $second) = unpack 'C*', substr($$buffer, 0, 2);

  # FIN
  my $fin = ($first & 0b10000000) == 0b10000000 ? 1 : 0;

  # RSV1-3
  my $rsv1 = ($first & 0b01000000) == 0b01000000 ? 1 : 0;
  my $rsv2 = ($first & 0b00100000) == 0b00100000 ? 1 : 0;
  my $rsv3 = ($first & 0b00010000) == 0b00010000 ? 1 : 0;

  # Opcode
  my $op = $first & 0b00001111;
  warn "-- Parsing frame ($fin, $rsv1, $rsv2, $rsv3, $op)\n" if DEBUG;

  # Small payload
  my ($hlen, $len) = (2, $second & 0b01111111);
  if ($len < 126) { warn "-- Small payload ($len)\n" if DEBUG }

  # Extended payload (16-bit)
  elsif ($len == 126) {
    return undef unless length $$buffer > 4;
    $hlen = 4;
    $len = unpack 'n', substr($$buffer, 2, 2);
    warn "-- Extended 16-bit payload ($len)\n" if DEBUG;
  }

  # Extended payload (64-bit with 32-bit fallback)
  elsif ($len == 127) {
    return undef unless length $$buffer > 10;
    $hlen = 10;
    my $ext = substr $$buffer, 2, 8;
    $len = MODERN ? unpack('Q>', $ext) : unpack('N', substr($ext, 4, 4));
    warn "-- Extended 64-bit payload ($len)\n" if DEBUG;
  }

  # Check message size
  return 1 if $len > $max_websocket_size;

  # Check if whole packet has arrived
  $len += 4 if my $masked = $second & 0b10000000;
  return undef if length $$buffer < ($hlen + $len);
  substr $$buffer, 0, $hlen, '';

  # Payload
  my $payload = $len ? substr($$buffer, 0, $len, '') : '';
  $payload = xor_encode($payload, substr($payload, 0, 4, '') x 128) if $masked;
  warn dumper $payload if DEBUG;

  return [$fin, $rsv1, $rsv2, $rsv3, $op, $payload];
}

sub server_handshake {
  my $tx = shift;

  my $res_headers = $tx->res->headers;
  $res_headers->upgrade('websocket')->connection('Upgrade');
  $res_headers->sec_websocket_accept(
    _challenge($tx->req->headers->sec_websocket_key));

  return $tx;
}

sub _challenge { b64_encode(sha1_bytes(($_[0] || '') . GUID), '') }

1;
