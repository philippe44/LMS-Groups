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
use Data::Dumper;

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
				
	$log->info("PLAYERTRACKSTARTED $client");
	
	# send started on behalf of master
	$self->SUPER::playerTrackStarted($client->master) if $client == $surrogate;
	
	return $self->SUPER::playerTrackStarted($client);
}

sub playerStatusHeartbeat {
	my ($self, $client) = @_;
	my $surrogate = _Surrogate($self);
		
	#$log->info("PLAYERSTATUSHEARTBEAT $client");
	
	# empty chunks regularly as there is no real player to use them
	@{$client->master->chunks} = ();
	
	# send heartbeat on behalf of master
	$self->SUPER::playerStatusHeartbeat($client->master) if $client == $surrogate;
	
	return $self->SUPER::playerStatusHeartbeat($client);
}

sub playerStopped {
	my ($self, $client) = @_;
	my $surrogate = _Surrogate($self);
		
	$log->info("PLAYERSTOPPED $client");
	
	# send stop on behalf of master
	if ($client == $surrogate) {
		$self->SUPER::playerStopped($client->master) if $client == $surrogate;
		$self->master->undoSync;		
	}
	
	$self->SUPER::playerStopped($client);
}

sub play {
	my $self = shift;
	
	$log->info("PLAY $self");
	
	# TODO : how to re-start a group when just one player quit?
	$self->master->doSync if $self->master->isa("Plugins::Groups::Player");
	return $self->SUPER::play(@_);
}	

sub stop {
	my $self = shift;
	
	$log->info("STOP $self");
	
	$self->master->undoSync if $self->master->isa("Plugins::Groups::Player");
	return $self->SUPER::stop(@_);
}	

=comment
sub unsync {
	my ($self, $player, $keepSyncGroupId) = @_;
	
	$log->info("UNSYNC $self $player");		
	return $self->SUPER::unsync($player, $keepSyncGroupId);
}

sub sync {
	my ($self, $player, $restart) = @_;
	
	$log->info("SYNCING $self $player");		
	return $self->SUPER::sync($player, $restart);
}
=cut

sub _Surrogate {
	my $self = shift;
	my @activePlayers = $self->activePlayers;
	return $activePlayers[1];
}


1;
