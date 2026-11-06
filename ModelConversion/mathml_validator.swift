import Foundation

@main
struct MathMLValidatorMain {
    static func main() throws {
        let lines = String(data: FileHandle.standardInput.readDataToEndOfFile(), encoding: .utf8)!.split(separator: "\n", omittingEmptySubsequences: false)
        let converter = LaTeXMathMLConverter()
        let values: [[String: Any]] = lines.map { line in
            do {
                let mathML = try converter.convert(String(line))
                return ["ok": true, "mathML": mathML]
            } catch {
                return ["ok": false, "error": String(describing: error)]
            }
        }
        let data = try JSONSerialization.data(withJSONObject: values, options: [])
        FileHandle.standardOutput.write(data)
    }
}
