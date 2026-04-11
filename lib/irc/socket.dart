import 'dart:async';
import 'dart:convert';
import 'dart:core';
import 'dart:io';

import 'message.dart';

class IrcSocket extends Stream<IrcMessage> implements Sink<IrcMessage> {
	final Socket _socket;

	IrcSocket(Socket socket) : _socket = socket;

	@override
	StreamSubscription<IrcMessage> listen(void Function(IrcMessage)? onData, {
		Function? onError,
		void Function()? onDone,
		bool? cancelOnError,
	}) {
		var decoder = Utf8Decoder(allowMalformed: true);
		var text = decoder.bind(_socket);
		var lines = text.transform(const LineSplitter());
		var messages = lines.map((l) => IrcMessage.parse(l));
		return messages.listen(onData, onDone: onDone, onError: onError, cancelOnError: cancelOnError);
	}

	@override
	void add(IrcMessage msg) {
		_socket.write(msg.toString() + '\r\n');
	}

	@override
	Future<void> close() {
		return _socket.close();
	}

	void destroy() {
		return _socket.destroy();
	}
}
