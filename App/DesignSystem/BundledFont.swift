import CoreText
import Foundation
import SwiftUI

/// Register once for this process, without changing the user's installed fonts.
enum BundledFont {
    private static let postScriptName = register("IoskeleyMonoNL-Regular")
    private static let nameFont = register("GoogleSansFlex")

    private static func register(_ resource: String) -> String? {
        guard let url = Bundle.main.url(forResource: resource, withExtension: "ttf"),
              let descriptors = CTFontManagerCreateFontDescriptorsFromURL(url as CFURL) as? [CTFontDescriptor],
              let descriptor = descriptors.first,
              let name = CTFontDescriptorCopyAttribute(descriptor, kCTFontNameAttribute) as? String else { return nil }
        var error: Unmanaged<CFError>?
        guard CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error) else { return nil }
        return name
    }

    static func programName(size: CGFloat) -> Font {
        guard let nameFont else { return .system(size: size, weight: .medium) }
        // Pin the variable font's weight axis instead of relying on its first named instance.
        let descriptor = CTFontDescriptorCreateWithAttributes([
            kCTFontNameAttribute: nameFont,
            kCTFontVariationAttribute: [NSNumber(value: 0x77676874): 500]
        ] as CFDictionary)
        return Font(CTFontCreateWithFontDescriptor(descriptor, size, nil))
    }

    static func mono(size: CGFloat) -> Font {
        guard let postScriptName else { return .system(size: size, design: .monospaced) }
        return .custom(postScriptName, fixedSize: size)
    }
}
