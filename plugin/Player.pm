package Plugins::Groups::Player;

use strict;

use base qw(Slim::Player::Player);

use Slim::Utils::Log;
use Slim::Utils::Misc;
use Slim::Utils::Network;
use Slim::Utils::Prefs;

use Plugins::Groups::Plugin;
use Plugins::Groups::StreamingController;

my $prefs = preferences('plugin.groups');
my $sprefs = preferences('server');
my $log = logger('plugin.groups');

{
	__PACKAGE__->mk_accessor('rw', qw(_volumeDispatching));
}

sub model { "group" }
sub modelName { "Group" }
sub maxTreble { 50 }
sub minTreble { 50 }
sub maxBass { 50 }
sub minBass { 50 }
sub maxTransitionDuration { 10 }
sub canDoReplayGain { 65536 }
sub isVirtual { 1 }

sub opened { return undef }
sub bufferFullness { 100000 }
sub bytesReceived { 100000 }
sub signalStrength { 100 }
sub startAt { 1 }
sub resume { 1 }
sub pauseForInterval { 1 }
sub skipAhead { 1 }
sub needsWeightedPlayPoint { 0 }
sub connected { $_[0]->tcpsock }
# sub ipport { '127.0.0.1:0' }

our $groupPrefs = {
	'transitionType'     => 0,
	'transitionDuration' => 10,
	'transitionSmart'    => 1,
	'replayGainMode'     => 0,
	'remoteReplayGain'   => -5,
};	

our $forcedPrefs = {
	'syncPower'          => 0,
	'syncVolume'         => 0,
};

my $defaultPrefs = {
	%{ $groupPrefs },
	%{ $forcedPrefs },
	'maxBitrate'		 => 0,
};

our @onGroupPrefs = qw(outputChannels);

our $playerPrefs = {
	'powerPlay' 	=> 1,
	'powerMaster' 	=> 1,
	'greedy' 		=> 0,
    'weakVolume'   => 0,
};	

$prefs->migrate(1, sub {
	$prefs->set('cliport', Slim::Utils::Prefs::OldPrefs->get('cliport') || 9090); 1;
});

# override the accessor from Client.pm: always return an empty list
sub chunks { [] }

sub maxSupportedSamplerate { 
	my $self = shift;
	my $rate = 192000;
		
	foreach ( @{$prefs->client($self)->get('members') || []} )	{
		my $member = Slim::Player::Client::getClient($_) || next;
		$rate = $member->maxSupportedSamplerate if $member->maxSupportedSamplerate < $rate;
	}

	return $rate;
} 

sub formats { 
	my $self = shift;
	my $codecs;		# use listref to distinguish undefined from empty
		
	foreach ( @{$prefs->client($self)->get('members') || []} )	{
		my $member = Slim::Player::Client::getClient($_) || next;

		if (!defined $codecs) {
			$codecs = [ $member->formats ];
			next;
		}		
		
		my %formats = map { $_ => 1 } $member->formats;
		$codecs = [ grep { $formats{$_} } @$codecs ];
	}
		
	# no attempt to create group done w/o codec
	return @{ $codecs || [] };
} 

sub new {
	my ($class, $id, $paddr, $rev, $s, $deviceid, $uuid) = @_;
	my $client = $class->SUPER::new($id, $paddr, $rev, $s, $deviceid, $uuid);
	
	$client->init_accessor(	
		_volumeDispatching => 0,
	);	
	
	$client->bufferReady(1);
	$client->bufferSize(128*1204);	
	
	$client->controller(Plugins::Groups::StreamingController->new($client));
	
	return $client;
}

sub init {
	my $client = shift;
	my $syncGroupId = $sprefs->client($client)->get('syncgroupid');
		
	# make sure we are not synchronized with anybody and try to get rid of dynamic group
	# if any, might not work if all players are not already connected. It's just a corner
	# case when restarting the server, at least we'll never be slave of a group
	foreach my $other (Slim::Player::Client::clients()) {
		next if $other == $client;
		my $otherMasterId = $sprefs->client($other)->get('syncgroupid');
		$other->controller->unsync($other) if $otherMasterId && ($otherMasterId eq $syncGroupId);
	}
	$sprefs->client($client)->remove('syncgroupid');
	
	# we take care of power on/off and volume sync
	$sprefs->client($client)->remove('syncPower');
	$sprefs->client($client)->remove('syncVolume');
	
	return $client->SUPER::init(@_);
}

sub initPrefs {
	my $client = shift;

	# make sure any preferences unique to this client may not have set are set to the default
	$sprefs->client($client)->init($defaultPrefs);
	
	# then init our own prefs
	$prefs->client($client)->init({
		%$playerPrefs,
		'members'		=> [],
		'volumes' 		=> {},
	});
	
	$client->SUPER::initPrefs;
}

sub fade_volume {
	my ($client, $fade, $callback, $callbackargs) = @_;
	
	$callback->(@{$callbackargs}) if ($callback);
	return 1;
}

sub songElapsedSeconds {
	my $client = shift;
	
	return 0 if $client->isStopped() || defined $_[0];
	
	my $surrogate = _Surrogate($client);
	
	# memorise last position for when we'll lose surrogate (pause)
	$client->SUPER::songElapsedSeconds($surrogate->songElapsedSeconds) if $surrogate;
		
	return $client->SUPER::songElapsedSeconds;
}

sub playPoint {
	my $client = shift;
	
	return if $client->isStopped();
	
	my $surrogate = _Surrogate($client);
	
	# memorise last playpoint for when we'll lose surrogate (pause)
	$client->SUPER::_playPoint($surrogate->controller->{'players'}->[1]->playPoint(@_)) if $surrogate;
	
	return $client->SUPER::_playPoint;
}

sub rebuffer {
	my $client = shift;
	
	# make sure we don't block the others
	$client->bufferReady(1);
	
	# I don't think this is strictly necessary as other players will move the 
	# controller to buffer ready state
	Slim::Utils::Timers::setTimer( $client,	Time::HiRes::time() + 0.125, sub {
						$client->controller->playerBufferReady($client);
						}
		);
}

sub play {
	my $client = shift;
	my $count = scalar $client->syncedWith;
	
	# do not try to play if there is no member
	$log->error("Group player has no member") if !$count;

	# something wrong happened, we don't have the right controller anymore
	if ( !$client->controller->isa("Plugins::Groups::StreamingController") ) {
		$log->error("controller overwritten ", $client->name);
		
		# exit from that group ASAP and restore our crashed controller
		Slim::Utils::Timers::setTimer( $client,	Time::HiRes::time(), sub {
						$client->controller->unsync($client);
						$client->controller(Plugins::Groups::StreamingController->new($client));
					}
		);
		
		return 0;
	}
	
	return $count ? 1 : 0;
}

sub power {
	my $client = shift;
	my $on     = shift;
	my $noplay = shift;
	
	return $client->SUPER::power($on, $noplay) unless defined $on;
		
	# seems that members must be powered on/off before the following is executed
	my $power = $prefs->client($client)->get('powerMaster');
	main::INFOLOG && $log->is_info && $log->info("powering $on all members for ", $client->name) if $power;
	
	# power on/off all connected members
	foreach ( @{$prefs->client($client)->get('members') || [] } )	{
		my $member = Slim::Player::Client::getClient($_);
		next unless $member;
		# $member->power($on, $noplay)
		Slim::Control::Request::executeRequest($member, ['power', $on, $noplay]) if $power;
		$member->pluginData(marker => 0);
	}

=comment
	code borrowed from Slim::Player::Player but that forces a controller stop 
	in all cases. We *must* not just stop the virtual otherwise a real player
	will become master and that'll be messy
=cut	

	my $resume = $sprefs->client($client)->get('powerOnResume');
	$resume =~ /(.*)Off-(.*)On/;
	my ($resumeOff, $resumeOn) = ($1,$2);
	
	my $controller = $client->controller();

	if (!$on) {
		my $playing = $controller->isPlaying(1);
		$sprefs->client($client)->set('playingAtPowerOff', $playing);
			
		if ($playing && ($resumeOff eq 'Pause')) {
			# Pause client mid track
			$client->execute(["pause", 1, undef, 1]);
		} elsif ($controller->isPaused() && ($resumeOff eq 'Pause')) {
			# already paused, do nothing
		} else {
			$client->execute(["stop"]);
		}
	 	
	 	# Do now, not earlier so that playmode changes still work
	 	$sprefs->client($client)->set('power', $on); # Do now, not earlier so that 
	} else {
		$sprefs->client($client)->set('power', $on);
		
		# if this really needed? As a virtual, we can't be inactive 
		$controller->playerActive($client);

		if (!$controller->isPlaying() && !$noplay) {
			
			if ($resumeOn =~ /Reset/) {
				# reset playlist to start, but don't start the playback yet
				$client->execute(["playlist","jump", 0, 1, 1]);
			}
			
			if ($resumeOn =~ /Play/ && Slim::Player::Playlist::song($client)
				&& $sprefs->client($client)->get('playingAtPowerOff')) {
				$client->execute(["play"]); # will resume if paused
			}
		}		
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
