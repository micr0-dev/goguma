import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:scrollable_positioned_list/scrollable_positioned_list.dart';
import 'package:share_handler/share_handler.dart';

import '../ansi.dart';
import '../client.dart';
import '../client_controller.dart';
import '../database.dart';
import '../irc.dart';
import '../linkify.dart';
import '../logging.dart';
import '../models.dart';
import '../notification_controller.dart';
import '../prefs.dart';
import '../widget/composer.dart';
import '../widget/date_indicator.dart';
import '../widget/link_preview.dart';
import '../widget/message_sheet.dart';
import '../widget/network_indicator.dart';
import '../widget/reactions_sheet.dart';
import '../widget/swipe_action.dart';
import 'buffer_details.dart';
import 'buffer_list.dart';

class BufferPageArguments {
	final BufferModel buffer;
	final SharedMedia? sharedMedia;

	const BufferPageArguments({
		required this.buffer,
		this.sharedMedia,
	});
}

class BufferPage extends StatefulWidget {
	static const routeName = '/buffer';

	final String? unreadMarkerTime;
	final SharedMedia? sharedMedia;

	const BufferPage({ super.key, this.unreadMarkerTime, this.sharedMedia });

	@override
	State<BufferPage> createState() => _BufferPageState();

	static void open(BuildContext context, String name, NetworkModel network) async {
		var db = context.read<DB>();
		var bufferList = context.read<BufferListModel>();
		var clientProvider = context.read<ClientProvider>();
		var client = clientProvider.get(network);
		var navigator = Navigator.of(context);

		var buffer = bufferList.get(name, network);
		if (buffer == null) {
			var entry = await db.storeBuffer(BufferEntry(name: name, network: network.networkId));
			buffer = BufferModel(entry: entry, network: network);
			bufferList.add(buffer);
		}

		// TODO: this is racy if the user has navigated away since the
		// BufferPage.open() call
		var until = ModalRoute.withName(BufferListPage.routeName);
		var args = BufferPageArguments(buffer: buffer);
		unawaited(navigator.pushNamedAndRemoveUntil(routeName, until, arguments: args));

		if (client.isChannel(name)) {
			_join(client, buffer);
		}
	}
}

void _join(Client client, BufferModel buffer) async {
	if (buffer.joined) {
		return;
	}

	buffer.joining = true;
	try {
		await client.join([buffer.name]);
	} on IrcException catch (err) {
		log.print('Failed to join "${buffer.name}"', error: err);
	} finally {
		buffer.joining = false;
	}
}

class _BufferPageState extends State<BufferPage> with WidgetsBindingObserver, TickerProviderStateMixin {
	final _itemScrollController = ItemScrollController();
	final _itemPositionsListener = ItemPositionsListener.create();
	final _userScrollListener = ScrollOffsetListener.create(recordProgrammaticScrolls: false);
	final _dateIndicatorValue = ValueNotifier<DateTime?>(null);
	final _showJumpToBottomValue = ValueNotifier<bool>(false);
	final _listKey = GlobalKey();
	final GlobalKey<ComposerState> _composerKey = GlobalKey();
	final GlobalKey<DateIndicatorState> _dateIndicatorKey = GlobalKey();
	late final AnimationController _blinkMsgController;
	late final StreamSubscription<double> _userScrollSubscription;

	bool _activated = true;
	bool _chatHistoryLoading = false;
	int _initialScrollIndex = 0;
	bool _isAtTop = false;
	bool _isAtBottom = false;

	bool _initialChatHistoryLoaded = false;
	int? _blinkMsgIndex;

	@override
	void initState() {
		super.initState();

		WidgetsBinding.instance.addObserver(this);

		_itemPositionsListener.itemPositions.addListener(_handleScroll);
		_userScrollSubscription = _userScrollListener.changes.listen(_handleUserScroll);

		_blinkMsgController = AnimationController(
			vsync: this,
			duration: const Duration(milliseconds: 200),
			value: 1,
		);

		var buffer = context.read<BufferModel>();
		if (buffer.messages.length >= 1000) {
			_setInitialChatHistoryLoaded();
			_updateBufferFocus();
			return;
		}

		_fetchMetadata();

		// Timer.run prevents calling setState() from inside initState()
		Timer.run(() async {
			try {
				await _fetchChatHistory();
			} on Exception catch (err) {
				log.print('Failed to fetch chat history', error: err);
			}
			if (mounted) {
				_updateBufferFocus();
			}
		});
	}

	void _handleScroll() {
		var positions = _itemPositionsListener.itemPositions.value;
		if (positions.isEmpty) {
			return;
		}

		var buffer = context.read<BufferModel>();
		var isAtTop = positions.any((pos) => pos.index == buffer.messages.length - 1);
		if (!_isAtTop && isAtTop) {
			_fetchChatHistory();
		}
		_isAtTop = isAtTop;

		var isAtBottom = positions.any((pos) => pos.index < 2);
		if (_isAtBottom != isAtBottom) {
			_isAtBottom = isAtBottom;
			_updateBufferFocus();
		}

		var firstDateTime = buffer.messages[buffer.messages.length - positions.last.index - 1].entry.dateTime;
		_dateIndicatorValue.value = firstDateTime;

		var showJumpToBottom = positions.any((pos) => pos.index >= 20) && !isAtBottom;
		_showJumpToBottomValue.value = showJumpToBottom;

		// Workaround for the last messages becoming hidden when the virtual
		// keyboard is opened: reset the alignment to 0.
		if (_initialScrollIndex != 0 && positions.any((pos) => pos.index == 0 && pos.itemLeadingEdge == 0)) {
			_itemScrollController.jumpTo(index: 0, alignment: 0);
			_initialScrollIndex = 0;
		}
	}

	void _handleUserScroll(double value) {
		_dateIndicatorKey.currentState?.show();
	}

	void _fetchMetadata() async {
		var clientProvider = context.read<ClientProvider>();
		var buffer = context.read<BufferModel>();
		var client = context.read<Client>();
		var userList = context.read<NetworkModel>().users;

		if (client.isChannel(buffer.name)) {
			if (buffer.members != null) {
				return;
			}

			List<WhoReply> replies;
			try {
				replies = await client.who(buffer.name);
			} on Exception catch (err) {
				log.print('Failed to fetch channel WHO', error: err);
				await client.names(buffer.name);
				return;
			}

			var members = MemberListModel(client.isupport.caseMapping);
			for (var reply in replies) {
				members.set(reply.nickname, reply.membershipPrefix!);
				userList.updateUser(UserModel(
					nickname: reply.nickname,
					realname: reply.realname,
				));
			}

			buffer.members = members;
		} else {
			clientProvider.fetchBufferUser(buffer);
			client.monitor([buffer.name]);
		}
	}

	Future<void> _fetchChatHistory() async {
		if (_chatHistoryLoading) {
			return;
		}

		var db = context.read<DB>();
		var clientProvider = context.read<ClientProvider>();
		var buffer = context.read<BufferModel>();
		var client = context.read<Client>();

		// First try to load history from the DB, then try from the server

		int? firstMsgId;
		if (!buffer.messages.isEmpty) {
			firstMsgId = buffer.messages.first.id;
		}

		var limit = 1000;
		var entries = await db.listMessagesBefore(buffer.id, firstMsgId, limit);
		var models = await buildMessageModelList(db, entries);
		buffer.populateMessageHistory(models.toList());

		if (entries.length >= limit || !client.caps.enabled.contains('draft/chathistory')) {
			if (mounted) {
				setState(_setInitialChatHistoryLoaded);
			}
			return;
		}

		setState(() {
			_chatHistoryLoading = true;
		});

		try {
			await clientProvider.fetchChatHistory(buffer);
		} finally {
			if (mounted) {
				setState(() {
					_chatHistoryLoading = false;
					_setInitialChatHistoryLoaded();
				});
			}
		}
	}

	void _setInitialChatHistoryLoaded() {
		if (_initialChatHistoryLoaded) {
			return;
		}
		_initialChatHistoryLoaded = true;

		if (widget.unreadMarkerTime == null) {
			return;
		}

		var buffer = context.read<BufferModel>();
		for (var i = buffer.messages.length - 1; i >= 0; i--) {
			var msg = buffer.messages[i];
			if (widget.unreadMarkerTime!.compareTo(msg.entry.time) >= 0) {
				_initialScrollIndex = buffer.messages.length - i - 1;
				break;
			}
		}
	}

	@override
	void dispose() {
		_itemPositionsListener.itemPositions.removeListener(_handleScroll);
		_userScrollSubscription.cancel();
		_blinkMsgController.dispose();
		WidgetsBinding.instance.removeObserver(this);
		super.dispose();
	}

	@override
	void deactivate() {
		_activated = false;
		_updateBufferFocus();
		super.deactivate();
	}

	@override
	void activate() {
		super.activate();
		_activated = true;
		_updateBufferFocus();
	}

	@override
	void didChangeAppLifecycleState(AppLifecycleState state) {
		super.didChangeAppLifecycleState(state);
		_updateBufferFocus();
	}

	void _updateBufferFocus() {
		var buffer = context.read<BufferModel>();
		var state = WidgetsBinding.instance.lifecycleState ?? AppLifecycleState.resumed;
		buffer.focused = state == AppLifecycleState.resumed && _activated && _isAtBottom;
		if (buffer.focused) {
			_markRead();
		}
	}

	void _markRead() {
		var db = context.read<DB>();
		var client = context.read<Client>();
		var buffer = context.read<BufferModel>();
		var notifController = context.read<NotificationController>();

		if (buffer.unreadCount > 0 && buffer.messages.length > 0) {
			buffer.entry.lastReadTime = buffer.messages.last.entry.time;
			db.storeBuffer(buffer.entry);

			if (buffer.entry.lastReadTime != null && client.state != ClientState.disconnected) {
				client.setReadMarker(buffer.name, buffer.entry.lastReadTime!);
			}
		}
		buffer.unreadCount = 0;

		notifController.cancelAllWithBuffer(buffer, null);
	}

	void _handleMsgRefTap(int id) {
		var buffer = context.read<BufferModel>();

		int? index;
		for (var i = 0; i < buffer.messages.length; i++) {
			if (buffer.messages[i].id == id) {
				index = buffer.messages.length - i - 1;
				break;
			}
		}
		if (index == null) {
			return;
		}

		setState(() {
			_blinkMsgIndex = index;
		});

		_itemScrollController.jumpTo(
			index: index,
			alignment: 0.5,
		);
		_blinkMsgController.repeat(reverse: true);
		Timer(_blinkMsgController.duration! * 4, () {
			if (!mounted) {
				return;
			}
			_blinkMsgController.animateTo(1);
			setState(() {
				_blinkMsgIndex = null;
			});
		});
	}

	@override
	Widget build(BuildContext context) {
		var client = context.read<Client>();
		var prefs = context.read<Prefs>();
		var buffer = context.watch<BufferModel>();
		var network = context.watch<NetworkModel>();

		var subtitle = buffer.topic ?? buffer.realname;
		var isOnline = network.state == NetworkState.synchronizing || network.state == NetworkState.online;
		var canSendMessage = canSendMessageToBuffer(buffer, network);
		var isChannel = client.isChannel(buffer.name);
		var messages = buffer.messages;

		var compact = prefs.bufferCompact;
		var showTyping = prefs.typingIndicator;
		if (!client.caps.enabled.contains('message-tags')) {
			showTyping = false;
		}

		if (canSendMessage && showTyping) {
			var typingNicks = buffer.typing;
			if (typingNicks.isNotEmpty) {
				subtitle = typingNicks.join(', ') + ' ${typingNicks.length > 1 ? 'are' : 'is'} typing...';
			}
		}

		MaterialBanner? banner;
		if (network.state == NetworkState.online && isChannel && !buffer.joined && !buffer.joining) {
			banner = MaterialBanner(
				content: Text('You have left this channel.'),
				actions: [
					TextButton(
						child: Text('JOIN'),
						onPressed: () {
							var bufferList = context.read<BufferListModel>();
							var db = context.read<DB>();

							bufferList.setArchived(buffer, false);
							db.storeBuffer(buffer.entry);

							_join(client, buffer);
							_fetchMetadata();
						},
					),
				],
			);
		}
		if (banner == null && buffer.archived) {
			banner = MaterialBanner(
				content: Text('This conversation is archived.'),
				actions: [
					TextButton(
						child: Text('UNARCHIVE'),
						onPressed: () {
							var bufferList = context.read<BufferListModel>();
							var db = context.read<DB>();

							bufferList.setArchived(buffer, false);
							db.storeBuffer(buffer.entry);

							_fetchMetadata();
						},
					),
				],
			);
		}

		Widget msgList;
		if (_initialChatHistoryLoaded && messages.isEmpty) {
			msgList = Center(child: Column(
				mainAxisAlignment: MainAxisAlignment.center,
				children: [
					Icon(Icons.forum, size: 100),
					Text(
						buffer.name,
						style: Theme.of(context).textTheme.headlineSmall,
						textAlign: TextAlign.center,
					),
					SizedBox(height: 15),
					Container(
						constraints: BoxConstraints(maxWidth: 300),
						child: Text(
							'No messages yet in this conversation.',
							textAlign: TextAlign.center,
						),
					),
				],
			));
		} else if (_initialChatHistoryLoaded) {
			msgList = ScrollablePositionedList.builder(
				key: _listKey,
				reverse: true,
				itemScrollController: _itemScrollController,
				itemPositionsListener: _itemPositionsListener,
				scrollOffsetListener: _userScrollListener,
				itemCount: messages.length,
				initialScrollIndex: _initialScrollIndex,
				initialAlignment: _initialScrollIndex > 0 ? 1 : 0,
				itemBuilder: (context, index) {
					var msgIndex = messages.length - index - 1;
					var msg = messages[msgIndex];
					var prevMsg = msgIndex > 0 ? messages[msgIndex - 1] : null;
					var key = ValueKey(msg.id);

					VoidCallback? onReply;
					if (isChannel && canSendMessage) {
						onReply = () {
							_composerKey.currentState!.replyTo(msg);
						};
					}

					if (compact) {
						return _CompactMessageItem(
							key: key,
							msg: msg,
							prevMsg: prevMsg,
							unreadMarkerTime: widget.unreadMarkerTime,
							onReply: onReply,
							last: msgIndex == messages.length - 1,
						);
					}

					var nextMsg = msgIndex + 1 < messages.length ? messages[msgIndex + 1] : null;

					Widget msgWidget = _MessageItem(
						key: key,
						msg: msg,
						prevMsg: prevMsg,
						nextMsg: nextMsg,
						unreadMarkerTime: widget.unreadMarkerTime,
						onReply: onReply,
						onMsgRefTap: _handleMsgRefTap,
					);
					if (index == _blinkMsgIndex) {
						msgWidget = FadeTransition(opacity: _blinkMsgController, child: msgWidget);
					}
					return msgWidget;
				},
			);
		} else {
			msgList = Container();
		}

		Widget jumpToBottom = ValueListenableBuilder(
			valueListenable: _showJumpToBottomValue,
			builder: (context, showJumpToBottom, _) {
				if (!showJumpToBottom) return Container();
				return Positioned(
					right: 15,
					bottom: 15,
					child: FloatingActionButton(
						mini: true,
						tooltip: 'Jump to bottom',
						heroTag: null,
						backgroundColor: Colors.grey,
						foregroundColor: Colors.white,
						onPressed: () {
							_itemScrollController.jumpTo(index: 0);
						},
						child: const Icon(Icons.keyboard_double_arrow_down, size: 18),
					),
				);
			},
		);

		Widget dateIndicator = Container(
			padding: EdgeInsets.only(top: 10),
			alignment: Alignment.topCenter,
			child: DateIndicator(key: _dateIndicatorKey, date: _dateIndicatorValue),
		);

		return Scaffold(
			appBar: AppBar(
				title: InkResponse(
					child: Column(
						mainAxisAlignment: MainAxisAlignment.center,
						crossAxisAlignment: CrossAxisAlignment.start,
						children: [
							Text(buffer.name, overflow: TextOverflow.fade),
							if (subtitle != null) Text(
								stripAnsiFormatting(subtitle),
								style: TextStyle(fontSize: 12.0),
								overflow: TextOverflow.fade,
							),
						],
					),
					onTap: () {
						Navigator.pushNamed(context, BufferDetailsPage.routeName, arguments: buffer);
					},
				),
				actions: [
					PopupMenuButton<String>(
						onSelected: (key) {
							var bufferList = context.read<BufferListModel>();
							var db = context.read<DB>();
							switch (key) {
							case 'details':
								Navigator.pushNamed(context, BufferDetailsPage.routeName, arguments: buffer);
								break;
							case 'pin':
								var client = context.read<Client>();
								if (client.metadataSubs.contains('soju.im/pinned')) {
									client.setMetadata(buffer.name, 'soju.im/pinned', buffer.pinned ? '0' : '1');
								} else {
									bufferList.setPinned(buffer, !buffer.pinned);
									db.storeBuffer(buffer.entry);
								}
								break;
							case 'mute':
								var client = context.read<Client>();
								if (client.metadataSubs.contains('soju.im/muted')) {
									client.setMetadata(buffer.name, 'soju.im/muted', buffer.muted ? '0' : '1');
								} else {
									bufferList.setMuted(buffer, !buffer.muted);
									db.storeBuffer(buffer.entry);
								}
								break;
							case 'part':
								var client = context.read<Client>();
								if (client.isChannel(buffer.name)) {
									client.send(IrcMessage('PART', [buffer.name]));
								} else {
									client.unmonitor([buffer.name]);
								}
								bufferList.setArchived(buffer, true);
								db.storeBuffer(buffer.entry);
								Navigator.pop(context);
								break;
							case 'delete':
								bufferList.remove(buffer);
								db.deleteBuffer(buffer.entry.id!);
								Navigator.pop(context);
								break;
							}
						},
						itemBuilder: (context) {
							return [
								PopupMenuItem(value: 'details', child: Text('Details')),
								if (isOnline) PopupMenuItem(value: 'pin', child: Text(buffer.pinned ? 'Unpin' : 'Pin')),
								if (isOnline) PopupMenuItem(value: 'mute', child: Text(buffer.muted ? 'Unmute' : 'Mute')),
								if (!buffer.archived && (isOnline || !isChannel)) PopupMenuItem(value: 'part', child: Text(buffer.joined ? 'Leave' : 'Archive')),
								if (buffer.archived) PopupMenuItem(value: 'delete', child: Text('Delete')),
							];
						},
					),
				],
			),
			body: NetworkIndicator(network: network, child: Column(children: [
				if (banner != null) banner,
				Expanded(child: Stack(children: [
					msgList,
					jumpToBottom,
					dateIndicator,
				])),
			])),
			bottomNavigationBar: Visibility(
				visible: canSendMessage,
				maintainState: true,
				child: Padding(
					// Hack to keep the bottomNavigationBar displayed when the
					// virtual keyboard shows up
					padding: EdgeInsets.only(
						bottom: MediaQuery.of(context).viewInsets.bottom,
					),
					child: Material(elevation: 15, child: Container(
						padding: EdgeInsets.all(10),
						child: Composer(key: _composerKey, sharedMedia: widget.sharedMedia),
					)),
				),
			),
		);
	}
}

class _CompactMessageItem extends StatelessWidget {
	final MessageModel msg;
	final MessageModel? prevMsg;
	final String? unreadMarkerTime;
	final VoidCallback? onReply;
	final bool last;

	const _CompactMessageItem({
		super.key,
		required this.msg,
		this.prevMsg,
		this.unreadMarkerTime,
		this.onReply,
		this.last = false,
	});

	@override
	Widget build(BuildContext context) {
		var prefs = context.read<Prefs>();
		var ircMsg = msg.msg;
		var entry = msg.entry;
		var sender = ircMsg.source!.name;
		var localDateTime = entry.dateTime.toLocal();
		var ctcp = CtcpMessage.parse(ircMsg);
		assert(ircMsg.cmd == 'PRIVMSG' || ircMsg.cmd == 'NOTICE');

		var prevIrcMsg = prevMsg?.msg;
		var prevEntry = prevMsg?.entry;
		var prevMsgSameSender = prevIrcMsg != null && ircMsg.source!.name == prevIrcMsg.source!.name;
		var showUnreadMarker = prevEntry != null && unreadMarkerTime != null && unreadMarkerTime!.compareTo(entry.time) < 0 && unreadMarkerTime!.compareTo(prevEntry.time) >= 0;
		var showDateMarker = prevEntry == null || !_isSameDate(localDateTime, prevEntry.dateTime.toLocal());

		var unreadMarkerColor = Theme.of(context).colorScheme.secondary;
		var textStyle = TextStyle(color: Theme.of(context).textTheme.bodyLarge!.color);

		String? text;
		List<TextSpan> textSpans;
		if (ctcp != null) {
			textStyle = textStyle.apply(fontStyle: FontStyle.italic);

			if (ctcp.cmd == 'ACTION') {
				text = ctcp.param;
				textSpans = applyAnsiFormatting(text ?? '', textStyle);
			} else {
				textSpans = [TextSpan(text: 'has sent a CTCP "${ctcp.cmd}" command', style: textStyle)];
			}
		} else if (entry.redacted) {
			textSpans = [TextSpan(
				text: 'This message has been deleted.',
				style: TextStyle(fontStyle: FontStyle.italic),
			)];
		} else {
			text = ircMsg.params[1];
			textSpans = applyAnsiFormatting(text, textStyle);
		}

		textSpans = textSpans.map((span) {
			var linkSpan = linkify(context, span.text!, linkStyle: TextStyle(decoration: TextDecoration.underline));
			return TextSpan(style: span.style, children: [linkSpan]);
		}).toList();

		List<Widget> stack = [];
		List<InlineSpan> content = [];

		if (!prevMsgSameSender) {
			var colorSwatch = Colors.primaries[sender.hashCode % Colors.primaries.length];
			var colorScheme = ColorScheme.fromSwatch(primarySwatch: colorSwatch);
			var senderStyle = TextStyle(color: colorScheme.primary, fontWeight: FontWeight.bold);
			stack.add(Positioned(
				top: 0,
				left: 0,
				child: Text(sender, style: senderStyle),
			));
			content.add(WidgetSpan(
				alignment: PlaceholderAlignment.top,
				child: SelectionContainer.disabled(
					child: Text(
						sender,
						style: senderStyle.apply(color: Color(0x00000000)),
						semanticsLabel: '',  // Make screen reader quiet
						textScaler: TextScaler.noScaling,
					),
				),
			));
		}

		content.addAll(textSpans);

		if (!prevMsgSameSender || prevEntry == null || entry.dateTime.difference(prevEntry.dateTime) > Duration(minutes: 2)) {
			var hh = localDateTime.hour.toString().padLeft(2, '0');
			var mm = localDateTime.minute.toString().padLeft(2, '0');
			var timeText = '\u00A0[$hh:$mm]';
			var timeStyle = TextStyle(color: Theme.of(context).textTheme.bodySmall!.color);
			stack.add(Positioned(
				bottom: 0,
				right: 0,
				child: Text(timeText, style: timeStyle),
			));
			content.add(WidgetSpan(
				alignment: PlaceholderAlignment.top,
				child: SelectionContainer.disabled(
					child: Text(
						timeText,
						style: timeStyle.apply(color: Color(0x00000000)),
						semanticsLabel: '',  // Make screen reader quiet
						textScaler: TextScaler.noScaling,
					),
				),
			));
		}

		var fg = Theme.of(context).colorScheme.secondaryContainer;
		var reactions = msg.reactionMap.entries.map((reactionEntry) {
			return GestureDetector(
				onTap: () {
					ReactionsSheet.open(context, msg.reactions);
				},
				child: _Reaction(
					text: reactionEntry.key,
					nicknames: reactionEntry.value,
					borderColor: fg,
					backgroundColor: fg.withAlpha(30),
				),
			);
		}).toList();

		stack.add(Container(
			margin: EdgeInsets.only(left: 4),
			child: Stack(children: [
				Container(
					margin: reactions.isEmpty ? null : EdgeInsets.only(bottom: 30),
					child: GestureDetector(
						onLongPress: () {
							var buffer = context.read<BufferModel>();
							MessageSheet.open(context, buffer, msg, onReply);
						},
						child: Text.rich(
							TextSpan(
								children: content,
							),
						),
					),
				),
				if (!reactions.isEmpty) Positioned(bottom: 4, child: Row(spacing: 2, children: reactions)),
			]),
		));

		Widget? linkPreview;
		if (prefs.linkPreview && text != null) {
			var body = stripAnsiFormatting(text);
			linkPreview = LinkPreview(
				text: body,
				builder: (context, child) {
					return Align(alignment: Alignment.center, child: Container(
						margin: EdgeInsets.symmetric(vertical: 5),
						child: ClipRRect(
							borderRadius: BorderRadius.circular(10),
							child: child,
						),
					));
				},
			);
		}

		return Column(children: [
			if (showUnreadMarker) Row(children: [
				Expanded(child: Divider(color: unreadMarkerColor)),
				SizedBox(width: 10),
				Text('Unread messages', style: TextStyle(color: unreadMarkerColor)),
				SizedBox(width: 10),
				Expanded(child: Divider(color: unreadMarkerColor)),
			]),
			if (showDateMarker)
				Container(
					margin: EdgeInsets.only(top: 2.5),
					alignment: Alignment.center,
					child: Text(_formatDate(localDateTime), style: textStyle),
				),
			Container(
				margin: EdgeInsets.only(top: prevMsgSameSender ? 0 : 2.5, bottom: last ? 10 : 0, left: 4, right: 5),
				child: DefaultTextStyle.merge(
					style: TextStyle(height: 1.15),
					child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
						Stack(children: stack),
						if (linkPreview != null) linkPreview,
					]),
				),
			),
		]);
	}
}

class _MessageItem extends StatelessWidget {
	final MessageModel msg;
	final MessageModel? prevMsg, nextMsg;
	final String? unreadMarkerTime;
	final VoidCallback? onReply;
	final void Function(int)? onMsgRefTap;

	const _MessageItem({
		super.key,
		required this.msg,
		this.prevMsg,
		this.nextMsg,
		this.unreadMarkerTime,
		this.onReply,
		this.onMsgRefTap,
	});

	@override
	Widget build(BuildContext context) {
		var client = context.read<Client>();
		var prefs = context.read<Prefs>();

		var ircMsg = msg.msg;
		var entry = msg.entry;
		var sender = ircMsg.source!.name;
		var localDateTime = entry.dateTime.toLocal();
		var ctcp = CtcpMessage.parse(ircMsg);
		var hasChannelContext = ircMsg.tags['+draft/channel-context'] != null;
		assert(ircMsg.cmd == 'PRIVMSG' || ircMsg.cmd == 'NOTICE');

		var target = ircMsg.params[0];
		var i = parseTargetPrefix(target, client.isupport.statusMsg);
		var statusMsgPrefix = target.substring(0, i);

		var prevIrcMsg = prevMsg?.msg;
		var prevCtcp = prevIrcMsg != null ? CtcpMessage.parse(prevIrcMsg) : null;
		var prevEntry = prevMsg?.entry;
		var prevMsgSameSender = prevIrcMsg != null && ircMsg.source!.name == prevIrcMsg.source!.name;
		var prevMsgIsAction = prevCtcp != null && prevCtcp.cmd == 'ACTION';

		var nextMsgSameSender = nextMsg != null && ircMsg.source!.name == nextMsg!.msg.source!.name;

		var isAction = ctcp != null && ctcp.cmd == 'ACTION';
		var showUnreadMarker = prevEntry != null && unreadMarkerTime != null && unreadMarkerTime!.compareTo(entry.time) < 0 && unreadMarkerTime!.compareTo(prevEntry.time) >= 0;
		var showDateMarker = prevEntry == null || !_isSameDate(localDateTime, prevEntry.dateTime.toLocal());
		var isFirstInGroup = showUnreadMarker || !prevMsgSameSender || prevMsgIsAction != isAction || hasChannelContext || statusMsgPrefix != '';
		var showTime = !nextMsgSameSender || nextMsg!.entry.dateTime.difference(entry.dateTime) > Duration(minutes: 2);

		var unreadMarkerColor = Theme.of(context).colorScheme.secondary;
		var eventColor = DefaultTextStyle.of(context).style.color!.withValues(alpha: 0.5);

		var boxColor = Colors.primaries[sender.hashCode % Colors.primaries.length].shade500;
		var boxAlignment = Alignment.centerLeft;
		var textColor = DefaultTextStyle.of(context).style.color!;

		if (client.isMyNick(sender)) {
			// Actions are displayed as if they were told by an external
			// narrator. To preserve this effect, always show actions on the
			// left side.
			boxColor = Colors.grey.shade200;
			if (!isAction) {
				boxAlignment = Alignment.centerRight;
			}
		}

		if (!isAction) {
			textColor = boxColor.computeLuminance() > 0.5 ? Colors.black : Colors.white;
		}

		const margin = 16.0;
		var marginBottom = margin;
		if (nextMsg != null) {
			marginBottom = 0.0;
		}
		var marginTop = margin;
		if (!isFirstInGroup) {
			marginTop = margin / 4;
		}

		var senderTextSpan = TextSpan(
			text: sender,
			style: TextStyle(fontWeight: FontWeight.bold),
		);
		if (hasChannelContext) {
			senderTextSpan = TextSpan(children: [
				senderTextSpan,
				TextSpan(text: ' (only visible to you)', style: TextStyle(color: textColor.withValues(alpha: 0.5))),
			]);
		} else if (statusMsgPrefix != '') {
			senderTextSpan = TextSpan(children: [
				senderTextSpan,
				TextSpan(text: ' (only visible to $statusMsgPrefix)', style: TextStyle(color: textColor.withValues(alpha: 0.5))),
			]);
		}

		var linkStyle = TextStyle(
			decoration: TextDecoration.underline,
			decorationColor: textColor,
		);

		List<InlineSpan> content;
		Widget? linkPreview;
		if (isAction) {
			var actionText = stripAnsiFormatting(ctcp.param ?? '');

			content = [
				WidgetSpan(
					child: Container(
						width: 8.0,
						height: 8.0,
						margin: EdgeInsets.all(3.0),
						decoration: BoxDecoration(
							shape: BoxShape.circle,
							color: boxColor,
						),
					),
				),
				senderTextSpan,
				TextSpan(text: ' '),
				linkify(context, actionText, linkStyle: linkStyle),
			];
		} else {
			var body = ircMsg.params[1];
			WidgetSpan? replyChip;
			if (msg.replyTo != null && msg.replyTo!.msg.source != null) {
				var replyNickname = msg.replyTo!.msg.source!.name;

				var replyPrefix = '$replyNickname: ';
				if (body.startsWith(replyPrefix)) {
					body = body.replaceFirst(replyPrefix, '');
				}

				replyChip = WidgetSpan(
					alignment: PlaceholderAlignment.middle,
					child: ActionChip(
						avatar: Icon(Icons.reply, size: 16, color: textColor),
						label: Text(replyNickname),
						labelPadding: EdgeInsets.only(right: 4),
						backgroundColor: Color.alphaBlend(textColor.withValues(alpha: 0.15), boxColor),
						labelStyle: TextStyle(color: textColor),
						visualDensity: VisualDensity(vertical: -4),
						onPressed: () {
							if (onMsgRefTap != null) {
								onMsgRefTap!(msg.replyTo!.id!);
							}
						},
					),
				);
			}

			TextSpan bodyTextSpan;
			if (entry.redacted) {
				bodyTextSpan = TextSpan(
					text: 'This message has been deleted.',
					style: TextStyle(fontStyle: FontStyle.italic),
				);
			} else {
				body = stripAnsiFormatting(body);
				bodyTextSpan = linkify(context, body, linkStyle: linkStyle);
			}

			content = [
				if (isFirstInGroup) senderTextSpan,
				if (isFirstInGroup) TextSpan(text: '\n'),
				if (replyChip != null) replyChip,
				if (replyChip != null) WidgetSpan(child: SizedBox(width: 5, height: 5)),
				bodyTextSpan,
			];

			if (prefs.linkPreview) {
				linkPreview = LinkPreview(
					text: body,
					builder: (context, child) {
						return Align(alignment: boxAlignment, child: Container(
							margin: EdgeInsets.only(top: 5),
							child: ClipRRect(
								borderRadius: BorderRadius.circular(10),
								child: child,
							),
						));
					},
				);
			}
		}

		Widget inner = Text.rich(TextSpan(children: content));

		if (showTime) {
			var hh = localDateTime.hour.toString().padLeft(2, '0');
			var mm = localDateTime.minute.toString().padLeft(2, '0');
			var time = '   $hh:$mm';
			var timeScreenReader = 'Sent at $hh $mm';
			var timeStyle = DefaultTextStyle.of(context).style.apply(
				color: textColor.withValues(alpha: 0.5),
				fontSizeFactor: 0.8,
			);

			// Add a fully transparent text span with the time, so that the real
			// time text doesn't collide with the message text.
			content.add(WidgetSpan(
				child: Text(
					time,
					style: timeStyle.apply(color: Color(0x00000000)),
					semanticsLabel: '',  // Make screen reader quiet
				),
			));

			inner = Stack(children: [
				inner,
				Positioned(
					bottom: 0,
					right: 0,
					child: Text(
						time,
						style: timeStyle,
						semanticsLabel: timeScreenReader,
					),
				),
			]);
		}

		inner = DefaultTextStyle.merge(style: TextStyle(color: textColor), child: inner);

		var reactions = msg.reactionMap.entries.map((reactionEntry) {
			return GestureDetector(
				onTap: () {
					ReactionsSheet.open(context, msg.reactions);
				},
				child: _Reaction(
					text: reactionEntry.key,
					nicknames: reactionEntry.value,
				),
			);
		}).toList();

		Widget decoratedMessage;
		if (isAction) {
			decoratedMessage = Align(
				alignment: boxAlignment,
				child: Container(
					child: inner,
				),
			);
		} else {
			decoratedMessage = Align(
				alignment: boxAlignment,
				child: Stack(children: [
					Container(
						decoration: BoxDecoration(
							borderRadius: BorderRadius.circular(10),
							color: boxColor,
						),
						margin: reactions.isEmpty ? null : EdgeInsets.only(bottom: 25),
						padding: EdgeInsets.all(10),
						child: inner,
					),
					if (!reactions.isEmpty) Positioned(bottom: 4, right: 10, child: Row(spacing: 2, children: reactions)),
				]),
			);
		}

		if (!client.isMyNick(sender)) {
			decoratedMessage = SwipeAction(
				background: Align(
					alignment: Alignment.centerLeft,
					child: Opacity(
						opacity: 0.6,
						child: Icon(Icons.reply),
					),
				),
				onSwipe: onReply,
				child: decoratedMessage,
			);
		}

		// TODO: support actions as well
		if (!isAction) {
			decoratedMessage = GestureDetector(
				onLongPress: () {
					var buffer = context.read<BufferModel>();
					MessageSheet.open(context, buffer, msg, onReply);
				},
				child: decoratedMessage,
			);
		}

		return Column(children: [
			if (showUnreadMarker) Container(
				margin: EdgeInsets.only(top: margin),
				child: Row(children: [
					Expanded(child: Divider(color: unreadMarkerColor)),
					SizedBox(width: 10),
					Text('Unread messages', style: TextStyle(color: unreadMarkerColor)),
					SizedBox(width: 10),
					Expanded(child: Divider(color: unreadMarkerColor)),
				]),
			),
			if (showDateMarker) Container(
				margin: EdgeInsets.symmetric(vertical: 20),
				child: Center(child: Text(_formatDate(localDateTime), style: TextStyle(color: eventColor))),
			),
			Container(
				margin: EdgeInsets.only(left: margin, right: margin, top: marginTop, bottom: marginBottom),
				child: Column(children: [
					decoratedMessage,
					if (linkPreview != null) linkPreview,
				]),
			),
		]);
	}
}

class _Reaction extends StatelessWidget {
	final String text;
	final Set<String> nicknames;
	final Color? borderColor;
	final Color? backgroundColor;

	const _Reaction({
		required this.text,
		required this.nicknames,
		this.borderColor,
		this.backgroundColor,
	});

	@override
	Widget build(BuildContext context) {
		var content = text;
		if (nicknames.length > 1) {
			content = '$text ${nicknames.length}';
		}

		var fg = Theme.of(context).colorScheme.secondaryContainer;
		var bg = Theme.of(context).colorScheme.surface;
		return Container(
			padding: EdgeInsets.symmetric(vertical: 2, horizontal: 7),
			alignment: Alignment.center,
			decoration: BoxDecoration(
				border: Border.all(
					width: 1,
					color: borderColor ?? bg,
				),
				borderRadius: BorderRadius.circular(100),
				color: backgroundColor ?? fg,
			),
			child: Text(content),
		);
	}
}

bool _isSameDate(DateTime a, DateTime b) {
	return a.year == b.year && a.month == b.month && a.day == b.day;
}

String _formatDate(DateTime dt) {
	var yyyy = dt.year.toString().padLeft(4, '0');
	var mm = dt.month.toString().padLeft(2, '0');
	var dd = dt.day.toString().padLeft(2, '0');
	return '$yyyy-$mm-$dd';
}
