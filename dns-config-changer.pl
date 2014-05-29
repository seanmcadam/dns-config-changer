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
use Sys::Syslog qw(:DEFAULT setlogsock);
use Net::Ping;
use File::Spec;
use strict;

my $VERSION = "0.9";
my $PING_TIMEOUT = 5;
my $CHECK_COUNT_TIMES = 60;

use constant {
    LOG_DEBUG   => 'debug',
    LOG_INFO    => 'info',
    LOG_NOTICE  => 'notice',
    LOG_WARNING => 'warning',
    LOG_ERR     => 'error',
    LOG_CRIT    => 'crit',
};

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
our $opt_C = 0;
our $opt_n = 0;

my $progname   = ( split( /\//, $0 ) )[-1];
my $CONFDIR    = "/var/named";
my $BASEDIR    = "/var/named";
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

getopts('nVShdt:B:C:');

if ($opt_h) {
    print "$progname [options]\n";
    print "\tOptions:\n";
    print "\t-t TARGET defaults to '$TARGET'\n";
    print "\t-C Config directory defaults to '$CONFDIR'\n";
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
    $DEBUG     = 1;
    $LOG_LEVEL = LOG_DEBUG;
}

if ($opt_t) {
    $TARGET = $opt_t;
}

if ($opt_B) {
    $BASEDIR = $opt_B;
}

if ($opt_C) {
    $CONFDIR = $opt_C;
}

if ($opt_S) {
    $STDOUT = 1;
}

if ($opt_n) {
    $DRY_RUN = 1;
}

my $NAMED_CONF     = $CONFDIR . $NAMED_LINK;
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
        openlog( $progname, "ndelay,pid" );

	my $count = $CHECK_COUNT_TIMES;
        #setlogmask( LOG_UPTO($LOG_LEVEL) );

	#
	# Run Check Count times, or until it returns True
	#
	while( $count-- ) {
        	if( check_link() ) { last; }
	}

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
        failover() if ( !$DRY_RUN );
    }
    elsif ( $LINK && ( !$DNS ) ) {

        #
        # Fail Back - Link UP, but in fail over mode
        #
        LOG( LOG_WARNING, "DNS FAILBACK - $TARGET UP\n" );
        failback() if ( !$DRY_RUN );
    }
    else {
        confess "Should not be here! LINK:$LINK DNS:$DNS\n";
    }

}

# ---------------------------------------------------------
sub check_link {
    my $P = Net::Ping->new("icmp", $PING_TIMEOUT);

    LOG( LOG_DEBUG, "CHECK LINK $TARGET" );

    if ( $P->ping($TARGET) ) {
        $LINK = 1;
        LOG( LOG_DEBUG, "LINK UP: $TARGET" );
	return 1;
    }
    else {
        $LINK = 0;
        LOG( LOG_DEBUG, "LINK DOWN: $TARGET" );
	return 0;
    }

}

# ---------------------------------------------------------
sub check_dns {

    my $file = readlink($NAMED_CONF);

    # $file = $BASEDIR . '/' . $file;

    LOG( LOG_DEBUG, "DNS CHECK - linked file: $file" );

    if ( $PRI_NAMED_CONF eq $file ) {
        $DNS = 1;
    }
    elsif ( $ALT_NAMED_CONF eq $file ) {
        $DNS = 0;
    }
    else {
        LOG( LOG_DEBUG, "NAMED: $NAMED_CONF" );
        LOG( LOG_DEBUG, "LINK: $file" );
        LOG( LOG_DEBUG, "PRI: $PRI_NAMED_CONF" );
        LOG( LOG_DEBUG, "ALT: $ALT_NAMED_CONF" );

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

    if ( ( $prio == LOG_DEBUG ) && !$DEBUG ) { return; }

    if ( $STDOUT || ( $prio eq LOG_WARNING ) || ( $prio eq LOG_ERR ) || ( $prio eq LOG_CRIT ) ) {
        print( $msg . "\n" );
    }

    syslog( $prio, $msg );

}

