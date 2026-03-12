# [goguma]

An IRC client for mobile devices.

- Modern: support for many IRCv3 extensions, plus some special support for IRC
  bouncers.
- Easy to use: offer a simple, straightforward interface.
- Offline-first: users should be able to read past conversations while offline,
  and network disruptions should be handled transparently
- Lightweight: go easy on resource usage to run smoothly on older phones and
  save battery power.
- Cross-platform: the main target platforms are Linux and Android, iOS is also
  supported.

If you want to try out goguma on Android, you can use [our F-Droid repository]
which provides nightly builds. Goguma is also available on the
[official F-Droid repository]. Community-supported Goguma versions are
available on [Google Play Store], [Apple App Store] and [AltStore PAL].

For more information about using Goguma, see our [documentation].

<img src="https://fs.emersion.fr/protected/img/goguma/main.png" width="220" alt="Conversation list">
<img src="https://fs.emersion.fr/protected/img/goguma/conversation.png" width="220" alt="Conversation view">
<img src="https://fs.emersion.fr/protected/img/goguma/conversation-details.png" width="220" alt="Conversation details">
<img src="https://fs.emersion.fr/protected/img/goguma/main-dark.png" width="220" alt="Conversation view, dark">

## Compiling

### For the Linux platform

Develop with:

    flutter run -d linux

Build with:

    flutter build linux

The built binary is in `build/linux/release/bundle/goguma`.

### For the Android platform

Build with:

    flutter build apk

The built APK is in `build/app/outputs/flutter-apk/app-release.apk`.

When running from the Android emulator, the server address
`irc+insecure://10.0.2.2` can be used to connect to a locally running IRC
server.

### For the iOS platform

Build with:

    flutter build ios # Build .app
    flutter build ipa # Build .ipa
    flutter build ipa --release # Build .ipa for App Store/Testflight

The built ipa file is in `build/ios/ipa`, ready for upload with [Transporter].

Please note that the bundle identifier is currently hardcoded to the one currently
being used for App Store distribution. You may want to change it if you want to
distribute Goguma yourself on the App Store, or a third-party platform.

## Contributing

Send patches and report bugs on [Codeberg]. Discuss in [#goguma on Libera Chat].

## License

AGPLv3 (see LICENSE) with an application store exception. As an additional
permission under section 7, you are allowed to distribute the software through
an application store, even if that store has restrictive terms and conditions
that are incompatible with the AGPL, provided that the source is also available
under the AGPL with or without this permission through a channel without those
restrictive terms and conditions.

Copyright (C) 2021 The goguma Contributors

[goguma]: https://codeberg.org/emersion/goguma
[our F-Droid repository]: https://fdroid.emersion.fr/#goguma-nightly
[official F-Droid repository]: https://f-droid.org/packages/fr.emersion.goguma/
[Google Play Store]: https://play.google.com/store/apps/details?id=fr.emersion.goguma.play
[Apple App Store]: https://apps.apple.com/fr/app/goguma-irc/id6470394620
[AltStore PAL]: https://altstore.goguma.im
[documentation]: doc/README.md
[Codeberg]: https://codeberg.org/emersion/goguma
[#goguma on Libera Chat]: ircs://irc.libera.chat/#goguma
[Transporter]: https://apps.apple.com/us/app/transporter/id1450874784
