import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../database.dart';
import '../irc.dart';
import '../models.dart';

class ReactionsSheet extends StatelessWidget {
	final Map<String, Set<String>> _reactions;
	final UserListModel _userList; // TODO: watch list and individual users

	ReactionsSheet({ super.key, required List<ReactionEntry> reactions, required UserListModel userList }) :
		_reactions = _groupReactionsByNickname(reactions),
		_userList = userList;

	static void open(BuildContext context, List<ReactionEntry> reactions) {
		var network = context.read<NetworkModel>();
		showModalBottomSheet<void>(
			context: context,
			showDragHandle: true,
			builder: (context) => ReactionsSheet(reactions: reactions, userList: network.users),
		);
	}

	@override
	Widget build(BuildContext context) {
		return ListView(shrinkWrap: true, children: _reactions.entries.map((entry) {
			var nickname = entry.key;
			var reactions = entry.value;
			var user = _userList.map[nickname];
			var realname = user?.realname;

			return ListTile(
				title: Text(nickname),
				subtitle: realname != null && !isStubRealname(realname, nickname) ? Text(realname) : null,
				trailing: Row(
					mainAxisSize: MainAxisSize.min,
					spacing: 5,
					children: reactions.map((reaction) => Text(
						reaction,
						style: TextStyle(fontSize: 22),
					)).toList(),
				),
			);
		}).toList());
	}
}

Map<String, Set<String>> _groupReactionsByNickname(List<ReactionEntry> reactions) {
	Map<String, Set<String>> byNickname = {};
	for (var reaction in reactions) {
		byNickname.putIfAbsent(reaction.msg.source!.name, () => {}).add(reaction.text);
	}
	return byNickname;
}
