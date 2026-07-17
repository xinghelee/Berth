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
    // 虚拟化 / 软路由 / NAS
    case proxmox, immortalwrt, istoreos, ikuai, routeros, pfsense, opnsense
    case freebsd, synology, truenas, unraid, vmware

    static func match(_ lower: String) -> Distro? {
        // 顺序即优先级:PVE 的 os-release 是 Debian、TrueNAS 基于 FreeBSD/Debian,
        // 专有系统必须排在通用发行版之前
        let table: [(String, Distro)] = [
            ("proxmox", .proxmox),
            ("immortalwrt", .immortalwrt), ("istoreos", .istoreos), ("ikuai", .ikuai), ("爱快", .ikuai),
            ("routeros", .routeros), ("mikrotik", .routeros),
            ("pfsense", .pfsense), ("opnsense", .opnsense),
            ("truenas", .truenas), ("unraid", .unraid),
            ("synology", .synology), ("dsm", .synology),
            ("vmware", .vmware), ("esxi", .vmware),
            ("openwrt", .openwrt), ("lede", .openwrt),
            ("freebsd", .freebsd),
            ("ubuntu", .ubuntu), ("debian", .debian), ("raspbian", .raspbian), ("raspberry", .raspbian),
            ("alpine", .alpine), ("arch", .arch), ("manjaro", .manjaro), ("centos", .centos),
            ("fedora", .fedora), ("red hat", .rhel), ("rhel", .rhel), ("rocky", .rocky),
            ("alma", .alma), ("suse", .suse), ("amazon", .amazon), ("kali", .kali),
            ("gentoo", .gentoo), ("nixos", .nixos),
        ]
        return table.first { lower.contains($0.0) }?.1
    }

    var baseNSColor: NSColor {
        switch self {
        case .ubuntu: return NSColor(hex: "#E95420")
        case .debian: return NSColor(hex: "#A81D33")
        case .alpine: return NSColor(hex: "#0D597F")
        case .arch: return NSColor(hex: "#1793D1")
        case .manjaro: return NSColor(hex: "#35BF5C")
        case .centos: return NSColor(hex: "#932279")
        case .fedora: return NSColor(hex: "#51A2DA")
        case .rhel: return NSColor(hex: "#E93A3A")
        case .rocky: return NSColor(hex: "#10B981")
        case .alma: return NSColor(hex: "#2C4A78")
        case .suse: return NSColor(hex: "#73BA25")
        case .amazon: return NSColor(hex: "#FF9900")
        case .kali: return NSColor(hex: "#557C94")
        case .gentoo: return NSColor(hex: "#54487A")
        case .nixos: return NSColor(hex: "#5277C3")
        case .openwrt: return NSColor(hex: "#00B5E2")
        case .raspbian: return NSColor(hex: "#C51A4A")
        case .tux: return NSColor(hex: "#3A3F4A")
        case .proxmox: return NSColor(hex: "#E57000")
        case .immortalwrt: return NSColor(hex: "#1F6FB2")
        case .istoreos: return NSColor(hex: "#0AA1DD")
        case .ikuai: return NSColor(hex: "#2A6BE9")
        case .routeros: return NSColor(hex: "#5A6B77")
        case .pfsense: return NSColor(hex: "#1475CF")
        case .opnsense: return NSColor(hex: "#D94F00")
        case .freebsd: return NSColor(hex: "#AB2B28")
        case .synology: return NSColor(hex: "#37474F")
        case .truenas: return NSColor(hex: "#0095D5")
        case .unraid: return NSColor(hex: "#F15A2C")
        case .vmware: return NSColor(hex: "#607078")
        }
    }

    var color: Color { Color(nsColor: baseNSColor) }
}

/// 单个徽章:品牌色渐变底块 + 高光描边 + Canvas 矢量白标(带微投影)
struct DistroIcon: View {
    let distro: Distro
    var size: CGFloat = 18

    var body: some View {
        let radius = size * 0.28
        let top = Color(nsColor: distro.baseNSColor.mixed(with: .white, ratio: 0.16))
        let bottom = Color(nsColor: distro.baseNSColor.mixed(with: .black, ratio: 0.18))
        Canvas { context, canvasSize in
            let rect = CGRect(origin: .zero, size: canvasSize)
            // 图形微投影,增加层次
            context.addFilter(.shadow(
                color: .black.opacity(0.28),
                radius: canvasSize.width * 0.035,
                x: 0,
                y: canvasSize.width * 0.03
            ))
            DistroIcon.draw(distro, in: rect, context: &context)
        }
        .frame(width: size, height: size)
        .background(
            RoundedRectangle(cornerRadius: radius)
                .fill(LinearGradient(colors: [top, bottom], startPoint: .top, endPoint: .bottom))
        )
        .overlay(
            // 顶亮底暗的一圈内描边,模拟打光
            RoundedRectangle(cornerRadius: radius)
                .strokeBorder(
                    LinearGradient(
                        colors: [.white.opacity(0.32), .white.opacity(0.04)],
                        startPoint: .top,
                        endPoint: .bottom
                    ),
                    lineWidth: max(0.5, size / 30)
                )
        )
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
            // 变色龙:圆头(镂空眼)+ 卷尾曲线
            context.fill(circle(0.7, 0.36, 0.12), with: white)
            var tail = Path()
            tail.move(to: point(0.63, 0.46))
            tail.addQuadCurve(to: point(0.4, 0.54), control: point(0.52, 0.68))
            tail.addQuadCurve(to: point(0.16, 0.6), control: point(0.28, 0.4))
            stroke(tail, 0.1)
            context.blendMode = .destinationOut
            context.fill(circle(0.73, 0.33, 0.04), with: .color(.black))
            context.blendMode = .normal

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
            // 勾玉 G:右下开口的月牙 + 上部内点
            var pebble = Path()
            pebble.addArc(center: point(0.5, 0.5), radius: 0.3 * rect.width, startAngle: .degrees(320), endAngle: .degrees(240), clockwise: false)
            stroke(pebble, 0.13)
            context.fill(circle(0.58, 0.4, 0.075), with: white)

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
            // 企鹅:头身一体剪影,肚皮向下开口镂空,双眼镂空
            var silhouette = Path()
            silhouette.addEllipse(in: CGRect(
                x: rect.minX + 0.34 * rect.width,
                y: rect.minY + 0.1 * rect.height,
                width: 0.32 * rect.width,
                height: 0.32 * rect.height
            ))
            silhouette.addEllipse(in: CGRect(
                x: rect.minX + 0.22 * rect.width,
                y: rect.minY + 0.28 * rect.height,
                width: 0.56 * rect.width,
                height: 0.64 * rect.height
            ))
            context.fill(silhouette, with: white)
            context.blendMode = .destinationOut
            var belly = Path()
            belly.addEllipse(in: CGRect(
                x: rect.minX + 0.36 * rect.width,
                y: rect.minY + 0.54 * rect.height,
                width: 0.28 * rect.width,
                height: 0.44 * rect.height
            ))
            context.fill(belly, with: .color(.black))
            context.fill(circle(0.45, 0.23, 0.035), with: .color(.black))
            context.fill(circle(0.55, 0.23, 0.035), with: .color(.black))
            context.blendMode = .normal

        case .proxmox:
            // 虚拟化 2×2 方块格
            for (cx, cy) in [(0.34, 0.34), (0.66, 0.34), (0.34, 0.66), (0.66, 0.66)] {
                let square = Path(roundedRect: CGRect(
                    x: rect.minX + (cx - 0.13) * rect.width,
                    y: rect.minY + (cy - 0.13) * rect.height,
                    width: 0.26 * rect.width,
                    height: 0.26 * rect.height
                ), cornerRadius: 0.05 * rect.width)
                context.fill(square, with: white)
            }

        case .immortalwrt:
            // 无限环 ∞
            var loop = Path()
            loop.addEllipse(in: CGRect(
                x: rect.minX + 0.14 * rect.width, y: rect.minY + 0.36 * rect.height,
                width: 0.32 * rect.width, height: 0.28 * rect.height
            ))
            loop.addEllipse(in: CGRect(
                x: rect.minX + 0.54 * rect.width, y: rect.minY + 0.36 * rect.height,
                width: 0.32 * rect.width, height: 0.28 * rect.height
            ))
            stroke(loop, 0.09)

        case .istoreos:
            // 店面:扇贝雨棚 + 门脸
            for (index, cx) in [0.32, 0.5, 0.68].enumerated() {
                _ = index
                context.fill(circle(cx, 0.34, 0.1), with: white)
            }
            let facade = Path(roundedRect: CGRect(
                x: rect.minX + 0.24 * rect.width,
                y: rect.minY + 0.34 * rect.height,
                width: 0.52 * rect.width,
                height: 0.42 * rect.height
            ), cornerRadius: 0.04 * rect.width)
            context.fill(facade, with: white)
            context.blendMode = .destinationOut
            let door = Path(roundedRect: CGRect(
                x: rect.minX + 0.42 * rect.width,
                y: rect.minY + 0.52 * rect.height,
                width: 0.16 * rect.width,
                height: 0.24 * rect.height
            ), cornerRadius: 0.03 * rect.width)
            context.fill(door, with: .color(.black))
            context.blendMode = .normal

        case .ikuai:
            // 仪表盘:半弧 + 指针(快)
            var dial = Path()
            dial.addArc(center: point(0.5, 0.64), radius: 0.32 * rect.width, startAngle: .degrees(180), endAngle: .degrees(360), clockwise: false)
            stroke(dial, 0.09)
            var needle = Path()
            needle.move(to: point(0.5, 0.64))
            needle.addLine(to: point(0.7, 0.4))
            stroke(needle, 0.08)
            context.fill(circle(0.5, 0.64, 0.06), with: white)

        case .routeros:
            // 路由器:机身 + 双天线
            let chassis = Path(roundedRect: CGRect(
                x: rect.minX + 0.18 * rect.width,
                y: rect.minY + 0.52 * rect.height,
                width: 0.64 * rect.width,
                height: 0.26 * rect.height
            ), cornerRadius: 0.06 * rect.width)
            context.fill(chassis, with: white)
            var antennas = Path()
            antennas.move(to: point(0.34, 0.52))
            antennas.addLine(to: point(0.26, 0.22))
            antennas.move(to: point(0.66, 0.52))
            antennas.addLine(to: point(0.74, 0.22))
            stroke(antennas, 0.07)
            context.fill(circle(0.26, 0.2, 0.045), with: white)
            context.fill(circle(0.74, 0.2, 0.045), with: white)

        case .pfsense:
            // 盾牌描边 + 芯点
            var shield = Path()
            shield.move(to: point(0.5, 0.12))
            shield.addLine(to: point(0.82, 0.26))
            shield.addLine(to: point(0.78, 0.58))
            shield.addLine(to: point(0.5, 0.88))
            shield.addLine(to: point(0.22, 0.58))
            shield.addLine(to: point(0.18, 0.26))
            shield.closeSubpath()
            stroke(shield, 0.08)
            context.fill(circle(0.5, 0.44, 0.08), with: white)

        case .opnsense:
            // 实心盾牌 + 镂空斜杠
            var shield = Path()
            shield.move(to: point(0.5, 0.12))
            shield.addLine(to: point(0.82, 0.26))
            shield.addLine(to: point(0.78, 0.58))
            shield.addLine(to: point(0.5, 0.88))
            shield.addLine(to: point(0.22, 0.58))
            shield.addLine(to: point(0.18, 0.26))
            shield.closeSubpath()
            context.fill(shield, with: white)
            context.blendMode = .destinationOut
            var slash = Path()
            slash.move(to: point(0.32, 0.6))
            slash.addLine(to: point(0.66, 0.3))
            context.stroke(slash, with: .color(.black), style: StrokeStyle(lineWidth: 0.1 * rect.width, lineCap: .round))
            context.blendMode = .normal

        case .freebsd:
            // 三叉戟
            var trident = Path()
            trident.move(to: point(0.32, 0.16))
            trident.addLine(to: point(0.32, 0.38))
            trident.move(to: point(0.5, 0.12))
            trident.addLine(to: point(0.5, 0.42))
            trident.move(to: point(0.68, 0.16))
            trident.addLine(to: point(0.68, 0.38))
            trident.move(to: point(0.32, 0.38))
            trident.addQuadCurve(to: point(0.68, 0.38), control: point(0.5, 0.52))
            trident.move(to: point(0.5, 0.46))
            trident.addLine(to: point(0.5, 0.86))
            stroke(trident, 0.08)

        case .synology:
            // NAS 机箱:外框 + 两道盘位 + 指示灯
            let chassis = Path(roundedRect: CGRect(
                x: rect.minX + 0.24 * rect.width,
                y: rect.minY + 0.18 * rect.height,
                width: 0.52 * rect.width,
                height: 0.64 * rect.height
            ), cornerRadius: 0.06 * rect.width)
            stroke(chassis, 0.07)
            var slots = Path()
            slots.move(to: point(0.34, 0.36))
            slots.addLine(to: point(0.66, 0.36))
            slots.move(to: point(0.34, 0.5))
            slots.addLine(to: point(0.66, 0.5))
            stroke(slots, 0.06)
            context.fill(circle(0.6, 0.68, 0.045), with: white)

        case .truenas:
            // 双波浪(存储之海)
            for y in [0.42, 0.62] {
                var wave = Path()
                wave.move(to: point(0.16, y))
                wave.addCurve(to: point(0.5, y), control1: point(0.27, y - 0.14), control2: point(0.39, y + 0.14))
                wave.addCurve(to: point(0.84, y), control1: point(0.61, y - 0.14), control2: point(0.73, y + 0.14))
                stroke(wave, 0.08)
            }

        case .unraid:
            // 错落竖条(中高旁低)
            for (index, (height, offset)) in [(0.3, 0.35), (0.56, 0.22), (0.3, 0.35)].enumerated() {
                let x = 0.3 + CGFloat(index) * 0.17
                let bar = Path(roundedRect: CGRect(
                    x: rect.minX + (x - 0.05) * rect.width,
                    y: rect.minY + offset * rect.height,
                    width: 0.1 * rect.width,
                    height: height * rect.height
                ), cornerRadius: 0.04 * rect.width)
                context.fill(bar, with: white)
            }

        case .vmware:
            // 双层虚拟机:两个错位方框
            let back = Path(roundedRect: CGRect(
                x: rect.minX + 0.3 * rect.width,
                y: rect.minY + 0.18 * rect.height,
                width: 0.5 * rect.width,
                height: 0.5 * rect.height
            ), cornerRadius: 0.06 * rect.width)
            stroke(back, 0.07)
            let front = Path(roundedRect: CGRect(
                x: rect.minX + 0.18 * rect.width,
                y: rect.minY + 0.34 * rect.height,
                width: 0.5 * rect.width,
                height: 0.5 * rect.height
            ), cornerRadius: 0.06 * rect.width)
            context.blendMode = .destinationOut
            context.fill(front, with: .color(.black))
            context.blendMode = .normal
            stroke(front, 0.07)
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
