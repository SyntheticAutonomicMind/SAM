import Foundation

/// Centralized appcast feed URLs for Sparkle updates
public enum AppcastURLs {
    /// Stable release channel (default) - production releases only
    public static let stable = URL(string: "https://raw.githubusercontent.com/SyntheticAutonomicMind/SAM/main/appcast.xml")!
    
    /// Development release channel (opt-in) - includes development builds + stable releases
    public static let development = URL(string: "https://raw.githubusercontent.com/SyntheticAutonomicMind/SAM/main/appcast-dev.xml")!
}
