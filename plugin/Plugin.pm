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
# override default Slim::Player::Playlist::stopAndClear()
use Plugins::Groups::Playlist;

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

# migrate existing prefs to new structure, bump prefs version by one tick
# XXX - this code can probably be removed - only needed for beta testers
$prefs->migrate(1, sub {
	my $groups = $prefs->get('groups') || {};
	
	return unless ref $groups eq 'HASH';
	
	my @groups;
	
	# move all group prefs to a client pref object
	foreach my $group (keys %$groups) {
		my $cprefs = Slim::Utils::Prefs::Client->new( $prefs, $group, 'no-migrate' );
		
		while ( my ($k, $v) = each %{$groups->{$group}} ) {
			next if $k eq 'name';
			$cprefs->set($k, $v);
		}
	}
	
	$prefs->remove('groups');
});

sub getDisplayName() {
	return 'PLUGIN_GROUPS_NAME';
}

sub initPlugin {
	my $class = shift;

	$log->info(string('PLUGIN_GROUPS_STARTING'));

	if ( main::WEBUI ) {
		require Plugins::Groups::Settings;
		Plugins::Groups::Settings->new;
	}	

	$class->initCLI();
	
	foreach my $id ( $class->groupIDs() ) {
		main::INFOLOG && $log->info("Creating player group $id");
		createPlayer($id);
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
													 $prefs->client($master)->get('syncVolume') &&
													 !$master->_volumeDispatching;

	my @group  = $client->syncedWith;
	my $oldVolume = $client->volume;
	$newVolume += $oldVolume if $newVolume =~ /^[\+\-]/;
	
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
	my $s = sockaddr_in(0, INADDR_LOOPBACK);

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

sub groupIDs {
	return map { $_->{clientid} } $prefs->allClients();
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

	my @groups = sort groupIDs();
	my $count = @groups;
	
	my ($valid, $start, $end) = $request->normalize(scalar($index), scalar($quantity), $count);
	
	$request->addResult('count', $count);
		
	my $loopname = 'groups_loop';
	my $chunkCount = 0;
	
	foreach my $group ( @groups[$start .. $end] ) {
		my $groupClient = Slim::Player::Client::getClient($group);
		my $cprefs = $prefs->client($groupClient)->get($group);

		$request->addResultLoop($loopname, $chunkCount, 'id', $group);				
		$request->addResultLoop($loopname, $chunkCount, 'name', $groupClient->name);
		$request->addResultLoop($loopname, $chunkCount, 'syncPower', $cprefs->get('syncPower'));
		$request->addResultLoop($loopname, $chunkCount, 'syncVolume', $cprefs->get('syncVolume'));
		$request->addResultLoop($loopname, $chunkCount, 'players', scalar @{ $cprefs->get('members') || [ ]});
		
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

	my $client = $request->client;
	
	if (!$client || $client->model ne 'group') {
		$log->warn($client->id . ' is either not a group, or it does not exist') if $client;
		$request->setStatusBadDispatch();
		return;
	}
	
	my $cprefs = $prefs->client($client);
	
	$request->addResult('name', $client->name);
	$request->addResult('syncPower', $cprefs->get('syncPower'));
	$request->addResult('syncVolume', $cprefs->get('syncVolume'));
	
	my $loopname = 'players_loop';
	my $chunkCount = 0;
	
	foreach my $player ( @{ $cprefs->get('members') || [] } ) {
		$request->addResultLoop($loopname, $chunkCount, 'id', $player);

		if ( my $slave = Slim::Player::Client::getClient($player) ) {
			$request->addResultLoop($loopname, $chunkCount, 'playername', $slave->name);
		}		
		$chunkCount++;
	}

	$request->setStatusDone();
}

1;
