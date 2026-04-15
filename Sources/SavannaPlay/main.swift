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

// ── Decoder: GPU (Metal) or CPU fallback ──
import Metal

print("Loading \(filePath)...")

// Try GPU decoder first, fall back to CPU
var gpuDec: GPUDecoder? = nil
var cpuDec: CarlosDelta.StreamingDecoder? = nil

let decWidth: Int, decHeight: Int, decFrameCount: Int, decTotalCells: UInt64
let decDisplayW: Int, decDisplayH: Int, decNeedsLOD: Bool, decStep: Int
let decKeyframeInterval: Int

if let gpu = try? GPUDecoder(path: filePath) {
    gpuDec = gpu
    decWidth = gpu.width; decHeight = gpu.height
    decFrameCount = gpu.frameCount; decTotalCells = gpu.totalCells
    decDisplayW = gpu.displayW; decDisplayH = gpu.displayH
    decNeedsLOD = gpu.needsLOD; decStep = gpu.step
    decKeyframeInterval = gpu.keyframeInterval
    print("  GPU: \(gpu.device.name)")
} else {
    let cpu = try! CarlosDelta.StreamingDecoder(path: filePath)
    cpuDec = cpu
    decWidth = cpu.width; decHeight = cpu.height
    decFrameCount = cpu.frameCount; decTotalCells = cpu.totalCells
    decDisplayW = cpu.displayW; decDisplayH = cpu.displayH
    decNeedsLOD = cpu.needsLOD; decStep = cpu.step
    decKeyframeInterval = cpu.keyframeInterval
    print("  Mode: CPU (no Metal)")
}

print("  Grid: \(decWidth)×\(decHeight)")
print("  Frames: \(decFrameCount)")
print("  Total cells: \(decTotalCells)")
if decKeyframeInterval > 0 {
    let iFrames = (decFrameCount + decKeyframeInterval - 1) / decKeyframeInterval
    let pFrames = decFrameCount - iFrames
    print("  I/P frames: \(iFrames) I + \(pFrames) P (interval \(decKeyframeInterval))")
    print("  Max seek distance: \(decKeyframeInterval) frames")
}
if decNeedsLOD {
    print("  LOD: \(decWidth)×\(decHeight) → \(decDisplayW)×\(decDisplayH) (step \(decStep))")
}

/// Unified frame access — GPU or CPU
func getDisplayFrame(_ index: Int) -> [Int8] {
    if let gpu = gpuDec { return gpu.displayFrame(index) }
    return cpuDec!.displayFrame(index)
}
func getFrame(_ index: Int) -> [Int8] {
    if let gpu = gpuDec { return gpu.displayFrame(index) }
    return cpuDec!.frame(index)
}

// Pre-warm (CPU path only — GPU is fast enough without cache)
if cpuDec != nil && decFrameCount > 0 {
    print("  Warming CPU cache: \(decFrameCount) frames...", terminator: "")
    fflush(stdout)
    let t0 = CFAbsoluteTimeGetCurrent()
    for i in 0..<decFrameCount { _ = getDisplayFrame(i) }
    let t1 = CFAbsoluteTimeGetCurrent()
    print(" \(String(format: "%.1f", t1 - t0))s (\(String(format: "%.0f", (t1 - t0) / Double(decFrameCount) * 1000))ms/frame)")
}
print("  Mode: \(gpuDec != nil ? "GPU (Metal)" : "CPU (cached)")")

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
        {"width":\(decWidth),"height":\(decHeight),"frame_count":\(decFrameCount),"cells":\(decWidth * decHeight),"total_cells":\(decTotalCells),"gpu":\(gpuDec != nil)}
        """
        responseBody = info.data(using: .utf8)!

    } else if path.hasPrefix("/savanna_state.bin") {
        contentType = "application/octet-stream"
        let frameIdx = currentFrame
        currentFrame = (currentFrame + 1) % decFrameCount
        let frame = getDisplayFrame(frameIdx)
        var w = UInt32(decDisplayW), h = UInt32(decDisplayH)
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
        let frame = getFrame(max(0, currentFrame - 1))
        var grass = 0, zebra = 0, lion = 0
        for e in frame {
            if e == 1 { grass += 1 } else if e == 2 { zebra += 1 } else if e == 3 { lion += 1 }
        }
        let telemetry = """
        {"tick":\(currentFrame),"day":\(currentFrame/4),"year":\(String(format:"%.2f", Double(currentFrame)/1460.0)),"ms":0,"tps":0,"speed":1,"grass":\(grass),"zebra":\(zebra),"lion":\(lion),"energy":0,"dG":0,"dZ":0,"dL":0,"ratio":\(String(format:"%.1f", zebra > 0 ? Double(zebra)/max(1,Double(lion)) : 0)),"grassPct":\(String(format:"%.1f", Double(grass)/Double(decWidth*decHeight)*100)),"nodes":\(decWidth*decHeight),"colors":7}
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
