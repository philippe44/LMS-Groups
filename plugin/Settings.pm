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
		my $groups = $prefs->get('groups') || [];
		my @newGroups;

		foreach my $id (@$groups) {
			my $cprefs = Slim::Utils::Prefs::Client->new( $prefs, $id, 'no-migrate' );

			if ($params->{"delete.$id"}) {
				main::INFOLOG && $log->info("Deleting $id");

				# remove client prefs
				$prefs->remove('_client:' . $id);
				
				Plugins::Groups::Plugin::delPlayer($id);
				next;
			}
			
			push @newGroups, $id;
			
			$cprefs->set('syncPower', $params->{"syncpower.$id"} ? 1 : 0);
			$cprefs->set('syncVolume', $params->{"syncvolume.$id"} ? 1 : 0);
				
			$cprefs->set('members', [ map {
				/members.$id.(.+)/;
				$1;
			} grep /members.$id/, keys %$params ]);
		}
		
		if ((defined $params->{'newGroupName'}) && ($params->{'newGroupName'} ne '')) {
			my $id = createId();
			
			push @newGroups, $id;
			
			$log->info("Adding $params->{'newGroupName'} $id");
			Plugins::Groups::Plugin::createPlayer($id, $params->{'newGroupName'});
		}

		$prefs->set('groups', \@newGroups);
	}

	$params->{newGroupName} = undef;
	$params->{groups} = $prefs->get('groups');
	%{$params->{clientPrefs}} = map { $_ => $prefs->client(Slim::Player::Client::getClient($_))->all } @{$params->{groups}};
	$params->{players} = makePlayerList();

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
	} @{ $prefs->get('groups') || [] };
	
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
