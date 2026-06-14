import Foundation

public enum ExamManagerPaths {
    public static let managementDirectory = URL(fileURLWithPath: "/Library/Management", isDirectory: true)
    public static let managementBinaryDirectory = URL(fileURLWithPath: "/Library/Management/bin", isDirectory: true)
    public static let networksetupBinary = URL(fileURLWithPath: "/usr/sbin/networksetup", isDirectory: false)
    public static let managedWhitelist = URL(fileURLWithPath: "/Library/Management/whitelist", isDirectory: false)
    public static let tinyproxyBinary = URL(fileURLWithPath: "/Library/Management/bin/tinyproxy", isDirectory: false)
    public static let tinyproxyConfigDirectory = URL(fileURLWithPath: "/Library/Management/lib/tinyproxy", isDirectory: true)
    public static let tinyproxyConfig = URL(fileURLWithPath: "/Library/Management/lib/tinyproxy/tinyproxy.conf", isDirectory: false)
    public static let whitelist = URL(fileURLWithPath: "/Library/Management/lib/tinyproxy/whitelist", isDirectory: false)
    public static let tinyproxyDefaultErrorPage = URL(fileURLWithPath: "/Library/Management/lib/tinyproxy/default.html", isDirectory: false)
    public static let notaryExamState = URL(fileURLWithPath: "/var/db/notaryExam.plist", isDirectory: false)
    public static let notaryExamFallbackPrefix = "notaryExam"
}
