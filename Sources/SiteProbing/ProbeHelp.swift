import AppKit

struct FieldHelp {
    let tip: String
    let detail: String
    let rule: HelpRule

    init(_ tip: String, _ detail: String, _ rule: HelpRule) {
        self.tip = tip
        self.detail = detail
        self.rule = rule
    }
}

enum HelpField: String, CaseIterable {
    case global = "探测总开关", siteEnabled = "站点启用", name = "名称", address = "HTTPS 地址"
    case method = "请求方法", codes = "成功状态码", laneEnabled = "类型启用", type = "探测类型"
    case host = "TCP 主机", port = "TCP 端口"
    case intensity = "探测强度"
    case interval = "发起间隔", warning = "告警时间", cutoff = "截止时间", capacity = "并发", traffic = "预计流量"

    var help: FieldHelp {
        switch self {
        case .global:
            return FieldHelp("暂停或恢复所有站点的探测，网速读数继续更新。",
                             "恢复时继续探测之前勾选的站点。关闭期间仍可编辑站点并查看开启后的预计流量。", .history)
        case .siteEnabled:
            return FieldHelp("勾选后探测这个站点。暂停会保留本站的参数。",
                             "每个启用的站点至少要开启一种探测类型。在菜单中勾选后立即保存。", .history)
        case .name:
            return FieldHelp("给站点起一个容易辨认的名字。留空会使用主机名。",
                             "例如给工作服务取名「办公入口」，悬停时就能找到它。仅改名称会保留近期结果。", .history)
        case .address:
            return FieldHelp("填写主机名或 HTTPS 地址，例如 example.com/health。省略协议时使用 HTTPS。",
                             "可包含路径和查询参数。请去掉网址中的账号、密码和 # 后的页面锚点。", .history)
        case .host:
            return FieldHelp("填写服务的主机名或 IP 地址，例如 nas。", "优先直连，按 Mac 当前的名称解析和路由连接目标。访问 Tailscale 设备时，可填写 Finder 使用的主机名。", .history)
        case .port:
            return FieldHelp("填写 1–65535 的服务端口，例如 SMB 使用 445。", "每次新建 TCP 连接，成功后立即关闭。此探测无需登录；共享目录的访问权限需在 Finder 中验证。", .success)
        case .method:
            return FieldHelp("HEAD 请求响应头。选 GET 时，收到响应头即可判定结果。",
                             "复用与新建共用此设置。自定义站点默认使用 HEAD。如果服务只支持 GET，可以在这里切换。", .history)
        case .codes:
            return FieldHelp("填入哪些 HTTP 状态码算成功。留空接受所有 2xx 响应。",
                             "例如填 2xx, 405，收到 204 或 405 都算成功。可填 200–599 中的单码，或 2xx–5xx 中的一类，用逗号分开。", .success)
        case .laneEnabled:
            return FieldHelp("开启这一类探测。关闭后参数会保留，这一类的预计流量归零。",
                             "可单独打开复用或新建，也可同时开启，分别观察已有连接和重新建立连接时的响应。", .colors)
        case .type:
            return FieldHelp("复用会优先使用已有连接。新建每次都建立独立连接。",
                             "复用探测遇到慢告警、状态码不符、连接错误或超时，后续请求会换连接。已经发出的请求仍按各自的截止时间等待。", .cost)
        case .intensity:
            return FieldHelp("在站点子菜单选择探测强度，选择后立即生效。", "个人强度只属于本站的这一种方式。从模板创建后保存，再到菜单选用。编辑使用中的个人强度，保存后更新运行参数。", .history)
        case .interval:
            return FieldHelp("从这一次实际发出请求起，隔多少秒再尝试发下一条。", "有空位时按间隔发起，满额时等待释放。间隔越短，8 小时发出的请求越多。", .schedule)
        case .warning:
            return FieldHelp("达到提醒时间后更新颜色，请求继续等到截止。", "内置强度均在 5 秒提醒。复用连接变慢时后续请求会换连接。", .colors)
        case .cutoff:
            return FieldHelp("一条请求最多等待的秒数，到点计为超时。", "内置复用等待 8 秒，新建等待 10 秒。个人强度的截止须大于或等于提醒。", .colors)
        case .capacity:
            return FieldHelp("这一类最多能同时有几条请求在途。名额满时，下一轮会等到有空位再发。",
                             "填写正整数。内置强度中，只有新建快速允许 2 条在途，其他强度为 1 条。正在取消的请求会占用名额，直到连接释放。", .schedule)
        case .traffic:
            return FieldHelp("按连续运行 8 小时估算探测次数，流量仅估算 HTTPS。",
                             "满额等待或睡眠会减少请求数。复用遇到重连时流量会增加。配置窗口合计只纳入已勾选站点开启的方式。", .cost)
        }
    }

    func tip(for lane: ProbeLane? = nil, readOnly: Bool = false) -> String {
        let text: String
        switch (self, lane) {
        case (.type, .daily): text = "优先使用已有连接。遇到慢告警或失败后，后续请求会换一条连接。"
        case (.type, .fresh): text = "每次都建立独立连接，可观察重新建连时的响应。"
        default: text = help.tip
        }
        return readOnly ? text + " 内置站点的此项固定。" : text
    }

    @MainActor
    func attach(to view: NSView, lane: ProbeLane? = nil, readOnly: Bool = false) {
        let text = tip(for: lane, readOnly: readOnly)
        view.toolTip = text
        view.setAccessibilityHelp(text)
    }
}

enum HelpRule: String, CaseIterable {
    case schedule = "为什么下一轮延后了？"
    case colors = "告警后还能算成功吗？"
    case success = "为什么红点旁边仍是 100%？"
    case cost = "为什么复用也有握手流量？"
    case history = "哪些改动会重新统计？"

    var summary: String {
        switch self {
        case .schedule: "间隔决定何时尝试发起，并发决定是否有空位。满额时只保留一次待发机会，释放名额后发出一条，再从那一刻计时。"
        case .colors: "可以。告警后、截止前收到预期 HTTPS 状态码或建立 TCP 连接，仍计为成功，耗时显示为橙色。表中「复用」指两类都开启时的复用探测。"
        case .success: "圆点反映当前状态。成功率只统计最近 5 分钟已有最终结果的请求，左右分别是复用和新建。刚告警的请求还在等待，先前全部成功时仍会显示 100%。"
        case .cost: "流量按发起请求的类型归账。一次复用探测需要重新建连时，握手开销也记入复用列。"
        case .history: "每个站点的两类探测分别统计。菜单选择立即生效。配置窗口的修改在保存后生效。"
        }
    }

    var rows: [[String]] {
        switch self {
        case .schedule:
            let p = ProbeLane.daily.strengths[0].values.parameters()
            return [["示例", "间隔 \(p.interval) 秒，截止 \(p.cutoff) 秒，只有 1 个名额"],
                    ["第 0 秒", "发出第一条请求，占用一个名额。"],
                    ["第 \(p.interval) 秒", "第一条仍在等待，记下一次待发机会。"],
                    ["第 \(p.cutoff) 秒", "如果第一条一直无响应，到达截止时间。等取消完成、名额释放后，再发出一条。"]]
        case .colors:
            return [["请求结果", "复用", "仅开复用", "新建"], ["及时成功", "绿", "绿", "绿"],
                    ["告警后仍在等待", "橙", "橙", "红"], ["迟到成功", "橙", "橙", "橙"],
                    ["明确失败或超时", "橙", "红", "红"]]
        case .success:
            return [["近 5 分钟的请求", "如何计数"], ["7 次及时成功 ＋ 2 次迟到成功", "9 次成功"],
                    ["再有 1 次最终失败", "共完成 10 次"], ["成功率", "9 ÷ 10 = 90%"]]
        case .cost:
            return [["连接方式", "费用归入"], ["复用探测沿用已有连接", "复用列，按复用开销估算"],
                    ["复用探测重新握手", "复用列，按新建开销估算"], ["新建探测独立建连", "新建列，按新建开销估算"]]
        case .history:
            return [["发生的变化", "近期结果"], ["仅修改名称", "继续累计"],
                    ["修改一类的启用、时间或并发", "这一类重新统计"], ["修改地址、方法或成功状态码", "本站两类重新统计"],
                    ["重新启用、唤醒或系统网络／代理变化", "受影响的探测重新统计"]]
        }
    }

    var note: String {
        switch self {
        case .schedule:
            let slots = ProbeLane.daily.strengths[0].values.parameters().requiredCapacity.map { "本例需要 \($0) 个名额。" } ?? ""
            return "持续无响应时，维持节奏所需的名额是截止时间除以间隔、向上取整。" + slots + "较小的值也可以保存。"
        case .colors: return "站点圆点和菜单栏箭头优先显示最严重的颜色。较新的请求已有判断后，旧请求仍可计入成功率。"
        case .success: return "按得到最终结果的时间计数。主动取消和等待中的请求跳过。首个样本完成即显示。全部失败显示 0，全部成功显示 100。当前没有样本或该类关闭时显示 —。"
        case .cost: return "菜单和配置窗口按 8 小时估算。悬停面板按近期完成的请求估算每小时开销，观察不足 1 分钟时按间隔估算。"
        case .history: return "取消编辑会丢弃本次草稿。代理软件内部换出口，若系统没有发出网络变化通知，统计会继续。"
        }
    }
}
