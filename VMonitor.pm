package Apache::VMonitor;

BEGIN {
  # RCS/CVS complient:  must be all one line, for MakeMaker
  $Apache::VMonitor::VERSION = do { my @r = (q$Revision: 1.1 $ =~ /\d+/g); sprintf "%d."."%02d" x $#r, @r }; 
}


use strict;
use Apache::Util ();
use Apache::Scoreboard ();
use Apache::Constants ();
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
   NETLOAD  => 0,
  );

     # devs to show if $Apache::VMonitor::Config{NETLOAD} != 0;
@Apache::VMonitor::NETDEVS  = qw ();

$Apache::VMonitor::PROC_REGEX = '';


use vars qw($gtop);
# initialize the gtop object
$gtop = GTop->new;

###########
sub handler{

    ##############################
    # process args and set refresh rate
    ##############################
  my $r = shift;
  my %params = $r->args;

    # modify the default args if requested
  map { $Apache::VMonitor::Config{$_} = $params{$_} 
	if defined $params{$_}
      } keys %Apache::VMonitor::Config;

    # build the updated URL
  $Apache::VMonitor::url = $r->uri."?".join "&", 
    map {"$_=$Apache::VMonitor::Config{$_}"} 
      keys %Apache::VMonitor::Config;

  my $pid = $params{pid} || 0;

  $Apache::VMonitor::url .= "&pid=$pid";

    # if the refresh is non-null, set the refresh header
  $r->header_out
    (Refresh => 
     "$Apache::VMonitor::Config{REFRESH}; URL=$Apache::VMonitor::url"
    ) if $Apache::VMonitor::Config{REFRESH} != 0;

  $r->content_type('text/html');
  $r->send_http_header;

  start_html();

  if ($pid) {
    print_single($params{pid});
  } else {
    print_top();    
    choice_bar();
    verbose();
  }

  print_bottom();

  print "</BODY>\n</HTML>\n";

  return Apache::Constants::OK;

} # end of sub handler


#################################
# the html header and refresh bar
#################################
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
	$Apache::VMonitor::Config{REFRESH} == $_
	  ? qq{[<B><FONT SIZE=+1> $_ </FONT></B>]}
	  : qq{<A HREF="@{[get_url(REFRESH => $_)]}"><B>[ $_ ]</B></A>};
      }
	qw(0 1 5 10 20 30 60);

} # end of start_html

# META: Glibtop has a process list with args - people might want to
# watch processes like squid, mysql so it can be configured to return
# a list of PIDs of the matched processes - see (Process list in the
# gtop manual)


##############
sub print_top{

# META: related to above: probably write an interface to dynamically
# add/remove the sections of report.

  print "<PRE><HR><FONT SIZE=-1>";

  if ($Apache::VMonitor::Config{SYSTEM}) {

    ########################
    # uptime and etc...
    #######################
    my $loadavg = $gtop->loadavg();
    printf "<B>%d/%.2d/%d %d:%.2d%s   up %s, load average: %.2f %.2f %.2f",
      map ({($_->[1]+1,$_->[0],$_->[2]+1900)}[(localtime)[3,4,5]]),
      map ({$_->[1] > 11 ? ($_->[1]%12,$_->[0],"pm") : ($_->[1],$_->[0],"am") } 
	   [(localtime)[1,2]]),
      format_time($gtop->uptime()->uptime()),  
      @{$loadavg->loadavg()};

      # linux specific info
    if ($^O eq 'linux'){
      printf ", %d processes: %d running</B>\n",
        $loadavg->nr_tasks,
        $loadavg->nr_running;
    } else {
      print "</B>\n";
    }

    #######################
    # total CPU stats
    #######################
    my $cpu = $gtop->cpu();
    my $total = $cpu->total();
    # META: I always get the same information here! Do you? Is it a bug?
    printf "<B>CPU:   %2.1f%% user, %2.1f%% nice, %2.1f%% sys, %2.1f%% idle</B>\n",
      $cpu->user() * 100 / $total,
      $cpu->nice() * 100 / $total,
      $cpu->sys()  * 100 / $total,
      $cpu->idle() * 100 / $total;

    #######################
    # total mem stats
    #######################
    my $mem = $gtop->mem();
    printf "<B>Mem:  %6dK av, %6dK used, %6dK free, %6dK shared, %6dK buff</B>\n",
      $mem->total()  / 1000,
      $mem->used()   / 1000,
      $mem->free()   / 1000,
      $mem->shared() / 1000,
      $mem->buffer() / 1000;

    #######################
    # total swap stats
    #######################
    # visual alert on swap usage:
    # 1) 5Mb < swap < 10 MB             color: light red
    # 2) 20% < swap (swapping is bad!)  color: red
    # 3) 70% < swap (swap almost used!) color: red + blinking

    my $swap = $gtop->swap();
    my $format = qq{%6dK av, %6dK used, %6dK free, %6d  pagein, %6d  pageout};

    my $swap_total = $swap->total() / 1000;
    my $swap_used  = $swap->used()  / 1000;
    my $swap_free  = $swap->free()  / 1000;
    my $swap_usage = $swap_used * 100 / $swap_total;

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
      $swap_total,
      $swap_used,
      $swap_free,
      $swap->pagein(),
      $swap->pageout();

    print "<HR>";

  } # end of if ($Apache::VMonitor::Config{SYSTEM})


  if ($Apache::VMonitor::Config{APACHE}){
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

    printf "<B> ##  %${max_pid_len}s %s %7s %7s %5s %5s %5s %5s %12s %27s</B>\n", 
      qw(PID M Elapsed LastReq Size Share VSize Rss Client), "Request (first 64 chars)";

    my $parent_format = "par: %${max_pid_len}s %1s %7s %7s %5s %5s %5s %5s\n";
    my $child_format  = "%3d: %${max_pid_len}s %1s %7s %7s %5s %5s %5s %5s %15.15s %.64s \n";	

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

#      my $share = $proc_mem->share($pid) / 1000;
#      my $vsize = $proc_mem->vsize($pid) / 1000;
#      my $rss   = $proc_mem->rss($pid)   / 1000;
#      my $size      = $proc_mem->size($pid)  / 1000;


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

	# setting visual alert for cur_req_elapsed_run hardcoded to
	# 15 secs so far
      $elapsed = $elapsed > 15
	? blinking(sprintf qq{<B><FONT color="red">%7s</FONT></B>},
		   format_time($elapsed))
        : format_time($elapsed);

	# setting visual alert for last_req_len hardcoded to 15secs so
	# far
      my $req_time = $process->req_time/1000;
      $req_time = $req_time > 15
	? sprintf qq{<B><FONT color="red">%7s</FONT></B>},
	          format_time($req_time)
        : format_time($req_time);

        # link the pid
      my $length   = length $pid;
      my $stuffing = $max_pid_len - $length;
      my $spacing  = "&nbsp;" x $stuffing;
      $pid = qq{$spacing<A HREF="@{[get_url(pid => $pid)]}">$pid</A>};

      # handle the parent case
      if ($i == -1) {
	printf $parent_format,
	$pid,
	$process->status,
	'',
	'',
	Apache::Util::size_string($size),
	Apache::Util::size_string($share),
	Apache::Util::size_string($vsize),
	Apache::Util::size_string($rss),
      } else {
	printf $child_format,
	$i,
	$pid,
	$process->status,
	$elapsed,
	$req_time,
	Apache::Util::size_string($size),
	Apache::Util::size_string($share),
	Apache::Util::size_string($vsize),
	Apache::Util::size_string($rss),
	$process->client,
	$process->request;
      }

    } # end of for (my $i=0...

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

  } # end of if ($Apache::VMonitor::Config{TOP})


  #########################
  # non-mod_perl processes
  #########################
  if ($Apache::VMonitor::Config{PROCS}) {
    print_other_procs();
  } # end of if ($Apache::VMonitor::Config{PROCS})

  #######################
  # mounted filesystems
  #######################
  if ($Apache::VMonitor::Config{MOUNT}) {
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

  } # end of if ($Apache::VMonitor::Config{MOUNT})


  #######################
  # filesystem usage
  #######################
  if ($Apache::VMonitor::Config{FS_USAGE}) {
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

  } # end of if ($Apache::VMonitor::Config{FS_USAGE})

  #######################
  # net interfaces stats
  #######################
  if ($Apache::VMonitor::Config{NETLOAD}) {
    if (@Apache::VMonitor::NETDEVS) {
      #      print "<B>Netload:</B>\n";
      for my $dev (@Apache::VMonitor::NETDEVS) {
	my $netload = $gtop->netload($dev);
	next unless $netload;
	printf "<B>%4s</B>\t       MTU:          %4d, collisions:    %d\n", 
	  $dev, 
	  $netload->mtu($dev),
	  $netload->collisions($dev);

	printf "\tTX:    packets:%10d, bytes:%10d, errors:%d\n",
	  $netload->packets_out($dev),
	  $netload->bytes_out($dev),
	  $netload->errors_out($dev);

	printf "\tRX:    packets:%10d, bytes:%10d, errors:%d\n",
	  $netload->packets_in($dev),
	  $netload->bytes_in($dev),
	  $netload->errors_in($dev);

	printf "\tTotal: packets:%10d, bytes:%10d, errors:%d\n\n",
	  $netload->packets_total($dev),
	  $netload->bytes_total($dev),
	  $netload->errors_total($dev);
      }

    } else {
      print qq{Don't know what devices to monitor...\nHint: set \@Apache::VMonitor::NETDEVS\n};
    } # end of if (@Apache::VMonitor::NETDEVS)

      print "<HR>";

  } # end of if ($Apache::VMonitor::Config{NETLOAD})

  print "</FONT>";

} # end of sub print_top

#'
# show other non-mod_perl procs based on regex
#################
sub print_other_procs{

  print(qq{Do not know what processes to display...
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

#  my $format = "%2s %${max_pid_len}s %-10s %5s %5s %5s %5s %12s %8s %10s  %-10s %s %s %s %s %s %s\n";
#  printf "<B>$format</B>",
#	   '##',qw(PID UID Size Share VSize Rss TTY State Time Command ARGV);


  my %all_total = map {$_ => 0} qw(size real);
  for my $cat (sort keys %procs) {

    my $id = 0;
    my %total = map {$_ => 0} qw(size real max_shared);

    for my $pid (@{ $procs{$cat} } ) {
      
#      my $proc_time = $gtop->proc_time($pid);
      my $proc_uid  = $gtop->proc_uid($pid);
      my $state     = $gtop->proc_state($pid);
      
      my $proc_mem  = $gtop->proc_mem($pid);
      my $size      = $proc_mem->size($pid);
      my $share     = $proc_mem->share($pid);
      my $vsize     = $proc_mem->vsize($pid);
      my $rss       = $proc_mem->rss($pid);

      $total{size}  += $size;
      $total{real}  += $size-$share;
      $total{max_shared} = $share if $total{max_shared} < $share;

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

    printf "    Total size %5dK (%s) , real %6dK (%s)\n\n",
      $total{size}/1000,
      Apache::Util::size_string($total{size}), 
      ($total{real} + $total{max_shared})/1000,
      Apache::Util::size_string($total{real} + $total{max_shared});

      $all_total{size}  += $total{size};
      $all_total{real}  += $total{real}+$total{max_shared};

  } # end of for my $cat (sort keys %procs)

    printf "<B>All matched Total size %5dK (%s) , real %6dK (%s)</B>\n",
      $all_total{size}/1000,
      Apache::Util::size_string($all_total{size}), 
      $all_total{real}/1000,
      Apache::Util::size_string($all_total{real});

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
sub print_bottom{
print qq{
    Generated by <A
    HREF="http://www.perl.com/CPAN-local/authors/id/S/ST/STAS/">Apache::VMonitor</A>
    ver. $Apache::VMonitor::VERSION
  };

}

#
# my $newurl = get_url(key,value)
# update some part of the url and return
############
sub get_url{
  my($key,$value) = @_;

  (my $new_url = $Apache::VMonitor::url) =~ s/$key=(\d+)/$key=$value/;
#  $new_url ||= "$Apache::VMonitor::url&$key=$value";
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
  return $Apache::VMonitor::Config{BLINKING} 
    ? join "", "<BLINK>",@_,"</BLINK>"
    : join "", @_;
} # end of sub blinking

# print the form to enable or disable choices
##############
sub choice_bar{

  print "<FONT SIZE=-1>";

  my @hide = ();
  my @show = ();

  foreach (qw(SYSTEM APACHE PROCS MOUNT FS_USAGE NETLOAD VERBOSE BLINKING)) {
    $Apache::VMonitor::Config{$_} != 0
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

  return unless $Apache::VMonitor::Config{VERBOSE};  

  foreach (sort keys %Apache::VMonitor::Config) {
    (my $note = $Apache::VMonitor::abbreviations{$_}) =~ s/\n\n/<P>\n/mg;
    print "$note<HR>"   
      if $Apache::VMonitor::Config{$_} or $_ eq "REFRESH";
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

	 <B>PID</B>   = Id<BR>
	 <B>M</B> = apache mode (See below a full table of abbreviations)<BR>
	 <B>Elapsed</B> = time since request was started if still in process (0 otherwise)
	 <B>LastReq</B> = time last request was served if idle now (0 otherwise)
	 <B>Size</B>  = total size<BR>
	 <B>Share</B> = shared size<BR>
	 <B>VSize</B> = virtual size<BR>
	 <B>RSS</B>   = resident size<BR>

	 <B>Client</B>  = Client IP<BR>
	 <B>Request</B> = Request (first 64 chars)<BR>

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

   NETLOAD  =>
   qq{
<B>Netload section</B>

reports network devices statistics:

<B>TX</B> = transmitted<BR>
<B>RX</B> = received<BR>
<B>Total</B> = total :)<BR>
<B>MTU</B> = Maximum Transfer Unit<BR>

Note that in order to report on device 'foo' you should add it to
@Apache::VMonitor::NETDEVS array at the server startup. e.g. to get
the report for 'eth0' and 'lo', set:

<CODE><B>\@Apache::VMonitor::NETDEVS = qw(lo eth0);</B></CODE>


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

  # Configuration in httpd.conf
  <Location /sys-monitor>
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
  $Apache::VMonitor::Config{NETLOAD}  = 1;
  
  @Apache::VMonitor::NETDEVS    = qw(lo eth0);
  $Apache::VMonitor::PROC_REGEX = join "\|", qw(httpd mysql squid);

=head1 DESCRIPTION

This module emulates the reporting functionalities of top(), mount(),
df() and ifconfig() utilities. It has a visual alert capabilities and
configurable automatic refresh mode. All the sections can be
shown/hidden dynamically through the web interface. 

The are two main modes: 

=over 

=item * Multi processes mode

All system processes and information are shown. See the detailed
description of the sub-modes below.

=item * Single process mode

An indepth information about a single process is shown.

If the chosen process is an Apache/mod_perl process, the following
info is displayed:

Process type (child or parent), status of the process (starting,
reading, sending waiting and etc), how long the current request is
processed or last was processed. 

Bytes transferred and requests served perl child and per slot.

Cpu times used by process: total, utime, stime, cutime, cstime.

For all processes:

General process info:

UID, GID, State, TTY, Command line args

Memory Usage: Size, Share, VSize, RSS

Memory Segments Usage: text, shared lib, date and stack.

Memory Maps: start-end, offset, device_major:device_minor, inode,
perm, library path.

Loaded libraries sizes.

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

Just like top() it shows current date/time, machine uptime, average
load, all the system CPU and memory usage: CPU Load, Mem and Swap
usage.

The top() section includes a swap space usage visual alert
capability. The color of the swap report will be changed:

   1) 5Mb < swap < 10 MB             color: light red
   2) 20% < swap (swapping is bad!)  color: red
   3) 70% < swap (swap almost used!) color: red + blinking

Note that you can turn off blinking with:

  $Apache::VMonitor::Config{BLINKING} = 0;

The module doesn't alert when swap is being used just a little (<5Mb),
since it happens most of the time, even when there is plenty of free
RAM.

If you don't want the system section to be displayed set:

  $Apache::VMonitor::Config{SYSTEM} = 0;

The default is to display this section.

=item top(1) emulation (Apache/mod_perl processes)

Then just like in real top() there is a report of the processes, but
it shows all the relevant information about httpd processes only! The
report includes the status of the process (starting, reading, sending
waiting and etc), process' id, time since current request was started,
last request processing time, size, shared, virtual and resident size.
It shows the last client's IP and Request (only 64 chars, as this is
the maximum length stored by underlying Apache core library).

At the end there is a calculation of the total memory being used by
all httpd processes as reported by kernel, plus a result of an attempt
to approximately calculate the real memory usage when sharing is in
place. How do I calculate this:

1. For each process sum up the difference between shared and system
memory.

2. Now if we add the share size of the process with maximum
shared memory, we will get all the memory that actually is being
used by all httpd processes but the parent process.

Please note that this might be incorrect for your system, so you use
this number on your own risk. I have verified this number, by writing
it down and then killing all the servers. The system memory went down
by approximately this number. Again, use this number wisely!

If you don't want the Apache section to be displayed set:

  $Apache::VMonitor::Config{APACHE} = 0;

The default is to display this section.

=item top(1) emulation (any processes)

This section, just like the Apache/mod_perl processes section,
displays the information in a top(1) fashion. You use a regular
expression for processes you want to see.

For each group of matched processes, just like with
Apache/mod_processes a total size and estimation of the real memory
taken into account the shared memory, is displayed.

If you want the Apache section to be displayed a REGEX for processes
to match. e.g if you want to see C<http>, C<mysql> and C<squid>
processes, set:

  $Apache::VMonitor::PROC_REGEX = join "\|", qw(httpd mysql squid);

and

  $Apache::VMonitor::Config{PROCS} = 1;

The default is not to display this section.

=item mount(1) emulation

This section reports about mounted filesystems, the same way as if you
have called mount() with no parameters.

If you want the mount() section to be displayed set:

  $Apache::VMonitor::Config{MOUNT} = 1;

The default is NOT to display this section.

=item df(1) emulation 

This section completely reproduces the df() utility. For each mounted
filesystem it reports the number of total and available blocks (for
both superuser and user), and usage in percents.

In addition it reports about available and used filenodes in numbers
and percents.

This section has a capability of visual alert which is being triggered
when either some filesystem becomes more than 90% full or there are
less 10% of free filenodes left. When that happens the filesystem
related line will go bold and red and a mounting point will blink if
the blinking is turned on. You can the blinking off with:

  $Apache::VMonitor::Config{BLINKING} = 0;

If you don't want the df() section to be displayed set:

  $Apache::VMonitor::Config{FS_USAGE} = 0;

The default is to display this section.

=item ifconfig(1) emulation 

This section emulates the reporting capabilities of the ifconfig()
utility. It reports how many packets and bytes were received and
transmitted, their total, counts of errors and collisions, mtu
size. in order to display this section you need to set two variables:

  $Apache::VMonitor::Config{NETLOAD} = 1;

and to set a list of net devices to report for, like:

  @Apache::VMonitor::NETDEVS  = qw(lo eth0);

The default is NOT to display this section.

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

  <Location /sys-monitor>
    SetHandler perl-script
    PerlHandler Apache::VMonitor
  </Location>

The monitor will be displayed when you request
http://localhost/sys-monitor or alike.

You can control the behavior of this module by configuring the
following variables in the startup file or inside the B<<Perl>>
section.

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
  $Apache::VMonitor::Config{NETLOAD}  = 1;

What net devices to display if B<$Apache::VMonitor::Config{NETLOAD}> is ON:

  @Apache::VMonitor::NETDEVS  = qw(lo);

A regex to match processes for 'PROCS' section:

  $Apache::VMonitor::PROC_REGEX = join "\|", qw(httpd mysql squid);


Read the L<DESCRIPTION|/DESCRIPTION> section for a complete
explanation of each of these variables.

=head1 DYNAMIC RECONFIGURATION

C<Apache::VMonitor> allows you to dynamically turn on and off all the
sections and enter a verbose mode that explains each section and the
used abbreviations.

=head1 PREREQUISITES

You need to have B<Apache::Scoreboard>, B<Time::HiResand> and B<GTop>
installed. And of course a running mod_perl enabled apache server.

=head1 BUGS

Netload section reports negative bytes transferring when the numbers
are very big, consider it a bug or a feature, but the problem is in
the underlying libgtop library or GTop module and demands
investigation.

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