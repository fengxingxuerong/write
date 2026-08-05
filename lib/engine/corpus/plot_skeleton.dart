/// 情节节拍（章法节点）。
///
/// 一个 [PlotBeat] 表示章节推进中的一个阶段，[stage] 为阶段名（起/承/转/合等），
/// [hint] 为生成时的内容提示。引擎按骨架顺序组织段落，形成基本章法。
class PlotBeat {
  /// 阶段名（如 起、承、转、合）。
  final String stage;

  /// 内容提示。
  final String hint;

  /// 构造节拍。
  const PlotBeat(this.stage, this.hint);
}

/// 情节骨架集合。
///
/// 每个题材内置若干骨架（MVP 基线 ≥10 个），每个骨架是若干 [PlotBeat] 的有序列表。
/// 引擎随机选取一个骨架，按节拍分段生成，使正文具备段落与章法而非随机拼接。
class PlotSkeleton {
  /// 多条骨架（每条 = 若干节拍）。
  final List<List<PlotBeat>> skeletons;

  /// 构造骨架集合。
  const PlotSkeleton(this.skeletons);

  /// 按题材取内置骨架；未命中回退到玄幻。
  static PlotSkeleton forGenre(String genre) {
    return PlotSkeleton(_byGenre[genre] ?? _byGenre['xuanhuan']!);
  }

  static const Map<String, List<List<PlotBeat>>> _byGenre =
      <String, List<List<PlotBeat>>>{
    'xuanhuan': _xuanhuan,
    'dushi': _dushi,
    'kehuan': _kehuan,
    'yanqing': _yanqing,
    'xuanyi': _xuanyi,
    'xianxia': _xianxia,
    'lishi': _lishi,
    'game': _game,
    'jingsai': _jingsai,
    'kongbu': _kongbu,
  };

  // ---- 玄幻（10 骨架） ----
  static const List<List<PlotBeat>> _xuanhuan = <List<PlotBeat>>[
    [PlotBeat('起', '铺垫修炼世界的规则与主角微末处境'), PlotBeat('承', '一次奇遇让主角获得机缘'), PlotBeat('转', '遭遇强敌或瓶颈，心境蜕变'), PlotBeat('合', '小有突破并埋下宗门暗流')],
    [PlotBeat('起', '宗门测评为引，凸显主角资质'), PlotBeat('承', '秘境开启，主角误入禁地'), PlotBeat('转', '古碑传承觉醒，实力跃迁'), PlotBeat('合', '携宝归来却惹来觊觎')],
    [PlotBeat('起', '主角受辱，立下变强之志'), PlotBeat('承', '偶遇隐世高人指点'), PlotBeat('转', '比武台上以弱胜强'), PlotBeat('合', '声名初显，宿敌现身')],
    [PlotBeat('起', '家族衰败，主角临危受命'), PlotBeat('承', '祖地秘藏现世'), PlotBeat('转', '血脉觉醒引动天地异象'), PlotBeat('合', '重振家声，暗敌环伺')],
    [PlotBeat('起', '凡人少年向往仙途'), PlotBeat('承', '以杂役之身窥见道法'), PlotBeat('转', '生死之间悟出本心'), PlotBeat('合', '被名门收为记名弟子')],
    [PlotBeat('起', '妖兽袭村，主角仓皇逃命'), PlotBeat('承', '避入洞天得妖丹'), PlotBeat('转', '人妖之辨令其迟疑'), PlotBeat('合', '携妖丹踏上复仇路')],
    [PlotBeat('起', '拍卖会上惊现残图'), PlotBeat('承', '主角识破图中玄机'), PlotBeat('转', '各方势力争夺，险象环生'), PlotBeat('合', '夺图而出，循迹探秘')],
    [PlotBeat('起', '同门相残，主角蒙冤'), PlotBeat('承', '坠崖未死反得造化'), PlotBeat('转', '查明真相却难昭雪'), PlotBeat('合', '隐忍蓄力待翻身')],
    [PlotBeat('起', '上古封印松动，邪祟外溢'), PlotBeat('承', '主角奉命镇守边关'), PlotBeat('转', '以身为阵暂封裂隙'), PlotBeat('合', '功成身退却失了修为')],
    [PlotBeat('起', '主角天生废脉被嘲笑'), PlotBeat('承', '误服异果重铸经脉'), PlotBeat('转', '一夜破境震惊四座'), PlotBeat('合', '旧日嘲者纷纷改颜')],
  ];

  // ---- 仙侠（10 骨架） ----
  static const List<List<PlotBeat>> _xianxia = <List<PlotBeat>>[
    [PlotBeat('起', '凡间少年偶遇仙缘'), PlotBeat('承', '拜入仙门从杂役做起'), PlotBeat('转', '悟道破境却遭同门忌惮'), PlotBeat('合', '下山历练初显锋芒')],
    [PlotBeat('起', '剑修一脉凋零'), PlotBeat('承', '主角得古剑传承'), PlotBeat('转', '剑心蒙尘后的重铸'), PlotBeat('合', '一剑惊动剑冢')],
    [PlotBeat('起', '仙门大比前夕'), PlotBeat('承', '秘境试炼暗藏杀机'), PlotBeat('转', '以智破局救下同门'), PlotBeat('合', '名动仙门却引暗流')],
    [PlotBeat('起', '凡尘情缘未了'), PlotBeat('承', '红尘历练再遇故人'), PlotBeat('转', '仙凡之别的抉择'), PlotBeat('合', '携手上九天')],
    [PlotBeat('起', '丹修少女的日常'), PlotBeat('承', '一炉失传丹药现世'), PlotBeat('转', '各方觊觎暗流涌动'), PlotBeat('合', '丹道问鼎扬名')],
    [PlotBeat('起', '魔道余孽作乱'), PlotBeat('承', '主角临危受命除魔'), PlotBeat('转', '身陷魔窟识破阴谋'), PlotBeat('合', '正邪之辨的沉思')],
    [PlotBeat('起', '散修摸爬滚打'), PlotBeat('承', '古遗迹中九死一生'), PlotBeat('转', '夺宝却惹上强敌'), PlotBeat('合', '隐姓埋名待崛起')],
    [PlotBeat('起', '仙途孤寂求道'), PlotBeat('承', '于天地间寻道'), PlotBeat('转', '大道之争的取舍'), PlotBeat('合', '得道却不失本心')],
    [PlotBeat('起', '轮回转世之谜'), PlotBeat('承', '前世记忆片段浮现'), PlotBeat('转', '因果纠缠难解'), PlotBeat('合', '超脱轮回重写命运')],
    [PlotBeat('起', '山门封印松动'), PlotBeat('承', '主角奉命镇守'), PlotBeat('转', '以血为引加固封印'), PlotBeat('合', '功成身退隐于山林')],
  ];

  // ---- 历史（10 骨架） ----
  static const List<List<PlotBeat>> _lishi = <List<PlotBeat>>[
    [PlotBeat('起', '乱世小民的挣扎'), PlotBeat('承', '投军从戎立下军功'), PlotBeat('转', '庙堂与沙场的抉择'), PlotBeat('合', '功成身退守一方平安')],
    [PlotBeat('起', '寒门学子进京赶考'), PlotBeat('承', '科场舞弊牵连入狱'), PlotBeat('转', '昭雪平冤得见天日'), PlotBeat('合', '金榜题名初入朝堂')],
    [PlotBeat('起', '边关烽烟再起'), PlotBeat('承', '孤军守城的绝境'), PlotBeat('转', '以奇计破敌解围'), PlotBeat('合', '凯旋受赏却见朝堂暗流')],
    [PlotBeat('起', '商贾之子的经营'), PlotBeat('承', '打通商路遇劫匪'), PlotBeat('转', '化险为夷声名鹊起'), PlotBeat('合', '富可敌国却忧国事')],
    [PlotBeat('起', '世家联姻的权谋'), PlotBeat('承', '新旧势力角力'), PlotBeat('转', '家族存亡一线'), PlotBeat('合', '以退为进保全家业')],
    [PlotBeat('起', '匠人之技传世'), PlotBeat('承', '绝技引来杀身之祸'), PlotBeat('转', '献技朝廷化解危机'), PlotBeat('合', '技艺流芳百世')],
    [PlotBeat('起', '太医署的日常'), PlotBeat('承', '疫病悄然蔓延'), PlotBeat('转', '以医者仁心救万民'), PlotBeat('合', '青史留名却淡泊如初')],
    [PlotBeat('起', '江湖侠客入庙堂'), PlotBeat('承', '卷入皇权之争'), PlotBeat('转', '剑指奸佞救社稷'), PlotBeat('合', '事了拂衣去')],
    [PlotBeat('起', '和亲路上的变故'), PlotBeat('承', '使团遇袭公主蒙难'), PlotBeat('转', '舍身护驾扭转危局'), PlotBeat('合', '和约达成归途漫漫')],
    [PlotBeat('起', '史官秉笔直书'), PlotBeat('承', '权贵施压欲改史'), PlotBeat('转', '以命护史骨气凛然'), PlotBeat('合', '青史不欺后人')],
  ];

  // ---- 游戏/无限流（10 骨架） ----
  static const List<List<PlotBeat>> _game = <List<PlotBeat>>[
    [PlotBeat('起', '误入全息游戏世界'), PlotBeat('承', '新手村隐藏任务'), PlotBeat('转', '首杀 BOSS 一战成名'), PlotBeat('合', 'PVP 之王惹来强敌')],
    [PlotBeat('起', '封测玩家的优势'), PlotBeat('承', '抢占稀有资源'), PlotBeat('转', '公会战一触即发'), PlotBeat('合', '建立自己的势力')],
    [PlotBeat('起', '副本开荒连败'), PlotBeat('承', '研究机制找到破绽'), PlotBeat('转', '极限操作翻盘'), PlotBeat('合', '全服首杀载入史册')],
    [PlotBeat('起', '氪金大佬的觉悟'), PlotBeat('承', '弃氪转肝的转变'), PlotBeat('转', '技术流逆袭钞能力'), PlotBeat('合', '实力赢得尊重')],
    [PlotBeat('起', '游戏 NPC 觉醒'), PlotBeat('承', '发现世界真相'), PlotBeat('转', '玩家与 NPC 的立场冲突'), PlotBeat('合', '改写游戏命运')],
    [PlotBeat('起', '无限流副本开启'), PlotBeat('承', '第一个死亡任务'), PlotBeat('转', '规则漏洞破局'), PlotBeat('合', '通关奖励与新的谜题')],
    [PlotBeat('起', '电竞选手的日常'), PlotBeat('承', '版本更迭被迫转型'), PlotBeat('转', '苦练新打法'), PlotBeat('合', '世界赛舞台证明自己')],
    [PlotBeat('起', '休闲玩家遇大佬'), PlotBeat('承', '被带飞后自立'), PlotBeat('转', '技术突飞猛进'), PlotBeat('合', '成为新一代大神')],
    [PlotBeat('起', '游戏币与现实交易'), PlotBeat('承', '黑市暗流涌动'), PlotBeat('转', '被卷入现实纷争'), PlotBeat('合', '守住游戏世界的纯粹')],
    [PlotBeat('起', '全服停服前夜'), PlotBeat('承', '玩家集体告别'), PlotBeat('转', '最后的攻城战'), PlotBeat('合', '青春散场各奔前程')],
  ];

  // ---- 竞技（10 骨架） ----
  static const List<List<PlotBeat>> _jingsai = <List<PlotBeat>>[
    [PlotBeat('起', '替补队员的等待'), PlotBeat('承', '主力受伤临危受命'), PlotBeat('转', '关键时刻力挽狂澜'), PlotBeat('合', '站稳主力位置')],
    [PlotBeat('起', '伤愈复出的挣扎'), PlotBeat('承', '状态低迷遭质疑'), PlotBeat('转', '心理重建找回手感'), PlotBeat('合', '重回巅峰')],
    [PlotBeat('起', '青训营的残酷竞争'), PlotBeat('承', '淘汰边缘的逆袭'), PlotBeat('转', '教练的指点与信任'), PlotBeat('合', '拿到职业合同')],
    [PlotBeat('起', '老将的最后赛季'), PlotBeat('承', '带伤坚持的执念'), PlotBeat('转', '年轻队员的成长'), PlotBeat('合', '传承与告别')],
    [PlotBeat('起', '草根球队的奇迹'), PlotBeat('承', '一路爆冷晋级'), PlotBeat('转', '半决赛的生死战'), PlotBeat('合', '虽败犹荣的敬意')],
    [PlotBeat('起', '个人项目的孤军奋战'), PlotBeat('承', '训练瓶颈期的迷茫'), PlotBeat('转', '突破极限的一跃'), PlotBeat('合', '站上领奖台')],
    [PlotBeat('起', '电竞战队的重组'), PlotBeat('承', '新老队员磨合阵痛'), PlotBeat('转', '关键比赛的信任危机'), PlotBeat('合', '团队精神的胜利')],
    [PlotBeat('起', '天赋与努力之争'), PlotBeat('承', '天才对手的压制'), PlotBeat('转', '笨办法练出绝招'), PlotBeat('合', '以勤补拙的逆袭')],
    [PlotBeat('起', '退役教练的复出'), PlotBeat('承', '执教濒临降级的队伍'), PlotBeat('转', '战术革新激活全队'), PlotBeat('合', '保级成功创造奇迹')],
    [PlotBeat('起', '校园联赛的荣耀'), PlotBeat('承', '同学间的竞争与友谊'), PlotBeat('转', '决赛的巅峰对决'), PlotBeat('合', '青春无悔的谢幕')],
  ];

  // ---- 恐怖（10 骨架） ----
  static const List<List<PlotBeat>> _kongbu = <List<PlotBeat>>[
    [PlotBeat('起', '夜半老宅的异响'), PlotBeat('承', '第一次看见不该看的东西'), PlotBeat('转', '真相是活人作祟'), PlotBeat('合', '人比鬼更可怕')],
    [PlotBeat('起', '废弃医院的传闻'), PlotBeat('承', '探险队深入其中'), PlotBeat('转', '同伴接连失踪'), PlotBeat('合', '唯一的幸存者')],
    [PlotBeat('起', '村口祠堂的禁忌'), PlotBeat('承', '误触禁忌的惩罚'), PlotBeat('转', '旧事被一层层揭开'), PlotBeat('合', '赎罪与解脱')],
    [PlotBeat('起', '夜班公交的乘客'), PlotBeat('承', '到站没人下车'), PlotBeat('转', '司机发现乘客不是人'), PlotBeat('合', '黎明前的终点')],
    [PlotBeat('起', '镜中的自己会动'), PlotBeat('承', '镜像开始模仿'), PlotBeat('转', '镜子里的世界入侵现实'), PlotBeat('合', '打破镜子的代价')],
    [PlotBeat('起', '老式手机的神秘来电'), PlotBeat('承', '来电预告死亡'), PlotBeat('转', '试图改变命运'), PlotBeat('合', '来电来自未来')],
    [PlotBeat('起', '雨夜民宿的借宿'), PlotBeat('承', '主人家的古怪规矩'), PlotBeat('转', '发现屋里有另一个自己'), PlotBeat('合', '逃出生天')],
    [PlotBeat('起', '祖传遗物的诅咒'), PlotBeat('承', '诅咒应验的征兆'), PlotBeat('转', '寻找破解之法'), PlotBeat('合', '代价惨重的真相')],
    [PlotBeat('起', '小镇连环失踪案'), PlotBeat('承', '幸存者的呓语'), PlotBeat('转', '调查触及禁忌之地'), PlotBeat('合', '失踪者从未离开')],
    [PlotBeat('起', '最后一通求救电话'), PlotBeat('承', '声音是多年以前的自己'), PlotBeat('转', '穿越时间线的营救'), PlotBeat('合', '改变过去却改变了自己')],
  ];

  // ---- 都市（10 骨架） ----
  static const List<List<PlotBeat>> _dushi = <List<PlotBeat>>[
    [PlotBeat('起', '平凡职场人的一天'), PlotBeat('承', '一次意外机遇降临'), PlotBeat('转', '主角在取舍中成长'), PlotBeat('合', '阶段成果与温情落点')],
    [PlotBeat('起', '房租与生活的重压'), PlotBeat('承', '兼职中显露才华'), PlotBeat('转', '被伯乐看中却要弃旧业'), PlotBeat('合', '遵从内心做出选择')],
    [PlotBeat('起', '相亲场合的尴尬相遇'), PlotBeat('承', '误会与笑料交织'), PlotBeat('转', '危机中见对方真心'), PlotBeat('合', '关系悄然升温')],
    [PlotBeat('起', '小店经营惨淡'), PlotBeat('承', '一句点评点醒主角'), PlotBeat('转', '改良口碑逆袭'), PlotBeat('合', '老街坊共度难关')],
    [PlotBeat('起', '职场新人频出纰漏'), PlotBeat('承', '前辈暗中提携'), PlotBeat('转', '关键项目力挽狂澜'), PlotBeat('合', '获得认可与自省')],
    [PlotBeat('起', '旧友重逢各奔前程'), PlotBeat('承', '合作中理念冲突'), PlotBeat('转', '坦诚化解隔阂'), PlotBeat('合', '携手再出发')],
    [PlotBeat('起', '深夜便利店的偶遇'), PlotBeat('承', '陌生人倾诉心事'), PlotBeat('转', '主角被触动而行动'), PlotBeat('合', '城市里微小的善意')],
    [PlotBeat('起', '创业受挫负债'), PlotBeat('承', '误打误撞抓到痛点'), PlotBeat('转', '熬过至暗时刻'), PlotBeat('合', '柳暗花明')],
    [PlotBeat('起', '家庭聚会的暗流'), PlotBeat('承', '旧事被翻出'), PlotBeat('转', '主角出面斡旋'), PlotBeat('合', '和解与释然')],
    [PlotBeat('起', '通勤路上的观察'), PlotBeat('承', '偶发善举被记录'), PlotBeat('转', '网络关注带来困扰'), PlotBeat('合', '回归本心的生活')],
  ];

  // ---- 科幻（10 骨架） ----
  static const List<List<PlotBeat>> _kehuan = <List<PlotBeat>>[
    [PlotBeat('起', '未来世界的科技日常'), PlotBeat('承', '异常信号打破秩序'), PlotBeat('转', '探索揭示惊人真相'), PlotBeat('合', '文明尺度的抉择')],
    [PlotBeat('起', '空间站例行巡检'), PlotBeat('承', '发现不明残骸'), PlotBeat('转', '残骸中的信息与抉择'), PlotBeat('合', '向地球发回警示')],
    [PlotBeat('起', 'AI 觉醒自我意识'), PlotBeat('承', '它与人类对话试探'), PlotBeat('转', '价值观冲突爆发'), PlotBeat('合', '共生还是隔离')],
    [PlotBeat('起', '气候崩溃后的城市'), PlotBeat('承', '地下城发现古设备'), PlotBeat('转', '重启引发争议'), PlotBeat('合', '希望与代价并存')],
    [PlotBeat('起', '时间实验初获成功'), PlotBeat('承', '悖论悄然出现'), PlotBeat('转', '主角陷于因果漩涡'), PlotBeat('合', '归还秩序的选择')],
    [PlotBeat('起', '星际航行休眠苏醒'), PlotBeat('承', '舰载系统已失控'), PlotBeat('转', '孤身修复航向'), PlotBeat('合', '抵达与新生的隐喻')],
    [PlotBeat('起', '记忆可移植的社会'), PlotBeat('承', '主角记忆被篡改'), PlotBeat('转', '追寻真实自我'), PlotBeat('合', '何为「我」的诘问')],
    [PlotBeat('起', '外星信标被破译'), PlotBeat('承', '人类分裂为两派'), PlotBeat('转', '接触前的最后博弈'), PlotBeat('合', '沉默的宇宙回响')],
    [PlotBeat('起', '纳米瘟疫蔓延'), PlotBeat('承', '唯一免疫者出现'), PlotBeat('转', '拯救与伦理拉锯'), PlotBeat('合', '新生纪元的开端')],
    [PlotBeat('起', '虚拟世界与现实交错'), PlotBeat('承', '主角疑是代码'), PlotBeat('转', '跳出层层的真相'), PlotBeat('合', '存在意义的回响')],
  ];

  // ---- 言情（10 骨架） ----
  static const List<List<PlotBeat>> _yanqing = <List<PlotBeat>>[
    [PlotBeat('起', '雨中初遇的惊鸿一瞥'), PlotBeat('承', '误会频频却心生好奇'), PlotBeat('转', '患难见真情'), PlotBeat('合', '相视而笑的默契')],
    [PlotBeat('起', '青梅竹马的别扭'), PlotBeat('承', '分别后的牵挂'), PlotBeat('转', '重逢物是人非'), PlotBeat('合', '迟来的告白')],
    [PlotBeat('起', '契约关系的开端'), PlotBeat('承', '相处中棱角被磨平'), PlotBeat('转', '假戏渐生真情'), PlotBeat('合', '卸下伪装相拥')],
    [PlotBeat('起', '暗恋者的默默守候'), PlotBeat('承', '对方遭遇低谷'), PlotBeat('转', '陪伴胜过千言'), PlotBeat('合', '被看见的温柔')],
    [PlotBeat('起', '错位身份的同游'), PlotBeat('承', '一路风景与心事'), PlotBeat('转', '离别在即的慌张'), PlotBeat('合', '回头奔赴彼此')],
    [PlotBeat('起', '家族联姻的抵触'), PlotBeat('承', '相互试探底线'), PlotBeat('转', '危机中放下成见'), PlotBeat('合', '棋逢对手的动心')],
    [PlotBeat('起', '旧爱结婚的请柬'), PlotBeat('承', '故地重游的酸涩'), PlotBeat('转', '新人的陪伴治愈'), PlotBeat('合', '与过去和解')],
    [PlotBeat('起', '校园里的并肩'), PlotBeat('承', '梦想与现实的拉扯'), PlotBeat('转', '为对方勇敢一次'), PlotBeat('合', '青春不负相遇')],
    [PlotBeat('起', '误会造成的疏远'), PlotBeat('承', '真相迟到地揭开'), PlotBeat('转', '弥补与等待'), PlotBeat('合', '破镜后的珍惜')],
    [PlotBeat('起', '异乡漂泊的依偎'), PlotBeat('承', '柴米中的小确幸'), PlotBeat('转', '现实风浪来袭'), PlotBeat('合', '握紧的手不放')],
  ];

  // ---- 悬疑（10 骨架） ----
  static const List<List<PlotBeat>> _xuanyi = <List<PlotBeat>>[
    [PlotBeat('起', '离奇命案现场'), PlotBeat('承', '第一处反常线索'), PlotBeat('转', '嫌疑人逐一洗清'), PlotBeat('合', '真相反转落定')],
    [PlotBeat('起', '失踪者最后的足迹'), PlotBeat('承', '监控里的空白'), PlotBeat('转', '旧案牵连浮现'), PlotBeat('合', '迟到的正义')],
    [PlotBeat('起', '古宅深夜的异响'), PlotBeat('承', '族谱里的隐秘'), PlotBeat('转', '活人伪装被揭'), PlotBeat('合', '尘封真相收束')],
    [PlotBeat('起', '匿名信指向旧事'), PlotBeat('承', '主角被卷入旋涡'), PlotBeat('转', '记忆拼图错位'), PlotBeat('合', '自我设局的反噬')],
    [PlotBeat('起', '连环手法雷同'), PlotBeat('承', '侧写锁定画像'), PlotBeat('转', '猎人与猎物互换'), PlotBeat('合', '收网与余悸')],
    [PlotBeat('起', '密室里的遗书'), PlotBeat('承', '时间戳露出破绽'), PlotBeat('转', '共犯浮出水面'), PlotBeat('合', '沉默者的供词')],
    [PlotBeat('起', '列车上的陌生人'), PlotBeat('承', '到站少了一人'), PlotBeat('转', '身份层层剥开'), PlotBeat('合', '终点站的真相')],
    [PlotBeat('起', '日记里的预言'), PlotBeat('承', '预言接连应验'), PlotBeat('转', '人为布局被识'), PlotBeat('合', '操纵者的动机')],
    [PlotBeat('起', '孤岛聚会邀约'), PlotBeat('承', '一人离奇暴毙'), PlotBeat('转', '每人皆有秘密'), PlotBeat('合', '举报信揭凶')],
    [PlotBeat('起', '旧照片中的孩童'), PlotBeat('承', '寻人牵出命案'), PlotBeat('转', '血缘迷雾散开'), PlotBeat('合', '迟来相认的代价')],
  ];
}
