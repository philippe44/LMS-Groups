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

This controller MUST act like a regular controller when its master is not 
a Group player
=cut

use constant TRACK_END	=> 0x0000;
use constant USER_STOP 	=> 0x0001;
use constant USER_PAUSE => 0x0002;

my $prefs = preferences('plugin.groups');
my $sprefs = preferences('server');
my $log   = logger('plugin.groups');

####################################################################
# overloaded functions

sub new {
	my ($class, $client) = @_;
	return $class->SUPER::new($client);
}

# playerBufferReady does not need to be surrogated as it is not filtered only for master

sub playerTrackStarted {
	my ($self, $client) = @_;
		
	if ($self->master->isa("Plugins::Groups::Player")) {
		my $surrogate = _Surrogate($self);
		main::INFOLOG && $log->is_info && $log->info("track started $client");
	
		# send started on behalf of master
		$self->SUPER::playerTrackStarted($client->master) if $client == $surrogate;
	}	
	
	return $self->SUPER::playerTrackStarted($client);
}

sub playerStatusHeartbeat {
	my ($self, $client) = @_;
		
	if ($self->master->isa("Plugins::Groups::Player")) {
		my $surrogate = _Surrogate($self);
		main::DEBUGLOG && $log->is_debug && $log->debug("status heartbeat $client");
	
		# send heartbeat on behalf of master
		$self->SUPER::playerStatusHeartbeat($client->master) if $client == $surrogate;
	}
	
	return $self->SUPER::playerStatusHeartbeat($client);
}

sub playerStopped {
	my ($self, $client) = @_;
		
	if ($self->master->isa("Plugins::Groups::Player")) {
		my $surrogate = _Surrogate($self);
		main::INFOLOG && $log->is_info && $log->info("track ended $client");
	
		# send stop on behalf of master
		if ($client == $surrogate) {
			$self->SUPER::playerStopped($client->master);
			$self->undoGroup(TRACK_END);		
		}
	}	
	
	$self->SUPER::playerStopped($client);
}

sub play {
	my $self = shift;
		
	if ($self->master->isa("Plugins::Groups::Player")) {
		main::INFOLOG && $log->is_info && $log->info("play request $self");

		# be careful if we have been synced manually with a normal player
		$self->doGroup;
	}
	
	return $self->SUPER::play(@_);
}	

sub stop {
	my $self = shift;
	my $client = shift;
		
	if ($self->master->isa("Plugins::Groups::Player")) {
		main::INFOLOG && $log->is_info && $log->info("stop request $self $client");
	
		# when a member stops on its own, do not stop the whole group, instead 
		# just unsync the member to let the group continue
		if (defined $client && $client != $self->master) {
			main::INFOLOG && $log->is_info && $log->info("A member $client stopped on its own from ", $self->master);
		
			# unsync (do not keep syncid) and rejoin previously established groups
			$self->SUPER::unsync($client);
			_detach($client, 1);
		
			# let the group continue if it has more members
			return undef if $self->activePlayers() > 1;
		} 
	
		# the master stopped, so undo the group and stops everything
		$self->undoGroup(USER_STOP);
	}
	 
	return $self->SUPER::stop(@_)
}	

sub resume {
	my $self = shift;
	
	if ($self->master->isa("Plugins::Groups::Player")) {
		main::INFOLOG && $log->is_info && $log->info("resume request $self");
		$self->doGroup(1);
	}
	
	return $self->SUPER::resume(@_);
}	

sub pause {
	my $self = shift;
	my $client = shift;
	return $self->SUPER::pause(@_) unless $self->master->isa("Plugins::Groups::Player");


	if ($self->master->isa("Plugins::Groups::Player")) {	
		main::INFOLOG && $log->is_info && $log->info("pause request $self from $client with master ", $self->master);

		# do not break up group solely when it's a "standalone" pause
		if (!defined $client || $client == $self->master) {	
			main::INFOLOG && $log->is_info && $log->info("master pause ", $self->master, " or no client $client");
			$self->undoGroup(USER_PAUSE);		
		} else {
			main::INFOLOG && $log->is_info && $log->info("member $client paused on its own for ", $self->master);
			# group will remain assembled for required time
			Slim::Utils::Timers::setTimer($self, time() + $prefs->get('breakupTimeout')*60, \&undoGroup) if $prefs->get('breakupTimeout');
		}	
	}	
	
	return $self->SUPER::pause(@_);
}

sub sync {
	return unless $prefs->get('syncReal');

	my $self = shift;
	my ($player) = @_;
	my $members = $prefs->client($self->master)->get('members');
	
	# do not allow a player to sync to his own group (iPeng tries that)
	if (grep { $_ eq $player->id } @$members) {
		$log->warn("cannot statically sync a player to his group ", $self->master->id, " ", $player->id);
		return;
	}
				
	return $self->SUPER::sync(@_);
}

=comment
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
=cut
	

####################################################################
# support functions

sub doGroup {
	my ($self, $resume) = @_;
		
	# stop disassemble timers started on individual player's pause
	Slim::Utils::Timers::killTimers($self, \&undoGroup);		
		
	my $master = $self->master;
	my $members = $prefs->client($master)->get('members') || return;
	my $volumes = $prefs->client($master)->get('volumes');
	my $greedy = $prefs->client($master)->get('greedy');
	
	# prevent volume calculation when setting back group values for members
	$master->_volumeDispatching(1);			
	
	foreach (@$members) {
		my $member = Slim::Player::Client::getClient($_);
		next unless $member && $member->controller != $self  && (!$member->pluginData('marker') || !$member->controller->isPlaying || $greedy);
				
		# un-mark client now that it has re-joined the group		
		$member->pluginData(marker => 0);		
	
		# only memorize syncgroupid, playlist, power and prefs if we are not already part of a Group 
		if (!$member->controller->isa("Plugins::Groups::StreamingController")) {
			$member->pluginData(syncgroupid => $sprefs->client($member)->get('syncgroupid') // -1);
			$member->pluginData(power => $member->power);
			$member->pluginData(playlist => {
						playlist 	=> [ @{$member->playlist} ],
						shufflelist => [ @{$member->shufflelist} ],
						index   	=> Slim::Player::Source::streamingSongIndex($member),
						shuffle  	=> $sprefs->client($member)->get('shuffle'),
						repeat		=> $sprefs->client($member)->get('repeat'),
					} );	

			foreach my $key (keys %$Plugins::Groups::Player::groupPrefs, @Plugins::Groups::Player::onGroupPrefs) {
				$member->pluginData($key => $sprefs->client($member)->get("$key"));
			}
		}	
		
		# set all prefs that inherit from virtual player
		foreach my $key (keys %$Plugins::Groups::Player::groupPrefs) {
			$sprefs->client($member)->set("$key", $sprefs->client($master)->get("$key"));
		}
		
		# then set player prefs that are specific to this group
		foreach my $key (@Plugins::Groups::Player::onGroupPrefs) {
			my $data = $prefs->client($master)->get("$key") || {};
			$sprefs->client($member)->set("$key", $data->{$member->id}) if defined $data->{$member->id};
		}		
		
		# power on all members on first play, not on resume unless needed
		Slim::Control::Request::executeRequest($member, ['power', 1, 1]) 
			if $prefs->client($master)->get('powerPlay') && !$member->power && (!$resume || $member->pluginData('powerOnResume'));
			
		main::INFOLOG && $log->is_info && $log->info("sync ", $member->name, " to ", $master->name, " former syncgroup ", $member->pluginData('syncgroupid'));
				
		$self->SUPER::sync($member, $resume);
		
		# memorize and set volume of members, but only memorize the original one
		my $volume = $member->pluginData('volume');
		$member->pluginData(volume => $sprefs->client($member)->get("volume")) if !defined($volume) || $volume == -1;
		# request should be ignored if fixed volume but do not try to set a wrong volume (-1)
		Slim::Control::Request::executeRequest($member, ['mixer', 'volume', $volumes->{$member->id}]) if $volumes->{$member->id} != -1;
	}
	
	# volumes done
	$master->_volumeDispatching(0);			
}

sub undoGroup {
	my ($self, $kind) = @_;
	my $master = $self->master;
	my $members = $prefs->client($master)->get('members');
	
	# stop disassemble timers started on individual player's pause
	Slim::Utils::Timers::killTimers($self, \&undoGroup);		
	
	# disassemble the group, except the statically linked
	foreach my $member ($master->syncedWith) {
		next unless grep { $_ eq $member->id} @$members;
		
		main::INFOLOG && $log->is_info && $log->info("undo group sync for ", $member->name, " from ", $master->name);
		$self->SUPER::unsync($member);
		
		# rejoin previously established groups
		_detach($member);
		
		# if member has not returned to a sync group, restore previous playlist 
		# if any or erase Group Player's playlist
		if ($member->controller()->allPlayers < 2) {
			my $playlist = $member->pluginData('playlist');
			
			main::INFOLOG && $log->is_info && $log->info("restoring playlist");
				
			@{$member->playlist} = @{$playlist->{playlist}};
			@{$member->shufflelist} = @{$playlist->{shufflelist}};
		
			$sprefs->client($member)->set('shuffle', $playlist->{shuffle});
			$sprefs->client($member)->set('repear', $playlist->{repeat});
		
			$member->controller()->resetSongqueue($playlist->{index});
			$member->currentPlaylistUpdateTime(Time::HiRes::time());

			Slim::Control::Request::notifyFromArray($member, ['playlist', 'stop']);	
			Slim::Control::Request::notifyFromArray($member, ['playlist', 'sync']);
			
			# memorize current power state to avoid powering back on resume if 
			# it has been powered off individually then restore initial status
			$member->pluginData(powerOnResume => $member->power);
			# only restore initial power if member currently powered on
			Slim::Control::Request::executeRequest($member, ['power', $member->pluginData('power'), 1]) if $member->power;
		}
	}
}

sub _detach {
	my ($client, $marker) = @_;
	
	# 'make room' in memorized static group for next playback
	my $syncGroupId = $client->pluginData('syncgroupid') // -1;
	$client->pluginData(syncgroupid => -1);
	
	# mark the player
	$client->pluginData(marker => $marker || 0);
	
	# reset volume to previous value and free up room, no risk of volume loop
	# as controller is a not a special one any more (we are unsync)
	# the request should be ignored if the device has fixed volume
	Slim::Control::Request::executeRequest($client, ['mixer', 'volume', $client->pluginData('volume')]);
	$client->pluginData(volume => -1);
	
	# erase powerOnResume flag, it will be reset correctly if we are undoing a 
	# group or if the player is joining another sync group on detatch
	$client->pluginData(powerOnResume => 0);
	
	# restore overwritten prefs
	foreach my $key (keys %$Plugins::Groups::Player::groupPrefs, @Plugins::Groups::Player::onGroupPrefs) {
		$sprefs->client($client)->set("$key", $client->pluginData("$key"));
	}
				
	# done if no sync group or not configure to restore them
	return unless $prefs->get('restoreStatic') && $syncGroupId != -1;
	
	# restore sync group
	$sprefs->client($client)->set('syncgroupid', $syncGroupId);
			
	# parse all players for a matching group but do not restart if it plays
	foreach my $other (Slim::Player::Client::clients()) {
		next if $other == $client;
		my $otherMasterId = $sprefs->client($other)->get('syncgroupid');

		if ($otherMasterId && ($otherMasterId eq $syncGroupId)) {
			$other->controller->sync($client, 1);
			main::INFOLOG && $log->is_info && $log->info("restore static ", $client->name, " with ", $other->name, " group $syncGroupId");
			# power-off if other is playing	to avoid member to play when virtual 
			# stops and memorize that powering on resume is needed
			if (!$other->isStopped) {
				Slim::Control::Request::executeRequest($client, ['power', 0]);
				$client->pluginData(powerOnResume => 1);				
			}	
			last;
		}	
	}
}

sub _Surrogate {
	my $self = shift;
	my @activePlayers = $self->activePlayers;
	return $activePlayers[1];
}


1;
