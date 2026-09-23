import Darwin

/// A scan decodes megabytes of provider JSON (`brew info --json=v2 --installed` is
/// ~1 MB of text) into short-lived objects. malloc keeps those freed pages dirty,
/// so a long-running app would carry them in its footprint until the next scan.
enum MemoryRelief {
    static func releaseFreedPages() {
        _ = malloc_zone_pressure_relief(nil, 0)
    }
}
