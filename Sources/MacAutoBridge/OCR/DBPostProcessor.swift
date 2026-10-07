import CoreGraphics
import Accelerate

// @beacon: db-post-processor — Differentiable Binarization post-processing for PP-OCR detection

/// A detected text region with 4 corner points and a confidence score.
struct TextBox {
    let points: [CGPoint]  // 4 corners, clockwise from top-left
    let score: Float
}

struct DBPostProcessor {

    /// Process detection model probability map into text boxes.
    /// - Parameters:
    ///   - probMap: Float array [height * width] from sigmoid output.
    ///   - width: Width of the probability map.
    ///   - height: Height of the probability map.
    ///   - srcWidth: Original source image width (for coordinate mapping).
    ///   - srcHeight: Original source image height (for coordinate mapping).
    ///   - boxThresh: Binarization threshold (pixels > this become foreground).
    ///   - boxScoreThresh: Minimum mean score inside a box to keep it.
    ///   - unClipRatio: Expansion ratio for unclip operation.
    /// - Returns: Array of detected TextBox regions in source image coordinates.
    static func process(
        probMap: [Float],
        width: Int,
        height: Int,
        srcWidth: Int,
        srcHeight: Int,
        boxThresh: Float = 0.3,
        boxScoreThresh: Float = 0.6,
        unClipRatio: Float = 1.6
    ) -> [TextBox] {
        // Step 1: Binarize
        var binaryMap = [UInt8](repeating: 0, count: width * height)
        for i in 0..<probMap.count {
            binaryMap[i] = probMap[i] > boxThresh ? 255 : 0
        }

        // Step 2: Dilate with 3x3 kernel
        dilate(&binaryMap, width: width, height: height)

        // Step 3: Connected components labeling
        let components = connectedComponents(binaryMap: binaryMap, width: width, height: height)

        // Step 4: For each component, compute minAreaRect, score, unclip, and map to source coords
        let scaleX = Float(srcWidth) / Float(width)
        let scaleY = Float(srcHeight) / Float(height)

        var boxes: [TextBox] = []

        for component in components {
            guard component.count >= 10 else { continue }  // Skip tiny components

            // Compute bounding box score on original probMap
            let score = boxScore(probMap: probMap, width: width, points: component)
            guard score >= boxScoreThresh else { continue }

            // Compute minimum area rotated rectangle
            guard let rect = minAreaRect(points: component) else { continue }

            // Unclip: expand the rectangle
            let expanded = unClip(rect: rect, ratio: unClipRatio)

            // Map corners to source image coordinates
            let mappedPoints = expanded.map { pt in
                CGPoint(x: CGFloat(Float(pt.x) * scaleX), y: CGFloat(Float(pt.y) * scaleY))
            }

            // Clip to source image bounds
            let clipped = mappedPoints.map { pt in
                CGPoint(
                    x: max(0, min(CGFloat(srcWidth - 1), pt.x)),
                    y: max(0, min(CGFloat(srcHeight - 1), pt.y))
                )
            }

            boxes.append(TextBox(points: clipped, score: score))
        }

        return boxes
    }

    // MARK: - Dilation

    /// 3x3 binary dilation (max filter).
    private static func dilate(_ map: inout [UInt8], width: Int, height: Int) {
        let src = map  // Copy for reading
        for y in 0..<height {
            for x in 0..<width {
                if src[y * width + x] == 255 { continue }  // Already foreground
                var found = false
                for dy in -1...1 {
                    for dx in -1...1 {
                        let nx = x + dx
                        let ny = y + dy
                        if nx >= 0 && nx < width && ny >= 0 && ny < height {
                            if src[ny * width + nx] == 255 {
                                found = true
                                break
                            }
                        }
                    }
                    if found { break }
                }
                if found {
                    map[y * width + x] = 255
                }
            }
        }
    }

    // MARK: - Connected Components (Flood Fill)

    /// Find connected components via flood fill. Returns array of point-sets (each point = (x, y) in map coords).
    private static func connectedComponents(binaryMap: [UInt8], width: Int, height: Int) -> [[CGPoint]] {
        var visited = [Bool](repeating: false, count: width * height)
        var components: [[CGPoint]] = []

        for y in 0..<height {
            for x in 0..<width {
                let idx = y * width + x
                guard binaryMap[idx] == 255 && !visited[idx] else { continue }

                // BFS flood fill
                var queue: [(Int, Int)] = [(x, y)]
                var head = 0
                var points: [CGPoint] = []
                visited[idx] = true

                while head < queue.count {
                    let (cx, cy) = queue[head]
                    head += 1
                    points.append(CGPoint(x: cx, y: cy))

                    for (dx, dy) in [(-1, 0), (1, 0), (0, -1), (0, 1)] {
                        let nx = cx + dx
                        let ny = cy + dy
                        guard nx >= 0 && nx < width && ny >= 0 && ny < height else { continue }
                        let nIdx = ny * width + nx
                        guard binaryMap[nIdx] == 255 && !visited[nIdx] else { continue }
                        visited[nIdx] = true
                        queue.append((nx, ny))
                    }
                }

                // Only keep components with enough pixels to form a meaningful text region
                if points.count >= 10 {
                    components.append(points)
                }
            }
        }

        return components
    }

    // MARK: - Box Score

    /// Mean of probMap values inside the component's bounding box (approximation of box score).
    private static func boxScore(probMap: [Float], width: Int, points: [CGPoint]) -> Float {
        var sum: Float = 0
        var count = 0
        for pt in points {
            let idx = Int(pt.y) * width + Int(pt.x)
            if idx >= 0 && idx < probMap.count {
                sum += probMap[idx]
                count += 1
            }
        }
        return count > 0 ? sum / Float(count) : 0
    }

    // MARK: - Minimum Area Rotated Rectangle

    /// Compute the minimum area bounding rectangle for a set of points using rotating calipers.
    /// Returns 4 corner points in clockwise order, or nil if insufficient points.
    private static func minAreaRect(points: [CGPoint]) -> [CGPoint]? {
        let hull = convexHull(points: points)
        guard hull.count >= 3 else {
            // Degenerate: use axis-aligned bounding box
            return axisAlignedRect(points: points)
        }

        var minArea: CGFloat = .greatestFiniteMagnitude
        var bestRect: [CGPoint]?

        let n = hull.count
        for i in 0..<n {
            let j = (i + 1) % n
            let edgeX = hull[j].x - hull[i].x
            let edgeY = hull[j].y - hull[i].y
            let edgeLen = sqrt(edgeX * edgeX + edgeY * edgeY)
            guard edgeLen > 0 else { continue }

            // Unit vector along edge and perpendicular
            let ux = edgeX / edgeLen
            let uy = edgeY / edgeLen
            let vx = -uy
            let vy = ux

            // Project all hull points onto edge direction (u) and perpendicular (v)
            var minU: CGFloat = .greatestFiniteMagnitude
            var maxU: CGFloat = -.greatestFiniteMagnitude
            var minV: CGFloat = .greatestFiniteMagnitude
            var maxV: CGFloat = -.greatestFiniteMagnitude

            for p in hull {
                let dx = p.x - hull[i].x
                let dy = p.y - hull[i].y
                let projU = dx * ux + dy * uy
                let projV = dx * vx + dy * vy
                minU = min(minU, projU)
                maxU = max(maxU, projU)
                minV = min(minV, projV)
                maxV = max(maxV, projV)
            }

            let area = (maxU - minU) * (maxV - minV)
            if area < minArea {
                minArea = area
                // Reconstruct 4 corners from projections
                let origin = CGPoint(
                    x: hull[i].x + minU * ux + minV * vx,
                    y: hull[i].y + minU * uy + minV * vy
                )
                let corner1 = CGPoint(
                    x: origin.x + (maxU - minU) * ux,
                    y: origin.y + (maxU - minU) * uy
                )
                let corner2 = CGPoint(
                    x: corner1.x + (maxV - minV) * vx,
                    y: corner1.y + (maxV - minV) * vy
                )
                let corner3 = CGPoint(
                    x: origin.x + (maxV - minV) * vx,
                    y: origin.y + (maxV - minV) * vy
                )
                bestRect = [origin, corner1, corner2, corner3]
            }
        }

        return bestRect
    }

    /// Axis-aligned bounding rect as fallback.
    private static func axisAlignedRect(points: [CGPoint]) -> [CGPoint]? {
        guard !points.isEmpty else { return nil }
        let xs = points.map { $0.x }
        let ys = points.map { $0.y }
        guard let minX = xs.min(), let maxX = xs.max(),
              let minY = ys.min(), let maxY = ys.max()
        else { return nil }
        return [
            CGPoint(x: minX, y: minY),
            CGPoint(x: maxX, y: minY),
            CGPoint(x: maxX, y: maxY),
            CGPoint(x: minX, y: maxY),
        ]
    }

    // MARK: - Convex Hull (Andrew's Monotone Chain)

    private static func convexHull(points: [CGPoint]) -> [CGPoint] {
        let sorted = points.sorted { $0.x < $1.x || ($0.x == $1.x && $0.y < $1.y) }
        guard sorted.count >= 3 else { return sorted }

        var hull: [CGPoint] = []

        // Lower hull
        for p in sorted {
            while hull.count >= 2 && cross(hull[hull.count - 2], hull[hull.count - 1], p) <= 0 {
                hull.removeLast()
            }
            hull.append(p)
        }

        // Upper hull
        let lowerCount = hull.count + 1
        for p in sorted.reversed() {
            while hull.count >= lowerCount && cross(hull[hull.count - 2], hull[hull.count - 1], p) <= 0 {
                hull.removeLast()
            }
            hull.append(p)
        }

        hull.removeLast()  // Remove duplicate of first point
        return hull
    }

    /// Cross product of vectors OA and OB.
    private static func cross(_ o: CGPoint, _ a: CGPoint, _ b: CGPoint) -> CGFloat {
        (a.x - o.x) * (b.y - o.y) - (a.y - o.y) * (b.x - o.x)
    }

    // MARK: - Unclip (Polygon Expansion)

    /// Expand a rectangle by offsetting each edge outward.
    /// offset_distance = area * ratio / perimeter
    private static func unClip(rect: [CGPoint], ratio: Float) -> [CGPoint] {
        guard rect.count == 4 else { return rect }

        let area = polygonArea(rect)
        let perimeter = polygonPerimeter(rect)
        guard perimeter > 0 else { return rect }

        let offset = CGFloat(Float(area) * ratio / Float(perimeter))

        // Compute centroid
        let cx = rect.map { $0.x }.reduce(0, +) / 4
        let cy = rect.map { $0.y }.reduce(0, +) / 4

        // Expand each point away from centroid
        return rect.map { pt in
            let dx = pt.x - cx
            let dy = pt.y - cy
            let dist = sqrt(dx * dx + dy * dy)
            guard dist > 0 else { return pt }
            let scale = (dist + offset) / dist
            return CGPoint(x: cx + dx * scale, y: cy + dy * scale)
        }
    }

    private static func polygonArea(_ pts: [CGPoint]) -> CGFloat {
        let n = pts.count
        var area: CGFloat = 0
        for i in 0..<n {
            let j = (i + 1) % n
            area += pts[i].x * pts[j].y
            area -= pts[j].x * pts[i].y
        }
        return abs(area) / 2
    }

    private static func polygonPerimeter(_ pts: [CGPoint]) -> CGFloat {
        let n = pts.count
        var perimeter: CGFloat = 0
        for i in 0..<n {
            let j = (i + 1) % n
            let dx = pts[j].x - pts[i].x
            let dy = pts[j].y - pts[i].y
            perimeter += sqrt(dx * dx + dy * dy)
        }
        return perimeter
    }
}
