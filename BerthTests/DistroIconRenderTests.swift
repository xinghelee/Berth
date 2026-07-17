import SwiftUI
import Testing
@testable import Berth

/// 临时快照:把整套发行版图标渲染成 PNG 供人工检查(不做断言)
@MainActor
struct DistroIconRenderTests {
    @Test func renderDistroIconSheet() throws {
        let sheet = VStack(alignment: .leading, spacing: 24) {
            Text("72pt").font(.caption).foregroundStyle(.gray)
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(96)), count: 6), spacing: 16) {
                ForEach(Array(Distro.allCases.enumerated()), id: \.offset) { _, distro in
                    VStack(spacing: 4) {
                        DistroIcon(distro: distro, size: 72)
                        Text(String(describing: distro)).font(.system(size: 10)).foregroundStyle(.white)
                    }
                }
            }
            Text("18pt(侧栏实际尺寸)").font(.caption).foregroundStyle(.gray)
            HStack(spacing: 8) {
                ForEach(Array(Distro.allCases.enumerated()), id: \.offset) { _, distro in
                    DistroIcon(distro: distro, size: 18)
                }
            }
            Text("侧栏行情境").font(.caption).foregroundStyle(.gray)
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Array([Distro.ubuntu, .debian, .alpine, .rhel, .raspbian, .tux].enumerated()), id: \.offset) { index, distro in
                    HStack(spacing: 8) {
                        DistroIcon(distro: distro, size: 18)
                        RoundedRectangle(cornerRadius: 1.5)
                            .fill(index == 0 ? Color.green : Color.gray.opacity(0.18))
                            .frame(width: 3, height: 26)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(String(describing: distro))-server")
                                .font(.system(size: 13.5, weight: .medium)).foregroundStyle(.white)
                            Text("root@192.168.1.\(100 + index)")
                                .font(.system(size: 11)).foregroundStyle(.gray)
                        }
                    }
                    .padding(.vertical, 5)
                    .padding(.horizontal, 10)
                }
            }
        }
        .padding(24)
        .background(Color(red: 0.05, green: 0.08, blue: 0.13))

        let renderer = ImageRenderer(content: sheet)
        renderer.scale = 2
        let image = try #require(renderer.nsImage)
        let tiff = try #require(image.tiffRepresentation)
        let bitmap = try #require(NSBitmapImageRep(data: tiff))
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        try png.write(to: URL(fileURLWithPath: "/tmp/berth-distro-icons.png"))
    }
}
