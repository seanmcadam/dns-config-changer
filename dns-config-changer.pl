#!/usr/bin/perl
#
# Author: Sean McAdam
# Website: https://github.com/seanmcadam/dns-config-changer
# License: GPL v2
#
#
# Purpose:
# Changes /etc/named.conf to point to a new config file (via symlink) if the server loses site of
# a specific host or IP address.
# This is used to swap config files when the gateway IP/host goes away, so that the name server starts
# to advertise an alternate config to accomodate the lost of connectivity
#
# --------------------------------------------
# Check current status of the DNS files
# /etc/named.primary.conf
# /etc/named.alternate.conf
#
# /etc/named.conf -> /etc/named.[primary|alternate].conf
#
# --------------------------------------------

use Carp;
use Getopt::Std;
use Sys::Syslog qw(:DEFAULT :macros setlogsock);
use Net::Ping;
use strict;

my $VERSION = "0.9";

sub check_link;
sub check_dns;
sub failover;
sub failback;
sub rndc_restart;
sub LOG($$);

our $opt_h = 0;
our $opt_t = 0;
our $opt_d = 0;
our $opt_S = 0;
our $opt_V = 0;
our $opt_B = 0;
our $opt_n = 0;

my $progname   = ( split( /\//, $0 ) )[-1];
my $BASEDIR    = "/etc";
my $NAMED_LINK = '/named.conf';
my $NAMED_PRI  = '/named.primary.conf';
my $NAMED_ALT  = '/named.alternate.conf';
my $LOG_LEVEL  = LOG_NOTICE;
my $DRY_RUN    = 0;
my $STDOUT     = 0;
my $DEBUG      = 0;
my $TARGET     = "8.8.8.8";
my $LINK       = 0;
my $DNS        = 1;

getopts('nVShdt:B:');

if ($opt_h) {
    print "$progname [options]\n";
    print "\tOptions:\n";
    print "\t-t TARGET defaults to '$TARGET'\n";
    print "\t-B Base directory defaults to '$BASEDIR'\n";
    print "\t-V print version info\n";
    print "\t-S print log to STDOUT\n";
    print "\t-h print this message\n";
    print "\t-n Dry Run, dont do anything\n";
    print "\t-d Turn on DEBUG\n";
    exit;
}

if ($opt_V) {
    print "$progname: $VERSION\n";
    exit;
}

if ($opt_d) {
    $DEBUG = 1;
    $LOG_LEVEL = LOG_DEBUG;
}

if ($opt_t) {
    $TARGET = $opt_t;
}

if ($opt_B) {
    $BASEDIR = $opt_B;
}

if ($opt_S) {
    $STDOUT = 1;
}

if ($opt_n) {
    $DRY_RUN = 1;
}

my $NAMED_CONF     = $BASEDIR . $NAMED_LINK;
my $PRI_NAMED_CONF = $BASEDIR . $NAMED_PRI;
my $ALT_NAMED_CONF = $BASEDIR . $NAMED_ALT;

if ( !-f $NAMED_CONF ) {
    LOG( LOG_ERR, $NAMED_CONF . " does not exist" );
    exit;
}
elsif ( !-l $NAMED_CONF ) {
    LOG( LOG_ERR, $NAMED_CONF . " is not a symbolic link" );
    exit;
}
else {

    eval {
        setlogsock('unix');
        openlog( $progname, "ndelay,pid", LOG_LOCAL0 );
	setlogmask( LOG_UPTO($LOG_LEVEL) );
        check_link();
        check_dns();
        action();
        closelog;
    };
    if ($@) {
        LOG( LOG_CRIT, "Eval Failed:" . $@ . "\n" );
    }
}

# ---------------------------------------------------------
sub action {

    LOG( LOG_DEBUG, "ACTION() LINK:$LINK DNS:$DNS" );

    if ( $LINK && $DNS ) {

        # Do Nothing - Everything nominal
        # All Clear
        #
        LOG( LOG_DEBUG, "DNS ALL CLEAR\n" );
    }
    elsif ( ( !$LINK ) && ( !$DNS ) ) {

        # Do Nothing - Link down, and already failed over
        # Failover Mode
        #
        LOG( LOG_NOTICE, "DNS IN FAILOVER MODE\n" );
    }
    elsif ( ( !$LINK ) && $DNS ) {

        #
        # Fail Over - Link Down, and not failed over
        #
        LOG( LOG_WARNING, "DNS FAILOVER - $TARGET DOWN\n" );
        failover() if ( ! $DRY_RUN );
    }
    elsif ( $LINK && ( !$DNS ) ) {

        #
        # Fail Back - Link UP, but in fail over mode
        #
        LOG( LOG_WARNING, "DNS FAILBACK - $TARGET UP\n" );
        failback() if ( ! $DRY_RUN );
    }
    else {
        confess "Should not be here! LINK:$LINK DNS:$DNS\n";
    }

}

# ---------------------------------------------------------
sub check_link {
    my $P = Net::Ping->new("icmp");

    LOG( LOG_DEBUG, "CHECK LINK $TARGET" );

    if ( $P->ping($TARGET) ) {
        $LINK = 1;
        LOG( LOG_DEBUG, "LINK UP" );
    }
    else {
        $LINK = 0;
        LOG( LOG_DEBUG, "LINK DOWN: $TARGET" );
    }

}

# ---------------------------------------------------------
sub check_dns {

    my $file = readlink($NAMED_CONF);

    LOG( LOG_DEBUG, "DNS CHECK - linked file: $file" );

    if ( $PRI_NAMED_CONF eq $file ) {
        $DNS = 1;
    }
    elsif ( $ALT_NAMED_CONF eq $file ) {
        $DNS = 0;
    }
    else {
        confess $NAMED_CONF . " points to $file\n";
    }

}

# ---------------------------------------------------------
sub failover {

    unlink $NAMED_CONF || confess "Cannot unlink $NAMED_CONF\n";
    symlink $ALT_NAMED_CONF, $NAMED_CONF || confess "Cannot symlink $ALT_NAMED_CONF to $NAMED_CONF\n";

    rndc_restart();

}

# ---------------------------------------------------------
sub failback {

    unlink $NAMED_CONF || confess "Cannot unlink $NAMED_CONF\n";
    symlink $PRI_NAMED_CONF, $NAMED_CONF || confess "Cannot symlink $PRI_NAMED_CONF to $NAMED_CONF\n";

    rndc_restart();

}

# ---------------------------------------------------------
sub rndc_restart {
    LOG( LOG_WARNING, "RELOADING NAME SERVER\n" );
    my $cmd = "rndc reload";
    system $cmd;
}

# ---------------------------------------------------------
sub LOG($$) {
    my $prio = shift;
    my $msg  = shift;

    if ($STDOUT) {
        print $msg . "\n";
    }
    else {
        if ( ( $prio == LOG_DEBUG ) && !$DEBUG ) { return; }
        syslog( $prio, $msg );
    }
}
