import AppKit
import Combine

/// 站点图标的异步加载与缓存，用于菜单栏按钮显示。
@MainActor
final class FaviconCache: ObservableObject {
    static let shared = FaviconCache()

    /// 只通知真正发生变化的站点，避免一个图标完成加载时重绘全部状态栏图标。
    let imageDidChange = PassthroughSubject<UUID, Never>()

    private var images: [UUID: NSImage] = [:]
    private var sourceURLs: [UUID: String] = [:]
    private var failedIDs = Set<UUID>()
    private var loading = Set<UUID>()
    private var generations: [UUID: UUID] = [:]
    private var tasks: [UUID: Task<Void, Never>] = [:]

    func image(for pin: Pin) -> NSImage? {
        if let cached = images[pin.id] { return cached }
        loadIfNeeded(pin)
        return nil
    }

    /// 页面声明了新图标时后台刷新；保留当前图标直到新图标加载成功，避免菜单栏闪烁。
    func refresh(pinID: UUID) {
        guard let pin = PinStore.shared.preset(with: pinID) else { return }
        if let url = URL(string: pin.iconURLString),
           sourceURLs[pinID] == url.absoluteString,
           images[pinID] != nil {
            return
        }
        failedIDs.remove(pinID)
        generations[pinID] = nil
        loading.remove(pinID)
        tasks[pinID]?.cancel()
        tasks[pinID] = nil
        loadIfNeeded(pin)
    }

    /// WebView 已拿到页面声明的全部候选时按优先级尝试，成功前不改持久化地址。
    func refresh(pinID: UUID, candidateURLStrings: [String]) {
        guard let pin = PinStore.shared.preset(with: pinID) else { return }
        let urls = Self.uniqueURLs(candidateURLStrings.compactMap(URL.init(string:)))
        guard !urls.isEmpty else { return }
        if let sourceURL = sourceURLs[pinID], images[pinID] != nil,
           urls.contains(where: { $0.absoluteString == sourceURL }) {
            return
        }

        failedIDs.remove(pinID)
        generations[pinID] = nil
        loading.remove(pinID)
        tasks[pinID]?.cancel()
        tasks[pinID] = nil

        let generation = UUID()
        generations[pinID] = generation
        let fallbackURL = URL(string: "https://\(pin.host)")?.appendingPathComponent("favicon.ico")
        fetchChain(pinID, urls: urls, generation: generation,
                   pageURL: nil, fallbackURL: fallbackURL)
    }

    private func loadIfNeeded(_ pin: Pin) {
        guard !loading.contains(pin.id), !failedIDs.contains(pin.id) else { return }
        var candidates: [URL] = []
        if !pin.iconURLString.isEmpty, let url = URL(string: pin.iconURLString) {
            candidates.append(url)
        }
        let fallbackURL = URL(string: "https://\(pin.host)")?.appendingPathComponent("favicon.ico")
        let generation = UUID()
        generations[pin.id] = generation
        fetchChain(pin.id, urls: candidates, generation: generation,
                   pageURL: pin.url, fallbackURL: fallbackURL)
    }

    private func fetchChain(_ id: UUID, urls: [URL], generation: UUID,
                            pageURL: URL?, fallbackURL: URL?) {
        guard generations[id] == generation else { return }
        guard let url = urls.first else {
            if let pageURL {
                discoverIcon(id: id, pageURL: pageURL, generation: generation,
                             fallbackURL: fallbackURL)
            } else if let fallbackURL {
                fetchChain(id, urls: [fallbackURL], generation: generation,
                           pageURL: nil, fallbackURL: nil)
            } else {
                markFailed(id)
            }
            return
        }
        loading.insert(id)
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        tasks[id] = Task { [weak self] in
            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                guard !Task.isCancelled,
                      let self,
                      self.generations[id] == generation else { return }
                self.loading.remove(id)
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                let ok = (200..<300).contains(status)
                if data.count <= 2 * 1024 * 1024, ok,
                   let image = Self.renderedIcon(from: data, url: url) {
                    self.images[id] = image
                    self.sourceURLs[id] = url.absoluteString
                    self.imageDidChange.send(id)
                    PinStore.shared.setIconURL(url.absoluteString, for: id)
                    self.generations[id] = nil
                    self.tasks[id] = nil
                } else {
                    self.fetchChain(id, urls: Array(urls.dropFirst()), generation: generation,
                                    pageURL: pageURL, fallbackURL: fallbackURL)
                }
            } catch {
                guard !Task.isCancelled,
                      let self,
                      self.generations[id] == generation else { return }
                self.loading.remove(id)
                self.fetchChain(id, urls: Array(urls.dropFirst()), generation: generation,
                                pageURL: pageURL, fallbackURL: fallbackURL)
            }
        }
    }

    /// 新站点尚未创建 WebView 时，直接读取首页 HTML 并发现 link[rel~=icon]。
    private func discoverIcon(id: UUID, pageURL: URL, generation: UUID, fallbackURL: URL?) {
        guard generations[id] == generation else { return }
        loading.insert(id)
        var request = URLRequest(url: pageURL)
        request.timeoutInterval = 15
        request.setValue("text/html,application/xhtml+xml", forHTTPHeaderField: "Accept")
        tasks[id] = Task { [weak self] in
            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                guard !Task.isCancelled,
                      let self,
                      self.generations[id] == generation else { return }
                self.loading.remove(id)
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                guard (200..<300).contains(status), data.count <= 2 * 1024 * 1024,
                      !Self.iconURLs(fromHTML: data, baseURL: pageURL).isEmpty else {
                    if let fallbackURL {
                        self.fetchChain(id, urls: [fallbackURL], generation: generation,
                                        pageURL: nil, fallbackURL: nil)
                    } else {
                        self.markFailed(id)
                    }
                    return
                }
                let iconURLs = Self.iconURLs(fromHTML: data, baseURL: pageURL)
                self.fetchChain(id, urls: iconURLs, generation: generation,
                                pageURL: nil, fallbackURL: fallbackURL)
            } catch {
                guard !Task.isCancelled,
                      let self,
                      self.generations[id] == generation else { return }
                self.loading.remove(id)
                if let fallbackURL {
                    self.fetchChain(id, urls: [fallbackURL], generation: generation,
                                    pageURL: nil, fallbackURL: nil)
                } else {
                    self.markFailed(id)
                }
            }
        }
    }

    private func markFailed(_ id: UUID) {
        failedIDs.insert(id)
        generations[id] = nil
        tasks[id] = nil
        loading.remove(id)
    }

    static func iconURL(fromHTML data: Data, baseURL: URL) -> URL? {
        iconURLs(fromHTML: data, baseURL: baseURL).first
    }

    static func iconURLs(fromHTML data: Data, baseURL: URL) -> [URL] {
        guard let html = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else {
            return []
        }
        let linkPattern = #"<link\b[^>]*>"#
        guard let regex = try? NSRegularExpression(pattern: linkPattern, options: [.caseInsensitive]) else {
            return []
        }
        let range = NSRange(html.startIndex..., in: html)
        var candidates: [(score: Int, order: Int, url: URL)] = []
        for match in regex.matches(in: html, range: range) {
            guard let tagRange = Range(match.range, in: html) else { continue }
            let tag = String(html[tagRange])
            guard let rel = attribute("rel", in: tag)?.lowercased(),
                  isPageTabIconRel(rel),
                  let href = attribute("href", in: tag),
                  let url = URL(string: href, relativeTo: baseURL)?.absoluteURL else { continue }
            let score = iconScore(rel: rel,
                                  sizes: attribute("sizes", in: tag),
                                  type: attribute("type", in: tag),
                                  url: url)
            candidates.append((score, candidates.count, url))
        }
        let sorted = candidates.sorted {
            $0.score == $1.score ? $0.order < $1.order : $0.score > $1.score
        }
        return uniqueURLs(sorted.map(\.url))
    }

    private static func iconScore(rel: String, sizes: String?, type: String?, url: URL) -> Int {
        let tokens = rel.split(whereSeparator: { $0.isWhitespace })
        var score = tokens.contains("icon") ? 100 : 20
        if rel.contains("shortcut") { score += 5 }
        if type?.lowercased().contains("svg") == true || url.pathExtension.lowercased() == "svg" {
            score -= 25
        } else {
            score += 10
        }
        if sizes?.lowercased() == "any" {
            score += 20
        } else if let sizes,
                  let first = sizes.split(separator: " ").first,
                  let width = Int(first.split(separator: "x").first ?? "") {
            score += max(0, 20 - abs(width - 32))
        }
        return score
    }

    private static func uniqueURLs(_ urls: [URL]) -> [URL] {
        var seen = Set<String>()
        return urls.filter { seen.insert($0.absoluteString).inserted }
    }

    /// Safari 的 mask-icon 是工具栏用单色图，不能替代页面 Tab favicon。
    private static func isPageTabIconRel(_ rel: String) -> Bool {
        let tokens = rel.split(whereSeparator: { $0.isWhitespace })
        return tokens.contains("icon") || tokens.contains("apple-touch-icon")
    }

    private static func attribute(_ name: String, in tag: String) -> String? {
        let pattern = "\\b\(NSRegularExpression.escapedPattern(for: name))\\s*=\\s*([\\\"'])(.*?)\\1"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let match = regex.firstMatch(in: tag, range: NSRange(tag.startIndex..., in: tag)),
              let valueRange = Range(match.range(at: 2), in: tag) else { return nil }
        return String(tag[valueRange])
    }

    /// 返回真正含可见像素的 18px 图标；AppKit 接受但无法绘制的 SVG 不算成功。
    static func renderedIcon(from data: Data, url: URL) -> NSImage? {
        if let raw = NSImage(data: data) {
            let image = resized(raw, to: 18)
            if hasVisiblePixels(image) { return image }
        }

        guard isSVG(data: data, url: url),
              let normalized = normalizedSVGData(data),
              let raw = NSImage(data: normalized) else { return nil }
        let image = resized(raw, to: 18)
        guard hasVisiblePixels(image) else { return nil }
        // 这类 SVG 依靠明暗主题切换单色填充，让菜单栏按系统外观着色。
        image.isTemplate = true
        return image
    }

    static func hasVisiblePixels(_ image: NSImage) -> Bool {
        guard let data = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: data) else { return false }
        for y in 0..<bitmap.pixelsHigh {
            for x in 0..<bitmap.pixelsWide {
                if (bitmap.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.01 {
                    return true
                }
            }
        }
        return false
    }

    private static func isSVG(data: Data, url: URL) -> Bool {
        url.pathExtension.lowercased() == "svg"
            || String(data: data.prefix(512), encoding: .utf8)?.range(
                of: #"<svg\b"#, options: [.regularExpression, .caseInsensitive]
            ) != nil
    }

    /// `_NSSVGImageRep` 不执行部分根级 CSS；把 :root 的 fill 写回 svg 根节点。
    private static func normalizedSVGData(_ data: Data) -> Data? {
        guard var svg = String(data: data, encoding: .utf8),
              let rootRegex = try? NSRegularExpression(
                pattern: #":root\s*\{[^}]*\bfill\s*:\s*([^;}\s]+)"#,
                options: [.caseInsensitive]
              ),
              let rootMatch = rootRegex.firstMatch(
                in: svg, range: NSRange(svg.startIndex..., in: svg)
              ),
              let fillRange = Range(rootMatch.range(at: 1), in: svg) else { return nil }

        var fill = String(svg[fillRange])
        if fill.lowercased() == "currentcolor" { fill = "#000000" }
        guard fill.hasPrefix("#") || fill.lowercased().hasPrefix("rgb") else { return nil }

        guard let openingRegex = try? NSRegularExpression(
            pattern: #"<svg\b[^>]*>"#, options: [.caseInsensitive]
        ), let openingMatch = openingRegex.firstMatch(
            in: svg, range: NSRange(svg.startIndex..., in: svg)
        ), let openingRange = Range(openingMatch.range, in: svg) else { return nil }

        var opening = String(svg[openingRange])
        if let fillRegex = try? NSRegularExpression(
            pattern: #"\bfill\s*=\s*([\"'])[^\"']*\1"#, options: [.caseInsensitive]
        ), fillRegex.firstMatch(
            in: opening, range: NSRange(opening.startIndex..., in: opening)
        ) != nil {
            opening = fillRegex.stringByReplacingMatches(
                in: opening,
                range: NSRange(opening.startIndex..., in: opening),
                withTemplate: "fill=\"\(fill)\""
            )
        } else if let end = opening.lastIndex(of: ">") {
            opening.insert(contentsOf: " fill=\"\(fill)\"", at: end)
        }
        svg.replaceSubrange(openingRange, with: opening)
        svg = svg.replacingOccurrences(of: "currentColor", with: fill,
                                       options: .caseInsensitive)
        return Data(svg.utf8)
    }

    private static func resized(_ image: NSImage, to side: CGFloat) -> NSImage {
        let target = NSSize(width: side, height: side)
        let result = NSImage(size: target)
        result.lockFocus()
        image.draw(in: NSRect(origin: .zero, size: target),
                   from: .zero,
                   operation: .sourceOver,
                   fraction: 1.0)
        result.unlockFocus()
        result.isTemplate = false
        return result
    }

    /// 不缩放内容、不加底板，仅裁掉 favicon 的四个直角。
    static func roundedTabIcon(from source: NSImage, side: CGFloat) -> NSImage {
        let result = NSImage(size: NSSize(width: side, height: side))
        let iconRect = NSRect(x: 0, y: 0, width: side, height: side)
        let cornerRadius = side * 0.22
        let clipPath = NSBezierPath(roundedRect: iconRect,
                                    xRadius: cornerRadius, yRadius: cornerRadius)

        result.lockFocus()
        NSGraphicsContext.current?.saveGraphicsState()
        NSGraphicsContext.current?.imageInterpolation = .high
        clipPath.addClip()
        source.draw(in: iconRect, from: .zero,
                    operation: .sourceOver, fraction: 1.0,
                    respectFlipped: true, hints: nil)
        NSGraphicsContext.current?.restoreGraphicsState()
        result.unlockFocus()
        result.isTemplate = source.isTemplate
        return result
    }

    /// 无 favicon 时的占位图标：首字母色块。
    static func placeholder(for pin: Pin) -> NSImage {
        let side: CGFloat = 18
        let image = NSImage(size: NSSize(width: side, height: side))
        image.lockFocus()

        let colors: [NSColor] = [.systemBlue, .systemGreen, .systemOrange,
                                 .systemPurple, .systemPink, .systemTeal, .systemIndigo]
        let index = abs(pin.host.hashValue) % colors.count
        let color = colors[index]

        let rect = NSRect(x: 1.5, y: 1.5, width: side - 3, height: side - 3)
        color.withAlphaComponent(0.9).setFill()
        NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4).fill()

        let letter = String((pin.name.isEmpty ? pin.host : pin.name).prefix(1)).uppercased()
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 10, weight: .semibold),
            .foregroundColor: NSColor.white,
        ]
        let str = NSAttributedString(string: letter, attributes: attrs)
        let size = str.size()
        str.draw(at: NSPoint(x: (side - size.width) / 2, y: (side - size.height) / 2))

        image.unlockFocus()
        return image
    }
}
