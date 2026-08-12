import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../ansi.dart';
import '../database.dart';
import '../models.dart';
import 'buffer.dart';

class SearchPage extends StatefulWidget {
	static const routeName = '/search';

	const SearchPage({ super.key });

	@override
	State<SearchPage> createState() => _SearchPageState();
}

class _SearchPageState extends State<SearchPage> {
	final _controller = TextEditingController();
	List<MessageEntry> _results = [];
	bool _loading = false;
	Timer? _debounce;

	@override
	void dispose() {
		_debounce?.cancel();
		_controller.dispose();
		super.dispose();
	}

	void _onChanged(String value) {
		_debounce?.cancel();
		var q = value.trim();
		if (q.isEmpty) {
			setState(() {
				_results = [];
				_loading = false;
			});
			return;
		}
		setState(() {
			_loading = true;
		});
		_debounce = Timer(const Duration(milliseconds: 250), () => _search(q));
	}

	Future<void> _search(String q) async {
		var db = context.read<DB>();
		var results = await db.searchMessagesGlobal(q);
		if (!mounted) {
			return;
		}
		setState(() {
			_results = results;
			_loading = false;
		});
	}

	@override
	Widget build(BuildContext context) {
		var bufferList = context.read<BufferListModel>();
		var theme = Theme.of(context);
		return Scaffold(
			appBar: AppBar(title: const Text('Search messages')),
			body: Column(children: [
				Padding(
					padding: const EdgeInsets.all(8),
					child: TextField(
						controller: _controller,
						autofocus: true,
						onChanged: _onChanged,
						decoration: const InputDecoration(
							hintText: 'Search all conversations...',
							prefixIcon: Icon(Icons.search),
							border: OutlineInputBorder(),
						),
					),
				),
				Expanded(child: _loading && _results.isEmpty
					? const Center(child: CircularProgressIndicator())
					: _results.isEmpty
						? Center(child: Text('No results', style: TextStyle(color: theme.textTheme.bodySmall?.color)))
						: ListView.builder(
							itemCount: _results.length,
							itemBuilder: (context, index) {
								var entry = _results[index];
								BufferModel? buffer;
								for (var b in bufferList.buffers) {
									if (b.id == entry.buffer) {
										buffer = b;
										break;
									}
								}
								var msg = entry.msg;
								var sender = msg.source?.name ?? '';
								var text = stripAnsiFormatting(msg.params.length > 1 ? msg.params[1] : msg.params.join(' '));
								var time = entry.dateTime.toLocal();
								var hh = time.hour.toString().padLeft(2, '0');
								var mm = time.minute.toString().padLeft(2, '0');
								return ListTile(
									title: Text.rich(TextSpan(children: [
										TextSpan(text: sender, style: const TextStyle(fontWeight: FontWeight.bold)),
										TextSpan(text: '  $text'),
									]), maxLines: 2, overflow: TextOverflow.ellipsis),
									subtitle: Text('${buffer?.name ?? '?'}  $hh:$mm'),
									onTap: () {
										if (buffer == null) {
											return;
										}
										Navigator.pushNamed(context, BufferPage.routeName, arguments: BufferPageArguments(buffer: buffer));
									},
								);
							},
						),
				),
			]),
		);
	}
}