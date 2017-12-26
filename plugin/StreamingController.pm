package Plugins::Groups::StreamingController;

use strict;

use base qw(Slim::Player::StreamingController);

use List::Util qw(min max);

use Slim::Utils::Log;
use Slim::Utils::Prefs;

use constant TRACK_END	=> 0x0000;
use constant USER_STOP 	=> 0x0001;
use constant USER_PAUSE => 0x0002;

use constant CHUNK_QUEUED_AWM	 => 5;
use constant CHUNK_MIN_TIMER 	=> 0.05;
use constant CHUNK_MAX_TIMER 	=> 30;

my $prefs = preferences('plugin.groups');
my $serverPrefs = preferences('server');
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
	
	# this is probably not strictly needed, but I'm not sure what happens with low
	# bitrate file when the cleaning timer is at max but more chunks are added again
	# because the player needs more ... that might cause queue stalling. By putting
	# another cleanup here, it does not hurt and will take care or regulat cleaning
	@{$client->master->chunks} = ();
	
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
		$self->unsync($client);
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
		
	# when pausing, the whole group shall stop, wheter pause comes from the
	# master or a member. But we shall save syncgroupid so that when that 
	# plaver restarts, we re-assemble the group. Difficulty is that when it
	# restarts, it's not anymore using a "Plugin::Group::StreamingController"
	# class, so the virtual group is just a member of that group, and will be
	# allocated a Slim::Player::Controller. We need to change that as soon
	# as we receive the sync 
	$self->undoGroup(USER_PAUSE, $client == $self->master) if $self->master->isa("Plugins::Groups::Player");
	return $self->SUPER::pause(@_);
}

sub _chunksCleaner {
	my ($self, $timer) = @_;
	my $chunks = scalar @{$self->master->chunks};

	@{$self->master->chunks} = ();
	
	# need to set a max because lowrate mp3 might cause us to sleep for a very long time but queue 
	# should resume at some point
	$timer = min(max($timer * CHUNK_QUEUED_AWM / ($chunks || CHUNK_QUEUED_AWM * 0.66), CHUNK_MIN_TIMER), CHUNK_MAX_TIMER);
	$log->info("$chunks chunks => sleep $timer");
	
	# restart ourselves - this timer will be terminated by undoGroup
	Slim::Utils::Timers::setTimer($self, Time::HiRes::time() + $timer, \&_chunksCleaner, $timer);
}

sub doGroup {
	my ($self, $resume) = @_;
	my $client = $self->master;
	
	foreach ( @{ $prefs->client($client)->get('members') || [] } ) {
		my $member = Slim::Player::Client::getClient($_);
		next unless $member;
		
		# power on all members if needed, only on first play, not on resume
		Slim::Control::Request::executeRequest($member, ['power', 1, 1]) if !$resume && $prefs->client($client)->get('syncPowerPlay');
		
		# if this player used to belong to a syncgroup, save it for later restoration	
		my $syncGroupId = $serverPrefs->client($member)->get('syncgroupid') || 0;
		$serverPrefs->client($member)->set('groups.syncgroupid', $syncGroupId) if $syncGroupId;
		$log->debug("sync ", $member->name, " to ", $client->name, " former syncgroup ", $syncGroupId);
				
		$self->sync($member, $resume);
	}
	
	# safety mechanism in case the Slim::Player::Source::nextChunk has not been 
	# overloaded properly. In theory, here is not the right place to start the 
	# timer because if we pause, the timer will continue to grow and upon resume
	# filling will restart on the Source that has the connection, will then be 
	# stalled till we empty our queue, which might not happen before a while.
	# But that does not happen as the group is broken up at every pause, so 
	# we'll restart a fresh timer
	Slim::Utils::Timers::setTimer($self, Time::HiRes::time() + CHUNK_MIN_TIMER, \&_chunksCleaner, CHUNK_MIN_TIMER);
}

sub undoGroup {
	my ($self, $kind, $keepSyncId) = @_;
	my $client = $self->master;
	
	# disassmble the group, take care of previously established groups
	foreach my $member ($client->syncedWith) {
		$log->info("undo group sync for ", $member->name, " from ", $client->name);
		$self->unsync($member, $keepSyncId);
		
		next if $kind == USER_PAUSE;
		
		my $syncGroupId = $serverPrefs->client($member)->get('groups.syncgroupid');
		$serverPrefs->client($member)->remove('groups.syncgroupid');
		
		# restore static group if any
		if ( $syncGroupId && $prefs->get('restoreStatic') ) {
			$log->info("restore static group $syncGroupId for ", $member->name);
			
			$serverPrefs->client($member)->set('syncgroupid', $syncGroupId);
			
			foreach my $other (Slim::Player::Client::clients()) {
				next if $other == $member;
				my $otherMasterId = $serverPrefs->client($other)->get('syncgroupid');
				$other->controller->sync($member, 1) if $otherMasterId && ($otherMasterId eq $syncGroupId);
			}
		}
	}
	
	# can stop chunks cleanup timers
	Slim::Utils::Timers::killTimers($self, \&_chunksCleaner);	
}
	

sub _Surrogate {
	my $self = shift;
	my @activePlayers = $self->activePlayers;
	return $activePlayers[1];
}


1;
