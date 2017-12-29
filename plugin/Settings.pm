package Plugins::Groups::Settings;

use strict;
use base qw(Slim::Web::Settings);

use Slim::Utils::Strings qw (string);
use Slim::Utils::Misc;
use Slim::Utils::Log;
use Slim::Utils::Prefs;
use Plugins::Groups::Plugin;
use Plugins::Groups::Player;
use Data::Dumper;

my $prefs = preferences('plugin.groups');
my $sprefs = preferences('server');
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
	
	if ($params->{saveSettings}) {
		foreach my $id ( Plugins::Groups::Plugin->groupIDs() ) {
	
			if ($params->{"delete.$id"}) {
				Plugins::Groups::Plugin::delPlayer($id);
				next;
			}

			Plugins::Groups::Plugin::setPrefs($id, 'powerMaster', $params->{"powerMaster.$id"} ? 1 : 0);
			Plugins::Groups::Plugin::setPrefs($id, 'powerPlay', $params->{"powerPlay.$id"} ? 1 : 0);
			Plugins::Groups::Plugin::setPrefs($id, 'members', [ map {
														/members.$id.(.+)/;
														$1;
														} grep /members.$id/, keys %$params ]);
		}
		
		if ((defined $params->{'newGroupName'}) && ($params->{'newGroupName'} ne '')) {
			my $id = createId();
			
			$log->info("Adding $params->{'newGroupName'} $id");
			Plugins::Groups::Plugin::createPlayer($id, $params->{'newGroupName'});
		}
	}

	$params->{newGroupName} = undef;
	$params->{players}      = makePlayerList();
	$params->{groups}      = [ Plugins::Groups::Plugin::getPrefs ];
	
	$log->debug("Groups::Settings->handler() done.");
	
	return $class->SUPER::handler( $client, $params );
}

sub createId {
	my $id;
	
	my $genMAC = sub {
		sprintf("10:10:%02x:%02x:%02x:%02x", int(rand(255)), int(rand(255)), int(rand(255)), int(rand(255)));
	};
	
	# create hash for quick lookup
	my %groups = map {
		$_ => 1
	} Plugins::Groups::Plugin->groupIDs();
	
	# generate MAC address and verify it doesn't exist yet
	while ( $groups{$id = $genMAC->()} ) {};

	return $id;
}

sub makePlayerList {
	my @playerList = ();
	
	foreach my $client (Slim::Player::Client::clients()) {
		my $player = { "name" => $client->name(), "id" => $client->id() };
		push @playerList, $player if $client->model() ne 'group';
	}
	
	@playerList = sort { lc($a->{'name'}) cmp lc($b->{'name'}) } @playerList;
	
	return \@playerList;
}


1;
