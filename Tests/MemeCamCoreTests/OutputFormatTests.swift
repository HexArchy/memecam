import Testing
@testable import MemeCamCore

@Test func outputFormatSizes() {
    let sizes = OutputFormat.all.map { "\($0.width)x\($0.height)" }
    #expect(sizes == ["1280x720", "1920x1080", "960x720", "1440x1080", "720x720", "1080x1080"])
    // The extension advertises formats in this order; index 0 must stay the default.
    #expect(OutputFormat.all.first == .default)
    #expect(OutputFormat.default.dimensions == "1280\u{00D7}720")
}

@Test func outputFormatDesignCanvasScalesToOutput() {
    for f in OutputFormat.all {
        #expect(Double(f.designWidth) * f.scale == Double(f.width))
        #expect(Double(OutputFormat.designHeight) * f.scale == Double(f.height))
    }
    #expect(OutputFormat(resolution: .hd1080, aspect: .standard).scale == 1.5)
}

@Test func outputFormatMatchingAndIndexRoundTrip() {
    for (i, f) in OutputFormat.all.enumerated() {
        #expect(f.index == i)
        #expect(OutputFormat.matching(width: f.width, height: f.height) == f)
    }
    #expect(OutputFormat.matching(width: 640, height: 480) == nil)
}
