import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../ansi.dart';
import '../client.dart';
import '../client_controller.dart';
import '../irc.dart';
import '../models.dart';
import '../page/buffer.dart';

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

	@override
	Widget build(BuildContext context) {
		var ircMsg = message.msg;
		var sender = ircMsg.source!.name;
		var client = context.read<Client>();
		var isOwn = client.isMyNick(sender);
		// TODO: we can redact if we are channel operator too
		var canRedact = client.caps.enabled.contains('draft/message-redaction') && ircMsg.tags['msgid'] != null && isOwn && !message.entry.redacted;

		return Column(mainAxisSize: MainAxisSize.min, children: [
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
