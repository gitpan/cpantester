#! /usr/bin/perl

use strict 'vars';
use vars qw(
    $VERSION
    $NAME
    $PROMPT
    $VERBOSE
    $INTERACTIVE
    $POLL
    $ftp
);
#use warnings;
#no warnings 'once';
use File::Slurp;
use File::Temp;
use Getopt::Long;
use Net::FTP;
use Test::Reporter;

our ($conf, $file, $files, $got_file, $TRACK);

$|++;

main();

sub main {
    $VERSION = '0.01_06';
    $NAME = 'cpantester';

    my $conf = parse_args();
    
    if (not $POLL) {
        do_verbose( '', 'STDOUT', "--> Mode: non-polling, 1\n" );
        test( $conf, fetch( $conf ), read_track( $conf ) );
    } else {
        do_verbose( '', 'STDOUT', "--> Mode: polling, 1 <--> infinite\n" );
        while (1) { 
	    my $PREFIX = '-->';
	    my $string = 'second(s) until polling again';
	    my $oldlen = 0;
	    
	    test( $conf, fetch( $conf ), read_track( $conf ) ); 
	    
	    for (my $sec = $POLL; $sec >= 1; $sec--) {
	        do_verbose( '', 'STDOUT', "$PREFIX $sec " );
		
		my $fulllen = (length( $PREFIX ) + 1 + length ( $sec ) + 1 + length( $string ));
		$oldlen = $fulllen unless $oldlen;
		my $blank = $oldlen - $fulllen;
		$oldlen = $fulllen;
		
		print( $string, ' ' x $blank, "\b" x ($fulllen + $blank) ) if ($VERBOSE && $sec != 1);
		$blank = 0;
		
		sleep 1;
	    }
	    do_verbose( '', 'STDOUT', "\n--> Polling\n" );
	}
    }
    
    exit 0;
}

sub test {
    local ($conf, $files, $got_file) = @_;
    local $file;
    
    local $TRACK = \*TRACK;
    open ($TRACK, ">>$conf->{track}") or die_mail( "Couldn't open $conf->{track} for writing: $!\n " );

    for $file (@{$files}) {
        next if ($got_file->{$file} || $file !~ /tar.gz$/);
	
	my ($dist) = $file =~ /(.*)\.tar.gz$/;
	
	next if do_interactive( "$dist - Skip? [y/N]: ", '^y$', 'print $TRACK "$file\n" unless $got_file->{$file}' );
      
        $ftp->get( $file, "$conf->{dir}/$file" )
          or die_mail( "Couldn't get $file: ", $ftp->message );
	
	my $skip = 0;
	
	chdir ( "$conf->{dir}" ) or die_mail( "Couldn't cd to $conf->{dir}: $!\n" );
	
	next if do_interactive( "tar xvvzf $file -C $conf->{dir}? [Y/n]: ", '^n$' );
	
    	my @tar = `tar xvvzf $file -C $conf->{dir}`;
	do_verbose( '', 'STDERR', @tar );
	die_mail( "$dist: tar xvvzf $file -C $conf->{dir}: $?\n" ) if ($? != 0);
	
	my $dist_dir = "$conf->{dir}/$dist";
	
    	unless (chdir ( "$dist_dir" )) {
	    warn "--> Could not cd to $dist_dir, processing next distribution\n"; 
	    $skip = 1; 
	}
	
	if (-e "$dist_dir/Build.PL") {
	    warn "--> Build.PL exists, processing next distribution\n";
	    $skip = 1;
	}

	next if $skip;
	
	next if do_interactive( 'perl Makefile.PL? [Y/n]: ', '^n$' );
	    
	my $stdout = tmpnam();
	my $stderr = tmpnam();
	system( "perl Makefile.PL > $stdout 2>> $stderr" );
	
	my $TMPFILE = \*TMPFILE;
	open ($TMPFILE, $stderr) or die_mail( "Could not open $stderr: $!\n" );
	while (my $line = <$TMPFILE>) {
	    if (my ($dist, $version) = $line =~ /^Warning: prerequisite (\w+::\w+) (.+) not found\.$/) {
	        do_verbose( 'warn "--> Prerequisites not found, skipping\n" if $VERBOSE' );
	        $skip = 1;
            }
        }    
	close ($TMPFILE) or die_mail( "Could not close $stderr: $!\n" );
		    
	die_mail( "$dist: perl Makefile.PL exited on $?\n" ) if ($? != 0);
	
	do_verbose( 'warn "perl Makefile.PL...\n" unless $INTERACTIVE; warn read_file( $stdout );' );

        next if $skip;
	
	next if do_interactive( 'make? [Y/n]: ', '^n$' );
	
	my @make = `make`;
	die_mail( "$dist: make exited on $?\n" ) if ($? != 0);
	do_verbose( 'warn "make...\n" unless $INTERACTIVE', 'STDOUT', @make );
	
	next if do_interactive( 'make test? [Y/n]: ', '^n$' );
	
	my @maketest = `make test`;
	die_mail( "$dist: make test exited on $?\n" ) if $? != 0;
	do_verbose( 'warn "make test...\n" unless $INTERACTIVE', 'STDOUT', @maketest );

	report( $conf, $dist, \@maketest );
	
	next if do_interactive( 'make realclean? [Y/n]: ', '^n$' ); 
    	    
        my @makerealclean = `make realclean`;
        die_mail( "$dist: make realclean exited on $?\n" ) if ($? != 0);
	do_verbose( 'warn "make realclean...\n" unless $INTERACTIVE', 'STDOUT', @makerealclean );
	
	next if do_interactive( 'rm -rf $dist_dir? [Y/n]: ', '^n$' ); 
    	    
        my @rm = `rm -rf $dist_dir`;
        die_mail( "$dist: rm -rf exited on $?\n" ) if ($? != 0);
	do_verbose( 'warn "rm -rf $dist_dir...\n" unless $INTERACTIVE', 'STDOUT', @rm );
	
        print $TRACK "$file\n"; # unless $got_file->{$file};
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
		
    do_verbose( '', 'STDERR', $reporter->debug( $VERBOSE ) );
	    
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
    
    GetOptions(\%opt, 'h', 'i', 'p=i', 'v', 'V') or $opt{'h'} = 1;
    
    $INTERACTIVE = $opt{i} ? 1 : 0;
    $VERBOSE     = $opt{v} ? 1 : 0;
    $POLL	 = $opt{p} ? $opt{p} : 0;

    if ($opt{'h'} || $opt{'V'}) {
        if ($opt{'h'}) {
            print <<"";
usage: $0 [options]
  -h			this help screen
  -i			interactive (defies -v) 
  -p intervall		run in polling mode 
  			    intervall: seconds to wait until polling
  -v			verbose
  -V			version info

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
    } until ($input =~ /^y$/i || $input =~ /^n$/i || $input eq '');
    
    return $input;
}

sub die_mail {
    my @err = @_;
    
    my $login    = getlogin;
    
    if ($VERBOSE) {
        warn "--> @err";
        warn "--> Reporting error coincidence via mail to $login", '@localhost', "\n";
    }
    
    my $sendmail = '/usr/sbin/sendmail';
    my $from     = "$NAME $VERSION <$NAME".'@localhost>';
    my $to	 = "$login".'@localhost';
    my $subject  = "error: @err";
    
    my $SENDMAIL = \*SENDMAIL;
    open ($SENDMAIL, "| $sendmail -t") or die "Could not open | to $sendmail: $!\n";
    
    my $selold = select ($SENDMAIL);
    
    print <<"MAIL";
From: $from
To: $to
Subject: $subject
@err
MAIL
    close ($SENDMAIL) or die "Could not close | to sendmail: $!\n";
    select ($selold);
    
    #exit ($? != 0) ? $? : -1;
}

sub do_interactive {
    if ($INTERACTIVE) {
        my ($prompt, $cond, $eval) = @_;
    
        my $input = user_input( $prompt );
    
        eval $eval if $eval;
        die $@ if $@;
    
        return ($input =~ /$cond/i) ? 1 : 0;
    }
}

sub do_verbose {
    if ($VERBOSE) {
        my ($eval, $out, @err) = @_;
    
        eval $eval if $eval;
        die @$ if $@;
    
        print $out @err;
    }
}

__END__

=head1 NAME

cpantester - Test CPAN contributions and submit reports to cpan-testers@perl.org

=head1 SYNOPSIS

 usage: cpantester.pl [options]

=head1 OPTIONS

   -h			this help screen
   -i			interactive (defies -v)
   -p intervall		run in polling mode 
  			    intervall: seconds to wait until poll again
   -v			verbose
   -V			version info

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
 rss		= 0
 rss_feed	= http://search.cpan.org/recent.rdf
 
=head1 MAIL

Upon errors the coincidence will be reported via mail to login@localhost.

=head1 CAVEATS

=head2 Prerequisites

Distributions are skipped upon the detection of missing prerequisites.

=head1 SEE ALSO

L<Test::Reporter>, L<testers.cpan.org>

=cut
