import Foundation

/// Shared bounds for foreground, encrypted attachment uploads.
public enum FileAttachmentLimits {
    public static let maxFileBytes = 20 * 1024 * 1024
    public static let chunkBytes = 64 * 1024
    public static let maxAttachments = 4
}
