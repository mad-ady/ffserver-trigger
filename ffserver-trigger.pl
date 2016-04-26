#!/usr/bin/perl
use strict;
use warnings;
use Sys::Syslog qw(:standard :macros);

#
#  Script to continually parse ffserver's log and initiate a stream when a client connects
#  Requires the non-standard libfile-tail-perl package
#

my $filetail = eval{
	require File::Tail;
	File::Tail->import();
	1;
};

die "This program requires that you install the File::Tail module (sudo apt-get install libfile-tail-perl)" if(!$filetail);

#some global config options
my $logfile = '/var/log/syslog'
# log line looks like this:
# Apr 26 13:52:04 odroid64 ffserver[11182]: Tue Apr 26 13:52:04 2016 192.168.1.5:0 - - "PLAY live.h264.sdp/streamid=1 RTP/TCP"
my $triggerString = 'ffserver.*PLAY live.h264.sdp\/streamid';

openlog('ffserver-trigger', "pid", "local0");    # don't forget this


#set up the log listener

my $file = File::Tail->new(name => $logfile, maxinterval => 3, interval => 0.5 );
while (defined(my $line=$file->read)) {
    print "DBG: $line";
    if($line=~/$triggerString/){
    	syslog("info", "FFServer playback detected - checking if we need to start the stream");
	streamProcessing($line);
    }
}

# the streamProcessing function decides if it needs to start the stream (or which stream to start)
# it needs to be customized based on your own needs.
# The default implementation does the following:
# 1. Checks if the stream was started recently based on a lockfile (to prevent many restarts)
# 2. If the stream has been started long ago, or is not running, kill the old stream
# 3. Restart mjpg_streamer (which is the stream source)
# 4. Start a new ffmpeg instance in the background
# 5. Write the lock file
sub streamProcessing{
    my $line = shift;
    my $lockfile = '/tmp/ffserver-trigger';
    my $graceInterval = 5; #ignore requests if they have been serviced in the last $graceInterval seconds
    if(-f $lockfile){
	my $mtime = (stat($lockfile))[9];
	#check if the lockfile has not been updated more recently than $graceInterval
	if ($mtime < time() - $graceInterval){
	    #old lock file. Kill and restart everything just to be sure
	    syslog("info", "Old lockfile, restarting capture and streaming processes");
	    restartFFMpeg($lockfile);
	}
        else{
	    syslog("info", "Ignoring trigger - too soon");
	}
    }
    else{
	#must be the first run, create the lockfile and start ffmpeg
	syslog("info", "$lockfile missing - creating and starting stream");
	open TMPFILE, '>', $lockfile and close TMPFILE or die "File error with $lockfile: $!";
	restartFFMpeg($lockfile);
    }
}

sub restartFFMpeg{
    my $lockfile = shift;
    syslog("info", "Service restart output:".`/usr/sbin/service mjpg_service restart; /usr/sbin/service ffmpeg restart`);
    #touch the lockfile
    my $atime = (stat($lockfile))[8];
    utime $atime, time(), $lockfile;
}
