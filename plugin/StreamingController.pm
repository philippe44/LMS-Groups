package Plugins::Groups::StreamingController;

use strict;

use base qw(Slim::Player::StreamingController);

use List::Util qw(min max);

use Slim::Utils::Log;
use Slim::Utils::Prefs;

=comment
Note that 'stop', 'pause', 'play', 'resume' events are controller events
which shall not be confused with player methods. 
Note that powering off a member does *not* generate a 'stop' event, only
clearing the playlist does

When a virtual starts, all members are assembled. If empty, previoussyncgroup 
is set to current syncgroup if any, otherwise it is set to -1. It's because
when a player is member of more than one virtual that were both playing 
(first 1 then 2), we don't want it to re-join the 1st virtual when the 2nd
stops, it must rejoin the inital syncgroup, if any. It would be especially
bad if the 1st virtual has stopped because it would create a fantom group
To have such player re-join the 1st virtual, then play something on it!

When a virtual stops, all *still* synchronized members re-join their 
previoussyncgroup (in no-restart mode) unless it’s -1. If that group is 
playing then re-joining players are powered off. It could be unpleasant to
have stopped a virtual and one of its member restarts playing because of 
that re-grouping. The previoussyncgroup property must be deleted.

When a virtual pauses, the process is the same. In fact, pause and stop
are very similiar, stop seems to only happens when the playlist is cleared
or finished

Nicely, when a member is powered off, no stop event is generated, but it's 
put out of the active member list (in 'allPlayers' but not in 'players')
and method 'syncedWith' returns 'allPlayers'

When a member stops (closing a playlist), it leaves the virtual but does
not stop it (this is only doable with replaced Slim::Player::Source and 
Slim::Player::Playlist, otherwise the events do not include the player 
which generated it, so only option for 'stop' is to treat it as master's 
event). It re-joins (in norestart mode) its savedsyncgroup (property is 
deleted) which cannot be another virtual as explained earlier. Still, if
such group is playing, it would be the same issue as when the virtual stops
so the player is powered off - although one can argue that the user explicitly
cleared the playlist, so such re-join effect could be expected

When a member pauses, the virtual pauses with it as it is assumed that if the
user just wanted to change something on this particular player, it would power
it off or change its playlist (see above). Then, one can assume that user might
want to press resume on a member and expects the virtual to resume. For this 
to be achieved, the virtual is not disassembled. 
=cut

use constant TRACK_END	=> 0x0000;
use constant USER_STOP 	=> 0x0001;
use constant USER_PAUSE => 0x0002;

my $prefs = preferences('plugin.groups');
my $sprefs = preferences('server');
my $log   = logger('plugin.groups');

sub new {
	my ($class, $client) = @_;
	return $class->SUPER::new($client);
}

# playerBufferReady does not need to be surrogated as it is not filtered only for mast

sub playerTrackStarted {
	my ($self, $client) = @_;
	my $surrogate = _Surrogate($self);
				
	$log->info("track started $client");
	
	# send started on behalf of master
	$self->SUPER::playerTrackStarted($client->master) if $client == $surrogate;
	
	return $self->SUPER::playerTrackStarted($client);
}

sub playerStatusHeartbeat {
	my ($self, $client) = @_;
	my $surrogate = _Surrogate($self);
		
	$log->debug("status heartbeat $client");
	
	# send heartbeat on behalf of master
	$self->SUPER::playerStatusHeartbeat($client->master) if $client == $surrogate;
	
	return $self->SUPER::playerStatusHeartbeat($client);
}

sub playerStopped {
	my ($self, $client) = @_;
	my $surrogate = _Surrogate($self);
		
	$log->info("track ended $client");
	
	# send stop on behalf of master
	if ($client == $surrogate) {
		$self->SUPER::playerStopped($client->master);
		$self->undoGroup(TRACK_END);		
	}
	
	$self->SUPER::playerStopped($client);
}

sub play {
	my $self = shift;
	
	$log->info("play request $self");

	# be careful if we have been synced manually with a normal player
	$self->doGroup if $self->master->isa("Plugins::Groups::Player");
	
	return $self->SUPER::play(@_);
}	

sub stop {
	my $self = shift;
	my $client = shift;
	
	$log->info("stop request $self $client");
	
	return $self->SUPER::stop(@_) unless $self->master->isa("Plugins::Groups::Player");
	
	# when a member stops on its own, do not stop the whole group, instead 
	# just unsync the member to let the group continue, unless the member is
	# the only player in that group
	if (defined $client && $client != $self->master && $self->activePlayers() > 2) {
		$log->info("A member $client stopped on its own from ", $self->master);
		
		# unsync (do not keep syncid) and rejoin previously established groups
		$self->SUPER::unsync($client);
		_detach($client);
		
		return undef;
	} 
	
	# the master stopped, so undo the group and stops everything
	$self->undoGroup(USER_STOP);
	
	return $self->SUPER::stop(@_)
}	

sub resume {
	my $self = shift;
	
	$log->info("resume request $self");
	
	$self->doGroup(1) if $self->master->isa("Plugins::Groups::Player");
	return $self->SUPER::resume(@_);
}	

sub pause {
	my $self = shift;
	my $client = shift;
	
	$log->info("pause request $self from $client with master ", $self->master);

	# do not break up group solely when it's a "standalone" pause
	if ((!defined $client || $client == $self->master) && $self->master->isa("Plugins::Groups::Player")) {	
		$log->info("master pause ", $self->master, " or no client $client");
		$self->undoGroup(USER_PAUSE);		
	} else {
		$log->info("member $client paused on its own for ", $self->master);
	}	
	
	return $self->SUPER::pause(@_);
}

sub doGroup {
	my ($self, $resume) = @_;
		
	# we might already be assembled if a pause came from a single player
	return if scalar @{ $self->{'allPlayers'} } > 1;
	
	my $master = $self->master;
	my $masterVolume = 0;
	my $members = $prefs->client($master)->get('members') || return;
	my $volumes = $prefs->client($master)->get('volumes');
	
	foreach (@$members) {
		my $member = Slim::Player::Client::getClient($_);
		next unless $member;
		
		# power on all members if needed, only on first play, not on resume
		# unless it was forced off
		Slim::Control::Request::executeRequest($member, ['power', 1, 1]) 
			if $prefs->client($master)->get('powerPlay') && (!$resume || $member->pluginData('forcedPowerOff'));

=comment		
		if this player used to belong to a syncgroup, save it for later 
		restoration. Always set the restore id to something so that
		undoGroup does not create fantom groups (see header note)
		FIXME: cannot find a way to erase / set to undef a pluginData key ...
=cut		
		my $syncGroupId = $sprefs->client($member)->get('syncgroupid') // -1;
		$member->pluginData(syncgroupid => $syncGroupId) unless 
						defined $member->pluginData('syncgroupid') && 
						$member->pluginData('syncgroupid') != -1;
		
		$log->info("sync ", $member->name, " to ", $master->name, " former syncgroup ", $syncGroupId);
				
		$self->SUPER::sync($member, $resume);
		
		# memorize and set volume of members, but only memorize the original one
		my $volume = $member->pluginData('volume');
		$member->pluginData(volume => $member->volume) if !defined($volume) || $volume == -1;
		Slim::Control::Request::executeRequest($member, ['mixer', 'volume', $volumes->{$member->id}]);
	}
}

sub undoGroup {
	my ($self, $kind) = @_;
	my $master = $self->master;
		
	# disassemble the group
	foreach my $member ($master->syncedWith) {
		$log->info("undo group sync for ", $member->name, " from ", $master->name);
		$self->SUPER::unsync($member);
		
		# members shall not remember group's queue (NB: this is a new controller)
		$member->controller()->resetSongqueue();
		$member->playlist( [] );
		$member->currentPlaylist(undef);

		# rejoin previously established groups
		_detach($member);
	}
}

sub _detach {
	my ($client) = @_;
	
	# 'make room' in memorized static group for next playback
	my $syncGroupId = $client->pluginData('syncgroupid');
	$client->pluginData(syncgroupid => -1);
	
	# reset volume to previous value and free up room 
	Slim::Control::Request::executeRequest($client, ['mixer', 'volume', $client->pluginData('volume')]);
	$client->pluginData(volume => -1);
	
	# erase forced power off sequence
	$client->pluginData(forcedPowerOff => 0);
				
	# nothing to restore, just done
	return unless $prefs->get('restoreStatic') && $syncGroupId != -1;
		
	# restore static group if any
	$sprefs->client($client)->set('syncgroupid', $syncGroupId);
			
	# parse all players for a matching group but do not restart if it plays
	foreach my $other (Slim::Player::Client::clients()) {
		next if $other == $client;
		my $otherMasterId = $sprefs->client($other)->get('syncgroupid');

		if ($otherMasterId && ($otherMasterId eq $syncGroupId)) {
			$other->controller->sync($client, 1);
			$log->info("restore static ", $client->name, " with ", $other->name, " group $syncGroupId");
			# power-off if other is playing	to avoid member to play when virtual 
			# stops and memorize that forced power off
			if (!$other->isStopped) {
				Slim::Control::Request::executeRequest($client, ['power', 0]);
				$client->pluginData(forcedPowerOff => 1);				
			}	
			last;
		}	
	}
}

sub sync {
	my $self = shift;
	my ($player) = @_;
	
	# do not manaually add members
	$log->error("can't manually add members to a group");
	return; 

	return $self->SUPER::sync(@_);
}

sub unsync {
	my $self = shift;
	my ($player, $keepSyncGroupId) = @_;
	
	# do not manually remove members
	if ( caller(0) =~ m/Commands/) {
		$log->error("can't manually remove members from a group ");
		return;
	}
	
	# do not unsync a Group player! (this means it's beeing synced with another controller)
	# TODO: still need to make sure the unsync is always called for a group which means add 
	# a fantom non-connected player
	if ( $player->isa("Plugins::Groups::Player") && scalar @{ $self->{'players'} } > 1) {
		$log->error("can't remove ourselves from own group");
		return;
	}	
	
	$self->SUPER::unsync(@_);
}
		
sub _Surrogate {
	my $self = shift;
	my @activePlayers = $self->activePlayers;
	return $activePlayers[1];
}


1;
