import SwiftUI

/// 发行版徽章:品牌色圆角块 + 原创简化矢量标志(致敬官方 logo 的几何要素,
/// 不含商标素材)。识别不了的 Linux 用企鹅剪影,macOS 用  符号,未探测用通用图标。
struct OSBadge: View {
    let osName: String

    var body: some View {
        let lower = osName.lowercased()
        if lower.contains("macos") || lower.contains("darwin") {
            Image(systemName: "apple.logo")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 18, height: 18)
                .background(RoundedRectangle(cornerRadius: 5).fill(Color.primary.opacity(0.08)))
        } else if let distro = Distro.match(lower) {
            DistroIcon(distro: distro)
                .help(osName)
        } else if lower.contains("linux") || lower.contains("bsd") {
            DistroIcon(distro: .tux)
                .help(osName)
        } else {
            Image(systemName: "server.rack")
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
                .frame(width: 18, height: 18)
                .background(RoundedRectangle(cornerRadius: 5).fill(Color.primary.opacity(0.06)))
        }
    }
}

enum Distro: CaseIterable {
    case ubuntu, debian, alpine, arch, manjaro, centos, fedora, rhel, rocky, alma
    case suse, amazon, kali, gentoo, nixos, openwrt, raspbian, tux

    static func match(_ lower: String) -> Distro? {
        let table: [(String, Distro)] = [
            ("ubuntu", .ubuntu), ("debian", .debian), ("raspbian", .raspbian), ("raspberry", .raspbian),
            ("alpine", .alpine), ("arch", .arch), ("manjaro", .manjaro), ("centos", .centos),
            ("fedora", .fedora), ("red hat", .rhel), ("rhel", .rhel), ("rocky", .rocky),
            ("alma", .alma), ("suse", .suse), ("amazon", .amazon), ("kali", .kali),
            ("gentoo", .gentoo), ("nixos", .nixos), ("openwrt", .openwrt),
        ]
        return table.first { lower.contains($0.0) }?.1
    }

    var color: Color {
        switch self {
        case .ubuntu: return Color(nsColor: NSColor(hex: "#E95420"))
        case .debian: return Color(nsColor: NSColor(hex: "#A81D33"))
        case .alpine: return Color(nsColor: NSColor(hex: "#0D597F"))
        case .arch: return Color(nsColor: NSColor(hex: "#1793D1"))
        case .manjaro: return Color(nsColor: NSColor(hex: "#35BF5C"))
        case .centos: return Color(nsColor: NSColor(hex: "#932279"))
        case .fedora: return Color(nsColor: NSColor(hex: "#51A2DA"))
        case .rhel: return Color(nsColor: NSColor(hex: "#EE0000"))
        case .rocky: return Color(nsColor: NSColor(hex: "#10B981"))
        case .alma: return Color(nsColor: NSColor(hex: "#2C4A78"))
        case .suse: return Color(nsColor: NSColor(hex: "#73BA25"))
        case .amazon: return Color(nsColor: NSColor(hex: "#FF9900"))
        case .kali: return Color(nsColor: NSColor(hex: "#557C94"))
        case .gentoo: return Color(nsColor: NSColor(hex: "#54487A"))
        case .nixos: return Color(nsColor: NSColor(hex: "#5277C3"))
        case .openwrt: return Color(nsColor: NSColor(hex: "#00B5E2"))
        case .raspbian: return Color(nsColor: NSColor(hex: "#C51A4A"))
        case .tux: return Color(nsColor: NSColor(hex: "#3A3F4A"))
        }
    }
}

/// 单个徽章:色块 + Canvas 矢量白标
struct DistroIcon: View {
    let distro: Distro
    var size: CGFloat = 18

    var body: some View {
        Canvas { context, canvasSize in
            let rect = CGRect(origin: .zero, size: canvasSize)
            DistroIcon.draw(distro, in: rect, context: &context)
        }
        .frame(width: size, height: size)
        .background(RoundedRectangle(cornerRadius: size * 0.28).fill(distro.color))
    }

    // MARK: - 绘制(单位坐标 0-1,白色图形)

    private static func draw(_ distro: Distro, in rect: CGRect, context: inout GraphicsContext) {
        let white = GraphicsContext.Shading.color(.white)
        // 单位坐标 → 画布坐标
        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: rect.minX + x * rect.width, y: rect.minY + y * rect.height)
        }
        func circle(_ cx: CGFloat, _ cy: CGFloat, _ radius: CGFloat) -> Path {
            Path(ellipseIn: CGRect(
                x: rect.minX + (cx - radius) * rect.width,
                y: rect.minY + (cy - radius) * rect.height,
                width: radius * 2 * rect.width,
                height: radius * 2 * rect.height
            ))
        }
        func stroke(_ path: Path, _ lineWidth: CGFloat) {
            context.stroke(path, with: white, style: StrokeStyle(lineWidth: lineWidth * rect.width, lineCap: .round, lineJoin: .round))
        }

        switch distro {
        case .ubuntu:
            // 三点环:圆环开三个缺口,缺口处各一实心点
            let gapAngles: [CGFloat] = [90, 210, 330]
            for base in gapAngles {
                var arc = Path()
                arc.addArc(
                    center: point(0.5, 0.5),
                    radius: 0.24 * rect.width,
                    startAngle: .degrees(base + 26),
                    endAngle: .degrees(base + 94),
                    clockwise: false
                )
                stroke(arc, 0.09)
            }
            for angle in gapAngles {
                let rad = angle * .pi / 180
                context.fill(circle(0.5 + 0.34 * cos(rad), 0.5 + 0.34 * sin(rad), 0.085), with: white)
            }

        case .debian:
            // 螺旋
            var spiral = Path()
            var first = true
            for step in 0...44 {
                let theta = CGFloat(step) / 44 * 2.2 * .pi
                let radius = 0.055 + 0.115 * theta / .pi
                let x = 0.52 + radius * cos(theta - 0.6)
                let y = 0.48 + radius * sin(theta - 0.6)
                if first { spiral.move(to: point(x, y)); first = false }
                else { spiral.addLine(to: point(x, y)) }
            }
            stroke(spiral, 0.09)

        case .alpine:
            // 双峰
            var peaks = Path()
            peaks.move(to: point(0.08, 0.78))
            peaks.addLine(to: point(0.42, 0.22))
            peaks.addLine(to: point(0.62, 0.55))
            peaks.addLine(to: point(0.74, 0.4))
            peaks.addLine(to: point(0.94, 0.78))
            peaks.closeSubpath()
            context.fill(peaks, with: white)

        case .arch:
            // 尖峰(底部内凹)
            var peak = Path()
            peak.move(to: point(0.5, 0.12))
            peak.addLine(to: point(0.9, 0.82))
            peak.addQuadCurve(to: point(0.5, 0.62), control: point(0.68, 0.62))
            peak.addQuadCurve(to: point(0.1, 0.82), control: point(0.32, 0.62))
            peak.closeSubpath()
            context.fill(peak, with: white)

        case .manjaro:
            // 三竖条(右短)
            for (index, height) in [0.66, 0.66, 0.36].enumerated() {
                let x = 0.2 + CGFloat(index) * 0.22
                let bar = Path(roundedRect: CGRect(
                    x: rect.minX + x * rect.width,
                    y: rect.minY + 0.17 * rect.height,
                    width: 0.14 * rect.width,
                    height: height * rect.height
                ), cornerRadius: 0.03 * rect.width)
                context.fill(bar, with: white)
            }

        case .centos:
            // 四方风车:四个旋转 45° 的小方块
            for angle in [0, 90, 180, 270] {
                let rad = CGFloat(angle) * .pi / 180
                let cx = 0.5 + 0.22 * cos(rad)
                let cy = 0.5 + 0.22 * sin(rad)
                var square = Path()
                let radius: CGFloat = 0.13
                square.move(to: point(cx, cy - radius))
                square.addLine(to: point(cx + radius, cy))
                square.addLine(to: point(cx, cy + radius))
                square.addLine(to: point(cx - radius, cy))
                square.closeSubpath()
                context.fill(square, with: white)
            }

        case .fedora:
            // f 字标
            var glyph = Path()
            glyph.move(to: point(0.66, 0.18))
            glyph.addQuadCurve(to: point(0.44, 0.36), control: point(0.44, 0.18))
            glyph.addLine(to: point(0.44, 0.46))
            glyph.move(to: point(0.28, 0.5))
            glyph.addLine(to: point(0.6, 0.5))
            glyph.move(to: point(0.44, 0.46))
            glyph.addLine(to: point(0.44, 0.68))
            glyph.addQuadCurve(to: point(0.3, 0.84), control: point(0.44, 0.84))
            stroke(glyph, 0.1)

        case .rhel:
            // 礼帽:帽冠 + 帽檐
            var crown = Path()
            crown.move(to: point(0.3, 0.56))
            crown.addQuadCurve(to: point(0.7, 0.56), control: point(0.5, 0.1))
            crown.closeSubpath()
            context.fill(crown, with: white)
            let brim = Path(roundedRect: CGRect(
                x: rect.minX + 0.12 * rect.width,
                y: rect.minY + 0.56 * rect.height,
                width: 0.76 * rect.width,
                height: 0.14 * rect.height
            ), cornerRadius: 0.07 * rect.width)
            context.fill(brim, with: white)

        case .rocky:
            // 圆环 + 内嵌山峰
            var ring = Path()
            ring.addArc(center: point(0.5, 0.5), radius: 0.34 * rect.width, startAngle: .degrees(0), endAngle: .degrees(360), clockwise: false)
            stroke(ring, 0.09)
            var mountain = Path()
            mountain.move(to: point(0.28, 0.66))
            mountain.addLine(to: point(0.48, 0.38))
            mountain.addLine(to: point(0.72, 0.66))
            mountain.closeSubpath()
            context.fill(mountain, with: white)

        case .alma:
            // 花点阵:五瓣 + 芯
            for step in 0..<5 {
                let rad = (CGFloat(step) * 72 - 90) * .pi / 180
                context.fill(circle(0.5 + 0.27 * cos(rad), 0.5 + 0.27 * sin(rad), 0.1), with: white)
            }
            context.fill(circle(0.5, 0.5, 0.08), with: white)

        case .suse:
            // 变色龙曲线 + 眼点
            var wave = Path()
            wave.move(to: point(0.14, 0.62))
            wave.addCurve(to: point(0.52, 0.5), control1: point(0.26, 0.78), control2: point(0.4, 0.42))
            wave.addCurve(to: point(0.86, 0.42), control1: point(0.64, 0.58), control2: point(0.76, 0.3))
            stroke(wave, 0.11)
            context.fill(circle(0.78, 0.36, 0.05), with: white)

        case .amazon:
            // 立方体线框(等距)
            var cube = Path()
            cube.move(to: point(0.5, 0.14))
            cube.addLine(to: point(0.84, 0.32))
            cube.addLine(to: point(0.84, 0.66))
            cube.addLine(to: point(0.5, 0.86))
            cube.addLine(to: point(0.16, 0.66))
            cube.addLine(to: point(0.16, 0.32))
            cube.closeSubpath()
            cube.move(to: point(0.16, 0.32))
            cube.addLine(to: point(0.5, 0.5))
            cube.addLine(to: point(0.84, 0.32))
            cube.move(to: point(0.5, 0.5))
            cube.addLine(to: point(0.5, 0.86))
            stroke(cube, 0.075)

        case .kali:
            // K 字标
            var glyph = Path()
            glyph.move(to: point(0.3, 0.16))
            glyph.addLine(to: point(0.3, 0.84))
            glyph.move(to: point(0.72, 0.16))
            glyph.addLine(to: point(0.32, 0.52))
            glyph.addLine(to: point(0.74, 0.84))
            stroke(glyph, 0.11)

        case .gentoo:
            // 卵石 G:月牙开口 + 内点
            var pebble = Path()
            pebble.addArc(center: point(0.5, 0.5), radius: 0.32 * rect.width, startAngle: .degrees(300), endAngle: .degrees(210), clockwise: false)
            stroke(pebble, 0.12)
            context.fill(circle(0.56, 0.42, 0.07), with: white)

        case .nixos:
            // 六向雪花(短臂折线)
            for step in 0..<6 {
                let rad = (CGFloat(step) * 60 + 30) * .pi / 180
                var arm = Path()
                arm.move(to: point(0.5 + 0.1 * cos(rad), 0.5 + 0.1 * sin(rad)))
                arm.addLine(to: point(0.5 + 0.36 * cos(rad), 0.5 + 0.36 * sin(rad)))
                stroke(arm, 0.08)
            }

        case .openwrt:
            // WiFi 弧 + 底点
            for (radius, span) in [(0.34, 46.0), (0.22, 52.0)] {
                var arc = Path()
                arc.addArc(
                    center: point(0.5, 0.78),
                    radius: radius * rect.width,
                    startAngle: .degrees(270 - span),
                    endAngle: .degrees(270 + span),
                    clockwise: false
                )
                stroke(arc, 0.09)
            }
            context.fill(circle(0.5, 0.74, 0.07), with: white)

        case .raspbian:
            // 浆果 + 双叶
            context.fill(circle(0.38, 0.55, 0.16), with: white)
            context.fill(circle(0.62, 0.55, 0.16), with: white)
            context.fill(circle(0.5, 0.72, 0.16), with: white)
            var leaf1 = Path()
            leaf1.move(to: point(0.5, 0.34))
            leaf1.addQuadCurve(to: point(0.26, 0.16), control: point(0.28, 0.34))
            leaf1.addQuadCurve(to: point(0.5, 0.34), control: point(0.48, 0.16))
            context.fill(leaf1, with: white)
            var leaf2 = Path()
            leaf2.move(to: point(0.5, 0.34))
            leaf2.addQuadCurve(to: point(0.74, 0.16), control: point(0.72, 0.34))
            leaf2.addQuadCurve(to: point(0.5, 0.34), control: point(0.52, 0.16))
            context.fill(leaf2, with: white)

        case .tux:
            // 企鹅剪影:头 + 蛋身,肚皮镂空
            context.fill(circle(0.5, 0.28, 0.16), with: white)
            var body = Path()
            body.addEllipse(in: CGRect(
                x: rect.minX + 0.24 * rect.width,
                y: rect.minY + 0.3 * rect.height,
                width: 0.52 * rect.width,
                height: 0.58 * rect.height
            ))
            context.fill(body, with: white)
            var belly = Path()
            belly.addEllipse(in: CGRect(
                x: rect.minX + 0.36 * rect.width,
                y: rect.minY + 0.5 * rect.height,
                width: 0.28 * rect.width,
                height: 0.32 * rect.height
            ))
            context.fill(belly, with: .color(Distro.tux.color))
        }
    }
}

#Preview("发行版图标一览") {
    LazyVGrid(columns: Array(repeating: GridItem(.fixed(40)), count: 6), spacing: 12) {
        ForEach(Array(Distro.allCases.enumerated()), id: \.offset) { _, distro in
            DistroIcon(distro: distro, size: 32)
        }
    }
    .padding(20)
    .background(Color.black)
}
