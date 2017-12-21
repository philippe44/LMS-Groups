use strict;

package Plugins::Groups::Plugin;

use base qw(Slim::Plugin::Base);

use Socket;
use Slim::Utils::Strings qw (string);
use Slim::Utils::Misc;
use Slim::Utils::Log;
use Slim::Utils::Prefs;
use Slim::Player::StreamingController;

use Plugins::Groups::StreamingController qw(TRACK_END USER_STOP USER_PAUSE);

use Exporter qw(import);
our @EXPORT_OK = qw(%groups);

our %groups;

my $log = Slim::Utils::Log->addLogCategory({
	'category' => 'plugin.groups',
	'defaultLevel' => 'ERROR',
	'description' => 'PLUGIN_GROUPS_NAME'
});

my $prefs = preferences('plugin.groups');
my $serverPrefs = preferences('server');

$prefs->init({
	restoreStatic => 1,
});

sub getDisplayName() {
	return 'PLUGIN_GROUPS_NAME';
}

sub initPlugin {
	my $class = shift;

	$log->info(string('PLUGIN_GROUPS_STARTING'));

	%groups = % { $prefs->get('groups') } if (defined $prefs->get('groups'));
	
	if ( main::WEBUI ) {
		require Plugins::Groups::Settings;
		Plugins::Groups::Settings->new;
	}	

	$class->initCLI();

	foreach my $id (keys %groups) {
		$log->info("creating player " . $groups{$id}->{'name'});
		createPlayer( $id, $groups{$id}->{'name'} );
	}
}

sub createPlayer {
	my ($id, $name) = @_;
	# need to have a fake socket because getClient does not call ipport() in an OoO way
	my $s =  sockaddr_in(0, INADDR_LOOPBACK);

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
	$client->tcpsock(1);
	$client->init;
		
	$log->info("create group player $client");
}

sub delPlayer {
	my $client = Slim::Player::Client::getClient($_[0]);

	$client->tcpsock(undef);
	$client->disconnected(1);
		
	Slim::Control::Request::notifyFromArray($client, ['client', 'disconnect']);
	Slim::Utils::Timers::setTimer( $client,	Time::HiRes::time() + 5, sub {
				# $client->forgetClient;
				Slim::Control::Request::executeRequest($client, ['client', 'forget']);
				} );
	
	$log->info("delete group player $client");
}

sub initCLI {
	#                                                            |requires Client
	#                                                            |  |is a Query
	#                                                            |  |  |has Tags
	#                                                            |  |  |  |Function to call
	#                                                            C  Q  T  F
	Slim::Control::Request::addDispatch(['playergroups', '_index', '_quantity'],
	                                                            [0, 1, 0, \&_cliGroups]
	);

	Slim::Control::Request::addDispatch(['playergroup'],        [1, 1, 0, \&_cliGroup]);
}

sub _cliGroups {
	my $request = shift;

	# check this is the correct query.
	if ($request->isNotQuery([['playergroups']])) {
		$request->setStatusBadDispatch();
		return;
	}
	
	my $index    = $request->getParam('_index') || 0;
	my $quantity = $request->getParam('_quantity') || 10;

	my @groups = sort keys %groups;
	my $count = @groups;
	
	my ($valid, $start, $end) = $request->normalize(scalar($index), scalar($quantity), $count);
	
	$request->addResult('count', $count);
		
	my $loopname = 'groups_loop';
	my $chunkCount = 0;
	
	foreach my $group ( @groups[$start .. $end] ) {
		$request->addResultLoop($loopname, $chunkCount, 'id', $group);				
		$request->addResultLoop($loopname, $chunkCount, 'name', $groups{$group}->{name});
		$request->addResultLoop($loopname, $chunkCount, 'syncPower', $groups{$group}->{syncPower});
		$request->addResultLoop($loopname, $chunkCount, 'syncVolume', $groups{$group}->{syncVolume});
		$request->addResultLoop($loopname, $chunkCount, 'players', scalar @{$groups{$group}->{members} || []});
		
		$chunkCount++;
	}

	$request->setStatusDone();
}

sub _cliGroup {
	my $request = shift;

	# check this is the correct query.
	if ($request->isNotQuery([['playergroup']])) {
		$request->setStatusBadDispatch();
		return;
	}

	my $client  = $request->client;
	
	if (!$client || $client->model ne 'group' || !$groups{$client->id}) {
		$log->warn($client->id . ' is either not a group, or it does not exist') if $client;
		$request->setStatusBadDispatch();
		return;
	}
	
	my $group = $groups{$client->id};
	
	warn Data::Dump::dump($group);
#	$request->addResult('id', $client->id);
	$request->addResult('name', $group->{name});
	$request->addResult('syncPower', $group->{syncPower});
	$request->addResult('syncVolume', $group->{syncVolume});
	
	my $loopname = 'players_loop';
	my $chunkCount = 0;
	
	foreach my $player ( @{$group->{members} || []} ) {
		$request->addResultLoop($loopname, $chunkCount, 'id', $player);
		
		if ( my $client = Slim::Player::Client::getClient($clientparam) ) {
			$request->addResultLoop($loopname, $chunkCount, 'playername', $client->name);
		}		
		$chunkCount++;
	}

	$request->setStatusDone();
}

1;
