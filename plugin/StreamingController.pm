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

my $prefs = preferences('plugin.groups');
my $log   = logger('plugin.groups');

sub new {
	my ($class, $self) = @_;

	$log->info("NEW controller $self");
	
	bless $self, $class;
	
	return $self;
}


sub _isSurrogate {
	my $client = shift;
	my $master = $client->master;
	
	return 0 if $master->model !~ m/group/;
	
	my $controller = $master->controller;
	my $idx = $master->controller()->{'players'}->[0] == $master ? 1 : 0;

=comment	
	foreach my $player (@{$master->controller()->{'players'}}) {
		$log->info("$player");
	}
=cut	
	
	my $res = $client == $master->controller()->{'players'}->[$idx] ? 1 : 0;
	
	$log->info("SURROGATE $client for $master") if $res;
			
	return $res;
}

sub playerTrackStarted {
	my ($self, $client) = @_;
	my $master = $client->master;
			
	$log->info("PLAYERTRACKSTARTED $client");
	$master->controller->SUPER::playerTrackStarted($master) if _isSurrogate($client);
	$self->SUPER::playerTrackStarted($client);
}

sub playerStatusHeartbeat {
	my ($self, $client) = @_;
	my $master = $client->master;
		
	$log->info("PLAYERSTATUSHEARTBEAT $client");
	$master->controller->SUPER::playerStatusHeartbeat($master) if _isSurrogate($client);
	$self->SUPER::playerStatusHeartbeat($client);
}

sub unsync {
	my ($self, $player, $keepSyncGroupId) = @_;
	
	$log->info("UNSYNC $player");		
	$self->SUPER::unsync($player, $keepSyncGroupId);
}

sub playerStopped {
	my ($self, $client) = @_;
	my $master = $client->master;
		
	$log->info("PLAYERSTOPPED $client");		
	$master->controller->SUPER::playerStopped($master) if _isSurrogate($client);
	$self->SUPER::playerStopped($client);
}


1;
