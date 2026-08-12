import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../ansi.dart';
import '../client.dart';
import '../client_controller.dart';
import '../database.dart';
import '../models.dart';
import '../page/edit_bouncer_network.dart';
import '../page/join.dart';
import '../page/settings.dart';
import '../widget/network_indicator.dart';
import 'buffer.dart';
import 'network_details.dart';
import 'search.dart';

class BufferListPage extends StatefulWidget {
	static const routeName = '/';

	const BufferListPage({ super.key });

	@override
	State<BufferListPage> createState() => _BufferListPageState();
}

Color networkStateColor(NetworkState state) {
	return switch (state) {
		NetworkState.online || NetworkState.synchronizing => const Color(0xFF43D17A),
		NetworkState.connecting || NetworkState.registering => const Color(0xFFE3B341),
		NetworkState.offline => const Color(0xFFF1766D),
	};
}

class _BufferListPageState extends State<BufferListPage> {
	String? _searchQuery;
	final TextEditingController _searchController = TextEditingController();
	final _listKey = GlobalKey();
	BufferModel? _splitBuffer;
	bool _wide = false;

	void _openBuffer(BufferModel buffer) {
		if (_wide) {
			setState(() {
				_splitBuffer = buffer;
			});
		} else {
			Navigator.popUntil(context, ModalRoute.withName(BufferListPage.routeName));
			Navigator.pushNamed(context, BufferPage.routeName, arguments: BufferPageArguments(buffer: buffer));
		}
	}

	@override
	void dispose() {
		_searchController.dispose();
		super.dispose();
	}

	void _search(String query) {
		setState(() {
			_searchQuery = query.toLowerCase();
		});
	}

	void _startSearch() {
		ModalRoute.of(context)?.addLocalHistoryEntry(LocalHistoryEntry(onRemove: () {
			setState(() {
				_searchQuery = null;
			});
			_searchController.text = '';
		}));
		_search('');
	}

	void _markAllBuffersRead() {
		var bufferList = context.read<BufferListModel>();
		var clientProvider = context.read<ClientProvider>();
		var db = context.read<DB>();

		for (var buffer in bufferList.buffers) {
			if (buffer.unreadCount == 0 || buffer.lastDeliveredTime == null) {
				continue;
			}

			buffer.unreadCount = 0;
			buffer.unreadMentions = 0;
			buffer.entry.lastReadTime = buffer.lastDeliveredTime!;
			db.storeBuffer(buffer.entry);

			var client = clientProvider.get(buffer.network);
			client.setReadMarker(buffer.name, buffer.lastDeliveredTime!);
		}

		// Re-compute hasUnreadBuffer
		setState(() {});
	}

	bool _shouldSuggestNewNetwork() {
		var clientProvider = context.read<ClientProvider>();
		if (clientProvider.clients.length != 1) {
			return false;
		}

		var client = clientProvider.clients.first;
		return client.caps.enabled.contains('soju.im/bouncer-networks') && client.params.bouncerNetId == null;
	}

	@override
	Widget build(BuildContext context) {
		List<BufferModel> buffers = context.watch<BufferListModel>().buffers;
		if (_searchQuery != null) {
			var query = _searchQuery!;
			List<BufferModel> filtered = [];
			for (var buf in buffers) {
				if (buf.name.toLowerCase().contains(query) || (buf.topic ?? buf.realname ?? '').toLowerCase().contains(query)) {
					filtered.add(buf);
				}
			}
			buffers = filtered;
		}

		var hasUnreadBuffer = false;
		for (var buffer in buffers) {
			if (buffer.unreadCount > 0) {
				hasUnreadBuffer = true;
			}
		}

		Widget body;
		if (buffers.length == 0) {
			if (_searchQuery != null) {
				body = _BufferListPlaceholder(
					icon: Icons.search,
					title: 'No search result',
					subtitle: 'No conversation matches the search query.',
				);
			} else if (_shouldSuggestNewNetwork()) {
				body = _BufferListPlaceholder(
					icon: Icons.hub,
					title: 'Join a network',
					subtitle: 'Welcome to IRC! To get started, join a network.',
					trailing: ElevatedButton(
						child: Text('New network'),
						onPressed: () {
							Navigator.pushNamed(context, EditBouncerNetworkPage.routeName);
						},
					),
				);
			} else {
				body = _BufferListPlaceholder(
					icon: Icons.tag,
					title: 'Join a conversation',
					subtitle: 'Welcome to IRC! To get started, join a channel or start a discussion with a user.',
					trailing: ElevatedButton(
						child: Text('New conversation'),
						onPressed: () {
							Navigator.pushNamed(context, JoinPage.routeName);
						},
					),
				);
			}
		} else {
			// Group the conversation list by server (network). Each network
			// becomes a header with its chats listed underneath it.
			Map<NetworkModel, List<BufferModel>> groups = {};
			for (var buffer in buffers) {
				groups.putIfAbsent(buffer.network, () => []).add(buffer);
			}
			body = ListView(
				key: _listKey,
				children: groups.entries.expand((group) => [
					_NetworkHeader(network: group.key),
					...group.value.map((buffer) => _BufferItem(buffer: buffer, onSelected: () => _openBuffer(buffer))),
				]).toList(),
			);
		}

		var listPane = NetworkListIndicator(
			child: _BackgroundServicePermissionBanner(child: body),
		);

		return LayoutBuilder(builder: (context, constraints) {
			_wide = constraints.maxWidth >= 900;

			var appBar = AppBar(
				leading: _searchQuery != null ? CloseButton() : null,
				title: Builder(builder: (context) {
					if (_searchQuery != null) {
						return TextField(
							controller: _searchController,
							autofocus: true,
							decoration: InputDecoration(
								hintText: 'Search...',
								border: InputBorder.none,
							),
							onChanged: _search,
						);
					} else {
						return Text('Goguma');
					}
				}),
				actions: _searchQuery != null ? null : [
					IconButton(
						tooltip: 'Search',
						icon: const Icon(Icons.search),
						onPressed: _startSearch,
					),
					PopupMenuButton(
						onSelected: (key) {
							switch (key) {
							case 'join':
								Navigator.pushNamed(context, JoinPage.routeName);
								break;
							case 'mark-all-read':
								_markAllBuffersRead();
								break;
							case 'search-messages':
								Navigator.pushNamed(context, SearchPage.routeName);
								break;
							case 'settings':
								Navigator.pushNamed(context, SettingsPage.routeName);
								break;
							}
						},
						itemBuilder: (context) {
							return [
								PopupMenuItem(value: 'join', child: Text('New conversation')),
								PopupMenuItem(value: 'search-messages', child: Text('Search messages')),
								if (hasUnreadBuffer) PopupMenuItem(value: 'mark-all-read', child: Text('Mark all as read')),
								PopupMenuItem(value: 'settings', child: Text('Settings')),
							];
						},
					),
				],
			);

			if (!_wide) {
				return Scaffold(appBar: appBar, body: listPane);
			}

			// Desktop/tablet: master-detail split with the chat on the right.
			Widget pane;
			var split = _splitBuffer;
			if (split == null) {
				pane = Center(child: Text(
					'Select a conversation',
					style: TextStyle(color: Theme.of(context).textTheme.bodySmall?.color),
				));
			} else {
				pane = MultiProvider(
					providers: [
						ChangeNotifierProvider<BufferModel>.value(value: split),
						ChangeNotifierProvider<NetworkModel>.value(value: split.network),
						Provider<Client>.value(value: context.read<ClientProvider>().get(split.network)),
					],
					child: BufferPage(
						unreadMarkerTime: split.entry.lastReadTime,
						onClose: () => setState(() => _splitBuffer = null),
					),
				);
			}

			return Scaffold(
				appBar: appBar,
				body: Row(children: [
					SizedBox(width: 340, child: listPane),
					const VerticalDivider(width: 1),
					Expanded(child: pane),
				]),
			);
		});
	}
}

class _BackgroundServicePermissionBanner extends StatelessWidget {
	final Widget child;

	const _BackgroundServicePermissionBanner({
		required this.child,
	});

	Widget _buildBackgroundSyncUnavailable(BuildContext context, Widget? child) {
		var clientProvider = context.read<ClientProvider>();
		return Column(children: [
			MaterialBanner(
				content: Text('This server doesn\'t support modern IRCv3 features. Goguma cannot maintain a persistent connection and will miss messages when running in the background.'),
				actions: [
					TextButton(
						child: Text('DISMISS'),
						onPressed: () {
							clientProvider.backgroundSyncStatus.value = BackgroundSyncStatus();
						},
					),
				],
				forceActionsBelow: true,
			),
			Expanded(child: child!),
		]);
	}

	Widget _buildNeedBackgroundServicePermissions(BuildContext context, Widget? child) {
		var clientProvider = context.read<ClientProvider>();
		return Column(children: [
			MaterialBanner(
				content: Text('This server doesn\'t support modern IRCv3 features. Goguma needs additional permissions to maintain a persistent network connection. This may increase battery usage.'),
				actions: [
					TextButton(
						child: Text('DISMISS'),
						onPressed: () {
							clientProvider.backgroundSyncStatus.value = BackgroundSyncStatus();
						},
					),
					TextButton(
						child: Text('ALLOW'),
						onPressed: () {
							clientProvider.askBackgroundServicePermissions();
						},
					),
				],
			),
			Expanded(child: child!),
		]);
	}

	@override
	Widget build(BuildContext context) {
		var clientProvider = context.read<ClientProvider>();
		return ValueListenableBuilder<BackgroundSyncStatus>(
			valueListenable: clientProvider.backgroundSyncStatus,
			builder: (context, backgroundSyncStatus, child) {
				if (backgroundSyncStatus.isUnavailable) {
					return _buildBackgroundSyncUnavailable(context, child);
				}
				if (backgroundSyncStatus.needServicePermissions) {
					return _buildNeedBackgroundServicePermissions(context, child);
				}
				return child!;
			},
			child: child,
		);
	}
}

class _BufferItem extends AnimatedWidget {
	final BufferModel buffer;
	final VoidCallback? onSelected;

	const _BufferItem({ required this.buffer, this.onSelected }) : super(listenable: buffer);

	@override
	Widget build(BuildContext context) {
		var subtitle = buffer.draft == null
			? (buffer.topic ?? buffer.realname)
			: 'Draft: ${buffer.draft!.text}';

		var title = Text(buffer.name, overflow: TextOverflow.ellipsis);

		List<Widget> trailing = [];
		if (buffer.muted) {
			trailing.add(Icon(
				Icons.notifications_off,
				size: 20,
				color: Theme.of(context).textTheme.bodySmall!.color,
			));
		}
		if (buffer.pinned) {
			trailing.add(Icon(
				Icons.push_pin,
				size: 20,
				color: Theme.of(context).textTheme.bodySmall!.color,
			));
		}
		if (buffer.archived) {
			trailing.add(Icon(
				Icons.inventory_2,
				size: 20,
				color: Theme.of(context).textTheme.bodySmall!.color,
			));
		}
		if (buffer.unreadMentions > 0) {
			// Amber "mention" badge takes precedence over the plain count.
			var theme = Theme.of(context);
			trailing.add(Container(
				padding: const EdgeInsets.all(3),
				decoration: BoxDecoration(
					color: buffer.muted ? theme.textTheme.bodySmall!.color : const Color(0xFFE3B341),
					borderRadius: BorderRadius.circular(20),
				),
				constraints: const BoxConstraints(minWidth: 22, minHeight: 22),
				child: Text(
					'${buffer.unreadMentions}',
					style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold),
					textAlign: TextAlign.center,
				),
			));
		} else if (buffer.unreadCount != 0) {
			var theme = Theme.of(context);
			trailing.add(Container(
				padding: EdgeInsets.all(3),
				decoration: BoxDecoration(
					color: buffer.muted ? theme.textTheme.bodySmall!.color : theme.colorScheme.secondaryContainer,
					borderRadius: BorderRadius.circular(20),
				),
				constraints: BoxConstraints(minWidth: 20, minHeight: 20),
				child: Text(
					'${buffer.unreadCount}',
					style: TextStyle(fontSize: 12),
					textAlign: TextAlign.center,
				),
			));
		}

		// extracted from the ListTile sourceIconData
		var theme = Theme.of(context);
		var dense = theme.listTileTheme.dense ?? false;
		var height = (dense ? 64.0 : 72.0) + theme.visualDensity.baseSizeAdjustment.dy;

		return Container(alignment: Alignment.center, height: height, child: ListTile(
			trailing: trailing.isEmpty ? null : Wrap(
				spacing: 5,
				children: trailing,
			),
			title: title,
			subtitle: subtitle == null ? null : Text(
				stripAnsiFormatting(subtitle),
				overflow: TextOverflow.fade,
				softWrap: false,
				style: buffer.draft == null ? null : TextStyle(fontStyle: FontStyle.italic),
			),
			onTap: onSelected ?? () {
				Navigator.popUntil(context, ModalRoute.withName(BufferListPage.routeName));
				Navigator.pushNamed(context, BufferPage.routeName, arguments: BufferPageArguments(buffer: buffer));
			},
		));
	}
}

class _NetworkHeader extends StatelessWidget {
	final NetworkModel network;

	const _NetworkHeader({ required this.network });

	@override
	Widget build(BuildContext context) {
		return ListenableBuilder(
			listenable: network,
			builder: (context, _) {
				var scheme = Theme.of(context).colorScheme;
				var dim = Theme.of(context).textTheme.bodySmall!.color ?? scheme.onSurface;
				var stateColor = networkStateColor(network.state);
				var stateLabel = networkStateDescription(network.state);

				return InkWell(
					onTap: () {
						Navigator.pushNamed(context, NetworkDetailsPage.routeName, arguments: network);
					},
					child: Container(
						color: scheme.surfaceContainerLow,
						padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 7),
						child: Row(children: [
							Icon(Icons.dns, size: 16, color: dim),
							const SizedBox(width: 8),
							Expanded(child: Text(
								network.displayName,
								style: const TextStyle(fontWeight: FontWeight.bold),
								overflow: TextOverflow.ellipsis,
							)),
							const SizedBox(width: 8),
							Container(
								width: 8,
								height: 8,
								decoration: BoxDecoration(color: stateColor, shape: BoxShape.circle),
							),
							const SizedBox(width: 6),
							Text(stateLabel, style: TextStyle(color: dim, fontSize: 12)),
						]),
					),
				);
			},
		);
	}
}

class _BufferListPlaceholder extends StatelessWidget {
	final IconData icon;
	final String title;
	final String subtitle;
	final Widget? trailing;

	const _BufferListPlaceholder({
		required this.icon,
		required this.title,
		required this.subtitle,
		this.trailing,
	});

	@override
	Widget build(BuildContext context) {
		return Center(child: Column(
			mainAxisAlignment: MainAxisAlignment.center,
			children: [
				Icon(icon, size: 100),
				Text(
					title,
					style: Theme.of(context).textTheme.headlineSmall,
					textAlign: TextAlign.center,
				),
				SizedBox(height: 15),
				Container(
					constraints: BoxConstraints(maxWidth: 300),
					child: Text(
						subtitle,
						textAlign: TextAlign.center,
					),
				),
				SizedBox(height: 15),
				if (trailing != null) trailing!,
			],
		));
	}
}
