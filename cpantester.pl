#! /usr/bin/perl

use strict;
use vars qw(
    $VERSION
    $NAME
    $VERBOSE
    $INTERACTIVE
    $PROMPT
    $ftp
);
use warnings;
use File::Slurp;
use Getopt::Long;
use Net::FTP;
use Test::Reporter;



$PROMPT      = "\n#";
$INTERACTIVE = 0;
$VERBOSE     = 0;



{
    my $conf = parse_args();
    test( $conf, fetch( $conf ), read_track( $conf ) );
}

sub test {
    my ($conf, $files, $got_file) = @_;
    
    my $TRACK = \*TRACK;
    open ($TRACK, ">>$conf->{track}") or err_quit( $conf->{track}, 'o+' );

    for my $file (@{$files}) {
        next if ($got_file->{$file} || $file !~ /tar.gz$/);
      
        $ftp->get( $file, "$conf->{dir}/$file" )
          or die "Couldn't get $file: ", $ftp->message;
	  
	my $file = "$conf->{dir}/$file";
	
	my $error = 0;
	
	chdir ( "$conf->{dir}" ) or die "Couldn't cd to $conf->{dir}: $!\n";
	
	if ($INTERACTIVE) { 
	    print "$PROMPT tar xvvzf $file -C $conf->{dir}? ";
	    <STDIN>; 
	} elsif ($VERBOSE) { 
	    warn "tar xvvzf $file -C $conf->{dir}...\n" 
	}
	
    	my @tar = `tar xvvzf $file -C $conf->{dir}`;
	if ($VERBOSE) { warn @tar }
	die "Could not tar xvvzf $file -C $conf->{dir}: $?\n" if ($? != 0);
	
    	my ($dist) = $file =~ /(.*)\.tar.gz$/;
	my $dist_dir = "$conf->{dir}/$dist";
	
    	unless (chdir ( "$dist_dir" )) {
	    warn "Could not cd to $dist_dir, skipping...\n"; 
	    $error = 1; 
	}
	
	$error = 1 if (-e "$dist_dir/Build.PL" || ! -e "$dist_dir/Makefile.PL");
	
	unless ($error) {
   	    if ($INTERACTIVE) { 
	        print "$PROMPT perl Makefile.PL? ";
	        <STDIN>; 
	    }
	    my @makefile = `perl Makefile.PL`;
	    die "perl Makefile.PL exited on $?\n" if ($? != 0);
	    if ($VERBOSE) {
	        warn "perl Makefile.PL...\n" unless $INTERACTIVE;
	        warn @makefile;
	    }
	
	    for my $line (@makefile) {
	        if ($line =~ /(?:error|not found)/i) {
	            print "Prerequisites missing, skipping...\n";
		    $error = 1; last TEST;
	        }
	    }
        }
        TEST:
	
        unless ($error) {
            if ($INTERACTIVE) { 
	        print "$PROMPT make? ";
	        <STDIN>; 
	    }
	    my @make = `make`;
	    die "make exited on $?\n" if ($? != 0);
	    if ($VERBOSE) {
	        warn "make...\n" unless $INTERACTIVE;
	        warn @make;
	    }
	    
	    if ($INTERACTIVE) { 
	        print "$PROMPT make test? ";
	       <STDIN>; 
	    }
	    my @maketest = `make test`;
	    die "make test exited on $?\n" if $? != 0;
	    if ($VERBOSE) {
	        warn "make test...\n" unless $INTERACTIVE;
		warn @maketest;
	    }
	    {
	        my $reporter = Test::Reporter->new();
		
	        $reporter->debug( $VERBOSE ) if $VERBOSE;
	    
	        $reporter->from( $conf->{mail} );
	        $reporter->distribution( $dist );
		    
	        my $failed = 0;
	    
	        for my $line (@maketest) {
	            next unless $line =~ /failed/i;
		    $failed = 1;
		    last;
	        }
		 
                if ($failed) { 
		    $reporter->grade('fail');
		} else { 
		    $reporter->grade('pass');
		}
		 
                $reporter->send() or die $reporter->errstr();
            }
    	    
            if ($INTERACTIVE) { 
                print "$PROMPT make realclean? ";
                <STDIN>;
            }
            my @makerealclean = `make realclean`;
            die "make realclean exited on $?\n" if ($? != 0);
            if ($VERBOSE) {
	        warn "make realclean...\n" unless $INTERACTIVE;
                warn @makerealclean;
            }
    	    
            if ($INTERACTIVE) {
                print "$PROMPT rm -rf $dist_dir? ";
                <STDIN>;
            }
            my @rm = `rm -rf $dist_dir`;
            die "rm -rf exited on $?\n" if ($? != 0);
            if ($VERBOSE) {
	        warn "rm -rf $dist_dir...\n" unless $INTERACTIVE;
                warn @rm;
	    }
        }
	
        print $TRACK "$file\n";
    }

    close ($TRACK) or err_quit( $conf->{track}, 'c' );

    $ftp->quit;
}

sub fetch {
    my ($conf) = @_;
    
    my @err_msg = (
        "Couldn't connect to $conf->{host}:",
	"Couldn't login: ",  
        "Couldn't switch to binary mode: ",
	"Couldn't change working directory: ",
	"Couldn't get list from $conf->{rdir}: ",
    );

    $ftp = Net::FTP->new( $conf->{host}, Debug => $VERBOSE )
      or die "$err_msg[0]: $@\n";
    
    $ftp->login( 'anonymous','-anonymous@' )
      or err_quit_ftp( $err_msg[1], $ftp );
  
    $ftp->binary or err_quit_ftp( $err_msg[2], $ftp );

    $ftp->cwd( $conf->{rdir} )
      or err_quit_ftp( $err_msg[3], $ftp );
  
    my @files = $ftp->ls()
      or err_quit_ftp( $err_msg[4], $ftp );

    @files = sort @files[ 0 .. $#files ];
    
    return \@files;
}

sub read_track {
    my ($conf) = @_;
    
    my (%got_file, $TRACK);
    $TRACK = \*TRACK;
    
    open ($TRACK, $conf->{track}) or err_quit( $conf->{track}, 'o' );
    chomp (my @files = <$TRACK>);
    @got_file{ @files } = (1) x @files;
    close ($TRACK) or err_quit( $conf->{track}, 'o' );
    
    return \%got_file;
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
    
    GetOptions(\%opt, 'h', 'i', 'v', 'V') or $opt{'h'} = 1;

    if ($opt{'h'} || $opt{'V'}) {
        if ($opt{'h'}) {
            print <<"";
usage: $0 [options]
  -h            this help screen
  -i		interactive (defies -v) 
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
    $VERBOSE     = 1 if $opt{v};
    
    return \%conf;
}   

sub err_quit {
    my ($err, $mode) = @_;
    
    my %msg = (
        c    => 'Could not close ',
	o    => 'Could not open ',
	'o+' => [ 'Could not open ', ' for reading:', ],
    );
    
    if (ref $msg{$mode} eq 'ARRAY') {
        die "${$msg{$mode}}[0]$err${$msg{$mode}}[1] $!\n";
    } else {
        die "$msg{$mode}$err: $!\n";
    }
} 

sub err_quit_ftp { 
    my $ftp = splice (@_, 1, 1);
    die "@_", $ftp->message;
}

BEGIN {
    $VERSION = '0.01_02';
    $NAME = 'cpantester';
}

1;
__END__

=head1 NAME

cpantester - test CPAN contributions and submit reports to cpan-testers@perl.org

=head1 SYNOPSIS

 usage: /scripts/cpantester.pl [options]

=head1 OPTIONS
   -h            this help screen
   -i		 interactive (defies -v) 
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

L<Test::Reporter>, L<testers.cpan.org>

=cut
