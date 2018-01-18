if (SqueezeJS.UI.Buttons.PlayerDropdown) {
	[% PROCESS jsString id='PLUGIN_GROUPS_NAME' jsId='choose_group' %]
	
	Ext.override(SqueezeJS.UI.Buttons.PlayerDropdown, {
		_addPlayerlistMenu: function(response){
			if (response.players_loop) {
				response.players_loop = response.players_loop.sort(this._sortPlayer);
				var specialItems = {};
	
				for (var x=0; x < response.players_loop.length; x++) {
					var playerInfo = response.players_loop[x];
					
					if (!playerInfo.connected)
						continue;
	
					// mark the current player as selected
					if (playerInfo.playerid == SqueezeJS.Controller.getPlayer()) {
						this.setText(playerInfo.name);
					}
	
					// add the players to the list to be displayed in the synch dialog
					this.playerList.add(playerInfo.playerid, {
						name: playerInfo.name,
						isplayer: playerInfo.isplayer
					});
	
					var tpl = new Ext.Template( '<div>{title}<span class="browsedbControls"><img src="' + webroot + 'html/images/{powerImg}.gif" id="{powerId}">&nbsp;<img src="' + webroot + 'html/images/{playPauseImg}.gif" id="{playPauseId}"></span></div>')
					
					var menuItem = new Ext.menu.CheckItem({
						text: tpl.apply({
							title: playerInfo.name,
							playPauseImg: playerInfo.isplaying ? 'b_pause' : 'b_play',
							playPauseId: playerInfo.playerid + ' ' + (playerInfo.isplaying ? 'pause' : 'play'),
							powerImg: playerInfo.power ? 'b_poweron' : 'b_poweroff',
							powerId: playerInfo.playerid + ' power ' + (playerInfo.power ? '0' : '1')
						}),
						value: playerInfo.playerid,
						cls: playerInfo.model,
						group: 'playerList',
						checked: playerInfo.playerid == playerid,
						hideOnClick: false,
						listeners: {
							click: function(self, ev) {
								var target = ev ? ev.getTarget() : null;
								
								// check whether user clicked one of the playlist controls
								if ( target && Ext.id(target).match(/^([a-f0-9:]+ (?:power|play|pause)\b.*)/i) ) {
									var cmd = RegExp.$1.split(' ');
									
									Ext.Ajax.request({
										url: SqueezeJS.Controller.getBaseUrl() + '/jsonrpc.js',
										method: 'POST',
										params: Ext.util.JSON.encode({
											id: 1,
											method: "slim.request",
											params: [cmd.shift(), cmd]
										}),
										callback: function() {
											SqueezeJS.Controller.updateAll();
										}
									});
									return false;
								}
							}
						},
						scope: this,
						handler: this._selectPlayer
					});
				
					// if a string "choose_MODEL" is defined, create separate group for this model
					console.log(playerInfo.model)
					if (playerInfo.model == 'group') {
						if (!specialItems[playerInfo.model])
							specialItems[playerInfo.model] = [];
						
						specialItems[playerInfo.model].push(menuItem);
					}
					else {
						this.menu.add(menuItem);
					}
				}
				
				Ext.iterate(specialItems, function(key, value) {
					this.menu.add(
						'-',
						'<span class="menu-title">' + SqueezeJS.string('choose_' + key) + '</span>'
					);
	
					Ext.each(value, function(menuItem) {
						this.menu.add(menuItem);
					}, this);
				}, this);
			}
		}
	});
}