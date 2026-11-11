import AppKit

@MainActor
enum ApplicationIcon {
    /// Read this bundle's bytes directly, rather than reusing a named image or
    /// the file icon supplied by Launch Services for an earlier installation.
    static func load(bundle: Bundle = .main) -> NSImage? {
        guard let resource = bundle.object(forInfoDictionaryKey: "CFBundleIconFile") as? String,
              !resource.isEmpty else { return nil }
        let path = resource as NSString
        let fileExtension = path.pathExtension.isEmpty ? "icns" : path.pathExtension
        let name = path.pathExtension.isEmpty ? resource : path.deletingPathExtension
        guard let url = bundle.url(forResource: name, withExtension: fileExtension),
              let data = try? Data(contentsOf: url),
              let image = NSImage(data: data),
              image.isValid else { return nil }
        return image
    }
}
