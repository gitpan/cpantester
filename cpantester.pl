#! /usr/bin/perl

use strict;
use vars qw(
    $VERSION
    $NAME
    $PROMPT
    $VERBOSE
    $INTERACTIVE
    $POLL
    $ftp
);
use warnings;
no warnings 'once';
use File::Slurp;
use File::Temp;
use Getopt::Long;
use Net::FTP;
use Test::Reporter;
use XML::RSS::Parser;

main();

sub main {
    my $conf = parse_args();
    
    if (not $POLL) {
        print "--> Mode: non-polling, 1\n" if $VERBOSE;
        test( $conf, fetch( $conf ), read_track( $conf ) );
    } else {
        print "--> Mode: polling, 1 <--> infinite\n" if $VERBOSE;
        while (1) { test( $conf, fetch( $conf ), read_track( $conf ) ) }
    }
    
    exit 0;
}

sub test {
    my ($conf, $files, $got_file) = @_;
    
    my $TRACK = \*TRACK;
    open ($TRACK, ">>$conf->{track}") or die_mail( "Couldn't open $conf->{track} for writing: $!\n " );

    for my $file (@{$files}) {
        next if ($got_file->{$file} || $file !~ /tar.gz$/);
	
	my ($dist) = $file =~ /(.*)\.tar.gz$/;
	
	if ($INTERACTIVE) {
	    my $input = user_input( "$dist - Skip? [y/N]: " );
            if ($input eq 'y') {
	        print $TRACK "$file\n" unless $got_file->{$file};
		next;
            }
	}
      
        $ftp->get( $file, "$conf->{dir}/$file" )
          or die_mail( "Couldn't get $file: ", $ftp->message );
	
	my $skip = 0;
	
	chdir ( "$conf->{dir}" ) or die_mail( "Couldn't cd to $conf->{dir}: $!\n" );
	
	if ($INTERACTIVE) { 
	    my $input = user_input( "tar xvvzf $file -C $conf->{dir}? [Y/n]: " );
            next if ($input eq 'n'); 
	}
	
    	my @tar = `tar xvvzf $file -C $conf->{dir}`;
	if ($VERBOSE) { warn @tar }
	die_mail( "$dist: tar xvvzf $file -C $conf->{dir}: $?\n" ) if ($? != 0);
	
	my $dist_dir = "$conf->{dir}/$dist";
	
    	unless (chdir ( "$dist_dir" )) {
	    warn "--> Could not cd to $dist_dir, processing next distributuion\n"; 
	    $skip = 1; 
	}
	
	if (-e "$dist_dir/Build.PL") {
	    warn "--> Build.PL exists, processing next distribution\n";
	    $skip = 1;
	}

	next if $skip;
	
   	if ($INTERACTIVE) { 
	    my $input = user_input( 'perl Makefile.PL? [Y/n]: ' );
            next if ($input eq 'n');
	}
	    
	my $stdout = tmpnam();
	my $stderr = tmpnam();
	system( "perl Makefile.PL > $stdout 2>> $stderr" );
	
	my $TMPFILE = \*TMPFILE;
	open ($TMPFILE, $stderr) or die_mail( "Could not open $stderr: $!\n" );
	while (my $line = <$TMPFILE>) {
	    if (my ($dist, $version) = $line =~ /^Warning: prerequisite (\w+::\w+) (.+) not found\.$/) {
	        $skip = 1;
            }
        }    
	close ($TMPFILE) or die_mail( "Could not close $stderr: $!\n" );
		    
	die_mail( "$dist: perl Makefile.PL exited on $?\n" ) if ($? != 0);
	
	if ($VERBOSE) {
	    warn "perl Makefile.PL...\n" unless $INTERACTIVE;
	    warn read_file( $stdout );
	}

        next if $skip;
	
        if ($INTERACTIVE) { 
	    my $input = user_input( 'make? [Y/n]: ' );
            next if ($input eq 'n');
	}
	my @make = `make`;
	die_mail( "$dist: make exited on $?\n" ) if ($? != 0);
	if ($VERBOSE) {
	    warn "make...\n" unless $INTERACTIVE;
	    warn @make;
	}
	   
	if ($INTERACTIVE) { 
	    my $input = user_input( 'make test? [Y/n]: ' );
            next if ($input eq 'n'); 
	}
	my @maketest = `make test`;
	die_mail( "$dist: make test exited on $?\n" ) if $? != 0;
	if ($VERBOSE) {
	    warn "make test...\n" unless $INTERACTIVE;
	    warn @maketest;
	}
	
	report( $conf, $dist, \@maketest );
    	    
        if ($INTERACTIVE) { 
            my $input = user_input( 'make realclean? [Y/n]: ' );
            next if ($input eq 'n'); 
        }
        my @makerealclean = `make realclean`;
        die_mail( "$dist: make realclean exited on $?\n" ) if ($? != 0);
        if ($VERBOSE) {
	    warn "make realclean...\n" unless $INTERACTIVE;
            warn @makerealclean;
        }
    	    
        if ($INTERACTIVE) {
            my $input = user_input( "rm -rf $dist_dir? [Y/n]: " );
            next if ($input eq 'n'); 
        }
        my @rm = `rm -rf $dist_dir`;
        die_mail( "$dist: rm -rf exited on $?\n" ) if ($? != 0);
        if ($VERBOSE) {
	    warn "rm -rf $dist_dir...\n" unless $INTERACTIVE;
            warn @rm;
        }
	
        print $TRACK "$file\n" unless $got_file->{$file};
    }

    close ($TRACK) or die_mail( "Couldn't close $conf->{track}: $!\n" );

    $ftp->quit;
}

sub fetch {
    my ($conf) = @_;

    $ftp = Net::FTP->new( $conf->{host}, Debug => $VERBOSE )
      or die_mail( "Couldn't connect to $conf->{host}: ", $ftp->message );
    
    $ftp->login( 'anonymous','-anonymous@' )
      or die_mail( "Couldn't login: ", $ftp->message ); 
  
    $ftp->binary or die_mail( "Couldn't switch to binary mode: ", $ftp->message );
      
    my @files;
      
    if ($conf->{rss}) {    
	require LWP::UserAgent;
 
        my $ua = LWP::UserAgent->new;
        my $response = $ua->get( $conf->{rss_feed} );
 
        if ($response->is_success) {
            @files = $response->content =~ /<title>(.*?)<\/title>/gm;  
        } else {
            die_mail( $response->status_line );
        }
	
	$ftp->cwd( $conf->{rdir} )
          or die_mail( "Couldn't change working directory: ", $ftp->message ); 
    } else {
        $ftp->cwd( $conf->{rdir} )
          or die_mail( "Couldn't change working directory: ", $ftp->message );
        
	@files = $ftp->ls()
          or die_mail( "Couldn't get list from $conf->{rdir}: ", $ftp->message );
    }
   
    @files = sort @files[ 2 .. $#files ];
    
    return \@files;
}

sub read_track {
    my ($conf) = @_;
    
    my (%got_file, $TRACK);
    $TRACK = \*TRACK;
    
    open ($TRACK, $conf->{track}) or die_mail( "Couldn't open $conf->{track}: $!\n" );
    chomp (my @files = <$TRACK>);
    @got_file{ @files } = (1) x @files;
    close ($TRACK) or die_mail( "Couldn't close $conf->{track}: $!\n" );
    
    return \%got_file;
}

sub report {
    my ($conf, $dist, $maketest) = @_;
    
    my $reporter = Test::Reporter->new();
		
    $reporter->debug( $VERBOSE ) if $VERBOSE;
	    
    $reporter->from( $conf->{mail} );
    $reporter->comments( "Automatically processed by $NAME $VERSION" );
    $reporter->distribution( $dist );
		    
    my $failed = 0;
	    
    for my $line (@{$maketest}) {
        next unless $line =~ /failed/i;
        $failed = 1 && last;
    }
		 
    if ($failed) { 
        $reporter->grade('fail');
    } else { 
        $reporter->grade('pass');
    }
		 
    $reporter->send() or die_mail( $reporter->errstr() );
}


sub parse_args {
    my $conf = usage();
    
    my $login   = getlogin;
    my $homedir = $login =~ /(root)/ ? "/$1" : "/home/$login";
    
    my $conf_text = read_file( "$homedir/.cpantesterrc" );
    %{$conf} = $conf_text =~ /^([^=]+?)\s+=\s+(.+)$/gm;
    
    return $conf;
}

sub usage {
    my @err = @_;
    
    $Getopt::Long::autoabbrev = 0;
    $Getopt::Long::ignorecase = 0; 
    
    my (%conf, %opt);
    
    $PROMPT = "#";
    
    GetOptions(\%opt, 'h', 'i', 'p', 'v', 'V') or $opt{'h'} = 1;
    
    $INTERACTIVE = $opt{i} ? 1 : 0;
    $VERBOSE     = $opt{v} ? 1 : 0;
    $POLL	 = $opt{p} ? 1 : 0;

    if ($opt{'h'} || $opt{'V'}) {
        if ($opt{'h'}) {
            print <<"";
usage: $0 [options]
  -h            this help screen
  -i		interactive (defies -v) 
  -p		run in polling mode
  -v		verbose
  -V            version info

        }
        else {
        print <<"";
  $NAME $VERSION

        }
        exit 0;
    }
    
    return \%conf;
}   

sub user_input {
    my ($msg) = @_;
    
    my $input;
    do {
        print "$PROMPT $msg";
        chomp ($input = <STDIN>);
    } until ($input eq 'y' || $input eq 'n' || $input eq '');
    
    return $input;
}

sub die_mail {
    my @err = @_;
    
    my $login    = getlogin;
    
    if ($VERBOSE) {
        warn "--> Reporting error/exit coincidence via mail to $login", '@localhost', "\n";
    }
    
    my $sendmail = '/usr/sbin/sendmail';
    my $from     = "$NAME $VERSION <$NAME".'@localhost>';
    my $to	 = "$login".'@localhost';
    my $subject  = "error/exit: @err";
    
    my $SENDMAIL = \*SENDMAIL;
    open ($SENDMAIL, "| $sendmail -t") or die "Could not open | to $sendmail: $!\n";
    
    select ($SENDMAIL);
    
    print <<"MAIL";
From: $from
To: $to
Subject: $subject
@err
MAIL
    close ($SENDMAIL) or die "Could not close | to sendmail: $!\n";
    select ($SENDMAIL);
    
    exit ($? != 0) ? $? : -1;
}

BEGIN {
    $VERSION = '0.01_04';
    $NAME = 'cpantester';
}

__END__

=head1 NAME

cpantester - Test CPAN contributions and submit reports to cpan-testers@perl.org

=head1 SYNOPSIS

 usage: cpantester.pl [options]

=head1 OPTIONS

   -h            this help screen
   -i		 interactive (defies -v)
   -p		 run in polling mode 
   -v		 verbose
   -V            version info

=head1 DESCRIPTION

This script features automated testing of new contributions that have
been submitted to CPAN and consist of a former package, i.e. have either
a Makefile.PL or a Build.PL and tests.

L<Test::Reporter> is used to send the test reports.

=head1 CONFIGURATION FILE

A .cpantesterrc may be placed in the appropriate home directory.

 # Example
 host		= pause.perl.org
 rdir		= incoming/
 dir		= /home/user/cpantester
 track		= /home/user/cpantester/track.dat
 mail		= user@host.tld (name)
 rss		= 1
 rss_feed	= http://search.cpan.org/recent.rdf
 
=head1 MAIL

Upon errors/exits the coincidence will be reported via mail to login@localhost.

=head1 CAVEATS

=head2 Prerequisites

Distributions are skipped upon the detection of missing prerequisites.

=head1 SEE ALSO

L<Test::Reporter>, L<testers.cpan.org>

=cut
