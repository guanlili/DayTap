import SwiftUI

/// 传输详情 sheet(#45):主屏清空后,「传上去没有」的完整答案与两个操作都在这里。
/// 计数只读——待传/失败是索引实况,已确认是 WatchLink 的持久累计(确认即删让索引留不下);
/// 动作沿用 `WatchModel.retry()`/`discardPending()`,触觉与结果文案由模型层出,
/// 结果文案就地在操作下方显示,主屏不再承载(#44)。
struct TransferSheet: View {
    @ObservedObject var model: WatchModel
    @State private var confirmDiscard = false

    /// 与主屏角标同源(#46),失败行/原因沿用这枚橙。
    private let badgeOrange = Color(red: 255 / 255, green: 149 / 255, blue: 0 / 255)

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 5) {
                Text("传输")
                    .font(.headline)
                    .padding(.bottom, 3)

                countRow("待传", value: model.transferWaiting)
                if model.transferWaiting > 0 {
                    // 占用只挂在「待传」下(#45 边界:不新增第四个数字)。
                    Text(DayTapFormat.bytes(model.transferBytes))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                countRow("已确认", value: model.transferConfirmed)
                countRow("失败", value: model.transferFailed, highlighted: model.transferFailed > 0)

                Button("再传一次") {
                    model.retry()
                }
                .buttonStyle(.borderedProminent)
                .font(.caption)
                .accessibilityIdentifier("daytap.record.retry")

                Button {
                    confirmDiscard = true
                } label: {
                    Text("丢弃待传 (\(model.transferWaiting))")
                }
                .buttonStyle(.bordered)
                .tint(.red)
                .font(.caption)
                .accessibilityIdentifier("daytap.record.discard")

                if !model.status.isEmpty {
                    Text(model.status)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                }
                // 失败原因的完整表述只住在这里,主屏不承载(#46);无失败时这一行不存在。
                if model.transferFailed > 0, let error = model.transferError {
                    Text(error)
                        .font(.system(size: 11))
                        .foregroundStyle(badgeOrange)
                        .lineLimit(2)
                }
            }
            .padding(.horizontal, 4)
        }
        .alert("丢弃待传录音?", isPresented: $confirmDiscard) {
            Button("丢弃", role: .destructive) { model.discardPending() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("\(model.transferWaiting) 条不会传给 iPhone，手表上直接删除。")
        }
    }

    /// 一行一个计数(#45:并排成行,不是三张卡片),失败行点亮橙与角标呼应。
    private func countRow(_ label: String, value: Int, highlighted: Bool = false) -> some View {
        HStack {
            Text(label)
            Spacer()
            Text("\(value)")
                .monospacedDigit()
                .foregroundStyle(highlighted ? badgeOrange : Color.primary)
        }
        .font(.caption)
    }
}
