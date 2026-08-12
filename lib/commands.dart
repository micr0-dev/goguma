import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'client.dart';
import 'database.dart';
import 'irc/irc.dart';
import 'models.dart';

typedef CommandIsAvailable = bool Function(BuildContext context);
typedef CommandExec = String? Function(BuildContext context, String? param);

class Command {
	final CommandExec _exec;
	final String usage;
	final String description;
	final CommandIsAvailable isAvailable;

	const Command(this._exec, {
		required this.usage,
		required this.description,
		this.isAvailable = _alwaysAvailable,
	});

	String? exec(BuildContext context, String? param) {
		if (!isAvailable(context)) {
			throw CommandException('Command unavailable in this context');
		}
		return _exec(context, param);
	}
}

bool _alwaysAvailable(BuildContext context) {
	return true;
}

bool _availableInChannels(BuildContext context) {
	var client = context.read<Client>();
	var buffer = context.read<BufferModel>();
	return client.isChannel(buffer.name);
}

bool _availableIfChannelsAreSupported(BuildContext context) {
	var client = context.read<Client>();
	return !client.isupport.chanTypes.isEmpty;
}

class CommandException implements Exception {
	final String message;
	const CommandException(this.message);
}

String _requireParam(String? param) {
	if (param == null) {
		throw CommandException('This command requires a parameter');
	}
	return param;
}

/// Remove the first parameter from a space-separated list
///
/// Each parameter may be separated by multiple spaces. Removes up to
/// the first space and returns it along with the remainder after the
/// first sequence of spaces.
///
/// The return value is either a length 2 list (param, remainder) or
/// length 1 if there is no remainder.
List<String> _chompParam(String params) {
	var i = params.indexOf(' ');
	if (i < 0) {
		return [params];
	}
	var first = params.substring(0, i);
	while (i < params.length && params[i] == ' ') {
		i += 1;
	}
	return (i >= params.length) ? [first] : [first, params.substring(i)];
}

String? _invite(BuildContext context, String? param) {
	var client = context.read<Client>();
	var parts = _requireParam(param).split(' ');
	var nick = parts[0];
	var channel = parts.length > 1 ? parts[1] : context.read<BufferModel>().name;
	client.send(IrcMessage('INVITE', [nick, channel]));
	return null;
}

String? _join(BuildContext context, String? param) {
	var client = context.read<Client>();
	client.join([_requireParam(param)]);
	return null;
}

String? _kick(BuildContext context, String? param) {
	var client = context.read<Client>();
	var buffer = context.read<BufferModel>();
	var parts = _requireParam(param).split(' ');
	var nick = parts[0];
	var reason = parts.length > 1 ? [parts.sublist(1).join(' ')] : <String>[];
	client.send(IrcMessage('KICK', [buffer.name, nick, ...reason]));
	return null;
}

String? _me(BuildContext context, String? param) {
	return CtcpMessage('ACTION', param).format();
}

String? _msg(BuildContext context, String? param) {
	var split = _chompParam(_requireParam(param));
	if (split.length < 2) {
		throw CommandException('Usage: /msg <nickname> <message>');
	}
	context.read<Client>().send(IrcMessage('PRIVMSG', split));
	return null;
}

String? _notice(BuildContext context, String? param) {
	var split = _chompParam(_requireParam(param));
	if (split.length < 2) {
		throw CommandException('Usage: /notice <target> <message>');
	}
	context.read<Client>().send(IrcMessage('NOTICE', split));
	return null;
}

String? _topic(BuildContext context, String? param) {
	var client = context.read<Client>();
	var buffer = context.read<BufferModel>();
	client.send(IrcMessage('TOPIC', [buffer.name, _requireParam(param)]));
	return null;
}

String? _away(BuildContext context, String? param) {
	var client = context.read<Client>();
	client.send(IrcMessage('AWAY', param == null ? [] : [param]));
	return null;
}

String? _nick(BuildContext context, String? param) {
	var client = context.read<Client>();
	var nick = _requireParam(param).split(' ').first;
	client.setNickname(nick).catchError((Object err) {
		if (context.mounted) {
			ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Failed to change nickname: $err')));
		}
	});
	return null;
}

String? _clear(BuildContext context, String? param) {
	context.read<BufferModel>().clearMessages();
	return null;
}

String? _close(BuildContext context, String? param) {
	var client = context.read<Client>();
	var bufferList = context.read<BufferListModel>();
	var buffer = context.read<BufferModel>();
	var db = context.read<DB>();
	if (client.isChannel(buffer.name)) {
		client.send(IrcMessage('PART', [buffer.name]));
	} else {
		client.unmonitor([buffer.name]);
	}
	bufferList.setArchived(buffer, true);
	db.storeBuffer(buffer.entry);
	return null;
}

String? _names(BuildContext context, String? param) {
	var client = context.read<Client>();
	unawaited(client.names(_requireParam(param)).then<void>((v) {}, onError: (Object err) {
		if (context.mounted) {
			ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(err.toString())));
		}
	}));
	return null;
}

String? _modeChannel(BuildContext context, String? param, String mode) {
	var client = context.read<Client>();
	var buffer = context.read<BufferModel>();
	client.send(IrcMessage('MODE', [buffer.name, mode, ..._requireParam(param).split(' ')]));
	return null;
}

String? _op(BuildContext context, String? param) => _modeChannel(context, param, '+o');
String? _deop(BuildContext context, String? param) => _modeChannel(context, param, '-o');
String? _voice(BuildContext context, String? param) => _modeChannel(context, param, '+v');
String? _devoice(BuildContext context, String? param) => _modeChannel(context, param, '-v');
String? _ban(BuildContext context, String? param) => _modeChannel(context, param, '+b');
String? _unban(BuildContext context, String? param) => _modeChannel(context, param, '-b');

String? _help(BuildContext context, String? param) {
	var items = commands.entries
		.map((e) => '/${e.key} ${e.value.usage}')
		.join('\n');
	showDialog<void>(
		context: context,
		builder: (context) => AlertDialog(
			title: const Text('Commands'),
			content: SingleChildScrollView(child: Text(items, style: const TextStyle(fontFamily: 'monospace'))),
			actions: [
				TextButton(child: const Text('OK'), onPressed: () => Navigator.pop(context)),
			],
		),
	);
	return null;
}

String? _mode(BuildContext context, String? param) {
	var client = context.read<Client>();
	var buffer = context.read<BufferModel>();
	client.send(IrcMessage('MODE', [buffer.name, ..._requireParam(param).split(' ')]));
	return null;
}

String? _oper(BuildContext context, String? param) {
	var split = _chompParam(_requireParam(param));
	if (split.length == 1) {
		throw CommandException('This command requires a name and a password parameter');
	}
	var client = context.read<Client>();
	var name = split[0];
	var password = split[1];
	client.send(IrcMessage('OPER', [name, password]));
	return null;
}

String? _part(BuildContext context, String? param) {
	var client = context.read<Client>();
	var bufferList = context.read<BufferListModel>();
	var buffer = context.read<BufferModel>();
	var db = context.read<DB>();
	if (param != null) {
		client.send(IrcMessage('PART', [buffer.name, param]));
	} else {
		client.send(IrcMessage('PART', [buffer.name]));
	}
	bufferList.setArchived(buffer, true);
	db.storeBuffer(buffer.entry);
	return null;
}

String? _quote(BuildContext context, String? param) {
	var client = context.read<Client>();
	IrcMessage msg;
	try {
		msg = IrcMessage.parse(_requireParam(param));
	} on FormatException {
		throw CommandException('Invalid IRC command');
	}
	client.send(msg);
	return null;
}

const Map<String, Command> commands = {
	'join': Command(_join, usage: '<channel>', description: 'Join a channel', isAvailable: _availableIfChannelsAreSupported),
	'part': Command(_part, usage: '[reason]', description: 'Leave a channel', isAvailable: _availableInChannels),
	'quit': Command(_close, usage: '[reason]', description: 'Close the current conversation'),
	'msg': Command(_msg, usage: '<nickname> <message>', description: 'Send a private message'),
	'notice': Command(_notice, usage: '<target> <message>', description: 'Send a NOTICE'),
	'me': Command(_me, usage: '<message>', description: 'Send an action message'),
	'nick': Command(_nick, usage: '<nickname>', description: 'Change your nickname'),
	'away': Command(_away, usage: '[reason]', description: 'Set your away status'),
	'topic': Command(_topic, usage: '<topic>', description: 'Change the channel topic', isAvailable: _availableInChannels),
	'names': Command(_names, usage: '[channel]', description: 'List the users in a channel', isAvailable: _availableIfChannelsAreSupported),
	'op': Command(_op, usage: '<nickname>', description: 'Give a user channel operator status', isAvailable: _availableInChannels),
	'deop': Command(_deop, usage: '<nickname>', description: 'Remove channel operator status', isAvailable: _availableInChannels),
	'voice': Command(_voice, usage: '<nickname>', description: 'Voice a user', isAvailable: _availableInChannels),
	'devoice': Command(_devoice, usage: '<nickname>', description: 'Devoice a user', isAvailable: _availableInChannels),
	'ban': Command(_ban, usage: '<mask>', description: 'Ban a user or mask', isAvailable: _availableInChannels),
	'unban': Command(_unban, usage: '<mask>', description: 'Remove a ban', isAvailable: _availableInChannels),
	'mode': Command(_mode, usage: '±<mode> [args...]', description: 'Change a channel or user mode'),
	'kick': Command(_kick, usage: '<nickname> [reason]', description: 'Remove another user from the channel', isAvailable: _availableInChannels),
	'invite': Command(_invite, usage: '<nickname> [channel]', description: 'Invite a user to the channel', isAvailable: _availableInChannels),
	'oper': Command(_oper, usage: '<name> <password>', description: 'Obtain server operator privileges'),
	'quote': Command(_quote, usage: '<command> [args...]', description: 'Execute a raw IRC command'),
	'help': Command(_help, usage: '', description: 'Show available commands'),
	'clear': Command(_clear, usage: '', description: 'Clear the current conversation view'),
};
