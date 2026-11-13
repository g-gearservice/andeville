# Andeville

A macOS notch hub: a live island around the MacBook notch with face unlock, a now-playing player with wing controls and real audio bars, and AirPods connect live activity.

## Requirements

- macOS 14 or later (Control Center controls need macOS 26)
- Xcode command line tools

## Build

```sh
./build.sh
```

Builds `Andeville.app`, signs it, runs a self-check and launches it. `./make-dmg.sh` packages a DMG.

## License

[MIT](LICENSE)
