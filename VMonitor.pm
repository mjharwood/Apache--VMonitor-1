package Apache::VMonitor;

$Apache::VMonitor::VERSION = '0.8';

use strict;

use Apache::Util ();
use Apache::Scoreboard ();
use Apache::Constants qw(OK);
use GTop ();
use Time::HiRes ();


#@Apache::VMonitor::shortflags = qw(. S _ R W K L D G N);
@Apache::VMonitor::longflags = ("Open slot with no current process",
				"Starting up",
				"Waiting for Connection",
				"Reading Request",
				"Sending Reply",
				"Keepalive (read)",
				"Logging",
				"DNS Lookup",
				"Gracefully finishing",
				"None",
			       );

use constant KBYTE =>       1024;
use constant MBYTE =>    1048576;
use constant GBYTE => 1073741824;

########################
# default config values
########################
%Apache::VMonitor::Config =
  (
     # behavior
   BLINKING => 1,
   REFRESH  => 0,
   VERBOSE  => 0,
     # sections to show
   SYSTEM   => 1,
   APACHE   => 1,
   PROCS    => 0,
   MOUNT    => 0,
   FS_USAGE => 1,
   SORT_BY  => 'size',
  );

$Apache::VMonitor::PROC_REGEX = '';

my $url    = '';
my %config = ();
my $gtop   = GTop->new;

#use Data::Dumper;

############
sub handler{
  my $r = shift;
  my %params = $r->args;

    # modify the default args if requested
  map { $config{$_} = $Apache::VMonitor::Config{$_};       # first the defaults
	$config{$_} = $params{$_} if defined $params{$_};  # second the dynamic config
      } keys %Apache::VMonitor::Config;

  my $pid = $params{pid} || 0;

    # build the updated URL (append the pid k/v pair)
  $url = $r->uri."?pid=$pid&".
      join "&", map {"$_=$config{$_}"} keys %config;

    # if the refresh is non-null, set the refresh header
  $r->header_out(Refresh => "$config{REFRESH}; URL=$url") 
      if $config{REFRESH};

  $r->send_http_header('text/html');

  start_html();

  if ($pid) {
    print_single($pid);
  } else {
    print_top();
    choice_bar();
    verbose();
  }

  end_html();

  return OK;

} # end of sub handler


# the html header and refresh bar
###############
sub start_html{

  print qq{<HTML>
	   <HEAD>
	   <TITLE>Apache::VMonitor</TITLE>
	   </HEAD>
	   <BODY BGCOLOR="white">
	  };

  print
    "&nbsp;" x 10,
    qq{<B><FONT SIZE=+1 COLOR="#339966">Apache::VMonitor</FONT></B>},
    "&nbsp;" x 10,
    "<B>Refresh rate:</B> ",
    join "&nbsp;&nbsp;",
    map
      {
	$config{REFRESH} == $_
	  ? qq{[<B><FONT SIZE=+1> $_ </FONT></B>]}
	  : qq{<A HREF="@{[get_url(REFRESH => $_)]}"><B>[ $_ ]</B></A>};
      }
	qw(0 1 5 10 20 30 60);

} # end of start_html

##############
sub print_top{

  print "<PRE><HR><FONT SIZE=-1>";

  if ($config{SYSTEM}) {

    ########################
    # uptime and etc...
    #######################
    my $loadavg = $gtop->loadavg;
    printf "<B>%d/%.2d/%d %d:%.2d%s   up %s, load average: %.2f %.2f %.2f",
        map ({($_->[1]+1,$_->[0],$_->[2]+1900)}[(localtime)[3,4,5]]),
        map ({$_->[1] > 11 ? ($_->[1]%12,$_->[0],"pm") : ($_->[1],$_->[0],"am") } 
             [(localtime)[1,2]]),
        format_time($gtop->uptime()->uptime()),
        @{$loadavg->loadavg};

      # linux specific info
    if ($^O eq 'linux'){
        printf ", %d processes/threads: %d running</B>\n",
            $loadavg->nr_tasks,
            $loadavg->nr_running;
    } else {
        print "</B>\n";
    }

    #######################
    # total CPU stats
    #######################
    my $cpu   = $gtop->cpu;
    my $total = $cpu->total;
    printf "<B>CPU:   %2.1f%% user, %2.1f%% nice, %2.1f%% sys, %2.1f%% idle</B>\n",
        map {$total ? ($cpu->$_() * 100 / $total) : 0 } qw(user nice sys idle);

    #######################
    # total mem stats
    #######################
    my $mem = $gtop->mem;
    printf "<B>Mem:  %5s av, %5s used, %5s free, %5s shared, %5s buff</B>\n",
        map {Apache::Util::size_string($mem->$_())} qw(total used free shared buffer);

    #######################
    # total swap stats
    #######################
    # visual alert on swap usage:
    # 1) 5Mb < swap < 10 MB             color: light red
    # 2) 20% < swap (swapping is bad!)  color: red
    # 3) 70% < swap (swap almost used!) color: red + blinking

    my $swap = $gtop->swap();
    my $format = qq{%5s av, %5s used, %5s free, %5s pagein, %5s pageout};

    my $swap_total = $swap->total;
    my $swap_used  = $swap->used;
    my $swap_usage = $swap_total ? ($swap_used * 100 / $swap_total) : 0;

    # choose format color according to swap occupation
    if (5000 < $swap_used and $swap_used < 10000) {
      $format = qq{<B>Swap: <FONT COLOR="#FF99CC">$format</FONT></B>\n};
    } elsif ($swap_usage > 20) {
      $format = qq{<B>Swap: <FONT COLOR="#FF0000">$format</FONT></B>\n};
    } elsif ($swap_usage > 70) {
      # swap on fire!
      $format = qq{<B>@{[blinking("Swap:")]} <FONT COLOR="#FF0000">$format</FONT></B>\n};
    } else {
      $format = qq{<B>Swap: $format</B>\n};
    }

    printf $format,
      Apache::Util::size_string($swap_total),
      Apache::Util::size_string($swap_used),
      Apache::Util::size_string($swap->free),
      format_counts($swap->pagein),
      format_counts($swap->pageout);

    print "<HR>";

  } # end of if ($config{SYSTEM})


  if ($config{APACHE}){
    #############################################
    # mem usage and other stats per httpd process
    #############################################

    my $image = Apache::Scoreboard->image;

      # init the stats hash
    my %total = map {$_ => 0} qw(size real max_shared);

      # calculate the max_length of the process - note that we cannot
      # just make this field "%6s" because of the HTML with hyperlink
      # that has to be stuffed in.
    my $max_pid_len = 0;
    for (my $i=-1; $i<Apache::Constants::HARD_SERVER_LIMIT; $i++) {
      my $pid = ($i==-1) ? getppid() : $image->parent($i)->pid;
      last unless $pid;
      my $length = length $pid;
      $max_pid_len = $length if $length > $max_pid_len;
    }

#    printf "<B> ##  %${max_pid_len}s %s %7s %7s %4s %5s %5s %5s %5s %12s %27s</B>\n", 
#      qw(PID M Elapsed LastReq Srvd Size Share VSize Rss Client), "Request (first 64 chars)";

    my %cols = (
                     # WIDTH       # LABEL                   # SORT
          pid     => [$max_pid_len,'PID'                     ,'d'],
          mode    => [           1,'M'                       ,'s'],
          elapsed => [           7,'Elapsed'                 ,'d'],
          lastreq => [           7,'LastReq'                 ,'d'],
          served  => [           4,'Srvd'                    ,'d'],
          size    => [           5,'Size'                    ,'d'],
          share   => [           5,'Share'                   ,'d'],
          vsize   => [           5,'VSize'                   ,'d'],
          rss     => [           5,'Rss'                     ,'d'],
          client  => [          12,'Client'                  ,'s'],
          request => [          27,'Request (first 64 chars)','s'],
                   );

    my @cols = qw(pid mode elapsed lastreq served size share vsize rss
                  client request);

    print "<B> ## ";
    for (@cols) {
        my $spacing  = "&nbsp;" x ($cols{$_}[0]-length $cols{$_}[1]);
        print qq{ $spacing<A HREF="@{[get_url(SORT_BY => $_)]}">$cols{$_}[1]</A>};
    }
    print "</B>\n";

    my $parent_format = "par: %${max_pid_len}s %1s %7s %7s %4s %5s %5s %5s %5s\n\n";
    my $child_format  = "%3d: %${max_pid_len}s %1s %7s %7s %4s %5s %5s %5s %5s %15.15s %.64s \n";	
    my %data = ();
    for (my $i=-1; $i<Apache::Constants::HARD_SERVER_LIMIT; $i++) {
        # handle the parent case
        my $pid = ($i==-1) ? getppid() : $image->parent($i)->pid;
        last unless $pid;
        my $proc_mem  = $gtop->proc_mem($pid);
        my $size      = $proc_mem->size($pid);

        # workarond for Apache::Scoreboard (or underlying C code) bug,
        # it reports processes that are already dead. So we easily
        # skip them, since their size is zero!
        next unless $size;

        my $share = $proc_mem->share($pid);
        my $vsize = $proc_mem->vsize($pid);
        my $rss   = $proc_mem->rss($pid);

        #  total http size update
        $total{size}  += $size;
        $total{real}  += $size-$share;
        $total{max_shared} = $share if $total{max_shared} < $share;

        my $process = $image->servers($i);

        # get absolute start and stop times in usecs since epoch
        my ($start_sec,$start_usec_delta) = $process->start_time;
        my $start_usec = $start_sec*1000000+$start_usec_delta;

        my ($stop_sec, $stop_usec_delta) =  $process->stop_time;
        my $stop_usec = $stop_sec*1000000+$stop_usec_delta;

        # measure running time till now if not idle
        my $elapsed = $stop_usec < $start_usec
            ? Time::HiRes::tv_interval
                ([$start_sec,$start_usec_delta], [Time::HiRes::gettimeofday])
            : 0;

        # link the pid
        my $length   = length $pid;
        my $stuffing = $max_pid_len - $length;
        my $spacing  = "&nbsp;" x $stuffing;
        my $pid_linked = qq{$spacing<A HREF="@{[get_url(pid => $pid)]}">$pid</A>};

        # handle the parent case
        if ($i == -1) {
            printf $parent_format,
                $pid_linked,
                $process->status,
                '',
                '',
                '',
                Apache::Util::size_string($size),
                Apache::Util::size_string($share),
                Apache::Util::size_string($vsize),
                Apache::Util::size_string($rss);
        } else {
            $data{$pid} =
                {
                 pid        => $pid,
                 pid_linked => $pid_linked,
                 mode       => $process->status,
                 elapsed    => $elapsed,
                 lastreq    => $process->req_time,
                 served     => $process->my_access_count,
                 size       => $size,
                 share      => $share,
                 vsize      => $vsize,
                 rss        => $rss,
                 client     => $process->client,
                 request    => $process->request,
                };
        }
    } # end of for (my $i=0...

    # print the httpd processes sorted 
    my $sort_field = $config{SORT_BY} || 'size';
    $sort_field = 'size' unless $cols{$sort_field};
    my $count = 0;

#use Data::Dumper;
#warn "sort field: $sort_field";
#warn Dumper $cols{$sort_field};
    # sort strings alphabetically, numbers numerically reversed
    for ($cols{$sort_field}[2] eq 's' 
         ? (sort {$data{$a}{$sort_field} cmp $data{$b}{$sort_field} } keys %data)
         : (sort {$data{$b}{$sort_field} <=> $data{$a}{$sort_field} } keys %data)
        ) {
        my $rec = $data{$_};

	# setting visual alert for cur_req_elapsed_run hardcoded to 15
	# secs so far
        my $elapsed = $rec->{elapsed};
        $elapsed = $elapsed > 15
            ? blinking(sprintf qq{<B><FONT color="red">%7s</FONT></B>},
                       format_time($elapsed))
            : format_time($elapsed);

	# setting visual alert for last_req_len hardcoded to 15secs so
	# far
        my $req_time = $rec->{lastreq}/1000;
        $req_time = $req_time > 15
            ? sprintf qq{<B><FONT color="red">%7s</FONT></B>},
                format_time($req_time)
            : format_time($req_time);

        # print sorted
	printf $child_format,
            ++$count,
            $rec->{pid_linked},
            $rec->{mode},
            $elapsed,
            $req_time,
            format_counts($rec->{served}),
            Apache::Util::size_string($rec->{size}),
            Apache::Util::size_string($rec->{share}),
            Apache::Util::size_string($rec->{vsize}),
            Apache::Util::size_string($rec->{rss}),
            $rec->{client},
            $rec->{request};
    }

    ### Summary of memory usage
    printf "\n<B>Total:     %5dK (%s) size, %6dK (%s) approx real size (-shared)</B>\n",
      $total{size}/1000,
      Apache::Util::size_string($total{size}), 
      ($total{real} + $total{max_shared})/1000,
      Apache::Util::size_string($total{real} + $total{max_shared});

    #  Note how do I calculate the approximate real usage of the memory:
    #  1. For each process sum up the difference between shared and system
    #  memory 2. Now if we add the share size of the process with maximum
    #  shared memory, we will get all the memory that actually is being
    #  used by all httpd processes but the parent process.

    print "<HR>";

  } # end of if ($config{TOP})


  #########################
  # non-mod_perl processes
  #########################
  if ($config{PROCS}) {
    print_other_procs();
  } # end of if ($config{PROCS})


  #######################
  # filesystem usage
  #######################
  if ($config{FS_USAGE}) {
    #    print "<B>df:</B>\n";

    my($mountlist, $entries) = $gtop->mountlist(1);
    my $fs_number = $mountlist->number;

      # for formatting purpose find out the max length of the filesystems
    my $max_fs_name_len = 0;
    my %fs = ();
    for (my $i = 0; $i < $fs_number; $i++) {
      my $path = $entries->mountdir($i);
      $fs{$path} = $i;
      my $len = length $path;
      $max_fs_name_len = $len if $len > $max_fs_name_len;
    }

    $max_fs_name_len = 12 if $max_fs_name_len < 12;
      # the header
    printf "<B>%-@{[${max_fs_name_len}-4]}s %14s %9s %9s %3s %12s %7s %5s</B>\n",
#    printf "<B>%${max_fs_name_len}s %9s %9s %9s %3s %12s %7s %5s</B>\n",
      "FS", "1k Blks: Total", "SU Avail", "User Avail", "Usage", 
    "   Files: Total", "Avail", "Usage", ;

      # the filesystems
    for my $path (sort keys %fs){
      my $i = $fs{$path};
      my $fsusage = $gtop->fsusage($entries->mountdir($i));

      my $tot_blocks        = $fsusage->blocks / 2;
      my $su_avail_blocks   = $fsusage->bfree  / 2 ;
      my $user_avail_blocks = $fsusage->bavail / 2;
      my $used_blocks       = $tot_blocks - $su_avail_blocks;
      my $usage_blocks      = $tot_blocks ? ($tot_blocks - $user_avail_blocks)* 100 / $tot_blocks : 0;
      my $tot_files         = $fsusage->files;
      my $free_files        = $fsusage->ffree;
      my $usage_files       = $tot_files ? ($tot_files - $free_files) * 100 / $tot_files : 0;

        # prepare a format
      my $format_blocks = "%9d %9d %10d %4d%% ";
      my $format_files  = "       %7d %7d %4d%%";
      my $format_fs     = "%-${max_fs_name_len}s ";
      my $format = '';

      # visual alert on filesystems of 90% usage!
      if ($usage_blocks >= 90 && $usage_files >= 90) {
	$format = 
	  qq{<B><FONT COLOR="#FF0000">@{[blinking($format_fs)]} $format_blocks $format_files</FONT></B>\n};
      } elsif ($usage_blocks >= 90){
	$format = 
	  qq{<B><FONT COLOR="#FF0000">@{[blinking($format_fs)]} $format_blocks</FONT></B> $format_files\n};
      } elsif ($usage_files  >= 90) {
	$format = 
	  qq{<B><FONT COLOR="#FF0000">@{[blinking($format_fs)]}</FONT></B> $format_blocks <B><FONT COLOR="#FF0000">$format_files</FONT></B>\n};
      } else {
	$format = qq{$format_fs $format_blocks $format_files\n};
      }

      printf $format,
        $path,
	$tot_blocks,
	$used_blocks,
	$user_avail_blocks,
	$usage_blocks,
	$tot_files,
	$free_files,
	$usage_files;
    }

    print "<HR>";

  } # end of if ($config{FS_USAGE})


  #######################
  # mounted filesystems
  #######################
  if ($config{MOUNT}) {
    #    print "<B>mount:</B>\n";   

    my($mountlist, $entries) = $gtop->mountlist(1);
    my $fs_number = $mountlist->number;   

    printf "<B>%-30s %-30s %-10s</B>\n", ("DEVICE", "MOUNTED ON", "FS TYPE");
    for (my $i=0; $i < $fs_number; $i++) {
      printf "%-30s %-30s %-10s\n",
	$entries->devname($i),
	$entries->mountdir($i),
	$entries->type($i);
    }

    print "<HR>";

  } # end of if ($config{MOUNT})

  print "</FONT>";

} # end of sub print_top

#'
# show other non-mod_perl procs based on regex
#################
sub print_other_procs{

  print(qq{Don't know what processes to display...
Hint: set \$Apache::VMonitor::PROC_REGEX
e.g. \$Apache::VMonitor::PROC_REGEX = join "\|", qw(httpd mysql);
<HR>}),
  return unless $Apache::VMonitor::PROC_REGEX;

  my $gtop = GTop->new;

  my($proclist, $entries) = $gtop->proclist;

  my %procs = ();
  for my $pid ( @$entries ){
    my $cmd = $gtop->proc_state($pid)->cmd;
    push @{ $procs{$cmd} },$pid
      if $cmd =~ /$Apache::VMonitor::PROC_REGEX/o;
  }

    # finding out various max lenthgs for a proper column formatting
    # set the minimum width here
  my %max_len = (pid => 3,
		 cmd => 3,
		 tty => 3,
		 uid => 3,
		);
  for my $cat (sort keys %procs) {
    for my $pid (@{ $procs{$cat} } ) {
        # pid len 
      my $len       = length $pid;
      $max_len{pid} = $len if $len > $max_len{pid};

        # command len
      $len          = length $gtop->proc_state($pid)->cmd;
      $max_len{cmd} = $len if $len > $max_len{cmd};

        # tty len      
      $len          = length $gtop->proc_uid($pid)->tty;
      $max_len{tty} = $len if $len > $max_len{tty};

        # uid len 
      $len          = length scalar getpwuid ($gtop->proc_state($pid)->uid);
      $max_len{uid} = $len if $len > $max_len{uid};     
    }
  }

  my $format = "%2s %${max_len{pid}}s %-${max_len{uid}}s %5s %5s %5s %5s %${max_len{tty}}s  %-2s  %-${max_len{cmd}}s\n";
  printf "<B>$format</B>",
	   '##',qw(PID UID Size Share VSize Rss TTY St Command);

#  my %all_total = map {$_ => 0} qw(size real);
  for my $cat (sort keys %procs) {

    my $id = 0;
#    my %total = map {$_ => 0} qw(size real max_shared);

    for my $pid (@{ $procs{$cat} } ) {
      
#      my $proc_time = $gtop->proc_time($pid);
      my $proc_uid  = $gtop->proc_uid($pid);
      my $state     = $gtop->proc_state($pid);
      
      my $proc_mem  = $gtop->proc_mem($pid);
      my $size      = $proc_mem->size($pid);
      my $share     = $proc_mem->share($pid);
      my $vsize     = $proc_mem->vsize($pid);
      my $rss       = $proc_mem->rss($pid);

#      $total{size}  += $size;
#      $total{real}  += $size-$share;
#      $total{max_shared} = $share if $total{max_shared} < $share;

      $id++;
      my $length   = length $pid;
      my $stuffing = $max_len{pid} - $length;
      my $spacing  = "&nbsp;" x $stuffing;
      my $tty = $proc_uid->tty;
      $tty = ' ' if $tty == -1;
      printf $format,
             $id,
	     qq{$spacing<A HREF="@{[get_url(pid => $pid)]}">$pid</A>},
	     scalar getpwuid ($state->uid),
	     format_bytes($size),
	     format_bytes($share), 
	     format_bytes($vsize), 
	     format_bytes($rss), 
	     $tty,
	     $state->state,
#	     format_time(time - $gtop->proc_time($pid)->start_time),
             $state->cmd;

    } # end of for my $pid (@{ $procs{$cat} } )

    print "\n";
#    printf "    Total size %5dK (%s) , real %6dK (%s)\n\n",
#      $total{size}/1000,
#      Apache::Util::size_string($total{size}), 
#      ($total{real} + $total{max_shared})/1000,
#      Apache::Util::size_string($total{real} + $total{max_shared});

#      $all_total{size}  += $total{size};
#      $all_total{real}  += $total{real}+$total{max_shared};

  } # end of for my $cat (sort keys %procs)

#    printf "<B>All matched Total size %5dK (%s) , real %6dK (%s)</B>\n",
#      $all_total{size}/1000,
#      Apache::Util::size_string($all_total{size}), 
#      $all_total{real}/1000,
#      Apache::Util::size_string($all_total{real});

  print "<HR>";

} # end of sub print_other_procs


# print status of a single proc
################
sub print_single{
  my $pid = shift || 0;

  my($proclist, $entries) = $gtop->proclist;

    # get the proc command name
  my $cmd = '';
  for my $proc_pid ( @$entries ){
    $cmd = $gtop->proc_state($pid)->cmd, last if $pid == $proc_pid;
  }
  
    # the title and the link back to the main mode
  print qq{<HR><b>Extensive Status for PID $pid ($cmd)</b>
  	   &nbsp; &nbsp;
  	   [ <A HREF="@{[get_url(pid => 0)]}">
  	   Back to multiproc mode</A> ]};
  
    # the process might be dead already by the time you click on it.
  my $proc_mem = $gtop->proc_mem($pid);
    # report to observer that the process has gone if it's dead
  print("<P>Sorry, the process $pid doesn't exist anymore!"),
    return unless $proc_mem;

    # ditto
  my $size  = $proc_mem->size($pid);
  print("<P>Sorry, the process $pid doesn't exist anymore!"),
    return unless $size;

  print qq{<PRE><FONT SIZE="-1">};

   #############################################
    # mem usage and other stats per httpd process
    #############################################

  my $share = $proc_mem->share($pid);
  my $vsize = $proc_mem->vsize($pid);
  my $rss   = $proc_mem->rss($pid)  ;

  my $title_format = "  <B>%-25s</B> :";

  my $image = Apache::Scoreboard->image;
  # iterate thru Scoreboard structure to find our $pid's entry
  my $i;
  my $is_httpd_child = 0;
  for ($i=0; $i<Apache::Constants::HARD_SERVER_LIMIT; $i++) {
    $is_httpd_child = 1, last if $pid == $image->parent($i)->pid;
  }
  $i = -1 if $pid == getppid();
  
  if ($is_httpd_child || $i == -1) {
    my $process = $image->servers($i);
    
    print "<HR><B>httpd specific info:</B>\n\n";
    
    printf "$title_format %s\n\n",  "Process type", 
      $i == -1 ? "Parent" : "Child";

      # print for all, but a parent process
    unless ($i == -1){

      printf "$title_format %s\n","Status",
        $Apache::VMonitor::longflags[$process->status];

      # get absolute start and stop times in usecs since epoch
      my ($start_sec,$start_usec_delta) = $process->start_time;
      my $start_usec = $start_sec*1000000+$start_usec_delta;
      
      my ($stop_sec, $stop_usec_delta) =  $process->stop_time;
      my $stop_usec = $stop_sec*1000000+$stop_usec_delta;
      
      # measure running time till now if not idle
      my $elapsed = $stop_usec < $start_usec
	? Time::HiRes::tv_interval
	  ([$start_sec,$start_usec_delta], [Time::HiRes::gettimeofday])
	    : 0;

      if ($elapsed) {
	# setting visual alert hardcoded to 15secs so far
	my $format = "$title_format %s\n";
	$format = qq{<B><FONT color="red">$format</FONT></B>} 
	  if $elapsed > 15; 

	  # print the running time if currently not idle
	printf $format, "Cur. req. is running for",format_time($elapsed);
      } else {
	printf "$title_format %s\n\n","Last request processed in",
	format_time($process->req_time/1000);
      }


#      print "\n";
      printf "$title_format <B>%16s</B>   <B>%16s</B> \n", " ","This slot", "This child";
      printf "$title_format %16s   %16s \n", "Requests Served", 
      $process->access_count,$process->my_access_count;
      printf "$title_format (%8s) %5s   (%8s) %5s \n\n", "Bytes Transferred",
      $process->bytes_served,
      Apache::Util::size_string($process->bytes_served),
      $process->my_bytes_served,
      Apache::Util::size_string($process->my_bytes_served);

      printf "$title_format %s\n",
        "Client IP or DNS",$process->client;
      printf "$title_format %s\n",
        "Request (first 64 chars)",$process->request;

    } # end of unless ($i == -1)

    print "\n";
    my @cpu_times = $process->times();
    my $cpu_total = eval join "+",@cpu_times;
    my $format = "%8s  %8s  %8s  %8s  %8s\n";
    printf "$title_format $format","CPU times (secs)",
       qw(total utime stime cutime cstime );
    printf "$title_format $format", " ", map {$_/100} $cpu_total, @cpu_times;

  } #  end of if ($is_httpd_child || $i == -1)


  ### print info that we can retrieve for any process
  print "<HR><B>General process info:</B>\n";
 
   # UID and STATE
  my $state     = $gtop->proc_state($pid);
  printf "\n$title_format %s","UID",scalar getpwuid ($state->uid);
  printf "\n$title_format %s","GID",scalar getgrgid ($state->gid);
  printf "\n$title_format %s","State",$state->state;

    # TTY
  my $proc_uid  = $gtop->proc_uid($pid);  
  my $tty = $proc_uid->tty;
  $tty = 'None' if $tty == -1;
  printf "\n$title_format %s","TTY", $tty;

    # ARGV
  printf "\n$title_format %s","Command line arguments",
    join " ", @{($gtop->proc_args($pid))[1]};  

  ### memory usage
  print "\n<HR><B>Memory Usage</B> (in bytes):\n\n";
  {
    no strict 'refs';
    map { my $size = $proc_mem->$_($pid);
	  printf "  %-10.10s : %10d (%s)\n", 
	    uc $_, $size, Apache::Util::size_string($size) } 
      qw(size share vsize rss);
  }


  ### memory segments usage
  print "\n<HR><B>Memory Segments Usage</B> (in bytes):\n\n";
  {
    no strict 'refs';
    my $proc_segment = $gtop->proc_segment($pid);
    map { my $size = $proc_segment->$_($pid);
	  printf "  %-10.10s : %10d (%s)\n", 
	  uc $_,$size, Apache::Util::size_string($size) } 
      qw(text_rss shlib_rss data_rss stack_rss);
  }

    #############################################
    # memory maps
    #############################################

  printf "<HR><B>Memory Maps:</B>\n\n";
  
  my($procmap, $maps) = $gtop->proc_map($pid);
  my $number = $procmap->number;
  my %libpaths = ();

  printf "%s-%s %s - %s:%s %s - %4s\n", qw(
	start end offset device_major device_minor inode perm
        filename);

  for (my $i = 0; $i < $number; $i++) {
    my $filename = $maps->filename($i) || "-";
    $libpaths{$filename}++;
    my $perm = $maps->perm_string($i);
    my $device = $maps->device($i);;
    my $device_minor = ($device & 255);
    my $device_major = (($device >> 8) & 255);
    my $ptr_size = length pack("p", 0);
    if ($filename) {
      my $format;
      if ($ptr_size == 8) {
	$format = "%016lx-%016lx %016lx - %02x:%02x %08lu - %4s - %s\n";
      }
      else {
	$format = "%08lx-%08lx %08lx - %02x:%02x %08lu - %4s - %s\n";
      }
      printf  $format,
      $maps->start($i),
      $maps->end($i),
      $maps->offset($i),
      $device_major, $device_minor,
      $maps->inode($i),
      $perm, $filename;
      
    } 
    else {
      my $format;
      
      if ($ptr_size == 8) {
	$format = "%016lx-%016lx %016lx - " .
	  "%02x:%02x %08lu - %4s\n";
      }
      else {
	$format = "%08lx-%08lx %08lx - " .
	  "%02x:%02x %08lu - %4s\n";
	
	printf  $format,
	$maps->start($i),
	$maps->end($i),
	$maps->offset($i),
	$device_major, $device_minor,
	$maps->inode($i),
	$perm;
      }
    }	
  }

    #############################################
    # loaded .so libs sizes
    #############################################

  printf "<HR><B>Loaded libs Sizes:</B> (in bytes)\n\n";
  my %libsizes = map { $_  => -s $_ } grep !/^-$/, keys %libpaths;

  my $total = 0;
  map { $total +=  $libsizes{$_};
	printf "%10d (%s) : %s\n", $libsizes{$_}, 
	Apache::Util::size_string($libsizes{$_}), $_
      } 
    sort {$libsizes{$b} <=> $libsizes{$a}} keys %libsizes;

  printf "\n<B>%10d (%s): %s</B>\n", $total,
  Apache::Util::size_string($total), "Total";

  print qq{</FONT></PRE><HR>};

} # end of sub print_single

################
sub end_html{
print qq{
    Generated by <A HREF="http://search.cpan.org/search?mode=module&query=Apache%3A%3AVMonitor">Apache::VMonitor</A>
    ver. $Apache::VMonitor::VERSION
    </BODY>
    </HTML>
  };

}

#
# my $newurl = get_url(key,value)
# update some part of the url and return
############
sub get_url{
  my($key,$value) = @_;

  (my $new_url = $url) =~ s/$key=([^&]+)?/$key=$value/;
#  $new_url ||= "$url&$key=$value";
  return $new_url;

} # end of sub get_url

# compacts numbers like 1200234 => 1.2M 
############
sub format_bytes{
  my $bytes = shift || 0;

  return sprintf "%5d",                                      $bytes       if $bytes < KBYTE;
  return sprintf "%4.@{[int($bytes/KBYTE) < 10 ? 1 : 0]}fK", $bytes/KBYTE if KBYTE < $bytes  and $bytes < MBYTE;
  return sprintf "%4.@{[int($bytes/MBYTE) < 10 ? 1 : 0]}fM", $bytes/MBYTE if MBYTE < $bytes  and $bytes < GBYTE;
  return sprintf "%4.@{[int($bytes/GBYTE) < 10 ? 1 : 0]}fG", $bytes/GBYTE if GBYTE < $bytes;

} # end of sub format_bytes

# any number that enters we return its compacted version of max 4
# chars in length (5, 123, 1.2M, 12M, 157G)
# note that here 1K is 1000 and not 1024!!!
############
sub format_counts{
  local $_ = shift || 0;

  my $digits = tr/0-9//;
  return $_                                                          if $digits < 4;
  return sprintf "%.@{[$digits%3 == 1 ? 1 : 0]}fK", $_/1000          if $digits < 7;
  return sprintf "%.@{[$digits%3 == 1 ? 1 : 0]}fM", $_/1000000       if $digits < 10;
  return sprintf "%.@{[$digits%3 == 1 ? 1 : 0]}fG", $_/1000000000    if $digits < 13;
  return sprintf "%.@{[$digits%3 == 1 ? 1 : 0]}fT", $_/1000000000000 if $digits < 16;

} # end of sub format_counts

# Takes seconds as int or float as an argument 
#
# Returns string of time in days (12d) or
# hours/minutes (11:13) if less then one day, 
# and secs.millisec (12.234s) if less than a minute
#
# The returned sting is always of 6 digits length (taken that
# length(int days)<4) so you can ensure the column with 
# printf "%7s", format_time($secs)
###############
sub format_time{
  my $secs = shift || 0;
  return sprintf "%6.3fs",$secs if $secs < 60;
  my $hours = $secs/3600;
  return sprintf "%6.2fd", $hours/24 if  $hours > 24;
  return sprintf " %02d:%2.2dm", int $hours, int $secs%3600 ?  int (($secs%3600)/60) : 0;
} # end of sub format_time


# should blink or not
############
sub blinking{
  return $config{BLINKING} 
    ? join "", "<BLINK>",@_,"</BLINK>"
    : join "", @_;
} # end of sub blinking

# print the form to enable or disable choices
##############
sub choice_bar{

  print "<FONT SIZE=-1>";

  my @hide = ();
  my @show = ();

  foreach (qw(SYSTEM APACHE PROCS MOUNT FS_USAGE VERBOSE BLINKING)) {
    $config{$_} != 0
    ? push @hide, $_
    : push @show, $_;
  }

  print "Show: ", 
    map({ qq{[ <A HREF="@{[get_url($_ => 1)]}">$_</A> ]}
	} @show
       ) , "\n"
	  if @show;

  print "Hide: ", 
    map({ qq{[ <A HREF="@{[get_url($_ => 0)]}">$_</A> ]}
	} @hide
       ) if @hide;

  print "</FONT><HR></PRE>";

} # end of sub choice_bar

############
sub verbose{

  return unless $config{VERBOSE};

  foreach (sort keys %config) {
      next unless $Apache::VMonitor::abbreviations{$_};
      next unless $config{$_} or $_ eq "REFRESH";
      (my $note = $Apache::VMonitor::abbreviations{$_}) =~ s/\n\n/<P>\n/mg;
      print "$note<HR>";
  }

} # end of sub verbose  


%Apache::VMonitor::abbreviations = 
  (

   VERBOSE =>
   qq{
     <B>Verbose option</B>

     Enables Verbose mode - displays an explanation and abbreviation
     table for each enabled section.

   },

   REFRESH  =>
   qq{
     <B>Refresh Section</B>

       You can tune the automatic refresh rate by clicking on the
       number of desired rate (in seconds). 0 (zero) means "no
       automatic refresh".
   },

   BLINKING =>

   qq{
     <B>Blinking Option</B>

       Apache::VMonitor is capable of visual alerting when something
       is going wrong, as of this moment it colors the problematic
       data in red (e.g when OS starts heavy swapping or file system is
       close to free disk space shortage), and to bring more attention
       it can make it blink. So this option allows you to control this
       mode.

   },

   SYSTEM =>
   qq{
     <B>Top section</B>

       Represents the emulation of top utility, while individually
       reporting only on httpd processes, and provides information
       specific to these processes.

       <B>1st</B>: current date/time, uptime, load average: last 1, 5 and 15
       minutes, total number of processes and how many are in the
       running state.

       <B>2nd</B>: CPU utilization in percents: by processes in user, nice,
       sys and idle state

       <B>3rd</B>: RAM utilization: total available, total used, free, shared
       and buffered

       <B>4th</B>: SWAP utilization: total available, total used, free, how
       many paged in and out
     },

   APACHE =>
   qq{
       <B>Apache/mod_perl processes:</B>

	First row reports the status of parent process (mnemonic 'par')

       Columns:
       <table>
         <tr bgcolor="EEEEEE"><td>Column Title  </td><td>Purpose</td></tr>
	 <tr><td><b>PID</b>    </td><td>Id</td></tr>
	 <tr><td><b>M</b>      </td><td>Apache mode (See below a full table of abbreviations)</td></tr>
	 <tr><td><b>Elapsed</b></td><td>Time since request was started if still in process (0 otherwise)</td></tr>
	 <tr><td><b>LastReq</b></td><td>Time last request was served if idle now (0 otherwise)</td></tr>
	 <tr><td><b>Srvd</b>   </td><td>How many requests were processed by this child</td></tr>
	 <tr><td><b>Size</b>   </td><td>Total Size</td></tr>
	 <tr><td><b>Share</b>  </td><td>Shared Size</td></tr>
	 <tr><td><b>VSize</b>  </td><td>Virtual Size</td></tr>
	 <tr><td><b>RSS</b>    </td><td>Resident Size</td></tr>
	 <tr><td><b>Client</b> </td><td>Client IP</td></tr>
	 <tr><td><b>Request</b></td><td>Request (first 64 chars)</td></tr>
       </table>

        <p> You can sort the report by clicking on any column (only
        the parent process is outstanding and is not sorted)</p>

	 Last row reports:

	 <B>Total</B> = a total size of the httpd processes (by summing the SIZE value of each process)

         <B>Approximate real size (-shared)</B> = 

1. For each process sum up the difference between shared and system
memory.

2. Now if we add the share size of the process with maximum
shared memory, we will get all the memory that actually is being
used by all httpd processes but the parent process.

Please note that this might be incorrect for your system, so you use
this number on your own risk. I have verified this number, by writing
it down and then killing all the servers. The system memory went down
by approximately this number. Again, use this number wisely!

The <B>modes</B> a process can be in:

<CODE><B>_</B></CODE> = Waiting for Connection<BR>
<CODE><B>S</B></CODE> = Starting up<BR>
<CODE><B>R</B></CODE> = Reading Request<BR>
<CODE><B>W</B></CODE> = Sending Reply<BR>
<CODE><B>K</B></CODE> = Keepalive (read)<BR>
<CODE><B>D</B></CODE> = DNS Lookup<BR>
<CODE><B>L</B></CODE> = Logging<BR>
<CODE><B>G</B></CODE> = Gracefully finishing<BR>
<CODE><B>.</B></CODE> = Open slot with no current process<BR>

   },

   PROCS    =>
   qq{
     <B>  Processes matched by <CODE>\$Apache::VMonitor::PROC_REGEX</CODE> (PROCS)</B>

Setting:
<PRE>\$Apache::VMonitor::PROC_REGEX = join "\|", qw(httpd mysql squid);</PRE> 

will display the processes that match /httpd|mysql|squid/ regex in a
top(1) fashion in groups of processes. After each group the report of
total size and approximate real size is reported (approximate == size
calculated with shared memory reducing)

At the end there is a report of total size and approximate real size.

   },

   MOUNT    =>
   qq{
<B>Mount section</B>

Reports about all mounted filesystems

<B>DEVICE</B>  = The name of the device<BR>
<B>MOUNTED ON</B>  = Mount point of the mounted filesystem<BR>
<B>FS TYPE</B> = The type of the mounted filesystem<BR>

   },

   FS_USAGE =>
   qq{
<B>File System usage</B>

Reports the utilization of all mounted filesystems:

<B>FS</B>  = the mount point of filesystem<BR>

<B>Blocks (1k)</B> = Space usage in blocks of 1k bytes<BR>

<B>Total</B>  = Total existing<BR>
<B>SU Avail</B> = Available to superuser (root) (tells how much space let for real)<BR>
<B>User Avail</B> = Available to user (non-root) (user cannot use last 5% of each filesystem)

<B>Usage</B> = utilization in percents (from user perspective, when it reaches
100%, there are still 5% but only for root processes)

<B>Files</B>: = File nodes usage<BR>
<B>Total</B>   = Total nodes possible <BR>
<B>Avail</B> = Free nodes<BR>
<B>Usage</B> = utilization in percents<BR>

   },

  );


# I have tried to plug this module into an Apache::Status, but it
# wouldn't quite work, because Apache::VMonitor needs to send refresh
# headers, and it's impossible when Apache::Status takes over
# 
# I guess we need a new method for Apache::Status, ether to
# automatically configure a plugged module and just link to a new
# location, with a plugged module autonomic or let everything work
# thru Apache::Status without it intervening with headers and html
# snippets, just let the module to overtake the operation

#Apache::Status->menu_item
# ('VisualMonitor' => 'VisualMonitor',
#  \&handler
# ) if $INC{'Apache.pm'} && Apache->module('Apache::Status');

1;

__END__

=pod

=head1 NAME

Apache::VMonitor - Visual System and Apache Server Monitor

=head1 SYNOPSIS

  # mod_status should be compiled in (it is by default)
  ExtendedStatus On

  # Configuration in httpd.conf
  <Location /system/vmonitor>
    SetHandler perl-script
    PerlHandler Apache::VMonitor
  </Location>

  # startup file or <Perl> section:
  use Apache::VMonitor();
  $Apache::VMonitor::Config{BLINKING} = 1;
  $Apache::VMonitor::Config{REFRESH}  = 0;
  $Apache::VMonitor::Config{VERBOSE}  = 0;
  $Apache::VMonitor::Config{SYSTEM}   = 1;
  $Apache::VMonitor::Config{APACHE}   = 1;
  $Apache::VMonitor::Config{PROCS}    = 1;
  $Apache::VMonitor::Config{MOUNT}    = 1;
  $Apache::VMonitor::Config{FS_USAGE} = 1;
  $Apache::VMonitor::Config{SORT_BY}  = 'size';
  
  $Apache::VMonitor::PROC_REGEX = join "\|", qw(httpd mysql squid);

=head1 DESCRIPTION

This module emulates the reporting functionalities of top(1), extended
for mod_perl processes, mount(1), and df(1) utilities. It has a visual
alerting capabilities and configurable automatic refresh mode. All the
sections can be shown/hidden dynamically through the web interface.

The are two main modes: 

=over 

=item * Multi processes mode

All system processes and information are shown. See the detailed
description of the sub-modes below.

=item * Single process mode


If you need to get an indepth information about a single process, you
just need to click on its PID.

If the chosen process is a mod_perl process, the following info is
displayed:

=over

=item *

Process type (child or parent), status of the process (I<Starting>,
I<Reading>, I<Sending>, I<Waiting>, etc.), how long the current
request is processed or the last one was processed if the process is
inactive at the moment of the report take.

=item *

How many bytes transferred so far. How many requests served per child
and per slot.

=item *

CPU times used by process: C<total>, C<utime>, C<stime>, C<cutime>,
C<cstime>.

=back

For all (mod_perl and non-mod_perl) processes the following
information is reported:

=over

=item *

General process info: UID, GID, State, TTY, Command line arguments

=item *

Memory Usage: Size, Share, VSize, RSS

=item *

Memory Segments Usage: text, shared lib, date and stack.

=item *

Memory Maps: start-end, offset, device_major:device_minor, inode,
perm, library path.

=item *

Loaded libraries sizes.

=back

Just like the multi-process mode, this mode allows you to
automatically refresh the page on the desired intervals.

=back

Other available modes within 'Multi processes mode'.

=over

=item refresh mode

From within a displayed monitor (by clicking on a desired refresh
value) or by setting of B<$Apache::VMonitor::Config{REFRESH}> to a number of
seconds between refreshes you can control the refresh rate. e.g:

  $Apache::VMonitor::Config{REFRESH} = 60;

will cause the report to be refreshed every single minute.

Note that 0 (zero) turns automatic refreshing off.

=item top(1) emulation (system)

Just like top(1) it shows current date/time, machine uptime, average
load, all the system CPU and memory usage: CPU load, Real memory and
swap partition usage.

The top(1) section includes a swap space usage visual alert
capability. The color of the swap report will be changed:

         swap usage               report color
   ---------------------------------------------------------
   5Mb < swap < 10 MB             light red
   20% < swap (swapping is bad!)  red
   70% < swap (almost all used!)  red + blinking (if enabled)

Note that you can turn off blinking with:

  $Apache::VMonitor::Config{BLINKING} = 0;

The module doesn't alert when swap is being used just a little (<5Mb),
since it happens most of the time, even when there is plenty of free
RAM.

If you don't want the system section to be displayed set:

  $Apache::VMonitor::Config{SYSTEM} = 0;

The default is to display this section.

=item top(1) emulation (Apache/mod_perl processes)

Then just like in real top(1) there is a report of the processes, but
it shows all the relevant information about mod_perl processes only!

The report includes the status of the process (I<Starting>,
I<Reading>, I<Sending>, I<Waiting>, etc.), process' ID, time since
current request was started, last request processing time, size,
shared, virtual and resident size.  It shows the last client's IP and
Request URI (only 64 chars, as this is the maximum length stored by
underlying Apache core library).

You can sort the report by any column, see the
L<CONFIGURATION|/CONFIGURATION> section for details.

The section is concluded with a report about the total memory being
used by all mod_perl processes as reported by kernel, plus extra
number, which results from an attempt to approximately calculate the
real memory usage when memory sharing is taking place. The calculation
is performed by using the following logic:

=over

=item 1

For each process sum up the difference between shared and total
memory.

=item 2

Now if we add the share size of the process with maximum shared
memory, we will get all the memory that is actually used by all
mod_perl processes, but the parent process.

=back

Please note that this might be incorrect for your system, so you
should use this number on your own risk. We have verified this number
on the Linux OS, by taken the number reported by C<Apache::VMonitor>,
then stopping mod_perl and looking at the system memory usage. The
system memory went down approximately by the number reported by the
tool. Again, use this number wisely!

If you don't want the mod_perl processes section to be displayed set:

  $Apache::VMonitor::Config{APACHE} = 0;

The default is to display this section.

=item top(1) emulation (any processes)


This section, just like the mod_perl processes section, displays the
information in a top(1) fashion. To enable this section you have to
set:

  $Apache::VMonitor::Config{PROCS} = 1;

The default is not to display this section.

Now you need to specify which processes are to be monitored. The
regular expression that will match the desired processes is required
for this section to work. For example if you want to see all the
processes whose name include any of these strings: I<http>, I<mysql>
and I<squid>, the following regular expression is to be used:

  $Apache::VMonitor::PROC_REGEX = join "\|", qw(httpd mysql squid);

=item mount(1) emulation

This section reports about mounted filesystems, the same way as if you
have called mount(1) with no parameters.

If you want the mount(1) section to be displayed set:

  $Apache::VMonitor::Config{MOUNT} = 1;

The default is NOT to display this section.

=item df(1) emulation 

This section completely reproduces the df(1) utility. For each mounted
filesystem it reports the number of total and available blocks (for
both superuser and user), and usage in percents.

In addition it reports about available and used file inodes in numbers
and percents.

This section has a capability of visual alert which is being triggered
when either some filesystem becomes more than 90% full or there are
less than 10% of free file inodes left. When this event happens the
filesystem related report row will be displayed in the bold font and
in the red color. A mount point directory will blink if the blinking
is turned on. You can turn the blinking on with:

  $Apache::VMonitor::Config{BLINKING} = 1;

If you don't want the df(1) section to be displayed set:

  $Apache::VMonitor::Config{FS_USAGE} = 0;

The default is to display this section.

=item abbreviations and hints

The monitor uses many abbreviations, which might be knew for you. If
you enable the VERBOSE mode with:

  $Apache::VMonitor::Config{VERBOSE} = 1;

this section will reveal all the full names of the abbreviations at
the bottom of the report.

The default is NOT to display this section.

=back

=head1 CONFIGURATION


To enable this module you should modify a configuration in
B<httpd.conf>, if you add the following configuration:

  <Location /system/vmonitor>
    SetHandler perl-script
    PerlHandler Apache::VMonitor
  </Location>

The monitor will be displayed when you request
http://localhost/system/vmonitor or alike.

You probably want to protect this location, from unwanted visitors. If
you are accessing this location from the same IP address, you can use
a simple host based authentication:

  <Location /system/vmonitor>
    SetHandler perl-script
    PerlHandler Apache::VMonitor
    order deny, allow
    deny  from all
    allow from 132.123.123.3
  </Location>

Alternatively you may use the Basic or other authentication schemes
provided by Apache and various extensions.

You can control the behavior of this module by configuring the
following variables in the startup file or inside the
C<E<lt>PerlE<gt>> section.

Module loading:

  use Apache::VMonitor();

Monitor reporting behavior:

  $Apache::VMonitor::Config{BLINKING} = 1;
  $Apache::VMonitor::Config{REFRESH}  = 0;
  $Apache::VMonitor::Config{VERBOSE}  = 0;

Control over what sections to display:

  $Apache::VMonitor::Config{SYSTEM}   = 1;
  $Apache::VMonitor::Config{APACHE}   = 1;
  $Apache::VMonitor::Config{PROCS}    = 1;
  $Apache::VMonitor::Config{MOUNT}    = 1;
  $Apache::VMonitor::Config{FS_USAGE} = 1;

Control the sorting of the mod_perl processes report. You can sort
them by one of the following columns: I<"pid">, I<"mode">,
I<"elapsed">, I<"lastreq">, I<"served">, I<"size">, I<"share">,
I<"vsize">, I<"rss">, I<"client">, I<"request">. For example to sort
by the process size the following setting will do:

  $Apache::VMonitor::Config{SORT_BY}  = 'size';

A regex to match processes for 'PROCS' section:

  $Apache::VMonitor::PROC_REGEX = join "\|", qw(httpd mysql squid);

Read the L<DESCRIPTION|/DESCRIPTION> section for a complete
explanation of each of these variables.

=head1 DYNAMIC RECONFIGURATION

C<Apache::VMonitor> allows you to dynamically turn on and off all the
sections and enter a verbose mode that explains each section and the
used abbreviations. These dynamic settings stored in the URI and not
on the server side. 


=head1 PREREQUISITES

You need to have B<Apache::Scoreboard> installed and configured in
I<httpd.conf>, which in turn requires mod_status to be installed. You
also have to enable the extended status for mod_status, for this
module to work properly. In I<httpd.conf> add:

  ExtendedStatus On

Notice that turning the C<ExtendedStatus> mode I<On> is not
recommended for high-performance production sites, as it adds an
overhead to the request response times.

You also need B<Time::HiRes> and B<GTop> to be installed.

And of course you need a running mod_perl enabled apache server.

=head1 BUGS

=head1 TODO

I want to include a report about open file handlers per process to
track file handlers leaking. It's easy to do that by just reading them
from C</proc/$pid/fd> but you cannot do that unless you are
root. C<libgtop> doesn't have this capability - if you come up with
solution, please let me know. Thanks!

=head1 SEE ALSO

L<Apache>, L<mod_perl>, L<Apache::Scoreboard>, L<GTop>

=head1 AUTHORS

Stas Bekman <stas@stason.org>

=head1 COPYRIGHT

The Apache::VMonitor module is free software; you can redistribute it
and/or modify it under the same terms as Perl itself.

=cut
