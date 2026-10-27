cask "birdnion" do
  version "0.10.56"
  sha256 "42b8c00298969278e19b8e5917c6f866ab8b5776af2074e2dc397166ecf386c6"

  url "https://github.com/hapo-nghialuu/BirdNion/releases/download/v#{version.csv.first}/BirdNion-#{version.csv.first}.zip"
  name "BirdNion"
  desc "AI quota menu bar app — tracks MiniMax, Codex, Claude, Hapo AI Hub and more"
  homepage "https://github.com/hapo-nghialuu/BirdNion"

  livecheck do
    url :homepage
    strategy :github_latest_release
  end

  depends_on :macos

  app "BirdNion.app"

  zap trash: [
    # BirdNion config + tokens
    "~/.config/birdnion",
    "~/.birdnion",
    "~/Library/Application Support/BirdNion",
    "~/Library/Preferences/com.local.birdnion.plist",
    "~/Library/Caches/com.local.birdnion",
    "~/Library/HTTPStorages/com.local.birdnion",
    "~/Library/HTTPStorages/com.local.birdnion.binarycookies",
    # Legacy (old app name AIStatusbar — kept for migration cleanup)
    "~/Library/Application Support/AIStatusbar",
    "~/Library/Preferences/com.local.aistatusbar.plist",
    "~/Library/Caches/com.local.aistatusbar",
    "~/Library/HTTPStorages/com.local.aistatusbar",
    "~/Library/HTTPStorages/com.local.aistatusbar.binarycookies",
  ]
end
