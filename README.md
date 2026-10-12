This is a fork of [Cellular](https://github.com/XuanHanTan/cellular) by Xuan Han Tan, which is no longer updated. It has been modified since October 2026 to work with current versions of macOS and Android; see the commit history for the changes. Builds of this fork are not available on the Mac App Store.

If you're looking for code documentation, view [this document](DEVDOCS.md) instead.

# About

Cellular was built with a simple goal in mind - to allow your Mac to connect to your phone's mobile hotspot seamlessly, as if your Mac has cellular data connectivity.

Cellular is a utility that brings your Mac and your Android phone closer together. When your Mac goes out of range of known Wi-Fi networks, Cellular seamlessly switches your Mac's internet connection to your phone's hotspot. And when you go in range of your trusted networks, Cellular intelligently turns off your phone's hotspot and reconnects you to the trusted network, saving energy while providing ultimate convenience.

# Features

- Connect to mobile hotspot seamlessly when other Wi-Fi networks are not available
- Disconnect from mobile hotspot automatically when computer is put to sleep
- Disconnect from mobile hotspot automatically when trusted Wi-Fi networks are available, including ones without a shared password like eduroam
- View phone information such as cell signal strength, network type and battery level from the menu bar of your Mac
- Turn off hotspot automatically when phone battery is below a set limit

On Android 16 and later, apps can no longer turn on the hotspot by themselves. Cellular Companion uses [Shizuku](https://shizuku.rikka.app/) to do it if you have it set up, and otherwise asks you to turn on the hotspot when your Mac needs it.

# Screenshots

<p>
    <img src="screenshots/screenshot_1.jpg" width=1000/>
    <img src="screenshots/screenshot_2.jpg" width=1000/>
    <img src="screenshots/screenshot_3.jpg" width=1000/>
</p>

# Download

**Option 1: Compile from source**

Verify the code and compile Cellular by yourself. You need macOS 14 or later and a recent Xcode with an Apple ID signed in (a free Personal Team works).

```sh
cp Config/Local.xcconfig.example Config/Local.xcconfig   # then set DEVELOPMENT_TEAM to your team ID
xcodebuild -project Cellular.xcodeproj -scheme Cellular -configuration Release -allowProvisioningUpdates build
```

To build under your own bundle identifiers, change `CELLULAR_BUNDLE_ID_PREFIX` in `Config/Base.xcconfig`.

**Option 2: Download from GitHub Releases**

Try Cellular immediately by downloading it from the [releases of this repository](https://github.com/nickredible/cellular/releases). Releases aren't notarized by Apple, so macOS blocks Cellular the first time you open it: open it once, then click **Open Anyway** in System Settings → Privacy & Security. Cellular checks for new releases once a day and lets you know when one is available, but you have to download and install it yourself. You can turn this off in Settings.

# Looking for Cellular Companion?

Cellular needs the Cellular Companion app on your Android phone. Download it from the [Cellular Companion repository](https://github.com/nickredible/cellular-companion/releases), where its source code also lives.

# Credits

Cellular was designed and built by Xuan Han Tan. This fork is by [nickredible](https://github.com/nickredible).

# License

Copyright © 2023 Xuan Han Tan<br>
Copyright © 2026 nickredible

Cellular is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, version 3 of the License. It is distributed in the hope that it will be useful, but without any warranty; without even the implied warranty of merchantability or fitness for a particular purpose. See [LICENSE](LICENSE) for details.
