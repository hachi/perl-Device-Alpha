#!/usr/bin/perl

use strict;
use warnings;

use Device::Alpha qw(mode);
use IO::Socket::INET;

my $sock = IO::Socket::INET->new(
    Proto => 'udp',
    LocalPort => '13375',
) || die "Can't listen on UDP socket: $!";

my @strings = qw(B C D E F G H I);

my $alpha = Device::Alpha->new('./foo.txt');

$alpha->setup_string(map { ($_, 120) } @strings);

$alpha->write_text(0 => '');

$alpha->write_text(A => mode('MIDDLE', 'COMPRESSED') . "\cU" . join( " // ", map { "\x10$_" } @strings));

$alpha->write_string($_ => '')
    foreach (@strings);

my %nodes;

while (my $input = <$sock>) {
    chomp $input;
    print "Input: $input\n";
    my ($node, $value) = $input =~ m/^(\S+)\s+\'([^\']*)\'$/;
    $value =~ s/ at.*$//;

    my %update_strings;
    my $exists = exists $nodes{$node};

    $nodes{$node}->{value} = $value;

    unless ($exists) {
        my @node_list = sort keys %nodes;
        my $i = @strings / (@node_list + 1);
        my $x = 0;

        foreach (@node_list) {
            $nodes{$_}->{string} = $strings[int($x += $i)];
        }
        $update_strings{$_} = 1 foreach @strings;
    }

    $update_strings{$nodes{$node}->{string}} = 1;

    foreach my $string (sort keys %update_strings) {
        $alpha->write_string($string,
                             join(" // ", (
                                        map {"$_: $nodes{$_}->{value}"}
                                        sort
                                        grep {$nodes{$_}->{string} eq $string}
                                        keys %nodes
                                        )
                                  )
                             );
    }
}

