#! /usr/bin/perl
use Win32::ODBC;
use strict;
use lib "o:\\lib\\src\\modules";
use lib "/NT/o/lib/src/modules";
use date_routines;
package dlq;
use vars qw(
    $base  $dir_sep  $distribDt  $distribDtPrev  $figure
    $loan  $log_dir $logging  $no_dealFiles  $prepayFigure
    $report  $report_append  $report_dir %bypass_checks
    $curDistrib
);

$| = 1;

$curDistrib = &main::yyyymmdd;

# BAD BAD BAD
# Special structure to hold deals or deal/month combos that bypass checks.
$bypass_checks{DLJ00STF}{ALL} = 1;

# Flag to turn off dropping dlq, pp files
$no_dealFiles ||= 0;

# What directory to log to if you are logging
$log_dir ||= ".";

my $logMsg = "";
my $db = new Win32::ODBC("DSN=TREPP;UID=treppdbuser;PWD=treppdbuser");

my %statusMap = (
    '1' => '30 Day', '2' => '60 Day', '3' => '90 Day', '4' => 'Balloon',
    '5' => 'Non Perf Balloon',
    '7' => 'Foreclosure', '8' => '90 Day', '9' => 'REO',
    '101' => 'Enforcement', '102' => 'Possession'
);
# Original delinquency
my @statusFigures = (
    'Total', '30 Day', '60 Day', '90 Day', 'Foreclosure', 'REO', 'Balloon'
);
# Additional delinquency
my @extraStatusFigures = (
  'Performing with Special Servicer', 'Specially Serviced','Non Perf Balloon',
  'Enforcement', 'Possession'
);
my %prepayMap = (
    '1' => 'Curtailment', '2' => 'Payoff Prior to Maturity',
    '3' => 'Disposition', '4' => 'Repurchase',
    '5' => 'Full Payoff At Maturity', '6' => 'DPO', '7' => 'Liquidation',
    '???' => 'Unknown'
);
# Original prepay
my @prepayFigures = (
    'Curtailment','Payoff Prior to Maturity', 'Disposition', 'Repurchase',
    'Full Payoff At Maturity', 'DPO', 'Liquidation', 'Unknown'
);
# AdditionalPrepay
my @extraPrepayFigures;

# Defaults, feel free to modify
if ($^O eq "linux") {
    $base ||= "/NT/o/lib/post/bloombergAdd";
    $report_dir ||= "/NT/m/Delinquencies";
    $dir_sep ||= "/";
}
else {
    $base ||= "o:\\lib\\post\\bloombergAdd";
    $report_dir ||= "m:\\delinquencies";
#    $base ||= "h:\\John\\temp\\his";
#    $report_dir ||= "h:\\John\\temp\\his";    
    $dir_sep ||= "\\";
}

&open_files; # Note, by default does nothing, can be called later

1;

#  End of initialization code, the rest are specific functions

sub export_vars {
    return ('db', $db, 'curDistrib', $curDistrib);
}

sub extrafiles {
     my $deal = uc shift;
     my $componentflag = 0;
     my $sql = qq/
         select bloombergName
         from deal
         where maxName = '$deal' and
       bloombergName is not null
     /;
     if ($db->Sql($sql)) {
         my @msg = (
            "The Bloomberg name for '$deal' cannot be selected:\n",
            $db->Error(),
            "\nThe SQL was\n'$sql'\n"
         );
         print @msg;
         print PROBLEMS @msg if $logging;
         sleep 1;
         print SKIPPED "$deal\n" if $logging;
         return;
     }
     unless ($db->FetchRow) {
         my $msg = "No bloombergName was found for deal $deal.\n";
         print $msg;
         print PROBLEMS $msg if $logging;
         sleep 1;
         print SKIPPED "$deal\n" if $logging;
         return;
     }
     my ($ticker) = $db->Data('bloombergName');
     $sql = "
         select c.distribDt,
             c.statusCode,
             c.schBal as bal,
             c.prepayPrin,
             c.prepayCode,
             c.prevSchBal,
             b.loanID,
             b.subLoan,
             c.specServTransDt,
             c.masterServReturnDt,
             d.poolNum as trusteeID,
             c.schedPmt,
             c.servPIAdvance,
             c.paidToDt,
             c.foreclosureDt,
             c.bankruptcyDt,
             c.reoDt,
             c.prepayYMC,
             d.propName,
             c.statusCodeDerived
             from deal a join loan b
             on a.dealID = b.dealID
             join loanHistory c
             on b.loanID = c.loanID
             join loanFileData d
             on b.loanID = d.loanID
             where a.maxName = '$deal'
             and (c.schBal <> 0 or c.prevSchBal<> 0) 
             and 0 < isnull(b.subLoan,1)
              
     ";
# remove 'and c.distribDt <= $curDistrib ' from above query where clause     
     if ($db->Sql($sql)) {
         print
           "Deal '$deal' cannot be selected:\n",
           $db->Error(),
           "\nThe SQL was\n'$sql'\n"
         ;
         if ($logging) {
           print PROBLEMS
             "Deal '$deal' cannot be selected:\n",
             $db->Error(),
             "\nThe SQL was\n'$sql'\n"
           ;
         }
         sleep 1;
         print SKIPPED "$deal\n" if $logging;
         return;
     }
     my %data = ();
     my %count = ();
     my $testMonth = &get_test_month($curDistrib);
     while ($db->FetchRow) {   # Get the data
       my (
         $distribDt, $cmsaStatusCode, $bal, $prepayPrin, $prepayCode,$prevBal,
         $loanID, $subLoan, $specServTransDt, $masterServReturnDt,
         $trusteeID, $schedPmt, $servPIAdvance, $paidToDt, $foreclosureDt,
         $bankruptcyDt, $reoDt, $prepayYMC, $propName, $statusCodeDerived
       ) = $db->Data(
         'distribDt', 'statusCode', 'bal', 'prepayPrin', 'prepayCode',
         'prevSchBal', 'loanID', 'subLoan', 'specServTransDt',
         'masterServReturnDt', 'trusteeID', 'schedPmt', 'servPIAdvance',
         'paidToDt', 'foreclosureDt', 'bankruptcyDt', 'reoDt',
         'prepayYMC', 'propName','statusCodeDerived'
       );
       my $statusCode;
       #if ( $distribDt > 20080500 ) {
       #  print "$loanID:$distribDt:$statusCode:$statusCodeDerived:$cmsaStatusCode:\n";
       #  <STDIN>;
       #}
       $statusCode = $statusCodeDerived ? $statusCodeDerived : $cmsaStatusCode;
         # print "Received $loanID for $distribDt\n";
         $componentflag = 1 if $subLoan;   # Set component flag
         unless (exists $data{$distribDt}) {
             # Initialize
             foreach $figure (
               @statusFigures, @prepayFigures, "prevTotal", "nulls",
               @extraStatusFigures
              
             ) {
                 $data{$distribDt}{$figure} = 0;
                 $count{$distribDt}{$figure} = 0;
             }
         }
         $data{$distribDt}{Total} += $bal;
         $data{$distribDt}{prevTotal} += $prevBal;
         $count{$distribDt}{Total}++ if $bal;  # Only count loans with payments
         $count{$distribDt}{prevTotal}++ if $prevBal;
         $count{$distribDt}{nulls}++ unless length($statusCode);
         if ($specServTransDt and $masterServReturnDt) {
             if ($masterServReturnDt > $specServTransDt) {
                 $specServTransDt = 0;
             }
         }

         # Some minor fixes to display of data
         $propName ||= " ";
         $trusteeID =~ s/^-//;
         unless (length($trusteeID)) {
             $trusteeID = "-";
         }
         $propName =~ s/"\n//g; #" Just in case
         if (0.015 < $bal and 19000101 < $specServTransDt and ((not defined($masterServReturnDt)) or ($masterServReturnDt < $specServTransDt))) {
             $data{$distribDt}{'Specially Serviced'} += $bal;
             $count{$distribDt}{'Specially Serviced'}++;
             if ($report and ($testMonth < $distribDt)) {
#                 print "$ticker,$deal,$trusteeID,$distribDt,delinquent,$loanID,$bal,$servPIAdvance,Specially Serviced\n";
                 print REPORT "$ticker,$deal,$trusteeID,$distribDt,delinquent,$loanID,$bal,$servPIAdvance,Specially Serviced\n";
             }
         }
         
         if ($statusCode == 5 and $distribDt < 19991200) {
           # this block introduced on 04/12/2003 - LS
           # the status code of 5 was used earlier for other reasons - see Wiki
               ;
         }elsif (exists $statusMap{$statusCode} and 0.015 < $bal) {
             $data{$distribDt}{$statusMap{$statusCode}} += $bal;
             $count{$distribDt}{$statusMap{$statusCode}}++;
             if ($report and ($testMonth < $distribDt)) {
#                 print "$ticker,$deal,$trusteeID,$distribDt,delinquent,$loanID,$bal,$servPIAdvance,$statusMap{$statusCode}\n";
                 print REPORT "$ticker,$deal,$trusteeID,$distribDt,delinquent,$loanID,$bal,$servPIAdvance,$statusMap{$statusCode}\n";
             }
         }
         elsif ($statusCode =~ /0|A|B/ and 0.015 < $bal) {
             if (19000101 < $specServTransDt and ((not defined($masterServReturnDt)) or ($masterServReturnDt < $specServTransDt))) {
                 $data{$distribDt}{'Performing with Special Servicer'} += $bal;
                 $count{$distribDt}{'Performing with Special Servicer'}++;
                 if ($report and ($testMonth < $distribDt)) {
#                     print "$ticker,$deal,$trusteeID,$distribDt,delinquent,$loanID,$bal,$servPIAdvance,Performing with Special Servicer\n";
                     print REPORT "$ticker,$deal,$trusteeID,$distribDt,delinquent,$loanID,$bal,$servPIAdvance,Performing with Special Servicer\n";
                 }
             }
         }
         if ($statusCode == 5 && $distribDt < 19991200) {  ## && $distribDt < 19991200 ? 
             $prepayCode = '2';
             # print "Assignment\n";
         }
         elsif (not exists $prepayMap{$prepayCode}) {
             $prepayCode = '???';
         }
         # print "Code $prepayCode, map $prepayMap{$prepayCode}\n";
         if (0.05 < $prepayPrin) {
             # print "Code $prepayCode, map $prepayMap{$prepayCode}\n";
             $data{$distribDt}{$prepayMap{$prepayCode}} += $prepayPrin;
             $count{$distribDt}{$prepayMap{$prepayCode}}++;
             if ($report and ($testMonth < $distribDt)) {
                 my $line =  "$ticker,$deal,$trusteeID,$distribDt,prepay,$loanID,$prepayPrin,$prepayYMC,$prepayMap{$prepayCode}\n";
#                 print $line;
                 print REPORT $line;
             }
         }
     }
     # Breakout here if we don't want individual deal files
     if ($no_dealFiles) {
         next;
     }
     else {
         print "\n\n\nGenerating dlq and prepay files for deal '$deal' ($ticker)\n";
     }

     my @dates = sort {$a <=> $b} keys %data;
     unless (scalar @dates) {
         print "Deal '$deal' has no status data in loanHistory\n";
         print SKIPPED "$deal\n" if $logging;
         return;
     }
     my $dealname = lc $deal;
     my @delinq = ();
     my @prepay = ();
     my $prevTotal = 0;
     my $prevCount = 0;
     foreach $distribDt (@dates) {

         # Save a space-delimited row of data to print later in each file
         # Note the use of unshift to put them at the beginning, so we run
         # through them backwards, and print them forwards
         my @line = ($distribDt, map {$data{$distribDt}{$_}} @statusFigures);
         push @line,  (map {$count{$distribDt}{$_}} @statusFigures);
         # Add the extras
         push @line, map {($data{$distribDt}{$_}, $count{$distribDt}{$_})} @extraStatusFigures;
         unshift @delinq, (join ' ', @line);
         @line = ($distribDt, map {$data{$distribDt}{$_}} 'Total', @prepayFigures);
         push @line,  (map {$count{$distribDt}{$_}} 'Total', @prepayFigures);
         # Add the extras
         push @line, map {($data{$distribDt}{$_}, $count{$distribDt}{$_})} @extraPrepayFigures;
         unshift @prepay, (join ' ', @line);

         ####################
         # ERROR LOGIC HERE #
         ####################
         if ( $bypass_checks{$deal}{ALL} or $bypass_checks{$deal}{$distribDt}) {
             print "Skipping error checks for deal $deal, period $distribDt\n";
             print PROBLEMS "Skipping error checks for deal $deal, period $distribDt\n";
             print BAD "$deal,$distribDt,Avoiding error checks,,\n";
             $logMsg .= "$deal,$distribDt,Avoiding error checks,,\n";
         }
         else {
             if (5 < $count{$distribDt}{nulls}) {
                 # Throw away this month and all previous
                 @delinq = ();
                 @prepay = ();
                 #next;
                 print "Skipping $distribDt from $deal ($count{$distribDt}{nulls}) nulls)\n";
             }
             elsif ($count{$distribDt}{Total} < $count{$distribDt}{nulls} + $count{$distribDt}{nulls} )  {
                 # Throw away this month and all previous
                 @delinq = ();
                 @prepay = ();
                 #next;
                 print "Skipping $distribDt from $deal ($count{$distribDt}{nulls}) nulls)\n";
             }
             elsif ($count{$distribDt}{nulls}) {
                 print PROBLEMS "$deal for $distribDt had $count{$distribDt}{nulls} nulls\n\n" if $logging;
                 print BAD "$deal,$distribDt,Nulls,$count{$distribDt}{nulls},,\n" if $logging;
                 $logMsg .= "$deal,$distribDt,Nulls,$count{$distribDt}{nulls},,\n";
                 print "$deal at $distribDt had $count{$distribDt}{nulls} nulls!\n";
             }
             if ($prevTotal) {  # If not the first distribDt
                 # Do sanity checks
                 if (($distribDtPrev != $distribDt - 100) and ($distribDtPrev != $distribDt - 8900)) {
                     print BAD "$deal,$distribDt,Prev distribDt not 1 month prev,$distribDtPrev,,\n" if $logging;
                     $logMsg .= "$deal,$distribDt,Prev distribDt not 1 month prev,$distribDtPrev,,\n";
                     print "$deal jumped from $distribDtPrev to $distribDt?\n";
                     print PROBLEMS "$deal jumped from $distribDtPrev to $distribDt?\n" if $logging;
                 }
                 if ($prevTotal != $data{$distribDt}{prevTotal}) {
                     print PROBLEMS (
                               "$deal for $distribDt had previous total ".
                               "$data{$distribDt}{prevTotal}\n".
                               "\tThe total previously calculated was $prevTotal.\n".
                               "\t(Difference: ", $data{$distribDt}{prevTotal} - $prevTotal, ")\n\n"
                           ) if $logging;
                     print BAD (
                                "$deal,$distribDt,prevTotal != total Prev,",
                                $data{$distribDt}{prevTotal} - $prevTotal,
                                ",$prevTotal,$data{$distribDt}{prevTotal}\n"
                           ) if $logging;
                 }
                 if ($prevCount < $count{$distribDt}{prevTotal}) { # Oops
                     print PROBLEMS "$deal for $distribDt had more deals with a prevSchBal than previously had a schBal!\n" if $logging;
                     print "$deal for $distribDt had more deals with a prevSchBal than previously had a schBal!\n";
                     print BAD (
                               "$deal,$distribDt,count(schBal) prev != count(prevSchBal),",
                               $prevCount - $count{$distribDt}{prevTotal},
                               ",$prevCount,$count{$distribDt}{prevTotal}\n"
                           ) if $logging;
                     $logMsg .= "$deal,$distribDt,count(schBal) prev != count(prevSchBal),".
                                ($prevCount - $count{$distribDt}{prevTotal}) .
                                ",$prevCount,$count{$distribDt}{prevTotal}\n";
                     @prepay = ();
                 }
                 if (($prevCount + 5 )  < $count{$distribDt}{Total}) {
                     # Changed logic in IF above based on disc w Julie 20110727
                     # - will trigger this block only if period loan cnt is more than 5 loans from prev total - to take care of increases due to loan splits.
                     print PROBLEMS "$deal for $distribDt had $count{$distribDt}{Total} loans, up from $prevCount.\n\n";
                     print BAD "$deal,$distribDt,count(loans) prev < count(loans),",
                                $prevCount - $count{$distribDt}{Total},
                                ",$prevCount,$count{$distribDt}{Total}\n";
                     $logMsg .= "$deal,$distribDt,count(loans) prev < count(loans)," .
                                 ($prevCount - $count{$distribDt}{Total}) .
                                 ",$prevCount,$count{$distribDt}{Total}\n";
                     # Clear the print for both
                     @delinq = (); # retain this check
                     @prepay = (); # retain this check
                 }
                 my $lowerBound = $data{$distribDt}{Total};  # Calculate a lower bound
                 foreach $prepayFigure (@prepayFigures) {
                     $lowerBound += $data{$distribDt}{$prepayFigure};
                 }
                 if ($prevTotal < $lowerBound) { # Oops!
                     print PROBLEMS "$deal for $distribDt had prepays+current balance sum to\n".
                                    "\t$lowerBound > $prevTotal (previous total)\n";
                     print BAD "$deal,$distribDt,previous total < prepays + current balance,",
                               $prevTotal - $lowerBound, ",$prevTotal,$lowerBound\n";
                     $logMsg .= "$deal,$distribDt,previous total < prepays + current balance,".
                                ($prevTotal - $lowerBound) .",$prevTotal,$lowerBound\n";
                     # Clear prepay report
                     #@prepay = (); # allow prepay report generation SAN MYINT
                     # Check for delinq problem
                     if ($prevTotal < $data{$distribDt}{Total}) { # Double oops!
                         print PROBLEMS "Even this month's total $data{$distribDt}{Total} is too big!\n\n";
                         print BAD "$deal,$distribDt,previous total < current total,",
                                   $prevTotal - $data{$distribDt}{Total},
                                   ",$prevTotal,$data{$distribDt}{Total}\n";
                         $logMsg .= "$deal,$distribDt,previous total < current total,".
                                   ($prevTotal - $data{$distribDt}{Total}) .
                                   ",$prevTotal,$data{$distribDt}{Total}\n";
                         # Clear delinq
                         #@delinq = (); # allow delinq file generation  SAN MYINT
                         # However, retaining the error ( warning ) mail
                     }
                     else {
                         print PROBLEMS "\n";
                     }
                 }
             }
         }
   # Reset statistics
         $prevTotal =  $data{$distribDt}{prevTotal};
         $prevCount = $count{$distribDt}{Total};
         $distribDtPrev = $distribDt;
     }
     if (scalar @delinq) {
         print "Writing delinquency file\n";
         &open_for_write(*DELINQ, "$base$dir_sep$dealname.dlq");
         print DELINQ "/*", (join ", ", "Distribution date",
                            @statusFigures,
          (
             map {
                "$_ (count)"
              } @statusFigures
          ),
                            map {
              "$_,$_ (count)"
          } @extraStatusFigures), "*/\n";
         print DELINQ "Flag Components\n" if $componentflag;
         print DELINQ map {"$_\n"} @delinq;
         close DELINQ;

     }
     elsif (-e "$base$dir_sep$dealname.dlq") {
         # Need to overwrite with a blank file  '
         print "Clearing delinquency file:\n" or print "Cannot write file: $!\n";
         &open_for_write(*DELINQ, "$base$dir_sep$dealname.dlq");
         print DELINQ "/*",
             (
          join ", ", "Distribution date",
                @statusFigures,
          (
              map {
            "$_ (count)"
        } @statusFigures
          ),
          map {
              "$_,$_ (count)"
          } @extraStatusFigures
       ), 
       "*/\n";
         close DELINQ;
     }
     if (scalar @prepay) {
         print "Writing prepay file:\n";
         &open_for_write(*PREPAY, "$base$dir_sep$dealname.pp");
         print PREPAY "/*",
            (
          join ", ", 
               "Distribution date", 
         'Total', 
         @prepayFigures, 
         (
             map {
                 "$_ (count)"
             } 'Total', @prepayFigures
         ),
         map {
             "$_,$_ (count)"
         } @extraPrepayFigures
            ), 
      "*/\n";
         print PREPAY "Flag Components\n" if $componentflag;
         print PREPAY map {"$_\n"} @prepay;
         close PREPAY;
     }
     elsif (-e "$base$dir_sep$dealname.pp") {
         # Need to overwrite with a blank file
         print "Clearing prepay file:\n" or print "Cannot write file: $!\n";
         &open_for_write(*PREPAY, "$base$dir_sep$dealname.pp");
         print PREPAY "/*",
           (
         join ", ", 
              "Distribution date", 
        'Total', 
        @prepayFigures, 
        (
            map {
                "$_ (count)"
            } 'Total', @prepayFigures
        ), 
        map {
            "$_,$_ (count)"
        } @extraPrepayFigures
     ), 
     "*/\n";
         close PREPAY;
     }
}

sub get_error {
    return $logMsg;
}

# This takes the distrib date and returns a test-value in yyyymmdd that can
# be used to locate dates within that current month and 2 months previous
sub get_test_month {
    my $distrib = shift;
    my ($yyyy, $mm, $dd) = ($distrib =~ /(\d{4})(\d\d)(\d\d)/);
    # Deal with year wrap
    if ($mm < 3) {
        $mm += 12;
        $yyyy--;
    }
    $mm -= 2;
    $dd = 0;
    return 10000*$yyyy + 100*$mm + $dd;
}

sub open_files {

    if ($logging) {
        &open_for_write(*SKIPPED, "$log_dir${dir_sep}skipped.txt");
        &open_for_write(*PROBLEMS, "$log_dir${dir_sep}trouble.txt");
        &open_for_write(*BAD, "$log_dir${dir_sep}bad.csv");
        print BAD "Deal,distribDt,Problem,Diff,Field1,Field2\n";
    }

    if ($report) {
        if ($report_append) {
            &open_for_write(*REPORT, ">$report_dir$dir_sep$curDistrib.csv");
        }
        else {
            &open_for_write(*REPORT, "$report_dir$dir_sep$curDistrib.csv");
        }
    }
}

# Takes a glob and a filename, and opens that file for writing
sub open_for_write {
    local *FH = shift;
    my $file = shift;
    unless (open(FH, ">$file")) {
        # Notify everyone you can, but don't die.  We may have more
        # work to do.
        my $msg = "Cannot open $file for writing: $!\n";
        if ($logging) {
            print SKIPPED $msg;
            print BAD $msg;
        }
        $logMsg .= $msg;
    }
}
