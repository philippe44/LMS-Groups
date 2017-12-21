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

# override default Slim::Player::Source::playmode()
use Plugins::Groups::Source;
use Plugins::Groups::Playlist;

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
my $originalVolumeHandler;

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
	
	$originalVolumeHandler = Slim::Control::Request::addDispatch(['mixer', 'volume', '_newvalue'], [1, 0, 0, \&mixerVolumeCommand]);
}

sub mixerVolumeCommand {
	my $request = shift;
    my $client  = $request->client;
	my $entity   = $request->getRequest(1);
	my $newVolume = $request->getParam('_newvalue');
	my $master = $client->controller->master;
		
	return $originalVolumeHandler->($request) unless $client->controller->isa("Plugins::Groups::StreamingController") &&
													 $groups{$master->id}->{'syncVolume'} &&
													 !$master->_volumeDispatching;

	my @group  = $client->syncedWith;
	my $oldVolume = $master->volume;
	
	# avoid recursing loop				
	$master->_volumeDispatching(1);			
	
	$log->info("volume command $newVolume for $client with old volume $oldVolume (master = $master)");
	
	if ($client == $master) {
		# when changing virtual player's volume, apply a ratio to all real players, unless the previous
		# volume was zero, which means everybody has a fresh start
		
		foreach my $slave (@group) {
			my $slaveVolume = $oldVolume ? $slave->volume * $newVolume / $oldVolume : $newVolume;
			$log->debug("new volume for $slave $slaveVolume");
			Slim::Control::Request::executeRequest($slave, ['mixer', 'volume', $slaveVolume]);
		}	
	} else {
		# when changing the volume of a slave, need to feed that back to the virtual player so that it
		# displays an average
		
		# take an average of the whole group, including ourselves but exclude virtual player
		foreach my $player (@group) { 
			next if $player == $master;
			$log->debug("current volume of $player ", $player->volume());
			$newVolume += $player->volume();
		}
		$newVolume /= scalar @group;
		
		$log->info("setting master volume from $client for $master at $newVolume");
	
		Slim::Control::Request::executeRequest($master, ['mixer', 'volume', $newVolume]) if $newVolume != $oldVolume;
	}
	
	# all dispatch done
	$master->_volumeDispatching(0);	
	
	$originalVolumeHandler->($request);
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
	
#	$request->addResult('id', $client->id);
	$request->addResult('name', $group->{name});
	$request->addResult('syncPower', $group->{syncPower});
	$request->addResult('syncVolume', $group->{syncVolume});
	
	my $loopname = 'players_loop';
	my $chunkCount = 0;
	
	foreach my $player ( @{$group->{members} || []} ) {
		$request->addResultLoop($loopname, $chunkCount, 'id', $player);

		if ( my $client = Slim::Player::Client::getClient($player) ) {
			$request->addResultLoop($loopname, $chunkCount, 'playername', $client->name);
		}		
		$chunkCount++;
	}

	$request->setStatusDone();
}

1;
