#! /usr/bin/perl

use strict;
use vars qw(
    $VERSION
    $NAME
    $VERBOSE
    $INTERACTIVE
    $PROMPT
    %conf
    $ftp
);
use warnings;
use Getopt::Long;
use Net::FTP;
use Test::Reporter;


$VERSION = '0.01_00';
$NAME = 'cpantester';


$PROMPT = "\n#";
$INTERACTIVE = 0;
$VERBOSE  = 0;


parse_args();
test( fetch(), read_track() );


sub parse_args {
    $Getopt::Long::autoabbrev = 0;
    $Getopt::Long::ignorecase = 0; 
    
    my %opt;
    
    GetOptions(\%opt, 'd', 'h', 'i', 'V') or $opt{'h'} = 1;

    if ($opt{'h'} || $opt{'V'}) {
        if ($opt{'h'}) {
            print <<"";
usage: $0 [options]
  -i		interactive (defies -v) 
  -h            this help screen
  -v		verbose
  -V            version info

        }
        else {
        print <<"";
  $NAME $VERSION

        }
        exit 0;
    }

    $INTERACTIVE = 1 if $opt{i};
    $VERBOSE     = 1 if $opt{d};
    
    my $login   = getlogin;
    my $homedir = $login eq 'root' ? '/root' : "/home/$login";
    
    my $rc = "$homedir/.cpantesterrc" unless $opt{f};
    open (RC, $rc) or die "Could not open $rc for reading: $!\n";
    my @rcconf = <RC>;
    close (RC) or die "Could not close $rc: $!\n";
    
    for my $line (@rcconf) {
        chomp $line;
        my @entry = split /\s+=\s+/, $line; 
	$conf{$entry[0]} = $entry[1];
    }
}    

sub fetch {
    my @files;

    $ftp = Net::FTP->new( $conf{host}, Debug => $VERBOSE )
      or die "Couldn't connect to $conf{host}: $@";

    $ftp->login( "anonymous",'-anonymous@' )
      or die "Couldn't login: ", $ftp->message;
  
    $ftp->binary or die "Couldn't switch to binary mode: ", $ftp->message;

    $ftp->cwd( $conf{rdir} )
      or die "Couldn't change working $conf{dir}ectory: ", $ftp->message;
  
    @files = $ftp->ls()
      or die "Couldn't get list from $conf{rdir}: ", $ftp->message;

    splice (@files, 0, 2);
    @files = sort @files;
    
    return \@files;
}

sub read_track {
    my %got_file;

    open (TRACK, $conf{track}) or die "Couldn't open $conf{track} for reading: $!\n";
    while (my $file = <TRACK>) {
        chomp $file;
        $got_file{$file} = 1;
    }
    close (TRACK) or die "Couldn't close $conf{track}: $!\n";
    
    return \%got_file;
}

sub test {
    my ($files, $got_file) = @_;
    
    open (TRACK, ">>$conf{track}") or die "Couldn't open $conf{track} for writing: $!\n";

    for (my $i = 0; $i < @{$files}; ) {
        if ($files->[$i] !~ /tar.gz$/ || $got_file->{$files->[$i]}) {
            splice (@{$files}, $i, 1);
        } 
        else {
            $ftp->get( $files->[$i], "$conf{dir}/$files->[$i]" )
              or die "Couldn't get $files->[$i]: ", $ftp->message;
	
	    my $error = 0;
	
	    if ($INTERACTIVE) { 
	        print "$PROMPT tar xvvzf $conf{dir}/$files->[$i] -C $conf{dir}? ";
	        (undef) = <STDIN>; 
	    }
	    if ($VERBOSE && !$INTERACTIVE) { warn "tar xvvzf $conf{dir}/$files->[$i] -C $conf{dir}...\n" }
	
	    chdir ( "$conf{dir}" ) or die "Couldn't cd to $conf{dir}: $!\n";
	
    	    system( "tar xvvzf $files->[$i] -C $conf{dir}" );
	    die "Could not tar xvvzf $conf{dir}/$files->[$i] -C $conf{dir}: $?\n" if ($? != 0);
	
    	    my ($dist) = $files->[$i] =~ /(.*)\.tar.gz$/;
    	    unless (chdir ( "$conf{dir}/$dist" )) {
	        warn "Could not cd to $conf{dir}/$dist, skipping...\n"; 
	        $error = 1; 
	    }
	
	    $error = 1 if (-e "$conf{dir}/$dist/Build.PL" || ! -e "$conf{dir}/$dist/Makefile.PL");
	
	    unless ($error) {
   	        if ($INTERACTIVE) { 
	            print "$PROMPT perl Makefile.PL? ";
	            (undef) = <STDIN>; 
	        }
		my @makefile = `perl Makefile.PL`;
		die "perl Makefile.PL exited on $?\n" if ($? != 0);
	        if ($VERBOSE && !$INTERACTIVE) { warn "perl Makefile.PL...\n" }
		if ($VERBOSE) { warn @makefile }
	
	        for my $line (@makefile) {
	            if ($line =~ /error/i || $line =~ /not found/) {
	                $error = 1;
	                print "Prerequisites missing, skipping...\n";
		        last TEST;
	            }
	        }
	    }
	    TEST:
	
	    unless ($error) {
    	        if ($INTERACTIVE) { 
	            print "$PROMPT make? ";
		    (undef) = <STDIN>; 
	        }
		my @make = `make`;
		die "make exited on $?\n" if ($? != 0);
	        if ($VERBOSE && !$INTERACTIVE) { warn "make...\n" }
		if ($VERBOSE) { warn @make }
	    
	        if ($INTERACTIVE) { 
	            print "$PROMPT make test? ";
		    (undef) = <STDIN>; 
	        }
		my @maketest = `make test`;
		die "make test exited on $?\n" if $? != 0;
	        if ($VERBOSE && !$INTERACTIVE) { warn "make test...\n" }
		if ($VERBOSE) { warn @maketest }
	        {
	            my $reporter = Test::Reporter->new();
		
		    $reporter->debug( $VERBOSE ) if $VERBOSE;
	    
	            $reporter->from( $conf{mail} );
	            $reporter->distribution( $dist );
		    
		    my $failed = 0;
	    
	            for my $line (@maketest) {
	                if ($line =~ /failed/i) {
		            $failed = 1;
		            last;
	               }
		    }
		 
		    $failed 
		      ? $reporter->grade('fail') 
		      : $reporter->grade('pass');
		 
	            $reporter->send() or die $reporter->errstr();
	        }
    	    
	        if ($INTERACTIVE) { 
	            print "$PROMPT make realclean? ";
		    (undef) = <STDIN>;
	        }
		my @makerealclean = `make realclean`;
		die "make realclean exited on $?\n" if ($? != 0);
	        if ($VERBOSE && !$INTERACTIVE) { warn "make realclean...\n" }
		if ($VERBOSE) { warn @makerealclean }
    	    
	        if ($INTERACTIVE) {
	            print "$PROMPT rm -rf $conf{dir}/$dist? ";
	            (undef) = <STDIN>;
                }
		my @rm = `rm -rf $conf{dir}/$dist`;
		die "rm -rf exited on $?\n" if ($? != 0);
	        if ($VERBOSE && !$INTERACTIVE) { warn "rm -rf $conf{dir}/$dist...\n" }
		if ($VERBOSE) { warn @rm }
            }
	
	    print TRACK "$files->[$i]\n";
	    $i++;
        }
    }
    
    close (TRACK) or die "Couldn't close $conf{track}: $!\n";

    $ftp->quit;
}

1;
__END__

=head1 NAME

cpantester - test CPAN contributions and submit reports to cpan-testers@perl.org

=head1 SYNOPSIS

 usage: /scripts/cpantester.pl [options]

=head1 OPTIONS

   -i		 interactive (defies -v) 
   -h            this help screen
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
 host  = pause.perl.org
 rdir  = incoming/
 dir   = /home/user/cpantests
 track = track.dat
 mail  = user@host.tld (name)

=head1 CAVEATS

=head2 Prerequisites missing

It's supposed to skip them at the moment, but I doubt some
regexps are seriously broken and need further investigation.

=head2 RSS

File indexes are received by Net::FTP's ls(), though
it's my intention to make it fetch the RSS-feed.

=head1 SEE ALSO

L<Test::Reporter>

=cut
