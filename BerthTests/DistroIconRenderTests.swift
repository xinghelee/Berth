import SwiftUI
import Testing
@testable import Berth

/// 临时快照:把整套发行版图标渲染成 PNG 供人工检查(不做断言)
@MainActor
struct DistroIconRenderTests {
    @Test func renderDistroIconSheet() throws {
        let grid = LazyVGrid(columns: Array(repeating: GridItem(.fixed(96)), count: 6), spacing: 16) {
            ForEach(Array(Distro.allCases.enumerated()), id: \.offset) { _, distro in
                VStack(spacing: 4) {
                    DistroIcon(distro: distro, size: 72)
                    Text(String(describing: distro)).font(.system(size: 10)).foregroundStyle(.white)
                }
            }
        }
        .padding(24)
        .background(Color(red: 0.05, green: 0.08, blue: 0.13))

        let renderer = ImageRenderer(content: grid)
        renderer.scale = 2
        let image = try #require(renderer.nsImage)
        let tiff = try #require(image.tiffRepresentation)
        let bitmap = try #require(NSBitmapImageRep(data: tiff))
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        try png.write(to: URL(fileURLWithPath: "/tmp/berth-distro-icons.png"))
    }
}
