package Plugins::Groups::PlayerSettings;

use strict;
use base qw(Slim::Web::Settings);
use List::Util qw(first);

use Slim::Utils::Log;
use Slim::Utils::Prefs;

# to be removed
use Data::Dumper;

my $sprefs = preferences('server');
my $prefs = preferences('plugin.groups');
my $log   = logger('plugin.groups');

sub name {
	return Slim::Web::HTTP::CSRF->protectName('PLUGIN_GROUPS_PLAYERSETTINGS');
}

sub needsClient {
	return 1;
}

=comment
sub validFor {
	my ($class, $client) = @_;
	return !$client->isa("Plugins::Groups::Player");
}
=cut

sub page {
	return Slim::Web::HTTP::CSRF->protectURI('plugins/Groups/settings/player.html');
}

sub prefs {
	my ($class, $client) = @_;
	return ($prefs, qw(showDisconnected)) if $client && $client->isa("Plugins::Groups::Player");
	return undef;
}

sub handler {
	my ($class, $client, $params) = @_;
	
	return $class->SUPER::handler( $client, $params ) unless defined $client;
	
	my $id = $client->id;
	
	if ( $params->{saveSettings} ) {
		if ($client->isa("Plugins::Groups::Player")) {
			Plugins::Groups::Settings::update($id, $params);
			
			my @members = @{ $prefs->client($client)->get('members') };
			
			# set all player parameter that are overidden when joining that group
			foreach my $key (@Plugins::Groups::Player::onGroupPrefs) {
				foreach my $mid (@members) {
					onGroupPrefs($key, $params->{"$key.$mid"}, $client, $mid);
				}	
			}
		} else {	
			foreach my $gid ( Plugins::Groups::Plugin->groupIDs() ) {
				my $group = Slim::Player::Client::getClient($gid);
				my $members = $prefs->client($group)->get('members');
			
				if ( $params->{"member.$gid"} ) {
					# add membership if missing
					push (@$members, $id) unless grep {$_ eq $id} @$members;
				
					# then set all player parameter that are overidden when joining that group
					foreach my $key (@Plugins::Groups::Player::onGroupPrefs) {
						onGroupPrefs($key, $params->{"$key.$gid"}, $group, $id);
					}
				} else {
					# remove membership, leave all other parameters
					$members = [ grep {$_ ne $id} @$members ];
				}
			
				$prefs->client($group)->set('members', $members);
			}
		}	
	}

	return $class->SUPER::handler( $client, $params );
}

sub beforeRender {
	my ($class, $params, $client) = @_;

	if ($client->isa("Plugins::Groups::Player")) {
		Plugins::Groups::Settings::beforeRender($class, $params, $client);
		
		$params->{device} = $prefs->client($client)->all;
				
		my @members = ();
		foreach my $id ( @{ $params->{device}->{members} } ) {
			my $data = first {$_->{id} eq $id} @{ $params->{playerList} };
			next unless defined $data;
					
			# players are always member of their group (ongroup.html)
			$data->{member} = 1;
			
			# then set all player parameter that are overriden when joining that group
			foreach my $key (@Plugins::Groups::Player::onGroupPrefs) {
				# can't use undef as they equal to 0 in TTK
				$data->{$key} = $params->{device}->{$key}->{$id} if $params->{device}->{$key};
				$data->{$key} //= 'n/a';
			}	
		
			push @members, $data;	
		}
		
		$log->error(Dumper(@members));
		$params->{devices} = [ sort { lc($a->{name}) cmp lc($b->{name}) } @members ];
	} else {
		my @groups;

		foreach my $id ( Plugins::Groups::Plugin->groupIDs ) {
			my $group = Slim::Player::Client::getClient($id);
			my $data;
		
			# set membership first
			$data->{id} = $id;
			$data->{member} = grep { $_ eq $client->id } @{ $prefs->client($group)->get('members') };
			$data->{name} = $sprefs->client($group)->get('playername');
		
			# then set all player parameter that are overriden when joining that group
			foreach my $key (@Plugins::Groups::Player::onGroupPrefs) {
				# can't use undef as they equal to 0 in TTK
				$data->{$key} = $prefs->client($group)->get($key)->{$client->id} if $prefs->client($group)->get($key);
				$data->{$key} //= 'n/a';
			}	
		
			push @groups, $data;	
		}	
	
		$log->error(Dumper(@groups));
		$params->{devices} = \@groups;
	}	
}

sub onGroupPrefs {
	my ($key, $value, $group, $id) = @_;
	my $data = $prefs->client($group)->get($key);
	$data->{$id} = $value if defined $value;
	delete $data->{$id} if $data->{$id} eq 'n/a';		
	$prefs->client($group)->set($key, $data);					
}	


1;