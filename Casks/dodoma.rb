cask "dodoma" do
  version "1.0.0"
  sha256 "483c48b86ef933a52f760b881fcc1e66ddbcc88776b34d11a77f1abb2188c69e"

  url "https://github.com/alialhawas/Language-changer/releases/download/v#{version}/Dodoma-#{version}.dmg"
  name "Dodoma"
  desc "Fixes text typed with the wrong keyboard layout, Arabic and English"
  homepage "https://github.com/alialhawas/Language-changer"

  depends_on macos: ">= :sonoma"

  app "Dodoma.app"

  # The build is self-signed, so Gatekeeper refuses it like any unnotarised
  # download. Homebrew quarantines casks by default, which means the same
  # refusal; installing with --no-quarantine skips it, and the caveats below
  # say so rather than leaving the user at a dead end.
  caveats <<~CAVEATS
    Dodoma is not notarised by Apple, so macOS will refuse to open it unless
    you install it without quarantine:

      brew install --cask --no-quarantine dodoma

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
