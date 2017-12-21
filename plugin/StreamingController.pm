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

	# be careful if we have been synched manually with a normal player
	$self->master->doSync if $self->master->isa("Plugins::Groups::Player");
	return $self->SUPER::play(@_);
}	

sub stop {
	my $self = shift;
	my $client = shift;
	
	$log->info("stop request $self $client");
	
	return $self->SUPER::stop(@_) unless $self->master->isa("Plugins::Groups::Player");
	
	# when a slave stops on its own, do not stop the whole group, instead 
	# just unsync the slave to let the group continue, unless the slave is
	# the only player in that group
	if (defined $client && $client != $self->master && $self->activePlayers() > 2) {
		$log->info("A slave $client stopped on its own from ", $self->master);
		$self->unsync($client);
		return undef;
	} 
	
	# the master stopped, so undo the group and stops everything
	$self->master->undoSync(USER_STOP);
	return $self->SUPER::stop(@_)
}	

sub resume {
	my $self = shift;
	
	$log->info("resume request $self");
	
	$self->master->doSync if $self->master->isa("Plugins::Groups::Player");
	return $self->SUPER::resume(@_);
}	

sub pause {
	my $self = shift;
	my $client = shift;
	
	$log->info("pause request $self $client");
		
	$self->master->undoSync(USER_PAUSE) if $self->master->isa("Plugins::Groups::Player");
	return $self->SUPER::pause(@_);
}	

sub _Surrogate {
	my $self = shift;
	my @activePlayers = $self->activePlayers;
	return $activePlayers[1];
}


1;
