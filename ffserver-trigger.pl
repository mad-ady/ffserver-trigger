#!/usr/bin/perl
use strict;
use warnings;
use Sys::Syslog qw(:standard :macros);

#
#  Script to continually parse ffserver's log and initiate a stream when a client connects
#  Also keeps track of connected clients and terminates the stream when the last client disconnects
#  Requires the non-standard libfile-tail-perl package
#

my $filetail = eval{
	require File::Tail;
	File::Tail->import();
	1;
};

die "This program requires that you install the File::Tail module (sudo apt-get install libfile-tail-perl)" if(!$filetail);

my $procnettcp = eval{
	require Linux::Proc::Net::TCP;
	Linux::Proc::Net::TCP->import();
	1;
};

die "This program requires that you install the Linux::Proc::Net::TCP module (sudo perl -MCPAN -e 'install Linux::Proc::Net::TCP')" if (!$procnettcp);

#some global config options
my $logfile = '/var/log/syslog';
# log line looks like this:
# Apr 26 13:52:04 odroid64 ffserver[11182]: Tue Apr 26 13:52:04 2016 192.168.1.5:0 - - "PLAY live.h264.sdp/streamid=1 RTP/TCP"
my $startStreaming = 'ffserver\[[0-9]+\].* ([0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}):.*PLAY live.h264.sdp\/streamid';
#log line looks like this:
#
my $stopStreaming = 'ffserver\[[0-9]+\].* ([0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}) .* (?:\[\] " RTP\/TCP"|\[\$#[0-9]+\] " ")';

openlog('ffserver-trigger', "pid", "local0");    # don't forget this

# A hash to store existing connections
my %connections = ();

my $lastStarted = 0;

#set up the log listener

my $file = File::Tail->new(name => $logfile, maxinterval => 1, interval => 0.2 );
while (defined(my $line=$file->read)) {
#    print "DBG: $line";
    if($line=~/$startStreaming/){
    	syslog("info", "FFServer playback detected - checking if we need to start the stream");
	streamProcessing($line);
    }
    if($line=~/$stopStreaming/){
	syslog("info", "FFServer playback stopped - checking if we need to stop the stream");
	streamProcessing($line);
    }
    if($line=~/ffserver.service: Unit entered failed state/){
	#oh, dear - ffserver crashed.
	#All RTSP clients are disconnected
	syslog("info", "Detected ffserver crash - disconnecting all clients");
	%connections = ();
    }
}

# the streamProcessing function decides if it needs to start the stream (or which stream to start)
# it needs to be customized based on your own needs.
# The default implementation does the following:
# 1. Identifies the IP requesting the stream and checks via netstat how many streams are active
# 2. Compares with historical information to detect the new stream (if any)
# 3. If new stream, starts ffmpeg process
# 4. When stream ends checks to see if it's the last stream and shuts down ffmpeg

sub streamProcessing{
    my $line = shift;
    my $ffmpegStatus = getFFMPEGStatus();
    if($line=~/$startStreaming/){
	my $ip = $1;
	#Use netstat to extract established TCP connections to port 554 for this IP
	my @ports = netstat($ip);
	syslog("debug", "Analyzing a start request");
	if(scalar @ports > 0 && $ffmpegStatus > 0){
		#we have new ports and ffmpeg is off
		restartFFMPEG();
	}
	else{
		syslog("info", "Not starting ffmpeg because it's already running ($ffmpegStatus) or no new ports request it (@ports)");
	}


    }
    if($line=~/$stopStreaming/){
	my $ip = $1;
	my $total = getTotalViewers();
	#Use netstat to extract established TCP connections to port 554 for this IP
        my @ports = netstat($ip);
	syslog("debug", "Analyzing a stop request");
	if(scalar @ports > 0 && $ffmpegStatus == 0){
		#only stop the stream if it's the last client, independent of IP
		syslog("debug", "We had a total of $total active viewers");
		if($total <= 1){
			#we can stop the stream
			stopFFMPEG();
		}
		else{
			syslog("info", "Not stopping the stream because we still have viewers");
		}
	}	
    }
}

sub getTotalViewers{
	my $total = 0;
	foreach my $ip (keys %connections){
		foreach my $port (keys %{$connections{$ip}}){
			$total++;
		}
	}
	return $total;
}

sub getFFMPEGStatus{
	my $status = system('/bin/systemctl', '--no-pager', 'status', 'ffmpeg');
	# 0 - running
	# >0 - not-running
	return $status;
}

sub netstat{
    # returns the new connection/deleted connection for this IP
    my $ip = shift;
    # We're Linux:Proc:Net:TCP to read /proc/net/tcp
    my $table = Linux::Proc::Net::TCP->read;
    my %currentPorts = ();
    my @changedPorts = ();

    foreach my $entry (@$table) {
	if($entry->local_port eq 554 || $entry->rem_port eq 554){
		if($entry->local_address eq $ip){
			$currentPorts{$entry->local_port} = $entry->st;
		}
		if($entry->rem_address eq $ip){
			$currentPorts{$entry->rem_port} = $entry->st;
		}
	}
    }
    #look for new ports
    foreach my $port (keys %currentPorts){
	if(!defined $connections{$ip}{$port}){
		#a new connection found
		syslog("debug", "Found new port $ip:$port in state $currentPorts{$port}");
		$connections{$ip}{$port} = 1;
		push @changedPorts, $port;
	}
    }
    #look for missing ports (closed connections)
    foreach my $port (keys %{$connections{$ip}}){
	if(!defined $currentPorts{$port}){
		#this port has closed - we save them as negative numbers
		syslog("debug", "Found closed port $ip:$port");
		delete $connections{$ip}{$port};
		push @changedPorts, "-$port";
	}
    }
    return @changedPorts;
}

# edit the code below to fit your restarting needs. Note, this process should start as root to be able to restart services

sub restartFFMPEG{
    # If you see that often the stream is locked when starting, uncomment the lines below to restart mjpg_streamer as well
    syslog("info", "Restarting mjpg_streamer");
    `/usr/sbin/service mjpg_streamer restart; sleep 2`;
    syslog("info", "Restarting ffmpeg streamer");
    `/usr/sbin/service ffmpeg restart`;
    $lastStarted = time();
}

sub stopFFMPEG{
    # we will stop ffmpeg only if it was started at least 20 seconds ago. This is to avoid fast start/stop cycles
    my $now = time();
    my $seconds = 20;
    if($now - $lastStarted > $seconds){
	syslog("info", "Stopping ffmpeg streamer");
	`/usr/sbin/service ffmpeg stop`;
    }
    else{
	syslog("info", "Ignoring ffmpeg stop command, because it was started less than $seconds seconds ago!");
    }
}
