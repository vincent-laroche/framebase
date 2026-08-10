import FramebaseCLI
import Foundation

@main
struct FramebaseTool {
    static func main() async {
        do {
            let output = try await FramebaseCLI.execute(arguments: Array(CommandLine.arguments.dropFirst()))
            print(output)
        } catch {
            FileHandle.standardError.write(Data("error: \(error.localizedDescription)\n".utf8))
            exit(1)
        }
    }
}
