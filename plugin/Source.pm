package Slim::Player::Source;

=comment
	This file is overriding the default Slim::Player::Source::playmode() 
	method to cover for the Groups plugin's need to have a reference 
	to the original	$client object when stopping playback
	
	Although, this method does not seem to be called, but rather the 
	playlist::stopAndClear is - don't know why, maybe it's a CLI thing only
=cut

use Slim::Utils::Log;

my $log = logger('player.source');

# playmode - start playing, pause or stop
sub playmode {
	my ($client, $newmode, $seekdata, $reconnect, $fadeIn) = @_;
	my $controller = $client->controller();

	assert($controller);
		
	# Short circuit.
	return _returnPlayMode($controller, $client) unless defined $newmode;
	
	main::INFOLOG && $log->is_info && $log->info('Custom Slim::Player::Source::playmode() called for Groups plugin');	
	
	if ($newmode eq 'stop') {
		# BEGIN - added $client
		$controller->stop($client);
		# END
	} elsif ($newmode eq 'play') {
		if (!$client->power()) {$client->power(1);}
		$controller->play(undef, $seekdata, $reconnect, $fadeIn);
	} elsif ($newmode eq 'pause') {
		# BEGIN - added $client
		$controller->pause($client);
		# END
	} elsif ($newmode eq 'resume') {
		if (!$client->power()) {$client->power(1);}
		$controller->resume($fadeIn);
	} else {
		logBacktrace($client->id . " unknown playmode: $newmode");
	}
	
	# bug 6971
	# set the player power item on Jive to whatever our power setting now is
	Slim::Control::Jive::playerPower($client);
	
	my $return = _returnPlayMode($controller, $client);
	
	if ( main::INFOLOG && $log->is_info ) {
		$log->info($client->id() . ": Current playmode: $return\n");
	}
		
	return $return;
}
		
1;