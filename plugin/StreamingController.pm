package Plugins::Groups::StreamingController;

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

use base qw(Slim::Player::StreamingController);

use Slim::Utils::Log;
use Slim::Utils::Prefs;

use constant TRACK_END	=> 0x0000;
use constant USER_STOP 	=> 0x0001;
use constant USER_PAUSE => 0x0002;

use Exporter qw(import);
our @EXPORT_OK = qw(TRACK_END USER_STOP USER_PAUSE);

my $prefs = preferences('plugin.groups');
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
	
	# empty chunks regularly as there is no real player to use them
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
		$self->SUPER::playerStopped($client->master) if $client == $surrogate;
		$self->master->undoSync(TRACK_END);		
	}
	
	$self->SUPER::playerStopped($client);
}

sub play {
	my $self = shift;
	
	$log->info("play request $self");
	
	$self->master->doSync if $self->master->isa("Plugins::Groups::Player");
	return $self->SUPER::play(@_);
}	

sub stop {
	my $self = shift;
	
	$log->info("stop request $self");
	
	# TODO : when a player quits because it's assigned to another group/virtual player
	# it's just an unsync happening so the former virtual player continues. But when 
	# a single player is ask to play something else, it will then stop the controller and the
	# virtual player (whole group) stops. Not sure there is a way to differentiate that the 
	# stop came from a individual player and not from the master
	$self->master->undoSync(USER_STOP) if $self->master->isa("Plugins::Groups::Player");
	return $self->SUPER::stop(@_);
}	


sub resume {
	my $self = shift;
	
	$log->info("resume request $self");
	
	$self->master->doSync if $self->master->isa("Plugins::Groups::Player");
	return $self->SUPER::resume(@_);
}	

sub pause {
	my $self = shift;
	
	$log->info("pause request $self");
	
	# TODO : when a player quits because it's assigned to another group/virtual player
	# it's just an unsync happening so the former virtual player continues. But when 
	# a single player is ask to play something else, it will then stop the controller and the
	# virtual player (whole group) stops. Not sure there is a way to differentiate that the 
	# stop came from a individual player and not from the master
	$self->master->undoSync(USER_PAUSE) if $self->master->isa("Plugins::Groups::Player");
	return $self->SUPER::pause(@_);
}	

=comment
sub unsync {
	my ($self, $player, $keepSyncGroupId) = @_;
	
	# if we are here, we are trying to sync a virtual player but we only get here if the
	# user did that while the group was playing. Otherwise, the group has no slaves so this
	# method will even not be called - so far, there is no way to prevent this madness
	if ( $player->isa("Plugins::Groups::Player") ) {
		$log->error("DO NOT SYNCHRONIZE PLAYER GROUP ", $player->name);
		return;
	}
	
	return $self->SUPER::unsync($player, $keepSyncGroupId);
}
=cut

sub _Surrogate {
	my $self = shift;
	my @activePlayers = $self->activePlayers;
	return $activePlayers[1];
}


1;
