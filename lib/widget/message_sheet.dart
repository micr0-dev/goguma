import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../ansi.dart';
import '../client.dart';
import '../client_controller.dart';
import '../database.dart';
import '../irc/irc.dart';
import '../models.dart';
import '../page/buffer.dart';
import '../page/buffer_details.dart';
import './emoji_sheet.dart';

const _defaultReactions = ['❤️', '👍', '👎', '😂', '😮', '😢'];

class MessageSheet extends StatelessWidget {
	final MessageModel message;
	final VoidCallback? onReply;
	final VoidCallback? onQuote;

	const MessageSheet({ super.key, required this.message, this.onReply, this.onQuote });

	static void open(BuildContext context, BufferModel buffer, MessageModel message, VoidCallback? onReply, {VoidCallback? onQuote}) {
		showModalBottomSheet<void>(
			context: context,
			showDragHandle: true,
			builder: (context) {
				var client = context.read<ClientProvider>().get(buffer.network);
				return MultiProvider(
					providers: [
						ChangeNotifierProvider<BufferModel>.value(value: buffer),
						ChangeNotifierProvider<NetworkModel>.value(value: buffer.network),
						Provider<Client>.value(value: client),
					],
					child: MessageSheet(message: message, onReply: onReply, onQuote: onQuote),
				);
			},
		);
	}

	Future<void> _handleWhois(BuildContext context, String nick) async {
		var client = context.read<Client>();
		Whois whois;
		try {
			whois = await client.whois(nick);
		} on Exception catch (err) {
			if (context.mounted) {
				ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Whois failed: $err')));
			}
			return;
		}
		if (!context.mounted) {
			return;
		}
		await showDialog<void>(
			context: context,
			builder: (context) => AlertDialog(
				title: Text(whois.nickname),
				content: SingleChildScrollView(child: Column(
					crossAxisAlignment: CrossAxisAlignment.start,
					children: [
						if (whois.source != null) _whoisRow('User', '${whois.source!.user}@${whois.source!.host}'),
						if (whois.realname != null) _whoisRow('Real name', whois.realname!),
						if (whois.account != null) _whoisRow('Account', whois.account!),
						if (whois.server != null) _whoisRow('Server', whois.server!),
						if (whois.away != null) _whoisRow('Away', whois.away!),
						if (whois.op) _whoisRow('Op', 'yes'),
						if (whois.secureConnection) _whoisRow('Connection', 'secure (TLS)'),
						if (whois.bot) _whoisRow('Type', 'bot'),
						if (!whois.channels.isEmpty) _whoisRow('Channels', whois.channels.keys.join(' ')),
					],
				)),
				actions: [TextButton(child: const Text('OK'), onPressed: () => Navigator.pop(context))],
			),
		);
	}

	Widget _whoisRow(String label, String value) {
		return Padding(
			padding: const EdgeInsets.symmetric(vertical: 2),
			child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
				SizedBox(width: 90, child: Text(label, style: const TextStyle(fontWeight: FontWeight.bold))),
				Expanded(child: Text(value)),
			]),
		);
	}

	void _handleViewProfile(BuildContext context, String sender) async {
		var db = context.read<DB>();
		var bufferList = context.read<BufferListModel>();
		var network = context.read<NetworkModel>();
		var navigator = Navigator.of(context);

		var buffer = bufferList.get(sender, network);
		if (buffer == null) {
			var entry = await db.storeBuffer(BufferEntry(name: sender, network: network.networkId));
			buffer = BufferModel(entry: entry, network: network);
			bufferList.add(buffer);
		}

		await navigator.pushNamed(BufferDetailsPage.routeName, arguments: buffer);
	}

	void _handleReact(BuildContext context, String reaction) async {
		var buffer = context.read<BufferModel>();
		var client = context.read<Client>();

		var reacted = message.reactionsByText[reaction]?.contains(client.nick) == true;
		var reactTag = reacted ? '+draft/unreact' : '+draft/react';

		await client.sendTextMessage(IrcMessage('TAGMSG', [buffer.name], tags: {
			'+draft/reply': message.entry.networkMsgid!,
			'+reply': message.entry.networkMsgid!,
			reactTag: reaction,
		}));
	}

	@override
	Widget build(BuildContext context) {
		var ircMsg = message.msg;
		var sender = ircMsg.source!.name;
		var client = context.read<Client>();
		var buffer = context.watch<BufferModel>();
		var network = context.watch<NetworkModel>();
		var isOwn = client.isMyNick(sender);
		var ctcp = CtcpMessage.parse(ircMsg);
		var isAction = ctcp != null && ctcp.cmd == 'ACTION';
		var canSendMessage = canSendMessageToBuffer(buffer, network);
		// TODO: we can redact if we are channel operator too
		var canRedact = canSendMessage && client.caps.enabled.contains('draft/message-redaction') && ircMsg.tags['msgid'] != null && isOwn && !message.entry.redacted;
		var reactions = message.reactionsByText;
		var canReact = canSendMessage && message.entry.networkMsgid != null && client.canReact && !message.entry.redacted;

		return SafeArea(child: Column(mainAxisSize: MainAxisSize.min, children: [
			if (canReact) Container(
				padding: EdgeInsets.symmetric(vertical: 10),
				child: Row(
					mainAxisAlignment: MainAxisAlignment.spaceEvenly,
					children: _defaultReactions.map((reaction) => IconButton.filledTonal(
						isSelected: reactions[reaction]?.contains(client.nick) ?? false,
						constraints: BoxConstraints(minWidth: 50, minHeight: 50),
						onPressed: () {
							Navigator.pop(context);
							_handleReact(context, reaction);
						},
						icon: Text(
							reaction,
							style: TextStyle(fontSize: 20),
						),
					)).followedBy([
						IconButton.filledTonal(
							isSelected: false,
							constraints: BoxConstraints(minWidth: 50, minHeight: 50),
							onPressed: () async {
								var reaction = await EmojiSheet.open(context);
								if (!context.mounted) {
									return;
								}
								if (reaction != null) {
									_handleReact(context, reaction);
								}
								Navigator.pop(context);
							},
							icon: Icon(Icons.add_reaction),
						),
					]).toList(),
				),
			),
			if (onReply != null && !isOwn) ListTile(
				title: Text('Reply'),
				leading: Icon(Icons.reply),
				onTap: () {
					Navigator.pop(context);
					onReply!();
				},
			),
			if (onQuote != null && !isOwn) ListTile(
				title: Text('Quote'),
				leading: Icon(Icons.format_quote),
				onTap: () {
					Navigator.pop(context);
					onQuote!();
				},
			),
			if (!isOwn) ListTile(
				title: Text('Whois'),
				leading: Icon(Icons.badge_outlined),
				onTap: () {
					Navigator.pop(context);
					_handleWhois(context, sender);
				},
			),
			if (!isOwn) ListTile(
				title: Text('Message $sender'),
				leading: Icon(Icons.chat_bubble),
				onTap: () {
					var network = context.read<NetworkModel>();
					Navigator.pop(context);
					BufferPage.open(context, sender, network);
				},
			),
			if (!isOwn) ListTile(
				title: Text('View profile'),
				leading: Icon(Icons.person),
				onTap: () {
					Navigator.pop(context);
					_handleViewProfile(context, sender);
				},
			),
			if (!message.entry.redacted) ListTile(
				title: Text('Copy'),
				leading: Icon(Icons.content_copy),
				onTap: () async {
					var text = '';
					if (isAction) {
						var body = ctcp.param;
						if (body == null) {
							return;
						}
						body = stripAnsiFormatting(body);
						text = '$sender $body';
					} else {
						var body = stripAnsiFormatting(ircMsg.params[1]);
						text = '<$sender> $body';
					}
					await Clipboard.setData(ClipboardData(text: text));
					if (context.mounted) {
						Navigator.pop(context);
					}
				},
			),
			if (canRedact) ListTile(
				title: Text('Delete'),
				leading: Icon(Icons.delete),
				onTap: () async {
					var buffer = context.read<BufferModel>();
					client.send(IrcMessage('REDACT', [buffer.name, ircMsg.tags['msgid']!]));
					Navigator.pop(context);
				},
			),
		]));
	}
}
