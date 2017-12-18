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

use Plugins::Groups::StreamingController;

use Data::Dumper;

my $prefs = preferences('plugin.groups');
my $log   = logger('plugin.groups');

sub new {
	my ($class, $id, $paddr, $rev, $s, $deviceid, $uuid) = @_;
	my $client = Slim::Utils::Accessor::new($class);

	main::INFOLOG && logger('network.protocol')->info("New client connected: $id");

	assert(!defined(Slim::Player::Client::getClient($id)));

	# Ignore UUID if all zeros or many zeroes (bug 6899)
	if ( defined $uuid && $uuid =~ /0000000000/ ) {
		$uuid = undef;
	}

	$client->init_accessor(

		# device identify
		id                      => $id,
		deviceid                => $deviceid,
		uuid                    => $uuid,

		# upgrade management
		revision                => $rev,
		_needsUpgrade           => undef,
		isUpgrading             => 0,

		# network state
		macaddress              => undef,
		paddr                   => $paddr,
		udpsock                 => undef,
		tcpsock                 => undef,

		# ir / knob state
		ircodes                 => undef,
		irmaps                  => undef,
		irRefTime               => undef,
		irRefTimeStored         => undef,
		lastirtime              => 0,
		lastircode              => 0,
		lastircodebytes         => 0,
		lastirbutton            => undef,
		startirhold             => 0,
		irtimediff              => 0,
		irrepeattime            => 0,
		irenable                => 1,
		_epochirtime            => Time::HiRes::time(),
		lastActivityTime        => 0,                   #  last time this client performed some action (IR, CLI, web)
		knobPos                 => undef,
		knobTime                => undef,
		knobSync                => 0,

		#The sequenceNumber is sent by the player for certain locally maintained player parameters like volume and power.
		#It is used to allow the player to act as the master for the locally maintained parameter.
		sequenceNumber          => 0,

		# The (controllerSequenceId, controllerSequenceNumber) tuple is used to enable synchronization of commands
		# sent to the player via the server and via an additional, out-of-band mechanism (currently UDAP).
		# It is used to enable the player to discard duplicate commands received via both channels.
		controllerSequenceId    => undef,
		controllerSequenceNumber=> undef,

		# streaming control
		controller              => undef,
		bufferReady             => 1,					# XXX => always ready
		readyToStream           => 1,
		streamStartTimestamp	=> undef,

		# streaming state
		streamformat            => undef,
		streamingsocket         => undef,
		remoteStreamStartTime   => 0,
		trackStartTime          => 0,
		outputBufferFullness    => undef,
		bytesReceived           => 0,
		songBytes               => 0,
		pauseTime               => 0,
		bytesReceivedOffset     => 0,
		streamBytes             => 0,
		songElapsedSeconds      => undef,
		bufferSize              => 128*1204,		   # XXX => forced
		directBody              => undef,
		chunks                  => [],
		bufferStarted           => 0,                  # when we started buffering/rebuffering
		streamReadableCallback  => undef,

		_currentplayingsong     => '',                 # FIXME - is this used ????

		# playlist state
		playlist                => [],
		shufflelist             => [],
		shuffleInhibit          => undef,
		startupPlaylistLoading  => undef,
		_currentPlaylist        => undef,
		currentPlaylistModified => undef,
		currentPlaylistRender   => undef,
		_currentPlaylistUpdateTime => Time::HiRes::time(), # only changes to the playlist
		_currentPlaylistChangeTime => undef,               # updated on song changes

		# display state
		display                 => undef,
		lines                   => undef,
		customVolumeLines       => undef,
		customPlaylistLines     => undef,
		lines2periodic          => undef,
		periodicUpdateTime      => 0,
		blocklines              => undef,
		suppressStatus          => undef,

		# button mode state
		modeStack               => [],
		modeParameterStack      => [],
		curDepth                => undef,
		curSelection            => {},
		lastLetterIndex         => 0,
		lastLetterDigit         => '',
		lastLetterTime          => 0,
		lastDigitIndex          => 0,
		lastDigitTime           => 0,
		searchFor               => undef,
		searchTerm              => [],
		lastID3Selection        => {},

		# sync state
		syncSelection           => undef,
		syncSelections          => [],
		_playPoint              => undef,              # (timeStamp, apparentStartTime) tuple
		playPoints              => undef,              # set of (timeStamp, apparentStartTime) tuples to determine consistency
		jiffiesEpoch            => undef,
		jiffiesOffsetList       => [],                 # array tracking the relative deviations relative to our clock

		# alarm state
		alarmData		=> {},			# Stored alarm data for this client.  Private.

		# Knob data
		knobData		=> {},			# Stored knob data for this client

		# other
		_tempVolume             => undef,
		musicInfoTextCache      => undef,
		metaTitle               => undef,
		languageOverride        => undef,
		controlledBy            => undef,
		controllerUA            => undef,
		password                => undef,
		currentSleepTime        => 0,
		sleepTime               => 0,
		pendingPrefChanges      => {},
		_pluginData             => {},
		updatePending           => 0,
		disconnected            => 0,

	);

	$Slim::Player::Client::clientHash{$id} = $client;

	$client->controller(Plugins::Groups::StreamingController->new($client));
	
	if (!main::SCANNER) {
		Slim::Control::Request::notifyFromArray($client, ['client', 'new']);
		
	}
	
	return $client;
}


sub model { "group" }
sub modelName { "Group" }
sub opened { return undef }
sub formats { return qw(wma ogg flc aif pcm mp3) }
sub bufferFullness { 100000 }
sub bytesReceived { 100000 }
sub signalStrength { 100 }
sub startAt { 1 }
sub resume { 1 }
sub pauseForInterval { 1 }
sub skipAhead { 1 }
sub needsWeightedPlayPoint { 0 }
sub connected { 1 }

sub songElapsedSeconds {
	my $surrogate = _Surrogate($_[0]);
	return $surrogate ? $surrogate->songElapsedSeconds : undef;
}

sub play {
	# return 1;
	my $count = scalar $_[0]->syncedWith;
	$log->error("Group player has no slave players") if !$count;
	return $count ? 1 : 0;
}

sub doSync {
	my ($client) = @_;
	
	my $needSync = 1;
	my %groups = Plugins::Groups::Plugin::getGroups();
		
	foreach my $member ( @{$groups{$client->id}->{'members'}} ) {
		my $slave = Slim::Player::Client::getClient($member);
		next unless $slave;
										
		$log->debug("sync ", $slave->name, " to ", $client->name);
				
		$client->controller()->sync($slave);
	}
}

sub undoSync {
	my $client = shift;
	
	$log->debug("un-sync ", $client->id);
	
	foreach my $slave ($client->syncedWith()) {
		$log->debug("unsync ", $slave->name, " from ", $client->name);
		$slave->controller()->unsync($slave);
	}
}

sub pause {
}

sub stop {
	my $client = shift;
	$client->SUPER::stop();
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
			
	# do normal stuff
	$client->SUPER::power($on, $noplay);
			
	return if !$prefs->client($client)->get('syncPower');
	
	my %groups = Plugins::Groups::Plugin::getGroups();
	
	$log->debug("powering all memebrs $on");
	
	# power on all connected members
	foreach my $member ( @{$groups{$client->id}->{'members'}} )	{
		my $slave = Slim::Player::Client::getClient($member);
		next unless $slave;
		$slave->power($on, $noplay)
	}
}

sub fade_volume { 1 }
	
sub volume {
	my $client = shift;
	my $newVolume = shift;
	my $isTemp = shift;

	if (defined $newVolume && !$isTemp) {
		my $oldVolume = $client->SUPER::volume();
		
		$log->debug("volume change $oldVolume $newVolume ");

		foreach my $slave ($client->syncedWith()) {
			my $slaveVolume = $slave->volume();
			$slave->volume($oldVolume ? $slaveVolume*$newVolume/$oldVolume  : $newVolume);
		}	
	}

	return $client->SUPER::volume($newVolume, $isTemp);
}

sub _Surrogate {
	my $client = shift;
	my @activePlayers = $client->controller->activePlayers;
	return $activePlayers[1];
}

1;
