# Homebrew cask. Lives in the tap repository (mdenizay/homebrew-tap) as
# Casks/mizu.rb; tools/release.sh fills in version and sha256.
cask "mizu" do
  version "VERSION"
  sha256 "SHA256"

  url "https://github.com/mdenizay/mizu-browser/releases/download/v#{version}/Mizu-#{version}.zip"
  name "Mizu"
  desc "Calm, light web browser with built-in ad blocking"
  homepage "https://github.com/mdenizay/mizu-browser"

  auto_updates true
  depends_on macos: :tahoe
  depends_on arch: :arm64

  app "Mizu.app"

  zap trash: [
    "~/Library/Application Support/Mizu",
    "~/Library/Caches/com.mdenizay.mizu",
    "~/Library/Preferences/com.mdenizay.mizu.plist",
    "~/Library/WebKit/com.mdenizay.mizu",
  ]
end
