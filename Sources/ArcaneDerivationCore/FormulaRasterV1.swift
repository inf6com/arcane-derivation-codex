import Foundation

public enum FormulaRasterV1 {
    public static let size = 512

    public enum RasterError: LocalizedError {
        case emptyOrDegenerateInput

        public var errorDescription: String? {
            "数式ラスター化にはx軸・y軸の両方に有限な入力範囲が必要です。"
        }
    }

    public static func pgm(from input: Inf6FormulaWholeInput.FormulaInput) throws -> Data {
        // The Python fixture rasterizes `model_features`, whose coordinates
        // are explicitly converted to IEEE-754 binary32. Rasterizing the
        // Codable Double evidence values would create a different image at
        // antialiased boundary pixels, despite the same nominal geometry.
        let traces = input.traces.map { trace in
            trace.map { point in (x: Double(Float(point.x)), y: Double(Float(point.y))) }
        }
        let points = traces.flatMap { $0 }
        guard let minX = points.map(\.x).min(), let maxX = points.map(\.x).max(), let minY = points.map(\.y).min(), let maxY = points.map(\.y).max(), maxX > minX, maxY > minY else {
            throw RasterError.emptyOrDegenerateInput
        }
        let margin = 32.0, scale = min((Double(size)-64)/(maxX-minX), (Double(size)-64)/(maxY-minY))
        var bytes = [UInt8](repeating: 255, count: size * size)
        for trace in traces where trace.count > 1 {
            for (a,b) in zip(trace, trace.dropFirst()) {
                let ax=margin+(a.x-minX)*scale, ay=margin+(a.y-minY)*scale, bx=margin+(b.x-minX)*scale, by=margin+(b.y-minY)*scale
                let loX=max(0,Int(floor(min(ax,bx)-3))), hiX=min(size-1,Int(ceil(max(ax,bx)+3))), loY=max(0,Int(floor(min(ay,by)-3))), hiY=min(size-1,Int(ceil(max(ay,by)+3))); let dx=bx-ax, dy=by-ay, den=dx*dx+dy*dy
                for y in loY...hiY { for x in loX...hiX { let u=den == 0 ? 0 : max(0,min(1,((Double(x)+0.5-ax)*dx+(Double(y)+0.5-ay)*dy)/den)); let offsetX=Double(x)+0.5-(ax+u*dx), offsetY=Double(y)+0.5-(ay+u*dy); let d=(offsetX*offsetX+offsetY*offsetY).squareRoot(); let c=max(0,min(1,2.5-d)); bytes[y*size+x]=min(bytes[y*size+x],UInt8((255*(1-c)).rounded(.toNearestOrEven))) } }
            }
        }
        return Data("P5\n512 512\n255\n".utf8) + Data(bytes)
    }
}
