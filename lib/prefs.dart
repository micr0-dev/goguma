import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _showTimestampsKey = 'show_timestamps';
const _monoFontKey = 'mono_font';
const _highlightWordsKey = 'highlight_words';
const _typingIndicatorKey = 'typing_indicator';
const _nicknameKey = 'nickname';
const _realnameKey = 'realname';
const _pushProviderKey = 'push_provider';
const _linkPreviewKey = 'link_preview';
const _linkExtAppKey = 'link_external_app';
const _recentReactionsKey = 'recent_reactions';
const _uploadErrorReportsKey = 'upload_error_reports';

const _maxRecentReactions = 14;

class Prefs extends ChangeNotifier {
	final SharedPreferences _prefs;

	Prefs._(this._prefs);

	static Future<Prefs> load() async {
		return Prefs._(await SharedPreferences.getInstance());
	}

	/// Whether to display a timestamp on every message line.
	bool get showTimestamps => _prefs.getBool(_showTimestampsKey) ?? true;

	/// Use the bundled monospaced terminal font instead of the default one.
	bool get monoFont => _prefs.getBool(_monoFontKey) ?? true;

	/// Comma-separated extra words to highlight in messages (besides our nick).
	String get highlightWords => _prefs.getString(_highlightWordsKey) ?? '';
	List<String> get highlightWordsList => highlightWords
		.split(',')
		.map((s) => s.trim())
		.where((s) => s.isNotEmpty)
		.toList();
	bool get typingIndicator => _prefs.getBool(_typingIndicatorKey) ?? false;
	String get nickname => _prefs.getString(_nicknameKey) ?? 'user';
	String? get realname => _prefs.getString(_realnameKey);
	String? get pushProvider => _prefs.getString(_pushProviderKey);
	bool get linkPreview => _prefs.getBool(_linkPreviewKey) ?? false;
	bool get linkExtApp => _prefs.getBool(_linkExtAppKey) ?? false;
	List<String> get recentReactions => _prefs.getStringList(_recentReactionsKey) ?? [];
	bool get uploadErrorReports => _prefs.getBool(_uploadErrorReportsKey) ?? true;

	set showTimestamps(bool enabled) {
		_prefs.setBool(_showTimestampsKey, enabled);
	}

	set monoFont(bool enabled) {
		_prefs.setBool(_monoFontKey, enabled);
		notifyListeners();
	}

	set highlightWords(String words) {
		_prefs.setString(_highlightWordsKey, words);
		notifyListeners();
	}

	set typingIndicator(bool enabled) {
		_prefs.setBool(_typingIndicatorKey, enabled);
	}

	set nickname(String nickname) {
		_prefs.setString(_nicknameKey, nickname);
	}

	void _setOptionalString(String k, String? v) {
		if (v != null) {
			_prefs.setString(k, v);
		} else {
			_prefs.remove(k);
		}
	}

	set realname(String? realname) {
		_setOptionalString(_realnameKey, realname);
	}

	set pushProvider(String? provider) {
		_setOptionalString(_pushProviderKey, provider);
	}

	set linkPreview(bool enabled) {
		_prefs.setBool(_linkPreviewKey, enabled);
	}

	set linkExtApp(bool enabled) {
		_prefs.setBool(_linkExtAppKey, enabled);
	}

	void addRecentReaction(String reaction) {
		var reactions = [reaction, ...recentReactions.where((r) => r != reaction).take(_maxRecentReactions - 1)];
		_prefs.setStringList(_recentReactionsKey, reactions);
	}

	set uploadErrorReports(bool enabled) {
		_prefs.setBool(_uploadErrorReportsKey, enabled);
	}
}
