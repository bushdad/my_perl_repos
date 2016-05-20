########################################|#######################################
$softwre = "o:\\lib\\src";
$program = "writehist";     # program name
$version = "\[version 1.0\]";           # version number
$purpose = "\nPURPOSE: copy deal(s) to latest.\n";
$company = "Trepp, LLC";           # company name, address
$address = "477 Madison Avenue 18th floor, NY, NY 10022";
$phonmbr = "(212) 754-1010";
$copyryt = "Copyright 1997-2015";
#################################################################################
# MAKING A SMALL CHANGE AS THE JOKER SRIDHAR
#********************************************************************************

# pc - 08/13/2015 Write writehist.don file to $ctldir when finished
#
#! /usr/bin/perl
#use strict;
use lib "o:\\lib\\src\\modules";
use dlq;
require "$softwre\\library.pm";
#---------------------------------------|---------------------------------------
# SET LIBRARY PATHS
# 09/22/15 PC - Added to write out don file 
&init_global_vars;
&init_paths;

my $date_time = "";
my $prgdon = "$ctldir\\writehist.don";

#$dlq::base = "m:\\ben\\nightly";
$dlq::logging = 1;
&dlq::open_files;

my %var = &dlq::export_vars;
my @deals = ();
my $sql = "
  select a.maxName from deal a, dealPostingStatus b
  where a.maxName = b.maxName and
    b.version = '4.0' and
    b.toDump = 1
  order by a.maxName
";
if ($var{db}->Sql($sql)) {
  print "Cannot get list of deal names:\n", $var{db}->Error(),
    "\nThe SQL was\n'$sql'\n";
  die;
}

while ($var{db}->FetchRow) {
  push @deals, $var{db}->Data('maxName');
}
print join "\n", @deals;

foreach $main::deal (@deals) {
  &dlq::extrafiles($main::deal);
}

my $log = &dlq::get_error();
if ($log) {
  my $host = "mail";
  my @recipients = ("Post_Monitor\@trepp.com","Post_System\@trepp.com");
  my $subject    = "DLQ and PP Discrepancies";
  my $sender     = "libload\@trepp.com";
  require "i:\\utility\\dbtools\\rbs-email.pl";
  $log = "Posting Errors\n\nDeal,distribDt,Problem,Diff,Field1,Field2\n$log";
  &send_mail($host,$log,$sender,$subject,@recipients);
  print $log;
}


unlink $prgdon if -f $prgdon;   # remove done file if it exists
#---------------------------------------|---------------------------------------
# CREATE DONE FILE
 
$date_time = &date_time;    # get date/time
open (DON,">$prgdon");      # open done for overwrite
print DON $date_time;     # write done
close (DON);        # close done