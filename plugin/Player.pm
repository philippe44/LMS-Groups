package Plugins::Groups::Player;

# Logitech Media Server Copyright 2001-2011 Logitech.
# This program is free software; you can redistribute it and/or
# modify it under the terms of the GNU General Public License,
# version 2.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.

use strict;

use base qw(Slim::Player::Player);

use Slim::Utils::Log;
use Slim::Utils::Misc;
use Slim::Utils::Network;
use Slim::Utils::Prefs;

use Plugins::Groups::StreamingController qw(TRACK_END USER_STOP USER_PAUSE);;
use Plugins::Groups::Plugin qw(%groups);

my $prefs = preferences('plugin.groups');
my $serverPrefs = preferences('server');
my $log   = logger('plugin.groups');

{
	__PACKAGE__->mk_accessor('rw', '_volumeDispatching');
}

our $defaultPrefs = {
	'maxBitrate'		 => 0,
};	

sub model { "group" }
sub modelName { "Group" }
sub formats { qw(wma ogg flc aif pcm mp3) }
sub maxSupportedSamplerate { 192000 }
sub maxTreble { 50 }
sub minTreble { 50 }
sub maxBass { 50 }
sub minBass { 50 }

sub opened { return undef }
sub bufferFullness { 100000 }
sub bytesReceived { 100000 }
sub signalStrength { 100 }
sub startAt { 1 }
sub resume { 1 }
sub pauseForInterval { 1 }
sub skipAhead { 1 }
sub needsWeightedPlayPoint { 0 }
sub fade_volume { 1 }
sub connected { $_[0]->tcpsock }
# sub ipport { '127.0.0.1:0' }

sub new {
	my ($class, $id, $paddr, $rev, $s, $deviceid, $uuid) = @_;
	my $client = $class->SUPER::new($id, $paddr, $rev, $s, $deviceid, $uuid);
	
	$client->init_accessor(	
		_volumeDispatching                  => 0,
	);	
	
	$client->bufferReady(1);
	$client->bufferSize(128*1204);	
	
	$client->controller(Plugins::Groups::StreamingController->new($client));
	
	return $client;
}

sub init {
	my $client = shift;
	my $syncGroupId = $serverPrefs->client($client)->get('syncgroupid');
		
	# make sure we are not synchronized with anybody and try to get rid of dynamic group
	# if any, might not work if all players are not already connected. It's just a corner
	# case when restarting the server, at least we'll never be slave of a group
	foreach my $other (Slim::Player::Client::clients()) {
		next if $other == $client;
		my $otherMasterId = $serverPrefs->client($other)->get('syncgroupid');
		$other->controller->unsync($other) if $otherMasterId && ($otherMasterId eq $syncGroupId);
	}
	$serverPrefs->client($client)->remove('syncgroupid');
	
	return $client->SUPER::init(@_);
}

sub initPrefs {
	my $client = shift;

	# make sure any preferences unique to this client may not have set are set to the default
	$serverPrefs->client($client)->init($defaultPrefs);

	$client->SUPER::initPrefs();
}

sub songElapsedSeconds {
	my $surrogate = _Surrogate($_[0]);
	return $surrogate ? $surrogate->songElapsedSeconds : undef;
}

sub rebuffer {
	my $client = shift;
	$client->bufferReady(1);
}

sub play {
	my $client = shift;
	my $count = scalar $client->syncedWith;
	
	# do not try to play if there is no slave
	$log->error("Group player has no slave players") if !$count;
	
	# huh-huh, some fool tried to sync a group with another player
	if ( !$client->controller->isa("Plugins::Groups::StreamingController") ) {
		$log->error("NEVER SYNCHRONIZE A GROUP WITH A PLAYER ", $client->name);
		
		Slim::Utils::Timers::setTimer( $client,	Time::HiRes::time(), sub {
						$client->controller->unsync($client);
						$client->controller(Plugins::Groups::StreamingController->new($client));
					}
		);
		
		return 0;
	}
	
	return $count ? 1 : 0;
}

sub doSync {
	my ($client) = @_;
	
	foreach my $member ( @{$groups{$client->id}->{'members'}} ) {
		my $slave = Slim::Player::Client::getClient($member);
		next unless $slave;

		# if this player used to belong to a syncgroup, save it for later restoration	
		my $syncGroupId = $serverPrefs->client($slave)->get('syncgroupid') || 0;
		$serverPrefs->client($slave)->set('groups.syncgroupid', $syncGroupId) if $syncGroupId;
		$log->debug("sync ", $slave->name, " to ", $client->name, " former syncgroup ", $syncGroupId);
				
		$client->controller()->sync($slave);
	}
}

sub undoSync {
	my ($client, $kind) = @_;
	
	foreach my $slave ($client->syncedWith) {
		$log->info("undo group sync for ", $slave->name, " from ", $client->name);
		$slave->controller()->unsync($slave);
		
		my $syncGroupId = $serverPrefs->client($slave)->get('groups.syncgroupid');
		$serverPrefs->client($slave)->remove('groups.syncgroupid');
		
		# if this player belonged to a static group, restore it
		if ( $syncGroupId && $prefs->get('restoreStatic') && $kind != USER_PAUSE) {
			$log->info("restore static group $syncGroupId for ", $slave->name);
			
			$serverPrefs->client($slave)->set('syncgroupid', $syncGroupId);
			
			foreach my $other (Slim::Player::Client::clients()) {
				next if $other == $slave;
				my $otherMasterId = $serverPrefs->client($other)->get('syncgroupid');
				$other->controller->sync($slave, 1) if $otherMasterId && ($otherMasterId eq $syncGroupId);
			}
		}
	}
}

sub playPoint {
	my $surrogate = _Surrogate($_[0]);
	return $surrogate ? $surrogate->controller->{'players'}->[1]->playPoint : undef;
}

sub power {
	my $client = shift;
	my $on     = shift;
	my $noplay = shift;
	
	return $client->SUPER::power unless defined $on;
	
	# try to recover from silly user synchronizing a group as this cannot be prevented
	if ( !$client->controller->isa("Plugins::Groups::StreamingController") ) {
		$client->controller(Plugins::Groups::StreamingController->new($client));
		$log->error("GROUP CONTROLLER WAS INCORRECT ", $client->name);
	}	
	
	# do normal stuff
	$client->SUPER::power($on, $noplay);
	
	return if !$groups{$client->id}->{'syncPower'};
	
	$log->info("powering $on all members for ", $client->name);
	
	# power on all connected members
	foreach my $member ( @{$groups{$client->id}->{'members'}} )	{
		my $slave = Slim::Player::Client::getClient($member);
		next unless $slave;
		# $slave->power($on, $noplay)
		Slim::Control::Request::executeRequest($slave, ['power', $on, $noplay]);
	}
}

sub _Surrogate {
	my $client = shift;
	my @activePlayers = $client->controller->activePlayers;
	
	# avoid infinite recursing if virtual player was synchronized with another real player 
	# and happened to be the first in the list ... that causes LMS to shutdown
	return $activePlayers[1] != $client ? $activePlayers[1] : undef;
}

1;
