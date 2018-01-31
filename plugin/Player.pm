package Plugins::Groups::Player;

use strict;

use base qw(Slim::Player::Player);

use List::Util qw(first);

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

# override the accessor from Client.pm: always return an empty list
sub chunks { [] }

use Data::Dumper;

sub formats { 
	my $self = shift;
	my $codecs;
	my @members = @{$prefs->client($self)->get('members') || []};
		
	foreach (@members)	{
		my $member = Slim::Player::Client::getClient($_);
		next unless $member;
		
		$codecs = [ $member->formats ] unless defined $codecs;
		@$codecs = map { my $v = $_; (first {$_ eq $v} $member->formats) || () } @$codecs;
	}
		
	# no attempt to create group done w/o codec
	return $codecs ? @$codecs : ();
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
	
	return $client->SUPER::init(@_);
}

sub initPrefs {
	my $client = shift;

	# make sure any preferences unique to this client may not have set are set to the default
	$sprefs->client($client)->init( {
		'maxBitrate'	=> 0,
	});
	
	# then init our own prefs
	$prefs->client($client)->init({
		'powerMaster' 	=> 1,
		'powerPlay' 	=> 1,
		'members'		=> [],
		'volumes' 		=> {},
	});
	
	$client->SUPER::initPrefs;
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
	
	# huh-huh, some fool tried to sync a group with another player
	if ( !$client->controller->isa("Plugins::Groups::StreamingController") ) {
		$log->error("NEVER SYNCHRONIZE A GROUP WITH A PLAYER ", $client->name);
		
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
	
	# try to recover from silly user synchronizing a group as this cannot be prevented
	if ( !$client->controller->isa("Plugins::Groups::StreamingController") ) {
		$client->controller(Plugins::Groups::StreamingController->new($client));
		$log->error("GROUP CONTROLLER WAS INCORRECT ", $client->name);
	}	
	
	# seems that members must be powered on/off before the following is executed
	if ($prefs->client($client)->get('powerMaster')) {
	
		main::INFOLOG && $log->is_info && $log->info("powering $on all members for ", $client->name);
	
		# power on/off all connected members
		foreach ( @{$prefs->client($client)->get('members') || [] } )	{
			my $member = Slim::Player::Client::getClient($_);
			next unless $member;
			# $member->power($on, $noplay)
			Slim::Control::Request::executeRequest($member, ['power', $on, $noplay]);
		}
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
