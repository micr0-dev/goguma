import 'package:flutter/widgets.dart';
import 'package:provider/provider.dart';

import 'client.dart';
import 'database.dart';
import 'irc.dart';
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
	'invite': Command(_invite, usage: '<nickname> [channel]', description: 'Invite a user to the channel', isAvailable: _availableInChannels),
	'join': Command(_join, usage: '<channel>', description: 'Join a channel', isAvailable: _availableIfChannelsAreSupported),
	'kick': Command(_kick, usage: '<nickname> [reason]', description: 'Remove another user from the channel', isAvailable: _availableInChannels),
	'me': Command(_me, usage: '<message>', description: 'Send an action message'),
	'mode': Command(_mode, usage: '±<mode> [args...]', description: 'Change a channel or user mode'),
	'oper': Command(_oper, usage: '<name> <password>', description: 'Obtain server operator privileges'),
	'part': Command(_part, usage: '[reason]', description: 'Leave a channel', isAvailable: _availableInChannels),
	'quote': Command(_quote, usage: '<command> [args...]', description: 'Execute a raw IRC command'),
};
