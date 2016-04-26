#!/usr/bin/perl
use strict;
use warnings;

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
