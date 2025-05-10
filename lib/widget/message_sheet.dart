import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../ansi.dart';
import '../client.dart';
import '../client_controller.dart';
import '../database.dart';
import '../irc.dart';
import '../models.dart';
import '../page/buffer.dart';

const DEFAULT_REACTIONS = ['❤️', '👍', '👎', '😂', '😮', '😢'];

class MessageSheet extends StatelessWidget {
	final MessageModel message;
	final VoidCallback? onReply;

	const MessageSheet({ super.key, required this.message, this.onReply });

	static void open(BuildContext context, BufferModel buffer, MessageModel message, VoidCallback? onReply) {
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
					child: MessageSheet(message: message, onReply: onReply),
				);
			},
		);
	}

	void _handleReact(BuildContext context, String reaction) async {
		var bufferList = context.read<BufferListModel>();
		var buffer = context.read<BufferModel>();
		var db = context.read<DB>();
		var client = context.read<Client>();
		var network = context.read<NetworkModel>();

		if (message.reactionMap[reaction]?.contains(client.nick) == true) {
			ScaffoldMessenger.of(context).showSnackBar(SnackBar(
				content: Text('Cannot remove reaction'),
			));
			return;
		}

		var msg = await client.sendTextMessage(IrcMessage('TAGMSG', [buffer.name], tags: {
			'+draft/reply': message.entry.networkMsgid!,
			'+draft/react': reaction,
		}));

		if (client.caps.enabled.contains('echo-message')) {
			return;
		}

		var entry = ReactionEntry(msg, buffer.id);
		await db.storeReactions([entry]);
		if (buffer.messageHistoryLoaded) {
			buffer.addReactions([entry]);
		}

		bufferList.bumpLastDeliveredTime(buffer, entry.time);
		if (network.networkEntry.bumpLastDeliveredTime(entry.time)) {
			await db.storeNetwork(network.networkEntry);
		}
	}

	@override
	Widget build(BuildContext context) {
		var ircMsg = message.msg;
		var sender = ircMsg.source!.name;
		var client = context.read<Client>();
		var buffer = context.watch<BufferModel>();
		var network = context.watch<NetworkModel>();
		var isOwn = client.isMyNick(sender);
		var canSendMessage = canSendMessageToBuffer(buffer, network);
		// TODO: we can redact if we are channel operator too
		var canRedact = canSendMessage && client.caps.enabled.contains('draft/message-redaction') && ircMsg.tags['msgid'] != null && isOwn && !message.entry.redacted;
		var reactions = message.reactionMap;
		var canReact = canSendMessage && client.caps.enabled.contains('message-tags') && client.isupport.isClientTagAllowed('react') && message.entry.networkMsgid != null;

		return Column(mainAxisSize: MainAxisSize.min, children: [
			if (canReact) Container(
				padding: EdgeInsets.symmetric(vertical: 10),
					child: Row(
					mainAxisAlignment: MainAxisAlignment.spaceEvenly,
					children: DEFAULT_REACTIONS.map((reaction) => IconButton.filledTonal(
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
					)).toList(),
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
			if (!isOwn) ListTile(
				title: Text('Message $sender'),
				leading: Icon(Icons.chat_bubble),
				onTap: () {
					var network = context.read<NetworkModel>();
					Navigator.pop(context);
					BufferPage.open(context, sender, network);
				},
			),
			ListTile(
				title: Text('Copy'),
				leading: Icon(Icons.content_copy),
				onTap: () async {
					var body = stripAnsiFormatting(ircMsg.params[1]);
					var text = '<$sender> $body';
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
		]);
	}
}
