import XCTest
@testable import ShellCopyCore

final class LineNormalizerTests: XCTestCase {
    func testReportedPartialIdentifierSelectionJoinsWithoutAddingSpace() {
        XCTAssertEqual(LineNormalizer.normalize("seedmux-lite-\n  team"), "seedmux-lite-team")
    }

    func testIdentifierWrapsKeepHyphensAndFinalLineEndings() {
        for padding in ["  ", "    ", "        "] {
            for ending in ["\n", "\r\n"] {
                for trailing in ["", ending] {
                    let input = "seedmux-" + ending + padding + "lite-" + ending + padding + "team" + trailing
                    let expected = "seedmux-lite-team" + trailing
                    XCTAssertEqual(LineNormalizer.normalize(input), expected)
                    XCTAssertEqual(LineNormalizer.normalize(expected), expected)
                }
            }
        }
        XCTAssertEqual(LineNormalizer.normalize("my_skill-v2-\n  beta_1"), "my_skill-v2-beta_1")
    }

    func testIdentifierRulePreservesAmbiguousAndStructuredSelections() {
        let samples = [
            "seedmux-lite-\nteam", "seedmux-lite-\n team", "seedmux-lite-\n\tteam",
            " seedmux-lite-\n  team", "seedmux-\n  lite-\n    team",
            "seedmux-lite\n  team", "seedmux-lite- \n  team", "seedmux-lite-\n  team ",
            "seedmux-lite-\n\n  team", "seedmux-lite-\n  team\n\n",
            "seedmux-lite-\n  team\n  another", "seedmux-lite-\n  team-",
            "seedmux-lite-\n  team\t", "seedmux-lite-\n  team\r",
            "seedmux-lite-\n  team member", "Heading\nseedmux-lite-\n  team",
            "Heading\n\nseedmux-lite-\n  team", "- seedmux-lite-\n  team",
            "echo seedmux-lite-\n  team", "value = seedmux-lite-\n  team",
            "seedmux-lite-\n  --team", "seedmux-lite-\n  team;",
            "2026-10-\n  18", "```\nseedmux-lite-\n  team\n```",
            "seedmux-lite-\n  team\0"
        ]
        for sample in samples { XCTAssertEqual(LineNormalizer.normalize(sample), sample, sample) }
    }

    func testReportedLoadTestParagraphsJoinWithoutRemovingParagraphBreaks() {
        let first = "CDP 侧已完成本轮压测：对 cg.cdp.thrift.GetSegmentData 发压，通过客群 23142 查询标签 102987，按该标签配置，最终调用下游"
        let next = "ad.ecp.uni_prom.HitDouble11Promotion 接口。"
        let second = "本轮从 50 QPS 起步，每阶段 30 秒、递增 50 QPS，最高达到约 500 QPS，执行约 6 分 40 秒，累计请求约 10.9 万次，成功率 100%，平均耗时 12.35 ms，P99 为"
        let tail = "24.25 ms，CDP 侧未观察到明显性能异常。"
        let last = "  下游可核对 10 月 16 日 14:12:50–14:19:30 的接口流量、错误率及资源监控，确认无异常后按计划安排上线。"
        let input = first + "\n  " + next + "\n\n  " + second + "\n  " + tail + "\n\n" + last
        let expected = first + next + "\n\n  " + second + tail + "\n\n" + last
        XCTAssertEqual(LineNormalizer.normalize(input), expected)
        XCTAssertEqual(LineNormalizer.normalize(expected), expected)
    }

    func testLaterParagraphWithCopyPadding() {
        let first = "这份发布检查报告详细说明本次上线之前仍需核对的历史数据"
        let input = first + "\n  校验结果。\n\n  " + first + "\n  校验结果。"
        XCTAssertEqual(LineNormalizer.normalize(input), first + "校验结果。\n\n  " + first + "校验结果。")
    }

    func testCopyPaddingPreservesProtectedBoundariesAndLineEndings() {
        let first = "This detailed deployment report explains the remaining work for the next"
        for count in [2, 4, 8] {
            let pad = String(repeating: " ", count: count)
            let opening = first + "\r\n" + pad + "release.\r\n  \r\n"
            let paragraph = pad + first + ":  \r\n" + pad + "Another check needs\n" + pad + "verification.\r\n"
            let expected = first + " release.\r\n  \r\n" + pad + first + ":  \r\n" + pad + "Another check needs verification.\r\n"
            XCTAssertEqual(LineNormalizer.normalize(opening + paragraph), expected)
            XCTAssertEqual(LineNormalizer.normalize(expected), expected)
        }
    }

    func testCopyPaddingDoesNotRelaxStandaloneNestedOrStructuredBlocks() {
        let first = "This detailed deployment report explains the remaining work for the next"
        let opening = first + "\n  release.\n\n"
        let normalizedOpening = first + " release.\n\n"
        for paragraph in [
            "  " + first + "\n    nested paragraph.",
            "    " + first + "\n    different padding.",
            "  " + first + "\n  echo hello",
            "  " + first + "\n  column\tvalue",
            "  " + first + "\n  - nested item",
            "  " + first + ".\n  Separate sentence.",
            "  Short title\n  explanation."
        ] {
            XCTAssertEqual(LineNormalizer.normalize(opening + paragraph), normalizedOpening + paragraph)
        }
        let paragraph = "  " + first + "\n  release."
        for prefix in ["", "Heading\n\n", first + ".\n  Separate sentence.\n\n", "• " + first + "\n  release.\n\n"] {
            XCTAssertTrue(LineNormalizer.normalize(prefix + paragraph).hasSuffix(paragraph))
        }
    }

    func testWarpColonPreservesFirstBreakButJoinsLaterWrap() {
        let first = "我需要写一个客群创编的skill 这是我之前梳理的客群skill原子能力："
        let next = "notes/2026-09-24-segment-authoring-skill-research.md，你结合代码帮我出"
        let last = "一个技术方案，使用AI unslop这个skill写作"
        let input = first + "\n  " + next + "\n  " + last
        let expected = first + "\n  " + next + last
        XCTAssertEqual(LineNormalizer.normalize(input), expected)
        XCTAssertEqual(LineNormalizer.normalize(expected), expected)
    }

    func testPartialJoinsPreserveProtectedBoundariesAndExactPadding() {
        let first = "这份发布检查报告详细说明本次上线之前仍需核对的历史数据"
        for prefix in ["", "  • ", "12) "] {
            let padding = prefix.isEmpty ? "    " : String(repeating: " ", count: prefix.count)
            let input = prefix + first + "\r\n" + padding + "校验结果：  \n" + padding + "另一项需要继续\r\n" + padding + "核对。\r\n"
            let expected = prefix + first + "校验结果：  \n" + padding + "另一项需要继续核对。\r\n"
            XCTAssertEqual(LineNormalizer.normalize(input), expected)
            XCTAssertEqual(LineNormalizer.normalize(expected), expected)
        }
        let input = "• " + first + "：\r\n\t\t另一项需要继续\n\t    核对。"
        XCTAssertEqual(LineNormalizer.normalize(input), "• " + first + "：\r\n\t\t另一项需要继续核对。")
    }

    func testProtectedPunctuationKeepsItsBreakWithoutBlockingLaterWraps() {
        let first = "This detailed deployment report explains the remaining work for the next"
        for punctuation in [".", "!", "?", ":", "。", "！", "？", "：", "；", "-", "—", "/", "=", "|", "]"] {
            let beginning = first + punctuation + "  \r\n    Another paragraph still needs"
            let expected = beginning + " verification."
            XCTAssertEqual(LineNormalizer.normalize(beginning + "\n    verification."), expected)
            XCTAssertEqual(LineNormalizer.normalize(expected), expected)
        }
    }

    func testReportedBulletSelectionJoinsChineseWordAcrossWrap() {
        let text = "当前必要修复：统一参与链路的加锁顺序。批量启停应在修改配置和业务表之前，按 ID 顺序获取全部 profile 锁；不能只给回调排序。同时核实并限制 MNS 等待时"
        let continuation = "间、批次大小和并发数，补 MySQL 并发回归。"
        for prefix in ["", "• ", "  • "] {
            let input = prefix + text + "\n    " + continuation
            XCTAssertEqual(LineNormalizer.normalize(input), prefix + text + continuation)
        }
    }

    func testClippedChineseListSelectionPreservesMarkersAndLineEndings() {
        let text = "这份发布检查报告详细说明本次上线之前仍需核对的历史数据"
        for marker in ["• ", "- ", "* ", "+ ", "1. ", "12) ", "a) "] {
            for indent in [4, 8] {
                let padding = String(repeating: " ", count: indent)
                let first = marker + text
                let input = first + "\r\n" + padding + "校验结果以及\r\n" + padding + "迁移记录。\r\n\r\n• 下一项。\r\n"
                let expected = first + "校验结果以及迁移记录。\r\n\r\n• 下一项。\r\n"
                XCTAssertEqual(LineNormalizer.normalize(input), expected)
                XCTAssertEqual(LineNormalizer.normalize(expected), expected)
            }
        }
    }

    func testClippedSelectionDoesNotRelaxOtherListBoundaries() {
        let first = "• 这份发布检查报告详细说明本次上线之前仍需核对的历史数据"
        let wrapped = first + "\n    校验结果。"
        let samples = [
            "标题\n" + wrapped, "标题\n\n" + wrapped, "\n" + wrapped,
            "• 上一项。\n" + wrapped, "  " + first + "\n      校验结果。",
            first + "。\n    单独一段。", "• 简短标题\n    单独一段。",
            first + "\n    - 子列表", first + "\n    const value = 1",
            first + "\n    列名\t值", first + "\n\n    单独一段。"
        ]
        for sample in samples { XCTAssertEqual(LineNormalizer.normalize(sample), sample) }
        let input = first + "\n    校验结果\n      更深的段落。\n• 下一项。"
        XCTAssertEqual(LineNormalizer.normalize(input), input)
    }

    func testListWrapsPreserveHeadingsItemsAndBlankLines() {
        let first = "  • **KR1：**完善资产生产进度披露，优先覆盖数据集、指标创建及回溯链路，试点范围内关键生产节点可视覆盖率达"
        let second = "  • **KR2：**完善 Agent 长任务执行与恢复能力，核心故障回归用例全部通过，验证任务状态可追踪、重复请"
        let third = "  • **KR3：**建立创编与 Oncall 场景的效果评测和发布回归机制，沉淀不少于 50 条真实需求，核心 Skill 与"
        let input = "O1：目标\r\n" + first + "\r\n    到 100%。\r\n" + second + "\r\n    求不重复创建。\r\n\r\nO2：目标\r\n\r\n" + third + "\r\n\t\t    模型配置变更均完成回归验收。"
        let expected = "O1：目标\r\n" + first + "到 100%。\r\n" + second + "求不重复创建。\r\n\r\nO2：目标\r\n\r\n" + third + "模型配置变更均完成回归验收。"
        XCTAssertEqual(LineNormalizer.normalize(input), expected)
        XCTAssertEqual(LineNormalizer.normalize(expected), expected)
    }

    func testAlignedEnglishAndNumberedListWraps() {
        for marker in ["• ", "- ", "* ", "+ ", "1. ", "12) ", "a) "] {
            let first = "  " + marker + "This detailed deployment report explains the remaining work for the next"
            let input = first + "\n" + String(repeating: " ", count: 2 + marker.count) + "release."
            XCTAssertEqual(LineNormalizer.normalize(input), first + " release.")
        }
    }

    func testListChildrenCodeAndIntentionalBreaksStaySeparate() {
        let first = "  • This detailed deployment report explains the remaining work for the next"
        for next in ["    - nested item", "      nested paragraph", "    echo do not join", "    const value = 1", "    # Heading", "    column\tvalue", "\t    English tab indentation", "  Another paragraph."] {
            let input = first + "\n" + next
            XCTAssertEqual(LineNormalizer.normalize(input), input)
        }
        let ended = first + ".\n    Separate sentence."
        XCTAssertEqual(LineNormalizer.normalize(ended), ended)
    }

    func testReportedChineseProseWithTwoSpaceWrapBecomesOneLine() {
        let first = "直接执行：已修复并重新打包。请退出旧版，再打开新版 Shell Copy (build/Shell Copy.app)，即可使用"
        let next = "Command-V 粘贴、Command-A 全选。"
        XCTAssertEqual(LineNormalizer.normalize(first + "\n  " + next), first + next)
    }

    func testShallowIndentContinuationAndSentenceBoundaries() {
        let first = "This detailed deployment report explains the remaining work for the next"
        for indent in [2, 4, 8, 32] {
            let padding = String(repeating: " ", count: indent)
            XCTAssertEqual(LineNormalizer.normalize(first + "\n" + padding + "release."), first + " release.")
            let separate = first + ".\n" + padding + "A separate sentence."
            XCTAssertEqual(LineNormalizer.normalize(separate), separate)
        }
    }

    func testOriginalUserExampleKeepsColumnSpacing() {
        let first = "useDag=0 直接物化 Hive    临时升级环境下通过，存在交付限制。 7377/429330 成功 11 人；7378/429331 Hive 成功后因 COUNT=0 失败。但依赖临时 Base64 模板和测试 JAR，验收后恢复了原模板，不能算永久启用"
        XCTAssertEqual(LineNormalizer.normalize(first + "\n" + String(repeating: " ", count: 32) + "完成。"), first + "完成。")
    }

    func testIndependentChineseContinuationAndMultipleLines() {
        let first = "batchMode=2 新版本校验    本轮抽样结果符合预期，后续仍需完成配置迁移以及历史数据"
        let input = first + "\n                核对，等待负责人确认后\n                统一发布。"
        XCTAssertEqual(LineNormalizer.normalize(input), first + "核对，等待负责人确认后统一发布。")
    }

    func testEnglishWordBoundariesAndInternalSpaces() {
        let first = "The migration report    explains why the updated service still requires additional"
        XCTAssertEqual(LineNormalizer.normalize(first + "\n        checks before the release can proceed."), first + " checks before the release can proceed.")
    }

    func testBlankParagraphsAndCRLFRemainExact() {
        let first = "This detailed deployment report explains the remaining work for the next"
        let input = first + "\r\n        release.\r\n  \r\nA short separate paragraph.\r\n"
        XCTAssertEqual(LineNormalizer.normalize(input), first + " release.\r\n  \r\nA short separate paragraph.\r\n")
    }

    func testListsCodeCommandsLogsAndIndentationArePreserved() {
        let samples = [
            "- This detailed deployment report explains the remaining work for the next\n        release.",
            "1. This detailed deployment report explains the remaining work for the next\n        release.",
            "This detailed deployment report explains the remaining work for the next\n        - release item",
            "```text\nThis detailed deployment report explains the remaining work for the next\n        release.\n\n```",
            "~~~python\nprint('a')\n~~~",
            "def explain_the_changes_in_this_detailed_report_for_release():\n        return result",
            "const explanation = this function needs enough words to look like prose\n        + continuation;",
            "curl https://example.test/a/very/long/path --header 'Accept: application/json' \\\n        --output response.json",
            "echo this shell command contains enough ordinary words to resemble a paragraph\n        and must remain untouched",
            "INFO This detailed deployment report explains the remaining work for the next\n        release.",
            "2026-10-08 10:12:13 This detailed deployment report explains the remaining work\n        for the next release.",
            "description: This detailed deployment report explains the remaining work for the next\n        release.",
            "    This detailed deployment report explains the remaining work for the next\n        release.",
            "This detailed deployment report explains the remaining work for the next\n\trelease.",
            "This detailed deployment report explains the remaining work for the next\n        release\n          with nested indentation",
            "KEY=value OTHER=value\n        unchanged"
        ]
        for sample in samples { XCTAssertEqual(LineNormalizer.normalize(sample), sample, sample) }
    }

    func testAmbiguousOrShortTextIsUnchanged() {
        let samples = [
            "one\n        two", "标题\n        说明。", "", "one line", "a\r\nb\r\n",
            "This detailed deployment report explains the remaining work for the next\nrelease.",
            "This detailed deployment report explains the remaining work for the next.\n        Separate sentence.",
            "This detailed deployment report explains the remaining work for the next\n release.",
            "This detailed deployment report explains the remaining work for the next-\n        release.",
            "This detailed deployment report explains the remaining work for the next\n        release.\0"
        ]
        for sample in samples { XCTAssertEqual(LineNormalizer.normalize(sample), sample) }
    }

    func testIdempotence() {
        let sample = "This detailed deployment report explains the remaining work for the next\n        release.\n\n这一份迁移检查报告说明了本次上线之前必须进一步确认的历史数据\n        校验结果。"
        let result = LineNormalizer.normalize(sample)
        XCTAssertNotEqual(result, sample)
        XCTAssertEqual(LineNormalizer.normalize(result), result)
    }
}
