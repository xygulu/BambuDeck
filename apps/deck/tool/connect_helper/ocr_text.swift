// deck_ocr —— 本地 OCR 小工具（macOS Vision 框架，不上传任何数据）。
//
// 用途：Bambu Connect 的设备下拉是 Electron 自定义浮层，AX 树里读不到选项，
// 只能截图后本地识别出每一行的文字和位置，再精确点目标行。
//
// 用法：deck_ocr <图片路径>
// 输出：每行一个 JSON 对象 {"t": 文字, "x": 左, "y": 上, "w": 宽, "h": 高}，
//       坐标单位是图片像素（左上角原点）。
//
// 由 bconnect_print.py 首次使用时自动编译到 ~/.bambudeck/bin/deck_ocr。

import AppKit
import Foundation
import Vision

guard CommandLine.arguments.count >= 2 else {
    FileHandle.standardError.write("usage: deck_ocr <image>\n".data(using: .utf8)!)
    exit(2)
}
guard let image = NSImage(contentsOfFile: CommandLine.arguments[1]) else {
    FileHandle.standardError.write("cannot read image\n".data(using: .utf8)!)
    exit(3)
}
var rect = CGRect(origin: .zero, size: image.size)
guard let cg = image.cgImage(forProposedRect: &rect, context: nil, hints: nil) else {
    FileHandle.standardError.write("cannot decode image\n".data(using: .utf8)!)
    exit(3)
}

let request = VNRecognizeTextRequest()
request.recognitionLevel = .accurate
request.recognitionLanguages = ["zh-Hans", "en-US"]
// 打印机名是专有名词（「123」「嘉兴」「拓竹A1宇树」），纠错反而会把数字/字母改坏。
request.usesLanguageCorrection = false

do {
    try VNImageRequestHandler(cgImage: cg, options: [:]).perform([request])
} catch {
    FileHandle.standardError.write("ocr failed: \(error)\n".data(using: .utf8)!)
    exit(4)
}

let width = CGFloat(cg.width)
let height = CGFloat(cg.height)
for observation in request.results ?? [] {
    guard let candidate = observation.topCandidates(1).first else { continue }
    let box = observation.boundingBox  // 归一化坐标，原点在左下
    let item: [String: Any] = [
        "t": candidate.string,
        "x": Int((box.origin.x * width).rounded()),
        "y": Int(((1 - box.origin.y - box.height) * height).rounded()),
        "w": Int((box.width * width).rounded()),
        "h": Int((box.height * height).rounded()),
    ]
    if let data = try? JSONSerialization.data(withJSONObject: item),
       let line = String(data: data, encoding: .utf8) {
        print(line)
    }
}
