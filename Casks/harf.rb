cask "harf" do
  version "1.0.0"
  sha256 "5bec9a37db5562ac664728820170f30b114970a0b3212ccaaf7202e0c3db9011"

  url "https://github.com/alialhawas/Language-changer/releases/download/v#{version}/Harf-#{version}.dmg"
  name "Harf"
  desc "Fixes text typed with the wrong keyboard layout, Arabic and English"
  homepage "https://github.com/alialhawas/Language-changer"

  depends_on macos: ">= :sonoma"

  app "Harf.app"
  # The same binary serves the menu-bar app and the command line, so `harf
  # --status` works without shipping a second executable.
  binary "#{appdir}/Harf.app/Contents/MacOS/Harf", target: "harf"

  # The build is self-signed, so Gatekeeper refuses it like any unnotarised
  # download. Homebrew quarantines casks by default, which means the same
  # refusal; installing with --no-quarantine skips it, and the caveats below
  # say so rather than leaving the user at a dead end.
  caveats <<~CAVEATS
    Harf is not notarised by Apple, so macOS will refuse to open it unless
    you install it without quarantine:

      brew install --cask --no-quarantine harf

    It then needs two permissions before it can do anything, both under
    System Settings > Privacy & Security:

      Accessibility      — to replace the text
      Input Monitoring   — to see the keys you press

    Neither is optional; the app cannot work with only one.
  CAVEATS

  zap trash: [
    "~/Library/Preferences/com.ali.dodoma.plist",
  ]
end
