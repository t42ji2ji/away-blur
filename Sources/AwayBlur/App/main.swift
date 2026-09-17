import AppKit

if let index = CommandLine.arguments.firstIndex(of: "--shot") {
    let path = CommandLine.arguments.count > index + 1 ? CommandLine.arguments[index + 1] : "."
    Diagnostics.shoot(into: URL(fileURLWithPath: path, isDirectory: true))
    exit(0)
}

if let index = CommandLine.arguments.firstIndex(of: "--compare"), CommandLine.arguments.count > index + 2 {
    Diagnostics.compare(CommandLine.arguments[index + 1], CommandLine.arguments[index + 2])
    exit(0)
}

if let index = CommandLine.arguments.firstIndex(of: "--font") {
    let path = CommandLine.arguments.count > index + 1 ? CommandLine.arguments[index + 1] : "font.png"
    Diagnostics.drawFont(to: path)
    exit(0)
}

if CommandLine.arguments.contains("--lines") {
    Diagnostics.showLines()
    exit(0)
}

if let index = CommandLine.arguments.firstIndex(of: "--scene") {
    let path = CommandLine.arguments.count > index + 1 ? CommandLine.arguments[index + 1] : "scene.png"
    Diagnostics.drawScene(to: path)
    exit(0)
}

if let index = CommandLine.arguments.firstIndex(of: "--cat") {
    let path = CommandLine.arguments.count > index + 1 ? CommandLine.arguments[index + 1] : "cat.png"
    Diagnostics.drawCat(to: path)
    exit(0)
}

if CommandLine.arguments.contains("--camera") {
    Diagnostics.lookThroughCamera()
    exit(0)
}

if CommandLine.arguments.contains("--edges") {
    Diagnostics.measureEdges()
    exit(0)
}

if CommandLine.arguments.contains("--measure") {
    Diagnostics.measureDrift()
    exit(0)
}

let application = NSApplication.shared
let delegate = AppDelegate()
application.delegate = delegate
application.setActivationPolicy(.accessory)
application.run()
