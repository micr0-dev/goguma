import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../ansi.dart';
import '../client.dart';
import '../irc.dart';
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
			return _Reaction(
				text: reactionEntry.key,
				count: reactionEntry.value.length,
				message: msg,
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
	final int count;
	final MessageModel message;
	final Color? borderColor;
	final Color? backgroundColor;

	const _Reaction({
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
				ReactionsSheet.open(context, message.reactions);
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
			return _Reaction(
				text: reactionEntry.key,
				count: reactionEntry.value.length,
				message: msg,
				borderColor: fg,
				backgroundColor: fg.withAlpha(30),
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

bool _isSameDate(DateTime a, DateTime b) {
	return a.year == b.year && a.month == b.month && a.day == b.day;
}

String _formatDate(DateTime dt) {
	var yyyy = dt.year.toString().padLeft(4, '0');
	var mm = dt.month.toString().padLeft(2, '0');
	var dd = dt.day.toString().padLeft(2, '0');
	return '$yyyy-$mm-$dd';
}
