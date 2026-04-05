import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../cached_network_image.dart';
import '../client.dart';
import '../client_controller.dart';
import '../database.dart';
import '../dialog/edit_profile.dart';
import '../irc.dart';
import '../logging.dart';
import '../models.dart';
import '../prefs.dart';
import 'connect.dart';
import 'edit_bouncer_network.dart';
import 'network_details.dart';

class SettingsPage extends StatefulWidget {
	static const routeName = '/settings';

	const SettingsPage({ super.key });

	@override
	State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
	late bool _compact;
	late bool _typing;
	late bool _linkPreview;
	late bool _linkExtApp;
	late bool _uploadErrorReports;
	late String? _uploadErrorReportsHost;
	bool _supportsInAppBrowserView = true;

	@override
	void initState() {
		super.initState();

		var prefs = context.read<Prefs>();
		_compact = prefs.bufferCompact;
		_typing = prefs.typingIndicator;
		_linkPreview = prefs.linkPreview;
		_linkExtApp = prefs.linkExtApp;
		_uploadErrorReports = prefs.uploadErrorReports;
		_uploadErrorReportsHost = log.sentryHost;

		unawaited(() async {
			var supportsInAppBrowserView = await supportsLaunchMode(LaunchMode.inAppBrowserView);
			if (!mounted) {
				return;
			}
			setState(() {
				_supportsInAppBrowserView = supportsInAppBrowserView;
			});
		}());
	}

	void _showLogoutDialog() {
		showDialog<void>(
			context: context,
			builder: (context) => AlertDialog(
				title: Text('Log out'),
				content: Text('Are you sure you want to log out?'),
				actions: [
					TextButton(
						child: Text('CANCEL'),
						onPressed: () {
							Navigator.pop(context);
						},
					),
					ElevatedButton(
						child: Text('LOG OUT'),
						onPressed: () {
							Navigator.pop(context);
							_logout();
						},
					),
				],
			),
		);
	}

	void _logout() async {
		var db = context.read<DB>();
		var networkList = context.read<NetworkListModel>();
		var bouncerNetworkList = context.read<BouncerNetworkListModel>();

		for (var network in networkList.networks) {
			unawaited(db.deleteNetwork(network.networkId));
		}
		networkList.clear();
		bouncerNetworkList.clear();
		context.read<ClientProvider>().clear();

		unawaited(Navigator.pushNamedAndRemoveUntil(context, ConnectPage.routeName, (Route<dynamic> route) => false));
	}

	@override
	Widget build(BuildContext context) {
		var networkList = context.watch<NetworkListModel>();

		NetworkModel? mainNetwork;
		for (var network in networkList.networks) {
			if (network.networkEntry.bouncerId == null) {
				mainNetwork = network;
				break;
			}
		}
		if (mainNetwork == null) {
			// This can happen when logging out: the settings page is still
			// being displayed because of a fade-out animation but we no longer
			// have any network configured.
			return Container();
		}

		var mainClient = context.read<ClientProvider>().get(mainNetwork);

		List<Widget> networks = [];
		for (var network in networkList.networks) {
			if (network.networkEntry.caps.containsKey('soju.im/bouncer-networks') && network.networkEntry.bouncerId == null) {
				continue;
			}
			networks.add(_NetworkItem(network: network));
		}

		var networkListenable = Listenable.merge(networkList.networks);
		return AnimatedBuilder(animation: networkListenable, builder: (context, _) => Scaffold(
			appBar: AppBar(
				title: Text('Settings'),
			),
			body: ListView(children: [
				SizedBox(height: 10),
				ListTile(
					title: Builder(builder: (context) => Text(
						mainNetwork!.nickname,
						style: DefaultTextStyle.of(context).style.apply(
							fontSizeFactor: 1.2,
						).copyWith(
							fontWeight: FontWeight.bold,
						),
					)),
					subtitle: isStubRealname(mainNetwork!.realname, mainNetwork.nickname) ? null : Text(mainNetwork.realname),
					leading: CircleAvatar(
						radius: 40,
						child: Icon(Icons.face, size: 32),
					),
					trailing: (mainClient.state != ClientState.connected) ? null : IconButton(
						icon: Icon(Icons.edit),
						onPressed: () {
							EditProfileDialog.show(context, mainNetwork!);
						},
					),
				),
				SizedBox(height: 10),
				Column(children: networks),
				if (mainClient.caps.enabled.contains('soju.im/bouncer-networks')) ListTile(
					title: Text('Add network'),
					leading: Icon(Icons.add),
					onTap: () {
						Navigator.pushNamed(context, EditBouncerNetworkPage.routeName);
					},
				),
				Divider(),
				SwitchListTile(
					title: Text('Compact message list'),
					secondary: Icon(Icons.reorder),
					value: _compact,
					onChanged: (bool enabled) {
						context.read<Prefs>().bufferCompact = enabled;
						setState(() {
							_compact = enabled;
						});
					},
				),
				SwitchListTile(
					title: Text('Send & display typing indicators'),
					secondary: Icon(Icons.border_color),
					value: _typing,
					onChanged: (bool enabled) {
						context.read<Prefs>().typingIndicator = enabled;
						setState(() {
							_typing = enabled;
						});
					},
				),
				SwitchListTile(
					title: Text('Display link previews'),
					subtitle: Text('Retrieve link previews directly from websites for messages you receive. Privacy-conscious users may want to leave this off.'),
					secondary: Icon(Icons.preview),
					value: _linkPreview,
					onChanged: (bool enabled) {
						context.read<Prefs>().linkPreview = enabled;
						setState(() {
							_linkPreview = enabled;
						});
					},
				),
				if (_supportsInAppBrowserView) SwitchListTile(
					title: Text('Open links in external app'),
					subtitle: Text('Use an external application (web browser, navigation, etc.) for opening links.'),
					secondary: Icon(Icons.link),
					value: _linkExtApp,
					onChanged: (bool enabled) {
						context.read<Prefs>().linkExtApp = enabled;
						setState(() {
							_linkExtApp = enabled;
						});
					},
				),
				if (_uploadErrorReportsHost != null) SwitchListTile(
					title: Text('Send crash reports'),
					subtitle: Text('Crash reports will be sent to $_uploadErrorReportsHost.'),
					secondary: Icon(Icons.bug_report),
					value: _uploadErrorReports,
					onChanged: (bool enabled) {
						context.read<Prefs>().uploadErrorReports = enabled;
						setState(() {
							_uploadErrorReports = enabled;
						});
					},
				),
				Divider(),
				ListTile(
					title: Text('About'),
					leading: Icon(Icons.info),
					onTap: () {
						launchUrl(Uri.parse('https://codeberg.org/emersion/goguma'));
					},
				),
				ListTile(
					title: Text('Logout'),
					leading: Icon(Icons.logout, color: Colors.red),
					textColor: Colors.red,
					onTap: _showLogoutDialog,
				),
			]),
		));
	}
}

class _NetworkItem extends AnimatedWidget {
	final NetworkModel network;

	_NetworkItem({ required this.network }) :
		super(listenable: Listenable.merge([network, network.bouncerNetwork]));

	@override
	Widget build(BuildContext context) {
		String subtitle;
		if (network.bouncerNetwork != null && network.state == NetworkState.online) {
			subtitle = bouncerNetworkStateDescription(network.bouncerNetwork!.state);
			if (network.bouncerNetwork?.error?.isNotEmpty == true) {
				subtitle = '$subtitle - ${network.bouncerNetwork!.error}';
			}
		} else {
			subtitle = networkStateDescription(network.state);
			if (network.connectError != null) {
				subtitle = '$subtitle - ${network.connectError}';
			}
		}

		var icon = network.icon;

		return ListTile(
			title: Text(network.displayName),
			subtitle: Text(subtitle),
			leading: Column(
				mainAxisAlignment: MainAxisAlignment.center,
				children: [ClipRRect(
					borderRadius: BorderRadius.circular(5),
					child: Container(
						width: 40,
						height: 40,
						color: Theme.of(context).colorScheme.surfaceContainerHigh,
						child: icon != null ? Image(
							image: CachedNetworkImage(icon),
							fit: BoxFit.contain,
						) : Icon(Icons.hub),
					),
				)],
			),
			onTap: () {
				Navigator.pushNamed(context, NetworkDetailsPage.routeName, arguments: network);
			},
		);
	}
}
