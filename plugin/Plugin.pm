use strict;

package Plugins::Groups::Plugin;

use base qw(Slim::Plugin::Base);

use Socket;
use Slim::Utils::Strings qw (string);
use Slim::Utils::Misc;
use Slim::Utils::Log;
use Slim::Utils::Prefs;
use Slim::Player::StreamingController;

use Plugins::Groups::Settings;
use Plugins::Groups::StreamingController;

my %groups;

my $log = Slim::Utils::Log->addLogCategory({
	'category' => 'plugin.groups',
	'defaultLevel' => 'ERROR',
	'description' => 'PLUGIN_GROUPS_NAME'
});

my $prefs = preferences('plugin.groups');
my $serverPrefs = preferences('server');

$prefs->init({
	lastID => int ( rand(2**32) ),
	restoreStatic => 1,
});

sub getDisplayName() {
	return 'PLUGIN_GROUPS_NAME';
}

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

sub playerAdd {
    my $client  = shift->client;
	my $controller = Plugins::Groups::StreamingController->new($client->controller());
	
	$client->controller($controller);
}	

sub createPlayer {
	my ($id, $name) = @_;
	my $s =  sockaddr_in(10000, inet_aton("127.1"));

	# $id, $paddr, $rev, $s, $deviceid, $uuid
	my $client = Plugins::Groups::Player->new($id, $s, 1.0, undef, 12, undef);
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

	Slim::Utils::Prefs::Client->new($serverPrefs, $id, 'no-migrate');
		
	$log->info("create group player $client");
}

sub delPlayer {
	my $client = Slim::Player::Client::getClient($_[0]);

	$client->tcpsock(undef);
	$client->disconnected(1);
	$client->forgetClient;
	
	Slim::Control::Request::notifyFromArray($client, ['client', 'disconnect']);
	Slim::Utils::Timers::setTimer( $client,	Time::HiRes::time() + 30, sub {
				Slim::Control::Request::executeRequest($client, ['client', 'forget']);					
				} );
	
	$log->info("delete group player $client");
}


1;
