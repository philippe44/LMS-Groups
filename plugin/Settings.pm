package Plugins::Groups::Settings;

use strict;
use base qw(Slim::Web::Settings);

use Slim::Utils::Strings qw (string);
use Slim::Utils::Misc;
use Slim::Utils::Log;
use Slim::Utils::Prefs;

use Plugins::Groups::Plugin;
use Plugins::Groups::Player;

my $prefs = preferences('plugin.groups');
my $sprefs = preferences('server');
my $log   = logger('plugin.groups');

sub name {
	return Slim::Web::HTTP::CSRF->protectName('PLUGIN_GROUPS_NAME');
}

sub page {
	return Slim::Web::HTTP::CSRF->protectURI('plugins/Groups/settings/basic.html');
}

sub prefs {
	return ($prefs, qw(restoreStatic showDisconnected breakupTimeout syncReal autoUnmute));
}

sub handler {
	my ($class, $client, $params) = @_;
	
	$log->debug("Groups::Settings->handler() called.");
	
	if ($params->{saveSettings}) {
		foreach my $id ( Plugins::Groups::Plugin->groupIDs() ) {
		
			if ($params->{"delete.$id"}) {
				$prefs->remove($Slim::Utils::Prefs::Client::clientPreferenceTag . ':' . $id);
				foreach my $namespace (@{ Slim::Utils::Prefs::namespaces() }) {
					preferences($namespace)->remove($Slim::Utils::Prefs::Client::clientPreferenceTag . ':' . $id);
				}
				Plugins::Groups::Plugin::delPlayer($id);
				next;
			}
			
			update($id, $params);
		}
		
		if ((defined $params->{'newGroupName'}) && ($params->{'newGroupName'} ne '')) {
			my $id = createId();
			
			main::INFOLOG && $log->is_info && $log->info("Adding $params->{'newGroupName'} $id");
			Plugins::Groups::Plugin::createPlayer($id, $params->{'newGroupName'});
		}
	}

	$params->{newGroupName} = undef;
	$params->{devices}      = [ Plugins::Groups::Plugin::allPrefs ];
	
	$log->debug("Groups::Settings->handler() done.");
	
	return $class->SUPER::handler( $client, $params );
}

sub createId {
	my $id;
	
	my $genMAC = sub {
		sprintf("02:00:%02x:%02x:%02x:%02x", int(rand(255)), int(rand(255)), int(rand(255)), int(rand(255)));
	};
	
	# create hash for quick lookup
	my %groups = map {
		$_ => 1
	} Plugins::Groups::Plugin->groupIDs();
	
	# generate MAC address and verify it doesn't exist yet
	while ( $groups{$id = $genMAC->()} ) {};

	return $id;
}

sub beforeRender {
	my ($class, $params, $client) = @_;

	my $showDisconnected = $prefs->get('showDisconnected');
	my @playerList = ();
	
	# need to build manually the list as client() is not available for disconnected devices
	if ($showDisconnected) {
		my @groups = Plugins::Groups::Plugin->groupIDs;
		foreach my $client ($sprefs->allClients) {
			next if grep { $_ eq $client->{clientid} } @groups;
			my $player = { "name" => $client->get('playername'), "id" => $client->{clientid} };
			push @playerList, $player if $player->{name};
		}	
		
	} else {	
		foreach my $client (Slim::Player::Client::clients()) {
			my $player = { "name" => $client->name(), "id" => $client->id() };
			push @playerList, $player if $client->model() ne 'group';
		}
		
	}	
	
	@playerList = sort { lc($a->{'name'}) cmp lc($b->{'name'}) } @playerList;
	$params->{playerList} = \@playerList;
}

sub update {
	my ($id, $params) = @_;
	
	# need to memorize all existing members if we only show connected players
	my $client = Slim::Player::Client::getClient($id);
	my $previous = $prefs->client($client)->get('members') if $client && !$prefs->get('showDisconnected');

	# update preferences by creating a new set
	my $cprefs = Slim::Utils::Prefs::Client->new( $prefs, $id, 'no-migrate' );
	
	# we assume that all prefs are booleans
	foreach my $key (keys %$Plugins::Groups::Player::playerPrefs) {
		$cprefs->set($key, $params->{"$key.$id"} ? 1 : 0);
	}
						
	# keep previous members that are not connected ($previous is empty when showing disconnected)								
	my $members = [ map { /members\.$id\.(.+)/; $1; } grep /members\.$id\./, keys %$params ];
	push @$members, grep { !Slim::Player::Client::getClient($_) } @$previous;
	$cprefs->set('members', $members);
									
	Plugins::Groups::Plugin::initVolume($id);
}	


1;
