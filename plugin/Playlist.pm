package Slim::Player::Playlist;

=comment
	This file is overriding the default Slim::Player::Source::stopandClear() method
	to cover for the Groups plugin's need to have a reference to the original
	$client object when stopping playback.
=cut

use Slim::Utils::Log;

my $log = logger('player.playlist');

sub stopAndClear {
	my $client = shift;
	
	# Bug 11447 - Have to stop player and clear song queue
	$client->controller->stop($client);
	$client->controller()->resetSongqueue();

	@{playList($client)} = ();
	$client->currentPlaylist(undef);
	
	# Remove saved playlist if available
	my $playlistUrl = _playlistUrlForClient($client);
	unlink(Slim::Utils::Misc::pathFromFileURL($playlistUrl)) if $playlistUrl;

	reshuffle($client);
}

1;