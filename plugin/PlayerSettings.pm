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
				push (@$members, $id) unless grep {$_ eq $id} @$members;
			} else {
				$members = [ grep {$_ ne $id} @$members ];
			}
			$prefs->client($group)->set('members', $members);
		}
	}

	return $class->SUPER::handler( $client, $params );
}

sub beforeRender {
	my ($class, $params, $client) = @_;

	$params->{groups} = [ sort { lc($sprefs->client(Slim::Player::Client::getClient($a->{clientid}))->get('playername')) cmp
							     lc($sprefs->client(Slim::Player::Client::getClient($b->{clientid}))->get('playername'))
						   } Plugins::Groups::Plugin::allPrefs ];
	$params->{playerid} = $client->id;
}


1;