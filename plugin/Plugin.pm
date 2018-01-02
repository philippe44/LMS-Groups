use strict;

package Plugins::Groups::Plugin;

use base qw(Slim::Plugin::Base);

use Socket;
use List::Util qw(first);

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

our $autoChunk = 0;

my $log = Slim::Utils::Log->addLogCategory({
	'category' => 'plugin.groups',
	'defaultLevel' => 'ERROR',
	'description' => 'PLUGIN_GROUPS_NAME'
});

my $prefs = preferences('plugin.groups');
my $sprefs = preferences('server');
my $originalVolumeHandler;

$prefs->init({
	restoreStatic => 1,
	showDisconnected => 0,
});

# migrate existing prefs to new structure, bump prefs version by one tick
# XXX - this code can probably be removed - only needed for beta testers
$prefs->migrate(3, sub {
	my @migrate = ( 'powerMaster', 'powerPlay', 'members', 'volumes' );

	foreach my $client ($sprefs->allClients) {
		next unless $client->exists($prefs->namespace);
		my $cprefs = Slim::Utils::Prefs::Client->new( $prefs, $client->{clientid}, 'no-migrate' );
		my $data = $client->get($prefs->namespace);
		foreach my $key (@migrate) { 
			$cprefs->set($key, $data->{$key});
		}	
		$client->remove($prefs->namespace);
	}
});

sub getDisplayName() {
	return 'PLUGIN_GROUPS_NAME';
}

sub initPlugin {
	my $class = shift;
	
	$log->info(string('PLUGIN_GROUPS_STARTING'));

	$autoChunk = defined &Slim::Player::Source::_groupOverload;
	$log->warn('cannot overload Slim::Player::Source ==> member stop will stop all group and chunks will be purged by timer') if !$autoChunk;
	$log->warn('cannot overload Slim::Player::Playlist ==> member stop will stop all group') if !defined &Slim::Player::Playlist::_groupOverload;

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
													 !$master->_volumeDispatching;
	
	my $members = $prefs->client($master)->get('members');	
	return $originalVolumeHandler->($request) unless scalar @$members;
	
	my $oldVolume = $client->volume;
	$newVolume += $oldVolume if $newVolume =~ /^[\+\-]/;
	
	# avoid recursing loop				
	$master->_volumeDispatching(1);			
	
	# get the memorized individual volumes
	my $volumes = $prefs->client($master)->get('volumes');
		
	$log->info("volume command $newVolume for $client with old volume $oldVolume (master = $master)");
	
	if ($client == $master) {
		# when changing virtual player's volume, apply a ratio to all members, 
		# whether they are currently sync'd or not (except the missing ones)
		foreach my $id (@$members) {
			my $volume = $oldVolume ? $volumes->{$id} * $newVolume / $oldVolume : $newVolume;
	
			$volumes->{$id} = $volume;
						
			$log->debug("new volume for $id $volume");
			
			# only apply if member is connected & synchronized 
			my $member = Slim::Player::Client::getClient($id);
			Slim::Control::Request::executeRequest($member, ['mixer', 'volume', $volume]) if $member && $master->isSyncedWith($member);
		}	
	} else {
		# memorize volume in master's prefs
		$volumes->{$client->id} = $newVolume;
		my $masterVolume = 0;
		
		# the virtual is an average of all members' volumes
		foreach my $id (@$members) { 
			# do not use actual $member->volume as we might not be actually synced with it
			$masterVolume += $volumes->{$id};
			$log->debug("current volume of $id ", $volumes->{$id});
		}
		
		$masterVolume /= scalar @$members;
		
		$log->info("setting master volume from $client for $master at $masterVolume");
	
		Slim::Control::Request::executeRequest($master, ['mixer', 'volume', $masterVolume]);
	}

	# memorize volumes for when group will be re-assembled
	$prefs->client($master)->set('volumes', $volumes) if scalar @$members;
	
	# all dispatch done
	$master->_volumeDispatching(0);	
	
	$originalVolumeHandler->($request);
}

sub initVolume {
	my $master = Slim::Player::Client::getClient($_[0]);
	my $masterVolume = 0;
	my $members = $prefs->client($master)->get('members');
	my $volumes = $prefs->client($master)->get('volumes');
	
	return unless scalar @$members;
	
	foreach my $id (@$members) {
		my $member = Slim::Player::Client::getClient($id);

		# initialize member's volume if possible & needed	
		$volumes->{$id} = $member->volume if defined $member && !defined $volumes->{$id};
		$masterVolume += $volumes->{$id};
	}
	
	$prefs->client($master)->set('volumes', $volumes);	
	
	# set master's volume
	$masterVolume /= scalar @$members;
	$log->info("new master volume $masterVolume");
	
	# this is init, so avoid loop in mixercommand (and can't rely on _volumeDispatching)
	$master->volume($masterVolume);
	$sprefs->client($master)->set('volume', $masterVolume);
	Slim::Control::Request::executeRequest($master, ['mixer', 'volume', $masterVolume]);
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
	
	# remove client prefs as it will not come back with same mac
	$sprefs->remove($Slim::Utils::Prefs::Client::clientPreferenceTag . ':' . $_[0]);

	$client->tcpsock(undef);
	$client->disconnected(1);
		
	Slim::Control::Request::notifyFromArray($client, ['client', 'disconnect']);
	Slim::Utils::Timers::setTimer( $client,	Time::HiRes::time() + 5, sub {
				# $client->forgetClient;
				Slim::Control::Request::executeRequest($client, ['client', 'forget']);
				} );
				
	main::INFOLOG && $log->info("delete group player $client");
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

	my @groups = sort groupIDs();
	my $count = @groups;
	
	my ($valid, $start, $end) = $request->normalize(scalar($index), scalar($quantity), $count);
	
	$request->addResult('count', $count);
		
	my $loopname = 'groups_loop';
	my $chunkCount = 0;
	
	foreach my $group ( @groups[$start .. $end] ) {
		my $groupClient = Slim::Player::Client::getClient($group);
		
		$request->addResultLoop($loopname, $chunkCount, 'id', $group);				
		$request->addResultLoop($loopname, $chunkCount, 'name', $groupClient->name);
		$request->addResultLoop($loopname, $chunkCount, 'powerMaster', $prefs->client($groupClient)->get('powerMaster'));
		$request->addResultLoop($loopname, $chunkCount, 'powerPlay', $prefs->client($groupClient)->get('powerPlay'));
		$request->addResultLoop($loopname, $chunkCount, 'players', scalar @{ $prefs->client($groupClient)->get('members') || [ ]});
		
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
	
	$request->addResult('name', $client->name);
	$request->addResult('powerMaster', $prefs->client($client)->get('powerMaster'));
	$request->addResult('powerPlay', $prefs->client($client)->get('powerPlay'));
	
	my $loopname = 'players_loop';
	my $chunkCount = 0;
	
	foreach my $player ( @{ $prefs->client($client)->get('members') || [] } ) {
		$request->addResultLoop($loopname, $chunkCount, 'id', $player);

		if ( my $member = Slim::Player::Client::getClient($player) ) {
			$request->addResultLoop($loopname, $chunkCount, 'playername', $member->name);
		}		
		$chunkCount++;
	}

	$request->setStatusDone();
}

sub allPrefs {
	return map { {clientid => $_->{clientid}, %{$_->all}} } $prefs->allClients;
}
		
sub groupIDs {
	return map { $_->{clientid} } $prefs->allClients;
}


1;
