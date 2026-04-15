/// savanna-play — Playback server for .savanna delta-compressed recordings.
/// Decodes Carlos Delta format, serves via HTTP for WebGL viewer.
///
/// Usage: savanna-play recording.savanna [--port 8800]

import Foundation
import Savanna

// ── Parse args ──────────────────────────────────────
let args = CommandLine.arguments
guard args.count >= 2 else {
    print("Usage: savanna-play <recording.savanna> [--port 8800]")
    exit(1)
}

let filePath = args[1]
let port: UInt16 = {
    if let i = args.firstIndex(of: "--port"), i + 1 < args.count {
        return UInt16(args[i + 1]) ?? 8800
    }
    return 8800
}()

// ── Decode ──────────────────────────────────────────
print("Loading \(filePath)...")
let decoder: CarlosDelta.Decoder
do {
    decoder = try CarlosDelta.Decoder(path: filePath)
} catch {
    print("Error: \(error)")
    exit(1)
}
print("  Grid: \(decoder.width)×\(decoder.height)")
print("  Frames: \(decoder.frameCount)")
print("  Total cells: \(decoder.totalCells)")

// ── GPU RG-LOD: Pre-downsample for browser ──────────
// If grid > 2048, downsample all frames at startup using majority vote.
// This is the "self-similar" LOD — same function for all scales.
// Ideally uses Metal GPU (generateLOD). Fallback: Swift CPU stride.
let maxDisplay = 2048
let needsDownsample = decoder.width > maxDisplay || decoder.height > maxDisplay
let displayW: Int
let displayH: Int
var displayFrames: [[Int8]]?

if needsDownsample {
    let step = max(decoder.width / maxDisplay, decoder.height / maxDisplay)
    displayW = decoder.width / step
    displayH = decoder.height / step
    print("  LOD: \(decoder.width)×\(decoder.height) → \(displayW)×\(displayH) (step \(step))")

    var downsampled = [[Int8]]()
    for i in 0..<decoder.frameCount {
        let src = decoder.frame(i)
        var dst = [Int8](repeating: 0, count: displayW * displayH)
        // Majority vote per block (vectorized in Swift)
        for dy in 0..<displayH {
            for dx in 0..<displayW {
                var counts = [0, 0, 0, 0, 0]  // empty, grass, zebra, lion, water
                for sy in 0..<step {
                    for sx in 0..<step {
                        let srcIdx = (dy * step + sy) * decoder.width + (dx * step + sx)
                        if srcIdx < src.count {
                            let e = Int(src[srcIdx]) & 0x7
                            if e < 5 { counts[e] += 1 }
                        }
                    }
                }
                // Majority vote
                var best = 0, bestCount = counts[0]
                for e in 1..<5 { if counts[e] > bestCount { best = e; bestCount = counts[e] } }
                // Boost rare entities
                let bs = step * step
                if counts[2] * 100 > bs * 3 { best = 2 }  // zebra >3%
                if counts[3] * 100 > bs * 1 { best = 3 }  // lion >1%
                dst[dy * displayW + dx] = Int8(best)
            }
        }
        downsampled.append(dst)
        if (i + 1) % 10 == 0 || i == 0 {
            print("    Frame \(i + 1)/\(decoder.frameCount) downsampled")
        }
    }
    displayFrames = downsampled
    print("  LOD complete: \(downsampled.count) frames at \(displayW)×\(displayH)")
} else {
    displayW = decoder.width
    displayH = decoder.height
}

// ── HTTP Server ─────────────────────────────────────
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

class PlaybackHandler: URLProtocol {
    // Placeholder — using raw sockets below
}

// Simple HTTP server using POSIX sockets
import Darwin

var currentFrame = 0

func handleRequest(_ clientFd: Int32) {
    var buffer = [UInt8](repeating: 0, count: 4096)
    let n = read(clientFd, &buffer, buffer.count)
    guard n > 0 else { close(clientFd); return }

    let request = String(bytes: buffer[0..<n], encoding: .utf8) ?? ""
    let path = request.split(separator: " ").dropFirst().first.map(String.init) ?? "/"

    var responseBody = Data()
    var contentType = "text/plain"
    var statusLine = "HTTP/1.1 200 OK\r\n"

    if path == "/info" || path == "/info?" {
        contentType = "application/json"
        let info = """
        {"width":\(decoder.width),"height":\(decoder.height),"frame_count":\(decoder.frameCount),"cells":\(decoder.width * decoder.height),"total_cells":\(decoder.totalCells)}
        """
        responseBody = info.data(using: .utf8)!

    } else if path.hasPrefix("/savanna_state.bin") {
        contentType = "application/octet-stream"
        let frameIdx = currentFrame
        currentFrame = (currentFrame + 1) % decoder.frameCount
        // Serve downsampled frame if available, otherwise full
        let frame: [Int8]
        let fw, fh: Int
        if let df = displayFrames {
            frame = df[frameIdx]
            fw = displayW; fh = displayH
        } else {
            frame = decoder.frame(frameIdx)
            fw = decoder.width; fh = decoder.height
        }
        var w = UInt32(fw), h = UInt32(fh)
        var tick = UInt32(frameIdx), day: UInt32 = 1
        var header = Data()
        header.append(Data(bytes: &w, count: 4))
        header.append(Data(bytes: &h, count: 4))
        header.append(Data(bytes: &tick, count: 4))
        header.append(Data(bytes: &day, count: 4))
        frame.withUnsafeBytes { header.append(Data($0)) }
        responseBody = header

    } else if path == "/savanna_telemetry.json" {
        contentType = "application/json"
        let frame = decoder.frame(max(0, currentFrame - 1))
        var grass = 0, zebra = 0, lion = 0
        for e in frame {
            if e == 1 { grass += 1 } else if e == 2 { zebra += 1 } else if e == 3 { lion += 1 }
        }
        let telemetry = """
        {"tick":\(currentFrame),"day":\(currentFrame/4),"year":\(String(format:"%.2f", Double(currentFrame)/1460.0)),"ms":0,"tps":0,"speed":1,"grass":\(grass),"zebra":\(zebra),"lion":\(lion),"energy":0,"dG":0,"dZ":0,"dL":0,"ratio":\(String(format:"%.1f", zebra > 0 ? Double(zebra)/max(1,Double(lion)) : 0)),"grassPct":\(String(format:"%.1f", Double(grass)/Double(decoder.width*decoder.height)*100)),"nodes":\(decoder.width*decoder.height),"colors":7}
        """
        responseBody = telemetry.data(using: .utf8)!

    } else if path == "/reset" || path == "/set_speed" || path.hasPrefix("/set_speed?") {
        responseBody = "ok".data(using: .utf8)!

    } else {
        // Try serving static files from current directory
        let filename = String(path.dropFirst()) // remove leading /
        let url = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(filename)
        if let data = try? Data(contentsOf: url) {
            responseBody = data
            if filename.hasSuffix(".html") { contentType = "text/html" }
            else if filename.hasSuffix(".js") { contentType = "application/javascript" }
            else if filename.hasSuffix(".css") { contentType = "text/css" }
            else if filename.hasSuffix(".bin") { contentType = "application/octet-stream" }
            else { contentType = "application/octet-stream" }
        } else {
            statusLine = "HTTP/1.1 404 Not Found\r\n"
            responseBody = "404".data(using: .utf8)!
        }
    }

    let headers = "\(statusLine)Content-Type: \(contentType)\r\nContent-Length: \(responseBody.count)\r\nAccess-Control-Allow-Origin: *\r\nConnection: close\r\n\r\n"
    let headerData = headers.data(using: .utf8)!
    headerData.withUnsafeBytes { _ = write(clientFd, $0.baseAddress!, headerData.count) }
    responseBody.withUnsafeBytes { _ = write(clientFd, $0.baseAddress!, responseBody.count) }
    close(clientFd)
}

// Start server
let serverFd = socket(AF_INET, SOCK_STREAM, 0)
var opt: Int32 = 1
setsockopt(serverFd, SOL_SOCKET, SO_REUSEADDR, &opt, socklen_t(MemoryLayout<Int32>.size))

var addr = sockaddr_in()
addr.sin_family = sa_family_t(AF_INET)
addr.sin_port = UInt16(port).bigEndian
addr.sin_addr.s_addr = INADDR_ANY.bigEndian

withUnsafePointer(to: &addr) { ptr in
    ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
        bind(serverFd, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
    }
}
listen(serverFd, 10)

print("savanna-play on :\(port)")
print("Open: http://localhost:\(port)/savanna_webgl.html")

while true {
    let clientFd = accept(serverFd, nil, nil)
    if clientFd >= 0 {
        DispatchQueue.global(qos: .userInteractive).async {
            handleRequest(clientFd)
        }
    }
}
