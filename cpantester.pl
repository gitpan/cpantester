#! /usr/bin/perl

use strict;
no strict 'refs';
use vars qw($VERSION $NAME);
use warnings;
no warnings qw(redefine);
use Carp 'croak';
use ExtUtils::MakeMaker;
use File::Slurp;
use File::Temp;
use Getopt::Long;
use Net::FTP;
use Test::Reporter;
use Tie::File;

$VERSION = '0.01_09';
$NAME = 'cpantester';

$| = 1;

main();

sub main {
    my ($conf) = parse_args();
    
    weed_out_track( $conf );
    
    unless ($conf->{POLL}) {
        do_verbose( $conf, 'STDERR', "--> Mode: non-polling, 1\n" );
        test( $conf, fetch( $conf ), read_track( $conf ) );
    } else {
        do_verbose( $conf, 'STDERR', "--> Mode: polling, 1 <--> infinite\n" );
	poll( $conf );
    } 
    
    exit 0;
}

sub test {
    my ($conf, $files, $got_file) = @_;
    my ($dist, $distindex, $getfile);
    
    open( my $track, ">>$conf->{track}" ) or die_mail( $conf, "Couldn't open $conf->{track} for writing: $!\n " );
    my $ftp = ftp_initiate( $conf );
    
    $ftp->cwd( $conf->{rdir} )
      or die_mail( $conf, "Couldn't change working directory: ", $ftp->message );

    my @install_prereqs;
    
    while (@{$files}) {
        if ($got_file->{$files->[0]} || $files->[0] !~ /^.*tar.gz$/) {
            shift @{$files};
	    next;
	}
	
	($dist) = $files->[0] =~ /(.*)\.tar.gz$/;
	
	next if process( $conf, '', "$dist - Process? [Y/n]: ", '^n$', $dist );
	
	unless (is_prereq( $files, @install_prereqs )) {
            $ftp->get( $files->[0], "$conf->{dir}/$files->[0]" )
              or die_mail( $conf, "Couldn't get $files->[0]: ", $ftp->message );
	}
	
	chdir ( $conf->{dir} ) or die_mail( $conf, "Couldn't cd to $conf->{dir}: $!\n" );
	
	next if process( $conf, "tar xvvzf $files->[0] -C $conf->{dir}", '[Y/n]', '^n$', $dist );
	die_mail( $conf, "$dist: tar xvvzf $files->[0] -C $conf->{dir}: $?\n" ) if $?;
	
	my $dist_dir = "$conf->{dir}/$dist";
	$/ = ',';
	chomp $dist_dir;
	$/ = "\n";
	
	next if dir_file_error( $dist_dir );

	next if process( $conf, 'perl Makefile.PL', '[Y/n]', '^n$', $dist );
	
	local *ExtUtils::MakeMaker::WriteMakefile = \&get_prereqs;
	my $makeargs = run_makefile( $dist_dir );
	
	my $install_prereqs = 0;
	my @prereqs;
	
	my $file_current = $files->[0];
	
	process_prereqs( $conf, $makeargs, $getfile, $ftp, $distindex );
	
	if ($install_prereqs) {
	    unshift( @{$files}, @prereqs );
	    push( @install_prereqs, @prereqs );
	    $got_file->{$files->[0]} = 1;
	    next;
	}
	
	next if process( $conf, 'make', '[Y/n]', '^n$', $dist );
	next if process( $conf, 'make test', '[Y/n]', '^n$', $dist );
        next if process( $conf, '', 'report? [Y/n]: ', '^n$', $dist ); 
	next if process( $conf, 'make realclean', '[Y/n]', '^n$', $dist ); 
	next if process( $conf, "rm -rf $dist_dir", '[Y/n]', '^n$', $dist );
	
	$got_file->{$files->[0]} = 1;
        print $track "$files->[0]\n";
	shift @{$files};
    }

    close( $track ) or die_mail( $conf, "Couldn't close $conf->{track}: $!\n" );

    $ftp->quit;
}

sub fetch {
    my ($conf) = @_;
    my @files;
    
    my $ftp = ftp_initiate( $conf );
      
    if ($conf->{rss}) {    
	require LWP::UserAgent;
 
        my $ua = LWP::UserAgent->new;
        my $response = $ua->get( $conf->{rss_feed} );
 
        if ($response->is_success) {
            @files = $response->content =~ /<title>(.*?)<\/title>/gm;  
        } else {
            die_mail( $conf, $response->status_line );
        }
	
	$ftp->cwd( $conf->{rdir} )
          or die_mail( $conf, "Couldn't change working directory: ", $ftp->message ); 
    } else {
        $ftp->cwd( $conf->{rdir} )
          or die_mail( $conf, "Couldn't change working directory: ", $ftp->message );
        
	@files = $ftp->ls()
          or die_mail( $conf, "Couldn't get list from $conf->{rdir}: ", $ftp->message );
    }
   
    @files = sort @files[ 2 .. $#files ];
    
    return \@files;
}

sub fetch_prereq {
    my ($conf, $getfile, $ftp, $distindex) = @_;    
    my ($dist, $distcmp, $distdir, @distindex, @distindex_);
    
    my $moduleindex = 'http://www.cpan.org/modules/01modules.index.html';
    
    do_verbose( $conf, 'STDERR', "$conf->{PREFIX} Fetching module index data from CPAN\n" );
    
    require LWP::UserAgent;
    
    my $ua = LWP::UserAgent->new;
    my $response = $ua->get( $moduleindex ); 
 
    if ($response->is_success) {
        $distindex = $response->content unless defined $distindex;  
	my @distindex = split /\n/, $distindex;
	my $distindexsize = @distindex;
	for (my $i = 0; $distindexsize; $i += 2, $distindexsize--) {
	    $distindex[$i] ||= ''; $distindex[$i + 1] ||= '';
	    push( @distindex,"$distindex[$i] . $distindex[$i + 1]" );
	}
	for $dist (@distindex) {
	    $dist ||= '';
	    if ($dist =~ /gz/) {
	        ($distdir) = $dist =~ /^\w+\s+<.*?>.*?<\/.*?>\s+<a href="\.\..*?\/(.*)\/.*\.tar\.gz".*/;
	    }
	    last if ($dist =~ /$getfile/);
	}
    } else {
        die_mail( $conf, $response->status_line );
    }
    
    ftp_initiate( $conf );
    
    $ftp->cwd( "/pub/PAUSE/$distdir" )
      or die_mail( $conf, "Couldn't change working directory: ", $ftp->message );
      
    $ftp->get( "$getfile", "$conf->{dir}/$getfile" )
      or ftp_redo( $conf, $distdir, $getfile, $ftp );
	  
    do_verbose( $conf, 'STDERR', "$conf->{PREFIX} Fetched $getfile from CPAN\n" ); 
}

sub report {
    my ($conf, $dist, $maketest) = @_;
    
    my $reporter = Test::Reporter->new();
		
    $reporter->debug( $conf->{VERBOSE} );
	    
    $reporter->from( $conf->{mail} );
    $reporter->comments( "Automatically processed by $NAME $VERSION" );
    $reporter->distribution( $dist );	    
    $reporter->grade( did_make_fail() );
	 
    $reporter->send() or die_mail( $conf, $reporter->errstr() );
}

sub parse_args {
    my (%conf, %opt);
    
    $Getopt::Long::autoabbrev = 0;
    $Getopt::Long::ignorecase = 0; 

    GetOptions(\%opt, 'h', 'i', 'p=i', 'v', 'V') or $opt{'h'} = 1;
        
    my $login   = getlogin;
    my $homedir = $login =~ /(root)/ ? "/$1" : "/home/$login";
    
    my $conf_text = read_file( "$homedir/.cpantesterrc" )
      or die "Could not open $homedir/.cpantesterc: $!\n";
    %conf = $conf_text =~ /^([^=]+?)\s+=\s+(.+)$/gm;
    
    $conf{PREFIX}      = '-->';
    $conf{PROMPT}      = '#';
    $conf{INTERACTIVE} = $opt{i} ? 1 : 0;
    $conf{POLL}        = $opt{p} ? $opt{p} : 0;
    $conf{VERBOSE}     = $opt{v} ? 1 : 0;
    
    if ($opt{h}) {
        usage();
    } elsif ($opt{V}) {
        version();
    }
    
    return \%conf;
}

sub usage {
    print <<"USAGE";
usage: $0 [options]
  -h			this help screen
  -i			interactive (defies -v) 
  -p intervall		run in polling mode 
  			    intervall: seconds to wait until polling
  -v			verbose
  -V			version info
USAGE

    exit 0;
}

sub version {
    print "  $NAME $VERSION\n";
    exit 0;
}
   
sub user_input {
    my ($conf, $cond, $cmd, $msg) = @_; 
    my $input;
    
    do {
        $cmd .= '? ' if $cmd;
	$msg .= ':' unless $msg =~ /:/;
	
        print "$conf->{PROMPT} $cmd$msg";
        chomp ($input = <STDIN>);
    } until ($input =~ /^y$/i || $input =~ /^n$/i || $input eq '');
    
    my $matched = 0;
    
    if ($input =~ /$cond/i) {
        $matched = 1;
    }
    
    return ($input, $matched);
}

sub poll {
    my ($conf, $ftp, $dist) = @_;
    
    while (1) { 
        my $string = 'second(s) until poll';
	my $oldlen = 0;
	    
	test( $conf, fetch( $conf, $ftp ), read_track( $conf ), $ftp);
	    
	for (my $sec = $conf->{POLL}; $sec >= 1; $sec--) {
	    do_verbose( $conf, 'STDERR', "$conf->{PREFIX} $sec " );
		
            my $fulllen = (length( $conf->{PREFIX} ) + 1 + length ( $sec ) + 1 + length( $string ));
	    $oldlen = $fulllen unless $oldlen;
	    my $blank = $oldlen - $fulllen;
	    $oldlen = $fulllen;
		
	    print( $string, ' ' x $blank, "\b" x ($fulllen + $blank) ) if ($conf->{VERBOSE} && $sec != 1);
	    $blank = 0;
		
	    sleep 1;
	}
        do_verbose( $conf, 'STDERR', "\n--> Polling\n" );
    }
}

sub read_track {
    my ($conf) = @_;   
    my %got_file;

    my $track = read_file( $conf->{track} ) or die "Could not read $conf->{track}: $!\n";
    my @files = split /\n/, $track;
    %got_file = map { $_ => 1 } @files;
    
    return \%got_file;
}

sub ftp_initiate {
    my ($conf) = @_;
    my $ftp;

    $ftp = Net::FTP->new( $conf->{host}, Debug => $conf->{VERBOSE} );
    die_mail( $conf, "Couldn't connect to $conf->{host}: $@") unless ($ftp);
    
    $ftp->login( 'anonymous','anonymous@example.com' )
      or die_mail( $conf, "Couldn't login: ", $ftp->message ); 
  
    $ftp->binary or die_mail( $conf, "Couldn't switch to binary mode: ", $ftp->message );
    
    return $ftp;
}

sub ftp_redo {
    my ($conf, $distdir, $getfile, $ftp) = @_;

    my @files = $ftp->ls()
      or die_mail( $conf, "Couldn't get list from /pub/PAUSE/$distdir: ", $ftp->message );
      
    my $gotdist;
      
    for my $file (@files) {
        if ($file =~ /$getfile/) {
            if ($ftp->get( "$file", "$conf->{dir}/$file" )) {
                $gotdist = 1;
	        last;
	    }
	}
    }
    
    die_mail( $conf, "Couldn't get $getfile: ", $ftp->message ) unless $gotdist;
}

sub is_prereq {
    my ($files, @install_prereqs) = @_;
    
    for my $nst_prereq (@install_prereqs) {
        if ($files->[0] eq $nst_prereq) {
	    return 1;
        }
    }

    return 0;
}

sub dir_file_error {
    my ($dist_dir) = @_;
    
    unless (chdir ( $dist_dir )) {
        warn "--> Could not cd to $dist_dir, processing next distribution\n";
	return 1;
    }
	
    if (-e "$dist_dir/Build.PL") {
        warn "--> Build.PL exists, processing next distribution\n";
        return 1;
    }
    
    return 0;
}

sub process_prereqs {
    my ($conf, $makeargs, $getfile, $ftp, $distindex) = @_;
    my ($install_prereqs, @prereqs);
    
    for my $prereq (sort keys %{$makeargs->{PREREQ_PM}}) {
	do_verbose( $conf, 'STDERR', "--> Prerequisite $prereq not found\n" );
	my $version = $makeargs->{PREREQ_PM}{$prereq} || '0.01';
	$prereq =~ s/::/-/;
	$getfile = "$prereq-$version.tar.gz";
	next if process( $conf, '', "Fetch $getfile from CPAN? [Y/n]: ", '^n$' ); 
	fetch_prereq( $conf, $getfile, $ftp, $distindex );
	push( @prereqs, $getfile );
	$install_prereqs++;
    }
}

sub did_make_fail {
    my (@make_lines) = @_ ;
 
    for my $line (@make_lines) {
        return 'fail' if $line =~ /failed/;
    }

    return 'pass';
}

sub die_mail {
    my ($conf, @err) = @_;
    
    my $login    = getlogin;
    
    if ($conf->{VERBOSE}) {
        warn "--> @err";
        warn "--> Reporting error coincidence via mail to $login", '@localhost', "\n";
    }
    
    my $send     = '/usr/sbin/sendmail';
    my $from     = "$NAME $VERSION <$NAME\@localhost>";
    my $to	 = "$login\@localhost";
    my $subject  = "error";
    
    open( my $sendmail, "| $send -t" ) or die "Could not open | to $send: $!\n";
    
    my $selold = select( $sendmail );
    
    print <<"MAIL";
From: $from
To: $to
Subject: $subject

@err
MAIL
    close( $sendmail ) or die "Could not close | to sendmail: $!\n";
    select( $selold );
}

sub weed_out_track {
    my ($conf) = @_;
    my %file;
    
    local $" = "\n";
    
    my $trackf = read_file( $conf->{track} ) or die "Could not open $conf->{track} for reading: $!\n";
    my @track = split /\n/, $trackf;

    for (my $i = 0; $i < @track; ) {
        if ($file{$track[$i]}) {
	    splice (@track, $i, 1);
	    next;
	}
        $file{$track[$i]} = 1;
	$i++;
    }
    
    @track = sort @track;
    
    open( my $track, ">$conf->{track}" ) or die "Could not open $conf->{track} for writing: $!\n";
    print $track "@track";
    close( $track ) or die "Could not close $conf->{track}: $!\n";
}

sub run_makefile {
    my ($dist_dir) = @_;
    
    my $MAKEFILE_PL = 'Makefile.PL';
    
    -e "$dist_dir/$MAKEFILE_PL"
      ? do "$dist_dir/$MAKEFILE_PL"
      : die "No $dist_dir/$MAKEFILE_PL found\n";
}

sub get_prereqs {
    return { @_ };
}

sub process {
    my ($conf, $cmd, $prompt, $cond, $dist) = @_;
    
    if ($conf->{INTERACTIVE}) {        
        my ($input, $matched) = user_input( $conf, $cond, $cmd, $prompt );
    
        if ($matched) {
	    return 1;
	} else {
	    print `$cmd`;
	    return 0;
	}
    } 
    else {
        print "$conf->{PREFIX} $cmd\n";
	system( $cmd );
    }   
    
    die_mail( $conf, "$dist: $cmd exited on $?\n" ) if $?;    
}

sub do_verbose {
    my ($conf, $out, @err) = @_;
    
    print $out @err if ($conf->{VERBOSE} && $out && @err);
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

Upon errors, the coincidence will be reported via mail to login@localhost.

=head1 CAVEATS

=head2 System requirements

Tests on Operating systems besides Linux/UNIX aren't supported yet.

=head1 SEE ALSO

L<Test::Reporter>, L<testers.cpan.org>

=cut
