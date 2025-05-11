import 'package:flutter/material.dart';
import 'package:unicode_emojis/unicode_emojis.dart';

const _gridItemSize = 60.0;

class EmojiSheet extends StatefulWidget {
	const EmojiSheet({ super.key });

	@override
	State<EmojiSheet> createState() => _EmojiSheetState();

	static Future<String?> open(BuildContext context) {
		return showModalBottomSheet<String?>(
			context: context,
			showDragHandle: true,
			isScrollControlled: true,
			builder: (context) => EmojiSheet(),
		);
	}
}

class _EmojiSheetState extends State<EmojiSheet> {
	final Map<Category, List<Emoji>> _allEmojis = _groupEmojiByCategory();

	List<Emoji>? _filteredEmojis;

	void _search(String query) {
		List<Emoji>? filtered;
		if (!query.isEmpty) {
			filtered = UnicodeEmojis.search(query);
		}

		setState(() {
			_filteredEmojis = filtered;
		});
	}

	@override
	Widget build(BuildContext context) {
		List<Widget> slivers;
		if (_filteredEmojis != null) {
			slivers = [_EmojiGrid(_filteredEmojis!)];
		} else {
			slivers = Category.values.expand((category) => [
				SliverList.list(children: [
					Container(
						padding: EdgeInsets.all(10),
						child: Text(category.description, style: TextStyle(fontWeight: FontWeight.bold)),
					),
				]),
				_EmojiGrid(_allEmojis[category]!),
			]).toList();
		}

		// Padding ensures the full list is visible when the OSK is open
		return Padding(
			padding: MediaQuery.of(context).viewInsets,
			child: DraggableScrollableSheet(
				expand: false,
				snap: true,
				minChildSize: 0.5,
				builder: (context, scrollController) => Column(children: [
					Container(
						padding: EdgeInsets.all(15),
						child: TextField(
							decoration: InputDecoration(
								prefixIcon: Icon(Icons.search),
								hintText: 'Search emoji',
								border: OutlineInputBorder(),
							),
							onChanged: _search,
						),
					),
					Expanded(child: CustomScrollView(slivers: slivers, controller: scrollController)),
				]),
			),
		);
	}
}

class _EmojiGrid extends StatelessWidget {
	final List<Emoji> emojis;

	const _EmojiGrid(this.emojis);

	@override
	Widget build(BuildContext context) {
		return SliverGrid.builder(
			gridDelegate: SliverGridDelegateWithMaxCrossAxisExtent(
				maxCrossAxisExtent: _gridItemSize,
				mainAxisExtent: _gridItemSize,
			),
			itemBuilder: (context, index) {
				return _EmojiItem(emojis[index]);
			},
			itemCount: emojis.length,
		);
	}
}

class _EmojiItem extends StatelessWidget {
	final Emoji emoji;

	const _EmojiItem(this.emoji);

	@override
	Widget build(BuildContext context) {
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
	}
}

Map<Category, List<Emoji>> _groupEmojiByCategory() {
	Map<Category, List<Emoji>> m = {};
	for (var emoji in UnicodeEmojis.allEmojis) {
		m.putIfAbsent(emoji.category, () => []).add(emoji);
	}
	return m;
}
