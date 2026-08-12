import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../ansi.dart';
import '../client.dart';
import '../emoji.dart';
import '../irc/irc.dart';
import '../linkify.dart';
import '../models.dart';
import '../prefs.dart';
import '../widget/link_preview.dart';
import '../widget/message_sheet.dart';
import '../widget/reactions_sheet.dart';
import '../widget/swipe_action.dart';

class RegularMessageItem extends StatelessWidget {
	final MessageModel msg;
	final MessageModel? prevMsg, nextMsg;
	final String? unreadMarkerTime;
	final VoidCallback? onReply;
	final void Function(int)? onMsgRefTap;

	const RegularMessageItem({
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
		var network = context.read<NetworkModel>();
		var buffer = context.read<BufferModel>();

		var ircMsg = msg.msg;
		var entry = msg.entry;
		var sender = ircMsg.source!.name;
		var localDateTime = entry.dateTime.toLocal();
		var ctcp = CtcpMessage.parse(ircMsg);
		var hasChannelContext = ircMsg.tags['+draft/channel-context'] != null;
		var isFromMe = client.isMyNick(sender);
		var isChannel = client.isChannel(buffer.name);
		assert(ircMsg.cmd == 'PRIVMSG' || ircMsg.cmd == 'NOTICE');

		var body = ircMsg.params[1];
		const maxEmotesForBigFont = 5;
		// use .take to avoid processing the entire string
		var bigEmotes = !entry.redacted && body.isNotEmpty &&
			body.characters.take(maxEmotesForBigFont + 1).length <= maxEmotesForBigFont &&
			body.characters.every(isEmoji);

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

		var colorScheme = Theme.of(context).colorScheme;
		var unreadMarkerColor = colorScheme.secondary;
		var eventColor = DefaultTextStyle.of(context).style.color!.withValues(alpha: 0.5);

		var boxColor = colorScheme.surfaceContainer;
		var boxAlignment = Alignment.centerLeft;
		var textColor = colorScheme.onSurface;
		var senderNickColor = _getNickColor(sender, colorScheme.brightness);

		if (isFromMe) {
			boxColor = colorScheme.primaryContainer;
			// Actions are displayed as if they were told by an external
			// narrator. To preserve this effect, always show actions on the
			// left side.
			if (!isAction) boxAlignment = Alignment.centerRight;
			textColor = colorScheme.onPrimaryContainer;
			senderNickColor = textColor;
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
			style: TextStyle(
				fontWeight: FontWeight.bold,
				color: isAction ? textColor : senderNickColor,
			),
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
			content = [
				WidgetSpan(
					child: Container(
						width: 8.0,
						height: 8.0,
						margin: EdgeInsets.all(3.0),
						decoration: BoxDecoration(
							shape: BoxShape.circle,
							color: senderNickColor,
						),
					),
				),
				senderTextSpan,
				TextSpan(text: ' '),
				_formatText(
					context,
					ctcp.param ?? '',
					nick: network.nickname,
					linkStyle: linkStyle,
					backgroundColor: colorScheme.surface,
					isFromMe: isFromMe,
				),
			];
		} else if (bigEmotes) {
			content = [
				if (isFirstInGroup && !isFromMe && isChannel) senderTextSpan,
				if (isFirstInGroup && !isFromMe && isChannel) TextSpan(text: '\n'),
				TextSpan(text: ircMsg.params[1], style: TextStyle(fontSize: 42)),
			];
		} else {
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
				bodyTextSpan = _formatText(
					context,
					body,
					nick: network.nickname,
					linkStyle: linkStyle,
					backgroundColor: boxColor,
					isFromMe: isFromMe,
				);
			}

			content = [
				if (isFirstInGroup && !isFromMe && isChannel) senderTextSpan,
				if (isFirstInGroup && !isFromMe && isChannel) TextSpan(text: '\n'),
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
					semanticsLabel: '', // Make screen reader quiet
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

		Widget decoratedMessage;
		if (isAction || bigEmotes) {
			decoratedMessage = inner;
		} else {
			var hasReactions = !msg.reactionsByText.isEmpty;
			decoratedMessage = ConstrainedBox(
				constraints: BoxConstraints(
					// Message bubbles are 80% of the screen width at most
					maxWidth: MediaQuery.of(context).size.width * 0.8,
				),
				child: Stack(children: [
					Container(
						decoration: BoxDecoration(
							borderRadius: BorderRadius.circular(10),
							color: boxColor,
						),
						margin: hasReactions ? EdgeInsets.only(bottom: 25) : null,
						padding: EdgeInsets.all(10),
						child: inner,
					),
					if (hasReactions) Positioned(
						bottom: 4,
						right: 10,
						child: _ReactionsRow(msg),
					),
				]),
			);
		}

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

		decoratedMessage = Align(
			alignment: boxAlignment,
			child: decoratedMessage,
		);

		decoratedMessage = GestureDetector(
			onLongPress: () {
				var buffer = context.read<BufferModel>();
				MessageSheet.open(context, buffer, msg, onReply);
			},
			child: decoratedMessage,
		);

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

class _ReactionsRow extends StatelessWidget {
	final MessageModel message;

	late final List<MapEntry<String, int>> _reactions;
	late final int _overflow;

	_ReactionsRow(this.message) {
		var map = message.reactionsByText;
		var entries = message.reactionsByText.entries
			.map((entry) => MapEntry(entry.key, entry.value.length))
			.toList();
		if (entries.length > 3) {
			entries.sort((a, b) => a.value.compareTo(b.value));
			entries = entries.take(2).toList();
		}
		_reactions = entries;
		_overflow = map.length - entries.length;
	}

	@override
	Widget build(BuildContext context) {
		MapEntry<String, int>? overflowEntry;
		if (_overflow > 0) {
			overflowEntry = MapEntry('+$_overflow', 0);
		}

		var reactions = _reactions.followedBy([
			if (overflowEntry != null) overflowEntry,
		]).map((reactionEntry) {
			return _ReactionChip(
				text: reactionEntry.key,
				count: reactionEntry.value,
				message: message,
			);
		}).toList();

		return Row(spacing: 2, children: reactions);
	}
}

class _ReactionChip extends StatelessWidget {
	final String text;
	final int count;
	final MessageModel message;
	final Color? borderColor;
	final Color? backgroundColor;

	const _ReactionChip({
		required this.text,
		required this.count,
		required this.message,
		this.borderColor,
		this.backgroundColor,
	});

	@override
	Widget build(BuildContext context) {
		var content = text;
		if (count > 1) {
			content = '$text $count';
		}

		var fg = Theme.of(context).colorScheme.secondaryContainer;
		var bg = Theme.of(context).colorScheme.surface;
		return GestureDetector(
			onTap: () {
				var buffer = context.read<BufferModel>();
				ReactionsSheet.open(context, buffer, message);
			},
			child: Container(
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
			),
		);
	}
}

class CompactMessageItem extends StatelessWidget {
	final MessageModel msg;
	final MessageModel? prevMsg;
	final String? unreadMarkerTime;
	final VoidCallback? onReply;
	final bool last;

	const CompactMessageItem({
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

		var prevEntry = prevMsg?.entry;
		var showUnreadMarker = prevEntry != null && unreadMarkerTime != null && unreadMarkerTime!.compareTo(entry.time) < 0 && unreadMarkerTime!.compareTo(prevEntry.time) >= 0;
		var showDateMarker = prevEntry == null || !_isSameDate(localDateTime, prevEntry.dateTime.toLocal());

		var scheme = Theme.of(context).colorScheme;
		var bodyTheme = Theme.of(context).textTheme;
		var bodyColor = bodyTheme.bodyLarge?.color ?? scheme.onSurface;
		var unreadMarkerColor = scheme.secondary;
		var dimColor = (bodyTheme.bodySmall?.color ?? bodyColor).withValues(alpha: 0.72);
		var senderColor = _getNickColor(sender, scheme.brightness);

		var isAction = ctcp != null && ctcp.cmd == 'ACTION';
		var isOtherCtcp = ctcp != null && !isAction;

		// Compose the line as a single selectable block in the classic IRC
		// format: "HH:MM <nick> message". The angle brackets are rendered
		// (near) invisible on screen but remain part of the text, so that
		// copy/paste yields the conventional <nick> form.
		List<InlineSpan> content = [];

		if (prefs.showTimestamps) {
			var hh = localDateTime.hour.toString().padLeft(2, '0');
			var mm = localDateTime.minute.toString().padLeft(2, '0');
			content.add(TextSpan(text: '$hh:$mm ', style: TextStyle(color: dimColor)));
		}

		if (isAction) {
			content.add(TextSpan(text: '* ', style: TextStyle(color: dimColor)));
			content.add(TextSpan(text: sender, style: TextStyle(color: senderColor, fontWeight: FontWeight.bold)));
			content.add(const TextSpan(text: ' '));
		} else {
			content.add(const TextSpan(text: '<', style: _hiddenBracketStyle));
			content.add(TextSpan(text: sender, style: TextStyle(color: senderColor, fontWeight: FontWeight.bold)));
			content.add(const TextSpan(text: '>', style: _hiddenBracketStyle));
			content.add(const TextSpan(text: ' '));
		}

		List<TextSpan> body;
		if (entry.redacted) {
			body = [TextSpan(
				text: 'This message has been deleted.',
				style: TextStyle(fontStyle: FontStyle.italic, color: dimColor),
			)];
		} else if (isOtherCtcp) {
			body = [TextSpan(text: 'has sent a CTCP "${ctcp.cmd}" command', style: TextStyle(color: bodyColor))];
		} else if (isAction) {
			body = applyAnsiFormatting(ctcp.param ?? '', TextStyle(color: bodyColor, fontStyle: FontStyle.italic));
		} else {
			body = applyAnsiFormatting(ircMsg.params[1], TextStyle(color: bodyColor));
		}

		body = body.map((span) {
			var linkSpan = linkify(context, span.text ?? '',
				linkStyle: TextStyle(decoration: TextDecoration.underline, color: scheme.primary));
			return TextSpan(style: span.style, children: [linkSpan]);
		}).toList();
		content.addAll(body);

		var fg = scheme.secondaryContainer;
		var reactions = msg.reactionsByText.entries.map((reactionEntry) {
			return _ReactionChip(
				text: reactionEntry.key,
				count: reactionEntry.value.length,
				message: msg,
				borderColor: fg,
				backgroundColor: fg.withAlpha(30),
			);
		}).toList();

		var line = GestureDetector(
			onLongPress: () {
				var buffer = context.read<BufferModel>();
				MessageSheet.open(context, buffer, msg, onReply);
			},
			child: Text.rich(
				TextSpan(children: content),
				textScaler: TextScaler.linear(1.05),
			),
		);

		Widget message = line;
		if (!reactions.isEmpty) {
			message = Padding(
				padding: const EdgeInsets.only(bottom: 26),
				child: Stack(children: [
					line,
					Positioned(bottom: -22, left: 4, child: Row(spacing: 2, children: reactions)),
				]),
			);
		}

		Widget? linkPreview;
		if (prefs.linkPreview && !entry.redacted && ircMsg.cmd == 'PRIVMSG' && !isAction) {
			var bodyText = stripAnsiFormatting(ircMsg.params[1]);
			linkPreview = LinkPreview(
				text: bodyText,
				builder: (context, child) {
					return Align(alignment: Alignment.centerLeft, child: Container(
						margin: const EdgeInsets.only(top: 6),
						child: child,
					));
				},
			);
		}

		return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
			if (showUnreadMarker) Container(
				margin: const EdgeInsets.only(top: 10, bottom: 4),
				child: Row(children: [
					Expanded(child: Divider(color: unreadMarkerColor)),
					const SizedBox(width: 10),
					Text('Unread messages', style: TextStyle(color: unreadMarkerColor)),
					const SizedBox(width: 10),
					Expanded(child: Divider(color: unreadMarkerColor)),
				]),
			),
			if (showDateMarker) Container(
				margin: const EdgeInsets.only(top: 14, bottom: 6),
				alignment: Alignment.center,
				child: Text(
					'—  ${_formatDate(localDateTime)}  —',
					style: TextStyle(color: dimColor),
				),
			),
			Padding(
				padding: EdgeInsets.only(
					top: showDateMarker ? 2 : 5,
					bottom: last ? 16 : 5,
					left: 12,
					right: 12,
				),
				child: DefaultTextStyle.merge(
					// Generous line height gives the classic scrollback feel
					// and clearer separation between messages.
					style: TextStyle(height: 1.45, color: bodyColor),
					child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
						message,
						if (linkPreview != null) linkPreview,
					]),
				),
			),
		]);
	}
}

// Rendered virtually invisible (kept small so it doesn't open up a visible
// gap between the name and the message), but still selectable/copyable so
// copied lines read as "<nick> message".
const _hiddenBracketStyle = TextStyle(color: Color(0x00000000), fontSize: 1);

bool _isSameDate(DateTime a, DateTime b) {
	return a.year == b.year && a.month == b.month && a.day == b.day;
}

String _formatDate(DateTime dt) {
	var yyyy = dt.year.toString().padLeft(4, '0');
	var mm = dt.month.toString().padLeft(2, '0');
	var dd = dt.day.toString().padLeft(2, '0');
	return '$yyyy-$mm-$dd';
}

TextSpan _formatText(BuildContext context, String text, {
	required String nick,
	required TextStyle linkStyle,
	required Color backgroundColor,
	required bool isFromMe,
}) {
	text = stripAnsiFormatting(text);

	if (isFromMe) return linkify(context, text, linkStyle: linkStyle);

	var highlightIndexes = findTextHighlights(text, nick);
	List<InlineSpan> children = [];
	for (var i in highlightIndexes) {
		children.add(linkify(context, text.substring(0, i), linkStyle: linkStyle));
		children.add(WidgetSpan(
			alignment: PlaceholderAlignment.middle,
			child: Builder(builder: (context) => Container(
				padding: EdgeInsets.symmetric(horizontal: 5, vertical: 1),
				decoration: BoxDecoration(
					color: DefaultTextStyle.of(context).style.color!,
					borderRadius: BorderRadius.circular(5),
				),
				child: Text(nick, style: TextStyle(color: backgroundColor)),
			)),
		));
		text = text.substring(i + nick.length);
	}
	children.add(linkify(context, text, linkStyle: linkStyle));

	return TextSpan(children: children);
}

// _getNickColor returns a color for the given nickname. The same nickname will always get the same color. The color is chosen from the primary colors of the current theme. The brightness parameter is used to choose a lighter or darker shade of the color.
Color _getNickColor(String nickname, Brightness brightness) {
	var colorSwatch = Colors.primaries[nickname.hashCode % Colors.primaries.length];
	return brightness == Brightness.dark ? colorSwatch.shade400 : colorSwatch.shade800;
}

