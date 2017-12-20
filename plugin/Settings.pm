package Plugins::Groups::Settings;

use strict;
use base qw(Slim::Web::Settings);

use Slim::Utils::Strings qw (string);
use Slim::Utils::Misc;
use Slim::Utils::Log;
use Slim::Utils::Prefs;
use Plugins::Groups::Plugin qw(%groups);
use Plugins::Groups::Player;

my $prefs = preferences('plugin.groups');
my $log   = logger('plugin.groups');
my @playerList;

sub name {
	return Slim::Web::HTTP::CSRF->protectName('PLUGIN_GROUPS_NAME');
}

sub page {
	return Slim::Web::HTTP::CSRF->protectURI('plugins/Groups/settings/basic.html');
}

sub prefs {
	return ($prefs, qw(restoreStatic));
}

sub handler {
	my ($class, $client, $params) = @_;
	
	$log->debug("Groups::Settings->handler() called.");
	
	if ($params->{'saveSettings'}) {

		foreach my $id (keys %groups) {

			if ($params->{"delete.$id"}) {
				$log->info("Deleting $id");
				delete $groups{$id};
				Plugins::Groups::Plugin::delPlayer($id);
				next;
			} 
			
			$groups{$id}->{'syncPower'} = $params->{"syncpower.$id"} ? 1 : 0;
			$groups{$id}->{'syncVolume'} = $params->{"syncvolume.$id"} ? 1 : 0;
				
			my @members = grep { $_ =~ /members.$id/ } keys %$params;

			delete $groups{$id}->{'members'};

			foreach my $player (@members) {
				my ($player) = $player =~ m/members.[^.]+.(.+)/;
				push @{$groups{$id}->{'members'}}, $player;
			}
		}
		
		if ((defined $params->{'newGroupName'}) && ($params->{'newGroupName'} ne '')) {
			my $id = addGroup($params->{'newGroupName'});
			$log->info("Adding $params->{'newGroupName'} $id");
			Plugins::Groups::Plugin::createPlayer($id, $params->{'newGroupName'});
		}

		$prefs->set('groups', \%groups);

	}

	$params->{'newGroupName'} = undef;
	$params->{'groups'} = \%groups;
	$params->{'players'} = 	makePlayerList();

	$log->debug("Groups::Settings->handler() done.");

	return $class->SUPER::handler( $client, $params );
}

sub addGroup {
	my ($name) = @_;

	my $id;
	
	my $genMAC = sub {
		sprintf("10:10:%02x:%02x:%02x:%02x", int(rand(255)), int(rand(255)), int(rand(255)), int(rand(255)));
	};
	
	# generate MAC address and verify it doesn't exist yet
	while ( $groups{$id = $genMAC->()} ) {};

	$groups{$id}->{'name'} = $name;
	$groups{$id}->{'syncPower'} = 1;
	$groups{$id}->{'syncVolume'} = 1;
	
	return $id;
}

sub makePlayerList {
	my @playerList = ();
	
	foreach my $client (Slim::Player::Client::clients()) {
		my $player = { "name" => $client->name(), "id" => $client->id() };
		push @playerList, $player if $client->model() !~ m/group/;
	}
	
	@playerList = sort { lc($a->{'name'}) cmp lc($b->{'name'}) } @playerList;
	
	return \@playerList;
}


1;
