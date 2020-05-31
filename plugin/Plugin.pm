use strict;

package Plugins::Groups::Plugin;

use base qw(Slim::Plugin::Base);

use Socket;
use List::Util qw(first);
use Data::Dump qw(dump);

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
my $sprefs = preferences('server');
my $originalVolumeHandler;
my $originalSyncHandler;
my $originalStatusHandler;

$prefs->init({
	# can't set prefs at a true value for checkboxes (unchecked = undef)
	# restoreStatic => 1,
	showDisconnected => 0,
	breakupTimeout => 30,
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
	
	main::INFOLOG && $log->is_info && $log->info(string('PLUGIN_GROUPS_STARTING'));
	
	$prefs->set('restoreStatic', 1) unless $prefs->exits('restoreStatic');

	if ( main::WEBUI ) {
		require Plugins::Groups::Settings;
		Plugins::Groups::Settings->new;
		
		require Plugins::Groups::PlayerSettings;
		Plugins::Groups::PlayerSettings->new;
				
		# try to add the Group Player section in the player selection drop-down menu - requires a recent 7.9.1 or later
		eval {
			require Slim::Web::Pages::JS;

			Slim::Web::Pages->addPageFunction("plugins/groups/js-main-grouping.js", sub {
				Slim::Web::HTTP::filltemplatefile('js-main-grouping.js', $_[1]);
			});
			
			Slim::Web::Pages::JS->addJSFunction('js-main', 'plugins/groups/js-main-grouping.js');		
		}
		
	}

	$class->initCLI();
		
	foreach my $id ( $class->groupIDs(1) ) {
		main::INFOLOG && $log->is_info && $log->info("Creating player group $id");
		createPlayer($id);
	}
	
	$originalVolumeHandler = Slim::Control::Request::addDispatch(['mixer', 'volume', '_newvalue'], [1, 0, 0, \&mixerVolumeCommand]);
	$originalSyncHandler = Slim::Control::Request::addDispatch(['sync', '_indexid-'], [1, 0, 1, \&syncCommand]);
}

sub shutdownPlugin {
	foreach ( Plugins::Groups::Plugin->groupIDs(1) ) {
		Slim::Player::Client::getClient($_)->controller()->undoGroup();
	}
}

sub doTransfer {
	my ($source, $dest) = @_;
			
	# need to preserve song index and seek data
	my $seekdata = $source->controller->playingSong->getSeekData($source->controller->playingSongElapsed);
	my $index = $source->controller->playingSong->index;
	
	# stop the destination and grab playlist from source	
	$dest->controller->stop;
	Slim::Player::Playlist::copyPlaylist($dest, $source);
				
	# start group player, it should assemble itself
	$dest->controller->play($index, $seekdata);
	Slim::Control::Request::notifyFromArray($dest, ['playlist', 'play']);
	Slim::Control::Request::notifyFromArray($dest, ['playlist', 'sync']);
	
	# if source player was member of dest group, do not stop it
	if ($source->controller != $dest->controller) {
		$source->controller->stop;
		Slim::Control::Request::notifyFromArray($source, ['playlist', 'stop']);
		Slim::Control::Request::notifyFromArray($source, ['playlist', 'sync']);
	}	
}

sub syncTimer {
	my $client = shift;
	my $slave = $client->pluginData('transfer');
	
	main::INFOLOG && $log->info("transfer timeout ", $client->id);
	return unless $slave;
	
	# because pluginData is faulty an does not allow undef to be set...
	$client->pluginData(transfer => 0);
	$client->controller->sync($slave) unless $slave->isa("Plugins::Groups::Player");
}

=comment
Switching playback from player A to B is usually a special pattern of events 
that requires special handling when a Group Player is involved
1) B is synchronized with A
2) Within a few x00ms, B is un-synchronized
So when receiving the request to sync B with A, do nothing except store in B
that transfer to A might happen. When B is unsynced, if it contains A inside,
then we do a transfer of playlist, not using sync/unsync
If B is never unsync, then it means that it was just a real sync, so we
execute it once a short timeout expired. All this does is delaying a tiny bit
sync request only when Group Players are involved
When receiving an unsync, it will just be processed normally if client
does contains any transfer candidate.
If X and Y are regular players and if X has nothing stored, then it's a 
normal process, just passthrough
It does not affect Group assembly / breakup because we call directly the
sync/unsync functions, to the calls do not go through this filter
iPeng does special management of source & destination when A is a member of a
Group (normally, user should not try to use members as source) that I can't 
deal with totally correctly. So it does create some ghost syncgroup
=cut

sub syncCommand {
	my $request = shift;
	my $client  = $request->client;
	my $id = $request->getParam('_indexid-');
	my $slave = Slim::Player::Client::getClient($id) if $id !~ /-/;
	
	main::DEBUGLOG && $log->debug("sync handler for groups ", dump($request));
	
	# make sure Group players are involved
	if (!$client->isa("Plugins::Groups::Player") && 
	    (!$slave || !$slave->isa("Plugins::Groups::Player")) && 
		!$client->pluginData('transfer')) {
		
		main::DEBUGLOG && $log->debug("nothing to process");
		$originalSyncHandler->($request);
		return;
	}
	
	if ($id !~ /-/) {
		# if a transfer/sync is already pending, must execute it first. There 
		# is probaby no good solution to that problem and the way iPeng 
		# manages switches
		if (my $pending = $client->pluginData('transfer')) {
			Slim::Utils::Timers::killTimers($client, \&syncTimer);		
			if ($pending->isa("Plugins::Groups::Player")) {
				main::INFOLOG && $log->info("pending transfer from ", $client->name, " to ", $pending->name);
				doTransfer($client, $pending);
			} else {
				main::INFOLOG && $log->info("pending sync from ", $client->name, " to ", $pending->name);
				$client->controller->sync($pending);
			}	
		}
		
		# now we're done with any pending 
		# mark the player receiving sync so that we can do the transfer 
		# if/when the unsync is received for that player
		main::INFOLOG && $log->info("marking player ", $client->name, " for transfer to ", $slave->name);
		$client->pluginData(transfer => $slave);
		
		# this is a transfer, so it should be done super quickly, otherwise 
		# it's a user attempt that shall be process normally. The streaming
		# controller will reject if not valid (member of the group ...)
		Slim::Utils::Timers::setTimer($client, time() + 2, \&syncTimer);
	} elsif ($slave = $client->pluginData('transfer')) {
		# if the player is marked, then do the transfer
		Slim::Utils::Timers::killTimers($client, \&syncTimer);		
		main::INFOLOG && $log->info("transferring from ", $client->name, " to ", $slave->name);
		# because pluginData is faulty an does not allow undef to be set...
		$client->pluginData(transfer => 0);
		doTransfer($client, $slave);
	} else {
		$log->error("don't know what we're doing here ", $client->name);
	}
	
	$request->setStatusDone;	
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
		
	main::INFOLOG && $log->is_info && $log->info("volume command $newVolume for $client with old volume $oldVolume (master = $master)");
	
	if ($client == $master) {
		# when changing virtual player's volume, apply a ratio to all members, 
		# whether they are currently sync'd or not (except the missing ones)
		foreach my $id (@$members) {
			# bypass fixed volumes (can't use getClient as it only works for connected devices)
			next if $volumes->{$id} == -1;
			my $volume = $oldVolume ? $volumes->{$id} * $newVolume / $oldVolume : $newVolume;
	
			$volumes->{$id} = $volume;
						
			main::DEBUGLOG && $log->is_debug && $log->debug("new volume for $id $volume");
			
			# only apply if member is connected & synchronized 
			my $member = Slim::Player::Client::getClient($id);
			Slim::Control::Request::executeRequest($member, ['mixer', 'volume', $volume]) if $member && $master->isSyncedWith($member);
		}	
	} else {
		# memorize volume in master's prefs 
		$volumes->{$client->id} = $sprefs->client($client)->get("digitalVolumeControl") ? $newVolume : -1;
		my $masterVolume = 0;
		my $count = 0;
		
		# the virtual is an average of all members' volumes
		foreach my $id (@$members) { 
			# do not take into account fixed volume members 
			next if $volumes->{$id} == -1; 
			
			# do not use actual $member->volume as we might not be actually synced with it
			$masterVolume += $volumes->{$id};
			$count++;
			main::DEBUGLOG && $log->is_debug && $log->debug("current volume of $id ", $volumes->{$id});
		}
		
		$masterVolume = $count ? $masterVolume / $count : -1;
				
		main::INFOLOG && $log->is_info && $log->info("setting master volume from $client for $master at $masterVolume");
	
		Slim::Control::Request::executeRequest($master, ['mixer', 'volume', $masterVolume]) if $masterVolume != -1;
	}

	# memorize volumes for when group will be re-assembled
	$prefs->client($master)->set('volumes', $volumes);
	
	# all dispatch done
	$master->_volumeDispatching(0);	
	
	$originalVolumeHandler->($request);
}

sub initVolume {
	my $master = Slim::Player::Client::getClient($_[0]);
	
	return unless $master;
	
	my $masterVolume = 0;
	my $members = $prefs->client($master)->get('members');
	my $volumes = $prefs->client($master)->get('volumes');
		
	return unless scalar @$members;
	
	my $count = 0;
	
	foreach my $id (@$members) {
		my $member = Slim::Player::Client::getClient($id);
		
		# initialize member's volume if possible & needed, ignore fixed volume
		if (!defined $member || $sprefs->client($member)->get('digitalVolumeControl')) {
			$count++;
	   		# if member is not connected, just use the last known volume
			$volumes->{$id} = (defined $member ? $member->volume : 50) if !defined $volumes->{$id};
			$masterVolume += $volumes->{$id};
		} else { 
			$volumes->{$id} = -1; 
		}	
	}
	
	$prefs->client($master)->set('volumes', $volumes);	
	
	# set master's volume, if none abitrary set at 50%
	$masterVolume = $count ? $masterVolume / $count : 50;
	main::INFOLOG && $log->is_info && $log->info("new master volume $masterVolume");
	
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
		
	main::INFOLOG && $log->is_info && $log->info("create group player $client");
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
				
	main::INFOLOG && $log->is_info && $log->info("delete group player $client");
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

	Slim::Control::Request::addDispatch(['playergroups', '_cmd'],
	                                                            [0, 0, 1, \&_cliCommand]
	);
																
	$originalStatusHandler = Slim::Control::Request::addDispatch(['status', '_index', '_quantity'], 
																[1, 1, 1, \&statusQuery]);																
}

sub statusQuery {
	my ($request) = @_;
	my $client = $request->client;
	
	$originalStatusHandler->($request);
	return unless $client->isa("Plugins::Groups::Player");

	my $members = $prefs->client($client)->get('members');
	return unless scalar @$members;

	my $list = join ',', @$members;	
	$request->addResult('members', $list);
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

sub _cliCommand {
	my $request = shift;

	# check this is the correct query.
	if ($request->isNotCommand([['playergroups']])) {
		$request->setStatusBadDispatch();
		return;
	}

	my $cmd = $request->getParam('_cmd');

	# command needs to be one of 4 different things
	if ($request->paramUndefinedOrNotOneOf($cmd, ['add', 'delete', 'update', 'can-manage']) ) {
		$request->setStatusBadParams();
		return;
	}

	if ($cmd eq 'can-manage') {
		$request->addResult('can-manage', 1);
		$request->setStatusDone();
		return;
	}

	my $id = $request->getParam('id');
	my $name = $request->getParam('name');
	my $powerMaster = $request->getParam('powerMaster');
	my $powerPlay = $request->getParam('powerPlay');
	my $members = $request->getParam('members');

	if ($cmd eq 'add') {
		if ($id || !$name) {
			$request->setStatusBadParams();
			return;
		}

		$id = Plugins::Groups::Settings::createId();

		main::INFOLOG && $log->is_info && $log->info("Adding $name $id");
		Plugins::Groups::Plugin::createPlayer($id, $name);
		my $cprefs = Slim::Utils::Prefs::Client->new($prefs, $id, 'no-migrate' );
		$cprefs->set('powerMaster', $powerMaster ? 1 : 0);
		$cprefs->set('powerPlay', $powerPlay ? 1 : 0);

		if ($members) {
			my @memberList = split /,/, $members;
			$cprefs->set('members', \@memberList);
		}

		$request->addResult('id', $id);
		$request->setStatusDone();
		return;
	}

	if ($cmd eq 'delete') {
		if (!$id) {
			$request->setStatusBadParams();
			return;
		}
		main::INFOLOG && $log->is_info && $log->info("Deleting $id");
		$prefs->remove($Slim::Utils::Prefs::Client::clientPreferenceTag . ':' . $id);
		foreach my $namespace (@{ Slim::Utils::Prefs::namespaces() }) {
			preferences($namespace)->remove($Slim::Utils::Prefs::Client::clientPreferenceTag . ':' . $id);
		}
		delPlayer($id);
		$request->setStatusDone();
		return;
	}

	if ($cmd eq 'update') {
		if (!$id || $name) {
			$request->setStatusBadParams();
			return;
		}
		main::INFOLOG && $log->is_info && $log->info("Updating $id");
		my $cprefs = Slim::Utils::Prefs::Client->new($prefs, $id, 'no-migrate');
		if ($powerMaster == 0 || $powerMaster == 1) {
			$cprefs->set('powerMaster', $powerMaster ? 1 : 0);
		}
		if ($powerPlay == 0 || $powerPlay == 1) {
			$cprefs->set('powerPlay', $powerPlay ? 1 : 0);
		}
		if ($members) {
			if ($members eq '-') {
				my @memberList = [];
				$cprefs->set('members', \@memberList);
			} else {
				my @memberList = split /,/, $members;
				$cprefs->set('members', \@memberList);
			}
		}
		$request->setStatusDone();
	}
}

sub allPrefs {
	my @group = map { {clientid => $_->{clientid}, %{$_->all}} } $prefs->allClients;
	return sort { lc($sprefs->client(Slim::Player::Client::getClient($a->{clientid}))->get('playername')) cmp
			      lc($sprefs->client(Slim::Player::Client::getClient($b->{clientid}))->get('playername')) } @group;
}
		
sub groupIDs {
	my ($class, $noSort) = @_;
	my @group = map { $_->{clientid} } $prefs->allClients;
	return @group if $noSort;
	return sort { lc($sprefs->client(Slim::Player::Client::getClient($a))->get('playername')) cmp
			      lc($sprefs->client(Slim::Player::Client::getClient($b))->get('playername')) } @group;	
}


1;
