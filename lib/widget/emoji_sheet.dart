import 'package:flutter/material.dart';
import 'package:unicode_emojis/unicode_emojis.dart';

const _gridItemSize = 60.0;

class EmojiSheet extends StatelessWidget {
	final Map<Category, List<Emoji>> _emojiByCategory = _groupEmojiByCategory();

	EmojiSheet({ super.key });

	static Future<String?> open(BuildContext context) {
		return showModalBottomSheet<String?>(
			context: context,
			showDragHandle: true,
			builder: (context) => EmojiSheet(),
		);
	}

	@override
	Widget build(BuildContext context) {
		return CustomScrollView(
			slivers: Category.values.expand((category) => [
				SliverList.list(children: [
					Container(
						padding: EdgeInsets.all(10),
						child: Text(category.description, style: TextStyle(fontWeight: FontWeight.bold)),
					),
				]),
				SliverGrid.builder(
					gridDelegate: SliverGridDelegateWithMaxCrossAxisExtent(
						maxCrossAxisExtent: _gridItemSize,
						mainAxisExtent: _gridItemSize,
					),
					itemBuilder: (context, index) {
						var emoji = _emojiByCategory[category]![index];
						return Container(
							alignment: Alignment.center,
							width: _gridItemSize,
							height: _gridItemSize,
							child: IconButton(
								onPressed: () {
									Navigator.pop(context, emoji.emoji);
								},
								icon: Container(
									alignment: Alignment.center,
									width: 40,
									height: 40,
									child: Text(emoji.emoji, style: TextStyle(fontSize: 30)),
								),
							),
						);
					},
					itemCount: _emojiByCategory[category]!.length,
				),
			]).toList(),
		);
	}
}

Map<Category, List<Emoji>> _groupEmojiByCategory() {
	Map<Category, List<Emoji>> m = {};
	for (var emoji in UnicodeEmojis.allEmojis) {
		m.putIfAbsent(emoji.category, () => []).add(emoji);
	}
	return m;
}
