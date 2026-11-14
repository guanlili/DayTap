import Foundation
import FoundationModels

/// 转写中心的结构化输出模型(#57 拆文件批次):@Generable 四件套 + 云端宽容解码 +
/// 聚合/对照的结果类型——全是文件级纯类型,与方法实现分离便于对照阅读。
/// (@Generable 宏要求类型非 private,故都在文件级。)

/// @Generable 的结构化输出(#35/#36/#29):一次模型调用产出 类别+短标题+摘要+待办。
/// 宏生成的 init 扩展要求类型非 private,故置于文件级。
@Generable
struct RecordingDigest {
    @Guide(description: "最贴切的类别,必须恰好是:会议、活动、灵感、日常、其他 五个词之一")
    var category: String
    @Guide(description: "内容短标题,不超过12个字,不要句号等结尾标点")
    var title: String
    @Guide(description: "内容摘要,不超过三句话")
    var summary: String
    @Guide(description: "录音里提到的待办事项,每条一句话;没有待办就给空列表")
    var actionItems: [String]
    @Guide(description: "与 actionItems 一一对应的截止时间数组,格式 yyyy-MM-dd HH:mm;把「周五下午」「下月1号」这类相对表述换算成具体日期,今天的日期在输入第一行给出,以它为基准;该条没有明确时间就给空字符串")
    var actionDeadlines: [String]
    @Guide(description: "与 actionItems 一一对应的方向数组:\"me\"=我答应别人的,\"other\"=别人答应我的;拿不准给 \"me\"")
    var actionDirections: [String]
    @Guide(description: "转写里明确提到的人名数组,只列真名或常用称呼,优先用背景段给过的规范写法;没提到给空列表")
    var people: [String]
}

/// @Generable 的块级结构化输出(#68):长录音分块摘要用,一次产出 章节标题+要点+待办。
@Generable
struct ChunkDigest {
    @Guide(description: "该片段的主题短标题,不超过8个字,不要句号等结尾标点")
    var sectionTitle: String
    @Guide(description: "该片段的要点,不超过两句话")
    var keyPoints: String
    @Guide(description: "片段里提到的待办事项,每条一句话;没有待办就给空列表")
    var actionItems: [String]
    @Guide(description: "与 actionItems 一一对应的截止时间数组,格式 yyyy-MM-dd HH:mm;把相对表述按输入第一行的今天换算成具体日期;没有明确时间就给空字符串")
    var actionDeadlines: [String]
    @Guide(description: "与 actionItems 一一对应的方向数组:\"me\"=我答应别人的,\"other\"=别人答应我的;拿不准给 \"me\"")
    var actionDirections: [String]
}

/// @Generable 的排程结构化输出(#80):平行数组口径与 #35 同款(嵌套结构体不赌宏的边角),
/// 配对与钳制在 DayAgenda.normalizedSuggestions,空标题先丢防左移(#62)。
@Generable
struct DayPlan {
    @Guide(description: "每条安排的标题,不超过12个字,无结尾标点")
    var titles: [String]
    @Guide(description: "与 titles 一一对应的理由,每条一句话")
    var reasons: [String]
    @Guide(description: "与 titles 一一对应的建议开始时刻,24小时制 HH:mm")
    var starts: [String]
    @Guide(description: "与 titles 一一对应的建议时长,分钟数")
    var minutes: [Int]
    @Guide(description: "与 titles 一一对应的类型:运动、专注、休息、复盘 之一")
    var kinds: [String]
}

/// 事的聚合结果(#78):现状+按时间的关键进展+未决待办;零实体,不落库。
struct AffairResult: Equatable {
    var status: String
    var highlights: [String]
    var openTodos: [String]
}

/// @Generable 的聚合结构化输出(#78)。
@Generable
struct AffairDigest {
    @Guide(description: "这件事的现状,不超过三句话")
    var status: String
    @Guide(description: "按时间排列的关键进展,每条一句话,可带日期;给 2 到 8 条")
    var highlights: [String]
    @Guide(description: "还没办完的事,每条一句话;没有给空列表")
    var openTodos: [String]
}

/// 云端 actionItems 的宽容解码(#61→#70):兼容旧裸串、新 {text,due,direction};
/// direction 只认 me/other,未知值解码后仍是 nil(呈现上视作 me)。
struct CloudAction: Decodable {
    var text: String?
    var due: String?
    var direction: String?

    init(from decoder: Decoder) throws {
        if let plain = try? decoder.singleValueContainer().decode(String.self) {
            text = plain
            due = nil
            direction = nil
            return
        }
        let container = try decoder.container(keyedBy: CodingKeys.self)
        text = try container.decodeIfPresent(String.self, forKey: .text)
        due = try container.decodeIfPresent(String.self, forKey: .due)
        direction = try? container.decodeIfPresent(String.self, forKey: .direction)
    }

    enum CodingKeys: String, CodingKey { case text, due, direction }
}
