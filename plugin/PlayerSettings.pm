package Plugins::Groups::PlayerSettings;

use strict;
use base qw(Slim::Web::Settings);

use Slim::Utils::Log;
use Slim::Utils::Prefs;

my $sprefs = preferences('server');
my $prefs = preferences('plugin.groups');
my $log   = logger('plugin.groups');

sub name {
	return Slim::Web::HTTP::CSRF->protectName('PLUGIN_GROUPS_PLAYERSETTINGS');
}

sub needsClient {
	return 1;
}

sub validFor {
	my $class = shift;
	my $client = shift;
	
	return !$client->isa("Plugins::Groups::Player");
}

use Data::Dumper;

sub page {
	return Slim::Web::HTTP::CSRF->protectURI('plugins/Groups/settings/player.html');
}

=comment
sub prefs {
	my ($class, $client) = @_;
	return ($prefs->client($client), @Plugins::Groups::Player::onGroupPrefs);
}
=cut

sub handler {
	my ($class, $client, $params) = @_;
	my $id = $client->id;
	
	if ( $params->{saveSettings} ) {
						
		foreach my $gid ( Plugins::Groups::Plugin->groupIDs() ) {
			my $group = Slim::Player::Client::getClient($gid);
			my $members = $prefs->client($group)->get('members');
			
			if ( $params->{"member.$gid"} ) {
				# add membership if missing
				push (@$members, $id) unless grep {$_ eq $id} @$members;
				
				# then set all player parameter that are overidden when joining that group
				foreach my $key (@Plugins::Groups::Player::onGroupPrefs) {
					my $data = $prefs->client($group)->get($key);
					$data->{$id} = $params->{"$key.$gid"} if defined $params->{"$key.$gid"};
					delete $data->{$id} if $data->{$id} eq 'n/a';		
					$prefs->client($group)->set($key, $data);					
				}
			} else {
				# remove membership, leave all other parameters
				$members = [ grep {$_ ne $id} @$members ];
			}
			
			$prefs->client($group)->set('members', $members);
		}
	}

	return $class->SUPER::handler( $client, $params );
}

sub beforeRender {
	my ($class, $params, $client) = @_;

	my @groups;

	foreach my $gid ( Plugins::Groups::Plugin->groupIDs ) {
		my $group = Slim::Player::Client::getClient($gid);
		my $data;
		
		# set membership first
		$data->{gid} = $gid;
		$data->{member} = grep { $_ eq $client->id } @{ $prefs->client($group)->get('members') };
		
		# then set all player parameter that are overriden when joining that group
		foreach my $key (@Plugins::Groups::Player::onGroupPrefs) {
			# can't use undef as they equal to 0 in TTK
			$data->{$key} = $prefs->client($group)->get($key)->{$client->id} if $prefs->client($group)->get($key);
			$data->{$key} //= 'n/a';
		}	
		
		push @groups, $data;	
	}
	
	$log->error(Dumper(\@groups));
	
	$params->{groups} = \@groups;
	
=comment	
	$params->{groups} = [ sort { lc($sprefs->client(Slim::Player::Client::getClient($a->{clientid}))->get('playername')) cmp
							     lc($sprefs->client(Slim::Player::Client::getClient($b->{clientid}))->get('playername'))
						   } Plugins::Groups::Plugin::allPrefs ];
=cut
}


1;