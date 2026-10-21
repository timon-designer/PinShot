import Testing
import CoreGraphics
import Foundation
@testable import PinShotCore

// MARK: - OCR 分段

@Suite("OCR 分段")
struct OCRSegmentTests {

    /// 造一行视觉行。Vision 坐标系原点在左下，所以 midY 越大越靠上。
    private func line(_ text: String, midY: CGFloat, height: CGFloat = 0.03) -> (text: String, box: CGRect) {
        (text, CGRect(x: 0.10, y: midY - height / 2, width: 0.80, height: height))
    }

    @Test("行距均匀 → 合成一段（清单/界面文案就是这种）")
    func uniformSpacingStaysOneSegment() {
        // 行距 0.01，行高 0.03 → 阈值 0.65*0.03 = 0.0195，不该切
        let boxes = (0..<5).map { line("line \($0)", midY: 0.90 - CGFloat($0) * 0.04) }
        let segments = OCRService.group(boxes)
        #expect(segments.count == 1)
        #expect(segments[0].lines.count == 5)
    }

    @Test("行距明显偏大（空行）→ 切成多段")
    func paragraphGapSplits() {
        // 前两行相邻（gap 0.01），第三行隔开（gap 0.05 > 0.0195）
        let boxes = [
            line("a", midY: 0.90),
            line("b", midY: 0.86),
            line("c", midY: 0.78),
        ]
        let segments = OCRService.group(boxes)
        #expect(segments.count == 2)
        #expect(segments[0].lines == ["a", "b"])
        #expect(segments[1].lines == ["c"])
    }

    @Test("段内多行以换行连接（送进模型时保留换行）")
    func segmentTextKeepsNewlines() {
        let boxes = [line("a", midY: 0.90), line("b", midY: 0.86)]
        #expect(OCRService.group(boxes)[0].text == "a\nb")
    }

    @Test("空输入 → 空结果，不崩")
    func emptyInput() {
        #expect(OCRService.group([]).isEmpty)
    }
}

// MARK: - 译文解析

@Suite("译文对齐")
struct SplitTranslatedTests {

    @Test("段数与原文一致 → 一一对应")
    func paragraphsMatch() {
        let out = TranslationService.splitTranslated("一\n\n二\n\n三", matching: ["a", "b", "c"])
        #expect(out == ["一", "二", "三"])
    }

    @Test("模型改用单换行 → 仍能按行还原")
    func fallbackToLines() {
        let out = TranslationService.splitTranslated("一\n二\n三", matching: ["a", "b", "c"])
        #expect(out == ["一", "二", "三"])
    }

    @Test("译文段数多于原文 → 多出来的并进最后一段，绝不丢内容")
    func mergeExtraParagraphs() {
        let out = TranslationService.splitTranslated("一\n\n二\n\n三\n\n四", matching: ["a", "b"])
        #expect(out.count == 2)
        #expect(out[0] == "一")
        #expect(out[1].contains("二"))
        #expect(out[1].contains("四"))
    }

    @Test("单段输入 → 原样返回（不做任何切分）")
    func singleSegment() {
        let raw = "第一行\n第二行\n第三行"
        let out = TranslationService.splitTranslated(raw, matching: ["whole"])
        #expect(out == [raw])
    }

    @Test("段数对不齐且行数也对不齐 → 整段返回，不抛错、不重试")
    func degenerateFallbackReturnsWhole() {
        let out = TranslationService.splitTranslated("只有一段译文", matching: ["a", "b", "c"])
        #expect(out == ["只有一段译文"])
    }

    @Test("去掉模型加的 Markdown 代码围栏")
    func stripCodeFence() {
        let out = TranslationService.splitTranslated("```\n你好\n```", matching: ["hi"])
        #expect(out == ["你好"])
    }

    @Test("空白响应 → 按原文段数返回空串，不崩")
    func emptyResponse() {
        let out = TranslationService.splitTranslated("   \n  ", matching: ["a", "b"])
        #expect(out.count == 2)
        // 用闭包而不是 `\.isEmpty` 关键路径写法：
        // `allSatisfy` 是 rethrows，配合 #expect 宏展开会被推断成 throwing → 编译报
        // "call can throw, but it is not marked with 'try'"，整个测试目标编不过。
        #expect(out.allSatisfy { $0.isEmpty })
    }
}
