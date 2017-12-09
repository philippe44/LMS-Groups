use strict;

package Plugins::Groups::Plugin;

use base qw(Slim::Plugin::Base);

use Socket;
use Slim::Utils::Strings qw (string);
use Slim::Utils::Misc;
use Slim::Utils::Log;
use Slim::Utils::Prefs;
use Plugins::Groups::Settings;

my %groups;

my $log = Slim::Utils::Log->addLogCategory({
	'category' => 'plugin.groups',
	'defaultLevel' => 'ERROR',
	'description' => 'PLUGIN_GROUPS_NAME'
});

sub getDisplayName() {
	return 'PLUGIN_GROUPS_NAME';
}

my $prefs = preferences('plugin.groups');

$prefs->init({ 
	lastID => int ( rand(2**32) ), 
	powerup => 1,
});

sub getGroups {
	return %groups;
}

sub setGroups {
	%groups = @_;
	$prefs->set('groups', \%groups);
}	

sub initPlugin {
	my $class = shift;
	
	$log->info(string('PLUGIN_GROUPS_STARTING'));
	
	$class->SUPER::initPlugin(@_);
	
	Plugins::Groups::Settings->new;
	
	%groups = % { $prefs->get('groups') } if (defined $prefs->get('groups'));
		
	foreach my $id (keys %groups) {
		$log->info("creating player " . $groups{$id}->{'name'});
		createPlayer( $id, $groups{$id}->{'name'} );
	}	
}

sub createPlayer {
	my ($id, $name) = @_;
	my $s =  sockaddr_in(10000, inet_aton("127.1"));
	
	# $id, $paddr, $rev, $s, $deviceid, $uuid
	my $client = Plugins::Groups::Player->new($id, $s, 0, undef, 12, undef);
	my $display_class = 'Slim::Display::NoDisplay';
		
	Slim::bootstrap::tryModuleLoad($display_class);

	if ($@) {
		$log->logBacktrace;
		$log->logdie("FATAL: Couldn't load module: $display_class: [$@]");
	}

	$client->display( $display_class->new($client) );
	$client->macaddress($id);
	$client->name($name);
	$client->init('group', 'codecs=mp3,flc,wma,ogg,pcm,aac', undef);
	$prefs->client($client)->set('syncPower', 0);
}

sub delPlayer {
	my $client = Slim::Player::Client::getClient($_[0]);
		
	$client->tcpsock(undef);
	Slim::Control::Request::notifyFromArray($client, ['client', 'disconnect']);
	# Slim::Control::Request::executeRequest($client, ['client', 'forget']);
}	


1;
