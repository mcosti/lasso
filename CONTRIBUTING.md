# Contributing

Thanks for helping. A few things to know before opening a pull request.

## Testing

Bluetooth does not exist in the Simulator, so anything that touches the bike
has to be tried on a real iPhone with a Cowboy bike. Use **Dry run** (Settings,
developer mode: tap the version number seven times) to see what the policy
would do without writing to the lock, and share the log from the Log card when
reporting a problem. The log contains your bike's Bluetooth identifier and
nothing else personal.

Everything else (UI, demo mode, screenshots) runs in the Simulator:

```sh
cd ios && xcodegen generate
xcodebuild test -scheme Lasso -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max'
```

## Licensing of contributions

The project is GPLv3. The maintainer also ships a build through the App Store,
which the GPL alone does not permit for code the maintainer does not own. By
submitting a contribution you agree that the maintainer may additionally
distribute your contribution under the terms needed for App Store distribution
(an App Store exception in the sense of GPLv3 section 7). If you are not
comfortable with that, say so in the pull request and we will talk.

## Style

Plain Swift, SwiftUI, no third-party dependencies beyond the purchase SDK.
Short doc comments that say why, not what. Keep user-facing strings in
`AppInfo` or next to the view that shows them.
