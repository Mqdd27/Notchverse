# Copy to Casks/notchverse.rb in a tap repo named homebrew-notchverse.
# Install: brew install --cask --no-quarantine mqdd/notchverse/notchverse
cask "notchverse" do
  version "0.1.0"
  sha256 :no_check

  url "https://github.com/Mqdd/Notchverse/releases/download/v#{version}/Notchverse-#{version}.dmg"
  name "Notchverse"
  desc "Synced lyrics in a notch-style pill for any player"
  homepage "https://github.com/Mqdd/Notchverse"

  depends_on macos: ">= :sonoma"

  app "Notchverse.app"

  zap trash: "~/Library/Application Support/Notchverse"
end
