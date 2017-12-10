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

use Data::Dumper;

my $prefs = preferences('plugin.groups');
my $log   = logger('plugin.groups');

sub new {
	my ($class, $id, $paddr, $rev, $s, $deviceid, $uuid) = @_;

	#my $client = $class->SUPER::new;
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
		tcpsock                 => 1,				# connected at creation

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

	$client->controller(Slim::Player::StreamingController->new($client));

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

sub connected {
	my $client = shift;
	return defined $client->tcpsock() ? 1 : 0;
}

# don't understand why this is never called, because it's used by the HTTP client of the real player?
sub nextChunk {
	$log->error("NEXT CHUNK CALLED");
	my $chunk = Slim::Player::Source::nextChunk(@_);
	@{$_[0]->chunks} = ();
}

sub songElapsedSeconds {
	my $active = firstActive($_[0]);
	return $active->songElapsedSeconds if $active;
}

sub play {
	my $client = shift;
	my $emptyChunk;
	
	$log->error("PLAYING ", $client, " ", $client->id, " ", $client->isPlaying);
	
	# Creating the sync group creates a stop that cannot be distinguished from a regular stop, and 
	# then another start happens
	Slim::Utils::Timers::killTimers($client, \&undoSync);
	
	my $needSync = 0;
	my %groups = Plugins::Groups::Plugin::getGroups();
	my $powerOn = $prefs->get('powerup');
	
	foreach my $member ( @{$groups{$client->id}->{'members'}} )	{
		my $slave = Slim::Player::Client::getClient($member);
		next unless $slave;
		$slave->power(1) if ($powerOn);
		$needSync |= !$client->isSyncedWith($slave);
	}	
	
	if ($needSync) {
		$log->debug("re-sync needed"); 
		
		# cannot call that in play() as this causes a recursing problem
		Slim::Utils::Timers::setTimer($client, Time::HiRes::time(), sub {
					foreach my $member ( @{$groups{$client->id}->{'members'}} ) {
						my $slave = Slim::Player::Client::getClient($member);
						next unless $slave;
				
						$log->debug("sync " . $slave->name() . " to " .  $client->name() . " Power " . $powerOn);
					
						$client->controller()->sync($slave);
					}
				} );	
	}			
	
	Slim::Utils::Timers::setTimer($client, Time::HiRes::time(), \&pollHandler);
						
	return 1;
}

sub undoSync {
	my $client = shift;
	
	$log->debug("un-sync ", $client->id);
	
	foreach my $slave ($client->syncedWith()) {
		$slave->controller()->unsync($slave);
	}
}

#
# pause
#
sub pause {
}

sub stop {
	my $client = shift;
	
	$log->error("STOP ", $client->isPlaying, " ", $client->id);
	
	Slim::Utils::Timers::killTimers($client, \&pollHandler);
		
	# Cannot undo sync now as STOP might be called immediately after START due to
	# sync creation. This timer will be killed by any PLAY request so that we do not
	# undo the sync just after we created it
	Slim::Utils::Timers::setTimer($client, Time::HiRes::time() + 5, \&undoSync);

	$client->SUPER::stop();

}

sub pollHandler {
	my $client = shift;
	
	Slim::Utils::Timers::setTimer($client, Time::HiRes::time() + 1, \&pollHandler);
	
	# empty chunks regularly as there is no real player to use them
	@{$client->chunks} = ();
	
	my $active = firstActive($client);
	return unless $active;

	# need to evaluate position + 2 as we only check every second
	if ( $active->songElapsedSeconds() + 2 > $active->playingSong()->duration() - $active->playingSong()->startOffset() ) {
		if ( $active->readyToStream() ) {
			$client->controller()->playerStopped($client);
		} else { 
			$client->controller()->playerTrackStarted($client);
		}	
	}
		
	$client->controller()->playerStatusHeartbeat($client) if $client->isPlaying;
}	

sub playPoint {
	my $active = firstActive($_[0]);
	return $active ? $active->playPoint : undef;
}

sub power {
	my $client = shift;
	my $on     = shift;
	my $noplay = shift;

	my $currOn = $prefs->client($client)->get('power') || 0;

	return $currOn unless defined $on;
	return unless (!defined(Slim::Buttons::Common::mode($client)) || ($currOn != $on));

	my $resume = $prefs->client($client)->get('powerOnResume');
	$resume =~ /(.*)Off-(.*)On/;
	my ($resumeOff, $resumeOn) = ($1,$2);

	my $controller = $client->controller();

	if (!$on) {
		# turning player off - unsync/pause/stop player and move to off mode
		my $playing = $controller->isPlaying(1);
		$prefs->client($client)->set('playingAtPowerOff', $playing);

		if ($playing && ($resumeOff eq 'Pause')) {
			# Pause client mid track
			$client->execute(["pause", 1, undef, 1]);
		} elsif ($controller->isPaused() && ($resumeOff eq 'Pause')) {
			# already paused, do nothing
		} else {
			$client->execute(["stop"]);
		}

		# Do now, not earlier so that playmode changes still work
		$prefs->client($client)->set('power', $on); # Do now, not earlier so that

	} else {

		$prefs->client($client)->set('power', $on);

		$controller->playerActive($client);

		if (!$controller->isPlaying() && !$noplay) {

			if ($resumeOn =~ /Reset/) {
				# reset playlist to start, but don't start the playback yet
				$client->execute(["playlist","jump", 0, 1, 1]);
			}

			if ($resumeOn =~ /Play/ && Slim::Player::Playlist::song($client)
				&& $prefs->client($client)->get('playingAtPowerOff')) {
				$client->execute(["play"]); # will resume if paused
			}
		}
	}

	# all players in group have synced power
	foreach my $slave ($client->syncedWith()) {
		# do not use [execute] otherwise this creates an infinite loop
		$slave->power($on) if $prefs->get('powerup');
	}
}

sub volume {
	my $client = shift;
	my $newVolume = shift;

	if (defined $newVolume) {
		my $oldVolume = $client->SUPER::volume();

		foreach my $slave ($client->syncedWith()) {
			my $slaveVolume = $slave->volume();
			$slave->volume($oldVolume ? $slaveVolume*$newVolume/$oldVolume  : $newVolume);
		}
	}

	return $client->SUPER::volume($newVolume, @_);
}

sub firstActive {
	my $client = shift;

	foreach my $slave ($client->syncedWith()) {
		return $slave unless !$slave->power;
	}

	return undef;
}


1;
