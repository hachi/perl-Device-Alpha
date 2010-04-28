package Device::Alpha;

use strict;
use warnings;

use base 'Exporter';

use Fcntl;
use List::Util qw(sum);

our @EXPORT_OK = qw(mode);

sub SYNC        () { "\x00" x 5 }
sub SOH         () { "\x01" }
sub STX         () { "\x02" }
sub ETX         () { "\x03" }
sub EOT         () { "\x04" }

my %TYPE = (
             VISUAL   => '!',
             ONE_LINE => '1',
             TWO_LINE => '2',
             ALL      => '?',
           # ALL      => 'Z', # ALTERNATE
             );

my %COMMANDS = (
                WRITE_TEXT        => 'A',
                READ_TEXT         => 'B',
                WRITE_SPECIAL     => 'E',
                READ_SPECIAL      => 'F',
                WRITE_STRING      => 'G',
                READ_STRING       => 'H',
                WRITE_SMALL_DOTS  => 'I',
                READ_SMALL_DOTS   => 'J',
                WRITE_RGB_DOTS    => 'K',
                READ_RGB_DOTS     => 'L',
                WRITE_LARGE_DOTS  => 'M',
                READ_LARGE_DOTS   => 'N',
                WRITE_BULLETIN    => 'O',
                SET_TIMEOUT       => 'T',
                );

my %DISPLAY_POSITION = (
                        MIDDLE   => ' ',
                        TOP      => '"',
                        BOTTOM   => '&',
                        FILL     => '0',
                        LEFT     => '1',
                        RIGHT    => '2',
                        );

my %MODE_CODES = (
                  ROTATE     => 'a',
                  HOLD       => 'b',
                  FLASH      => 'c',
                  # 'd' is reserved
                  ROLL_UP    => 'e',
                  ROLL_DOWN  => 'f',
                  ROLL_LEFT  => 'g',
                  ROLL_RIGHT => 'h',
                  WIPE_UP    => 'i',
                  WIPE_DOWN  => 'j',
                  WIPE_LEFT  => 'k',
                  WIPE_RIGHT => 'l',
                  SCROLL     => 'm',
                  AUTOMODE   => 'o',
                  ROLL_IN    => 'p',
                  ROLL_OUT   => 'q',
                  WIPE_IN    => 'r',
                  WIPE_OUT   => 's',
                  COMPRESSED => 't',
                  EXPLODE    => 'u',
                  CLOCK      => 'v',
                  SPECIAL    => 'n',
                  );

my %SPECIAL_MODES = (
                     TWINKLE => '0',
                     #POPULATE LATER
                     );

=head1 METHODS

=head2 new

  $alpha = Device::Alpha->new( device )

Returns a new Device::Alpha object providing an interface to the named C<device>.

=cut

sub new {
    my $class = shift;
    my $device = shift;

    my $self = bless {
        app_buffer => [],
        packet_buffer => [],
        device => $device,
    }, (ref $class || $class);
    $self->init;
    return $self;
}

sub open {
    my $self = shift;

    my $device = $self->{device};

    sysopen(my $fh, $device, O_RDWR) || die "$!";
    $self->{fh} = $fh;
    return $fh;
}

sub init {
    my $self = shift;
    $self->open();
}

sub flush {
    my $self = shift;
    my $app_buffer = $self->{app_buffer};
    my $packet_buffer = $self->{packet_buffer};

    push @$packet_buffer, transmission(['ALL', '00'], @$app_buffer);
    @$app_buffer = ();
    $self->device_write;
}

sub device_write {
    my $self = shift;
    my $packet_buffer = $self->{packet_buffer};
    my $text_buffer = '';

    while (@$packet_buffer) {
        my $data = shift @$packet_buffer;
        if (ref $data and $data->can('delay')) {
            select(undef, undef, undef, $data->delay);
            next;
        }
        $text_buffer .= $data;
    }
    return unless length $text_buffer;
    my $fh = $self->{fh};
    syswrite($fh, $text_buffer) || die "$!";
}

sub transmission {
    my @selectors;

    if (ref $_[0] eq 'ARRAY') {
        my $s = shift;
        my ($rawtype, $address) = (shift @$s, shift @$s);
        my $type = $TYPE{$rawtype} || die "Unknown type '$rawtype'";
        die "Address must be 2 characters" unless length $address == 2;
        push @selectors, [$type, $address];
    }
    my @packets = @_;

    die unless @selectors > 0;
    die unless @packets > 0;

    my $selectors = join ',', map { $_->[0] . $_->[1] } @selectors;

    return SYNC, SOH, $selectors, @packets, EOT;
}

sub packet {
    my $command = shift || die "Command not supplied";

    # 100ms delay after STX
    my $ret   = $command . join('', @_) . ETX;
    my $check = unpack('%16C*', STX . $ret);
    return STX, delay(.1), $ret . sprintf("%04X", $check);
}

sub delay {
    return Device::Alpha::Delay->new(@_);
}

sub packet_no_checksum {
    die;
    my $command = shift || die "Command not supplied";
    return STX . $command . join('', @_);
}

=head2 write_text

  $alpha->write_text( file, text )

Writes C<text> to the C<file> on the alpha devices being controlled by C<$alpha>

=cut

sub write_text {
    my $self = shift;
    my $file = shift;
    my $text = shift;

    die if @_;

    $self->_queue(packet($COMMANDS{WRITE_TEXT}, $file, $text));
}

=head2 write_string

  $alpha->write_string( file, string )

Writes C<string> to the C<file> on the alpha devices being controlled by C<$alpha>

=cut

sub write_string {
    my $self = shift;
    my $file = shift;
    my $string = shift;

    die if @_;
    $self->_queue(packet($COMMANDS{WRITE_STRING}, $file, $string));
}

=head2 setup_string

  $alpha->setup_string( string name => string length, ... )

Takes a list of pairs of string names and lengths and sets them up on the alpha devices which are being controlled by C<$alpha>.

=cut

sub setup_string {
    my $self = shift;
    my %strings = @_;

    $self->_queue(
              packet($COMMANDS{WRITE_SPECIAL}, '$',
                     'A', 'A', 'U', sprintf('%04X', 120), 'FF00',
                     map { $_, 'B', 'L', sprintf('%04X', $strings{$_}), '0000' } keys %strings,
                     ));
}

=head1 FUNCTIONS

=head2 mode

  mode( alignment, mode )

  mode( alignment, 'n', special mode )

Returns data to be fed into the Device::Alpha object writing methods to set C<alignment>, C<mode> (and possibly C<special mode>)

=cut

sub mode {
    my $alignment = shift || 'MIDDLE';
    my $mode_code = shift;

    my $ret = "\x1b" . $DISPLAY_POSITION{$alignment} . $MODE_CODES{$mode_code};

    if ($mode_code eq 'n') {
        my $special_mode = shift;
        $ret .= $SPECIAL_MODES{$special_mode};
    }
    return $ret;
}

sub _queue {
    my $self = shift;
    my $app_buffer = $self->{app_buffer};
    push @$app_buffer, @_;
    $self->flush;
}


# This doesn't actually work... find a good call syntax for it.
sub tied_string {
    tie my $scalar, 'Device::Alpha::TiedString', @_;
}

package Device::Alpha::TiedString;

sub TIESCALAR {
    my $class = shift;
    my $alpha = shift;
    my $file = shift;
    die unless $file =~ m/^\w$/;
    return bless [undef, $alpha, $file], $class;
}

sub FETCH {
    my $self = shift;
    return $self->[0];
}

sub STORE {
    my $self = shift;
    my $val = shift;
    my $alpha = $self->[1];
    $alpha->write_string($self->[1], $val);
    return $self->[0] = $val;
}

package Device::Alpha::Delay;

sub new {
    my $class = shift;
    my $value = shift;
    my $self = bless \$value, $class;
    return $self;
}

sub delay {
    my $self = shift;
    return $$self;
}
