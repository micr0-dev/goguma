import 'dart:async';

import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import 'ansi.dart';
import 'database.dart';
import 'irc.dart';
import 'logging.dart';
import 'models.dart';

var _nextId = 1;
var _launchSelectionPopped = false;
const _maxId = 0x7FFFFFFF; // 2^31 - 1

class _NotificationChannel {
	final String id;
	final String name;
	final String? description;

	const _NotificationChannel({ required this.id, required this.name, this.description });
}

const _directMessageChannel = _NotificationChannel(
	id: 'privmsg',
	name: 'Private messages',
	description: 'Private messages sent directly to you',
);

const _highlightChannel = _NotificationChannel(
	id: 'highlight',
	name: 'Mentions',
	description: 'Messages mentioning your nickname in a channel',
);

const _inviteChannel = _NotificationChannel(
	id: 'invite',
	name: 'Invitations',
	description: 'Invitations to join a channel',
);

var _channels = Map.fromEntries([
	_directMessageChannel,
	_highlightChannel,
	_inviteChannel,
].map((channel) => MapEntry(channel.id, channel)));

class _ActiveNotification {
	final int id;
	final String tag;
	final String title;
	final String? body;
	final String? channelId;
	final MessagingStyleInformation? messagingStyleInfo;

	const _ActiveNotification({
		required this.id,
		required this.tag,
		required this.title,
		this.body,
		this.channelId,
		this.messagingStyleInfo,
	});
}

class NotificationController {
	final FlutterLocalNotificationsPlugin _plugin = FlutterLocalNotificationsPlugin();
	final StreamController<String?> _selectionsController = StreamController(sync: true);
	final List<_ActiveNotification> _active = [];

	static NotificationController? _instance;

	Stream<String?> get selections => _selectionsController.stream;

	NotificationController._();

	Future<void> _init() async {
		await _plugin.initialize(
			settings: InitializationSettings(
				iOS: DarwinInitializationSettings(
					requestAlertPermission: true,
					requestBadgePermission: true,
					requestSoundPermission: true,
				),
				linux: LinuxInitializationSettings(defaultActionName: 'Open'),
				android: AndroidInitializationSettings('ic_stat_name'),
				windows: WindowsInitializationSettings(appName: 'Goguma', appUserModelId: 'fr.emersion.goguma', guid: '41b2ec15-f640-44be-a9c2-a4144969e94b'),
			),
			onDidReceiveNotificationResponse: _handleNotificationResponse,
		);

		var androidPlugin = _plugin.resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();
		if (androidPlugin != null) {
			try {
				var activeNotifs = await androidPlugin.getActiveNotifications();
				_populateActive(androidPlugin, activeNotifs);
			} on Exception catch (err) {
				log.print('Failed to list active notifications', error: err);
			}
		}
	}

	static Future<NotificationController> init() async {
		// Use a singleton because flutter_local_notifications gets confused
		// when initialized multiple times per Isolate
		if (_instance == null) {
			_instance = NotificationController._();
			await _instance!._init();
		}
		return _instance!;
	}

	Future<String?> popLaunchSelection() async {
		if (_launchSelectionPopped) {
			return null;
		}
		NotificationAppLaunchDetails? launchDetails;
		try {
			launchDetails = await _plugin.getNotificationAppLaunchDetails();
		} on UnimplementedError {
			// Ignore
		}
		_launchSelectionPopped = true;
		if (launchDetails == null || !launchDetails.didNotificationLaunchApp) {
			return null;
		}
		return launchDetails.notificationResponse?.payload;
	}

	void _populateActive(AndroidFlutterLocalNotificationsPlugin androidPlugin, List<ActiveNotification> activeNotifs) async {
		for (var notif in activeNotifs) {
			if (notif.id == null) {
				continue; // not created by the flutter_local_notifications plugin
			}

			if (_nextId <= notif.id!) {
				_nextId = notif.id! + 1;
				_nextId = _nextId % _maxId;
			}

			if (notif.tag == null || notif.title == null) {
				log.print('Found an active notification without a tag or title');
				continue;
			}

			MessagingStyleInformation? messagingStyleInfo;
			try {
				messagingStyleInfo = await androidPlugin.getActiveNotificationMessagingStyle(
					id: notif.id!,
					tag: notif.tag,
				);
			} on Exception catch (err) {
				log.print('Failed to get active notification messaging style', error: err);
			}

			_active.add(_ActiveNotification(
				id: notif.id!,
				tag: notif.tag!,
				title: notif.title!,
				body: notif.body,
				channelId: notif.channelId,
				messagingStyleInfo: messagingStyleInfo,
			));
		}
	}

	void _handleNotificationResponse(NotificationResponse resp) {
		_selectionsController.add(resp.payload);
	}

	String _bufferTag(BufferModel buffer) {
		return 'buffer:${buffer.id}';
	}

	Future<void> showDirectMessage(List<MessageEntry> entries, BufferModel buffer) async {
		var entry = entries.first;
		String tag = _bufferTag(buffer);
		_ActiveNotification? replace = _getActiveWithTag(tag);

		String title;
		if (replace == null) {
			title = 'New message from ${entry.msg.source!.name}';
		} else {
			title = _incrementTitleCount(replace.title, entries.length, ' messages from ${entry.msg.source!.name}');
		}

		List<Message> messages = replace?.messagingStyleInfo?.messages ?? [];
		messages.addAll(entries.map(_buildMessage));

		await _show(
			title: title,
			body: _getMessageBody(entry),
			channel: _directMessageChannel,
			dateTime: _getLatestMessageTimestamp(messages),
			messagingStyleInfo: _buildMessagingStyleInfo(messages, buffer, false),
			tag: _bufferTag(buffer),
		);
	}

	Future<void> showHighlight(List<MessageEntry> entries, BufferModel buffer) async {
		var entry = entries.first;
		String tag = _bufferTag(buffer);
		_ActiveNotification? replace = _getActiveWithTag(tag);

		String title;
		if (replace == null) {
			title = '${entry.msg.source!.name} mentioned you in ${buffer.name}';
		} else {
			title = _incrementTitleCount(replace.title, entries.length, ' mentions in ${buffer.name}');
		}

		List<Message> messages = replace?.messagingStyleInfo?.messages ?? [];
		messages.addAll(entries.map(_buildMessage));

		await _show(
			title: title,
			body: _getMessageBody(entry),
			channel: _highlightChannel,
			dateTime: _getLatestMessageTimestamp(messages),
			messagingStyleInfo: _buildMessagingStyleInfo(messages, buffer, true),
			tag: _bufferTag(buffer),
		);
	}

	Future<void> showInvite(IrcMessage msg, NetworkModel network) async {
		assert(msg.cmd == 'INVITE');
		var channel = msg.params[1];
		var time = msg.tags['time'];

		await _show(
			title: '${msg.source!.name} invited you to $channel',
			channel: _inviteChannel,
			dateTime: time != null ? DateTime.tryParse(time) : null,
			tag: 'invite:${network.networkEntry.id}:$channel',
		);
	}

	String _incrementTitleCount(String title, int incr, String suffix) {
		int total;
		if (!title.endsWith(suffix)) {
			total = 1;
		} else {
			total = int.parse(title.substring(0, title.length - suffix.length));
		}
		total += incr;
		return '$total$suffix';
	}

	MessagingStyleInformation _buildMessagingStyleInfo(List<Message> messages, BufferModel buffer, bool isChannel) {
		// TODO: Person.key, Person.bot, Person.uri
		return MessagingStyleInformation(
			Person(name: buffer.name),
			conversationTitle: buffer.name,
			groupConversation: isChannel,
			messages: messages,
		);
	}

	Message _buildMessage(MessageEntry entry) {
		return Message(
			_getMessageBody(entry),
			entry.dateTime,
			Person(name: entry.msg.source!.name),
		);
	}

	String _getMessageBody(MessageEntry entry) {
		var sender = entry.msg.source!.name;
		var ctcp = CtcpMessage.parse(entry.msg);
		if (ctcp == null) {
			return stripAnsiFormatting(entry.msg.params[1]);
		}
		if (ctcp.cmd == 'ACTION') {
			var action = stripAnsiFormatting(ctcp.param ?? '');
			return '$sender $action';
		} else {
			return '$sender has sent a CTCP "${ctcp.cmd}" command';
		}
	}

	DateTime? _getLatestMessageTimestamp(List<Message> messages) {
		DateTime? latest;
		for (var msg in messages) {
			if (latest == null || msg.timestamp.isAfter(latest)) {
				latest = msg.timestamp;
			}
		}
		return latest;
	}

	Future<void> cancelAllWithBuffer(BufferModel buffer, DateTime? before) async {
		var tag = _bufferTag(buffer);
		var prevActive = [..._active]; // copy to be able to remove while iterating
		List<Future<void>> futures = [];
		for (var notif in prevActive) {
			if (notif.tag != tag) {
				continue;
			}

			var prevMessagingStyleInfo = notif.messagingStyleInfo;
			var prevMessages = prevMessagingStyleInfo?.messages ?? [];

			var epsilon = Duration(milliseconds: 500); // the platform may round notification timestamps
			var messages = prevMessages.where((msg) {
				return before != null && msg.timestamp.subtract(epsilon).isAfter(before);
			}).toList();

			_NotificationChannel? channel;
			if (notif.channelId != null) {
				channel = _channels[notif.channelId];
			}

			// TODO: on non-Android, check notification timestamp
			if (messages.isEmpty || channel == null || prevMessagingStyleInfo == null) {
				futures.add(_plugin.cancel(id: notif.id, tag: notif.tag));
				_active.remove(notif);
				continue;
			}

			if (messages.length == prevMessages.length) {
				continue;
			}

			// TODO: update notification title
			futures.add(_show(
				title: notif.title,
				body: notif.body,
				channel: channel,
				dateTime: _getLatestMessageTimestamp(messages),
				messagingStyleInfo: MessagingStyleInformation(
					prevMessagingStyleInfo.person,
					conversationTitle: prevMessagingStyleInfo.conversationTitle,
					groupConversation: prevMessagingStyleInfo.groupConversation,
					messages: messages,
				),
				tag: notif.tag,
			));
		}
		await Future.wait(futures);
	}

	_ActiveNotification? _getActiveWithTag(String tag) {
		for (var notif in _active) {
			if (notif.tag == tag) {
				return notif;
			}
		}
		return null;
	}

	bool _isIdAvailable(int id) {
		for (var notif in _active) {
			if (notif.id == id) {
				return false;
			}
		}
		return true;
	}

	Future<void> _show({
		required String title,
		String? body,
		required _NotificationChannel channel,
		required String tag,
		DateTime? dateTime,
		MessagingStyleInformation? messagingStyleInfo,
	}) async {
		_ActiveNotification? replaced = _getActiveWithTag(tag);
		int id;
		var onlyAlertOnce = false;
		if (replaced != null) {
			_active.remove(replaced);
			id = replaced.id;

			var oldMessageCount = replaced.messagingStyleInfo?.messages?.length ?? 0;
			var newMessageCount = messagingStyleInfo?.messages?.length ?? 0;
			onlyAlertOnce = oldMessageCount > newMessageCount;
		} else {
			while (true) {
				id = _nextId++;
				_nextId = _nextId % _maxId;
				if (_isIdAvailable(id)) {
					break;
				}
			}
		}
		_active.add(_ActiveNotification(
			id: id,
			tag: tag,
			title: title,
			body: body,
			channelId: channel.id,
			messagingStyleInfo: messagingStyleInfo,
		));

		await _plugin.show(
			id: id,
			title: title,
			body: body,
			notificationDetails: NotificationDetails(
				linux: LinuxNotificationDetails(
					category: LinuxNotificationCategory.imReceived,
				),
				android: AndroidNotificationDetails(channel.id, channel.name,
					channelDescription: channel.description,
					importance: Importance.high,
					priority: Priority.high,
					category: AndroidNotificationCategory.message,
					when: dateTime?.millisecondsSinceEpoch,
					styleInformation: messagingStyleInfo,
					tag: tag,
					enableLights: true,
					onlyAlertOnce: onlyAlertOnce,
				),
			),
			payload: tag,
		);
	}
}
